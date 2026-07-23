-- OnlySwap — initial schema (revision 2)
--
-- Two ideas carry the whole security model:
--   1. every row knows its university, and RLS enforces isolation at the database
--   2. real identity lives in a table the client can never read
--
-- Revision 2 closes the holes found in the schema review. The three that mattered:
--   * grant_tokens was SECURITY DEFINER and callable by any client (Postgres grants
--     EXECUTE to PUBLIC by default; Supabase exposes public-schema functions as RPC).
--     Section 11 now revokes EXECUTE from every function and re-grants only where a
--     client is genuinely meant to call it. Read section 11 before adding a function.
--   * profiles was fully client-updatable, so a user could mint tokens, forge a rating,
--     or change university_id and hop campuses. Now column-grant restricted AND
--     trigger-guarded (section 10).
--   * conversations.listing_id was ON DELETE SET NULL under a CHECK that forbade null,
--     which made deleting any listing with a conversation impossible.
--
-- Run as one migration. Read section 8 before changing any policy.

-- ============================================================
-- 1. Enums
-- ============================================================

create type listing_status  as enum ('active','pending','sold','removed');
create type item_condition  as enum ('new','like_new','good','fair','parts');
create type bid_status      as enum ('pending','accepted','rejected','withdrawn');
create type swipe_direction as enum ('left','right');
create type report_status   as enum ('open','reviewing','actioned','dismissed');
create type account_status  as enum ('active','suspended','deleted');

-- was free text. Free text meant a typo silently created a new token kind, and the
-- prize thresholds are computed off it.
create type token_kind as enum (
  'listing_created',
  'sale_completed',
  'five_star',
  'admin_adjustment'
);

-- ============================================================
-- 2. Tenancy + identity
-- ============================================================

create table universities (
  id           uuid primary key default gen_random_uuid(),
  name         text not null,
  email_domain text not null unique,   -- 'case.edu'
  -- is_active is the ONLY campus gate. There is no campus env var; a build must never
  -- need to change to add or retire a school.
  is_active    boolean not null default true,
  -- App Review campus. See BUILD_PLAN Phase 3. A demo university is a real row with a
  -- real domain we control, flagged so it can be excluded from analytics and so its
  -- seeded content never leaks into a real campus deck.
  is_demo      boolean not null default false,
  created_at   timestamptz not null default now()
);

-- PRIVATE. RLS enabled, zero policies. No client can read this under any circumstance.
-- The service role bypasses RLS, which is how the admin panel reads it.
create table user_identities (
  id            uuid primary key references auth.users(id) on delete cascade,
  university_id uuid not null references universities(id),
  -- nullable because account deletion scrubs PII in place rather than deleting the row
  -- (see section 9, delete_my_account). Deleting the row would orphan the status gate
  -- and let a "deleted" account keep browsing.
  email         text unique,
  first_name    text,        -- captured at signup; surfaced ONLY via mutual reveal
  legal_name    text,
  phone         text,
  status        account_status not null default 'active',
  is_admin      boolean not null default false,
  deleted_at    timestamptz,
  created_at    timestamptz not null default now()
);

create index on user_identities (university_id, status);

-- PUBLIC within a university. This is the only face other users ever see.
create table profiles (
  id            uuid primary key references auth.users(id) on delete cascade,
  university_id uuid not null references universities(id),
  handle        text not null,                 -- 'quiet-otter'
  plate         text not null,                 -- two-letter locker plate, e.g. 'QO'
  plate_color   text not null,
  avatar_key    text,                          -- R2 object key, nullable
  rating_avg    numeric(3,2),
  rating_count  integer not null default 0,
  tokens        integer not null default 0,    -- cached sum of token_events; server-only
  deleted_at    timestamptz,
  created_at    timestamptz not null default now(),
  -- was globally unique, which meant campus two would start with a namespace already
  -- eaten by campus one. Handles only need to be unique to the people who can see them.
  unique (university_id, handle)
);

-- ============================================================
-- 3. Helpers — the functions every policy is built on
-- ============================================================

-- Returns null for: no profile yet, suspended, or deleted. Because every policy keys off
-- this, a suspended or deleted account loses read access to everything in one place.
-- This is also what makes BUILD_PLAN Phase 11's "suspend a user and confirm they are
-- locked out" true by construction rather than by remembering to check it per screen.
create or replace function current_university_id()
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select p.university_id
  from profiles p
  join user_identities ui on ui.id = p.id
  where p.id = (select auth.uid())
    and ui.status = 'active'
    and p.deleted_at is null;
$$;

create or replace function is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select ui.is_admin from user_identities ui
      where ui.id = (select auth.uid()) and ui.status = 'active'),
    false);
$$;

-- Suspension / deletion gate for policies that are scoped by auth.uid() alone. Those
-- policies never touch current_university_id(), so without this a suspended user keeps
-- full access to their own conversations, messages, bids, blocks, and ledger — and,
-- worst of all, can still SEND messages. Single source of truth: it derives from
-- current_university_id(), which already returns null for suspended and deleted accounts.
create or replace function is_active_account()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select current_university_id() is not null;
$$;

-- The client cannot read user_identities, so it has no way to tell a suspended account
-- from an account whose campus simply has no data. Session bootstrap needs to know the
-- difference to show the suspended-account screen instead of an empty app. Returns
-- 'active' | 'suspended' | 'deleted', or null when no identity row exists yet.
create or replace function my_account_status()
returns text
language sql
stable
security definer
set search_path = public
as $$
  select status::text from user_identities where id = (select auth.uid());
$$;

-- is_blocked_between() is the fourth helper, but it is defined in section 5 — a SQL
-- function body is validated at creation time and it references blocks, which does not
-- exist yet here.

-- ============================================================
-- 4. Marketplace
-- ============================================================

create table listings (
  id              uuid primary key default gen_random_uuid(),
  university_id   uuid not null references universities(id),
  seller_id       uuid not null references profiles(id) on delete cascade,
  title           text not null check (char_length(title) between 1 and 80),
  description     text check (char_length(description) <= 1000),
  price_cents     integer not null check (price_cents >= 0),
  condition       item_condition not null,
  meetup_location text,
  status          listing_status not null default 'active',
  sold_at         timestamptz,
  -- Left-swipe hiding is permanent. A listing returns to a deck it was dismissed from
  -- only when bumped_at moves — a price DROP always bumps; a material edit bumps at most
  -- once per 24h. Both rules live in on_listing_updated(). The cooldown exists so a
  -- seller cannot churn edits to re-enter every deck on campus.
  bumped_at       timestamptz not null default now(),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

create table listing_images (
  id         uuid primary key default gen_random_uuid(),
  listing_id uuid not null references listings(id) on delete cascade,
  r2_key     text not null,          -- full image
  thumb_key  text not null,          -- 300px
  position   smallint not null default 0,
  unique (listing_id, position)      -- was absent; duplicate positions = nondeterministic order
);

-- "I need X" bulletin board. v1 is post + browse only: there is no conversation from a
-- request, and therefore no buyer/seller role inversion anywhere in the schema. The CTA
-- on a request is "Post a listing", prefilled. Conversations-from-requests is v1.1.
create table requests (
  id            uuid primary key default gen_random_uuid(),
  university_id uuid not null references universities(id),
  author_id     uuid not null references profiles(id) on delete cascade,
  title         text not null check (char_length(title) between 1 and 80),
  description   text check (char_length(description) <= 500),
  budget_cents  integer check (budget_cents >= 0),
  is_open       boolean not null default true,
  created_at    timestamptz not null default now()
);

create table swipes (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references profiles(id) on delete cascade,
  listing_id uuid not null references listings(id) on delete cascade,
  direction  swipe_direction not null,
  created_at timestamptz not null default now(),
  -- A resurfaced listing can be swiped again, so the client MUST upsert:
  --   on conflict (user_id, listing_id)
  --   do update set direction = excluded.direction, created_at = now()
  -- A plain insert will fail the second time. See CLAUDE.md section 3.
  unique (user_id, listing_id)
);

-- Bids are append-only. Re-bidding inserts a new row and withdraws the previous one
-- (place_bid does both atomically) rather than overwriting in place, so there is a real
-- history to show an admin when two students dispute what was agreed.
create table bids (
  id            uuid primary key default gen_random_uuid(),
  listing_id    uuid not null references listings(id) on delete cascade,
  buyer_id      uuid not null references profiles(id) on delete cascade,
  amount_cents  integer not null check (amount_cents > 0),
  status        bid_status not null default 'pending',
  superseded_by uuid references bids(id),   -- set on the old row when a buyer re-bids
  created_at    timestamptz not null default now()
);

-- one LIVE bid per buyer per listing. Withdrawn and rejected rows accumulate freely.
create unique index bids_one_live_per_buyer
  on bids (listing_id, buyer_id) where status = 'pending';

-- ============================================================
-- 5. Chat
-- ============================================================

create table conversations (
  id              uuid primary key default gen_random_uuid(),
  university_id   uuid not null references universities(id),
  -- was nullable with ON DELETE SET NULL under a CHECK forbidding null, which made
  -- deleting any listing that had a conversation fail outright. v1 has no
  -- request-originated conversations, so this is simply NOT NULL now.
  -- Listings are never hard-deleted by a client (status = 'removed' instead), so the
  -- CASCADE only fires on an admin purge, where losing the thread is correct.
  listing_id      uuid not null references listings(id) on delete cascade,
  buyer_id        uuid not null references profiles(id) on delete cascade,
  seller_id       uuid not null references profiles(id) on delete cascade,
  last_message_at timestamptz,
  created_at      timestamptz not null default now(),
  unique (listing_id, buyer_id),
  check (buyer_id <> seller_id)
);

create table messages (
  id              uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references conversations(id) on delete cascade,
  sender_id       uuid references profiles(id) on delete set null,
  body            text not null check (char_length(body) <= 2000),
  is_system       boolean not null default false,
  created_at      timestamptz not null default now(),
  -- is_system is the ONLY authority on whether a message is a system message. Two deletion
  -- paths, both verified safe: in-app deletion ANONYMIZES the profile (row kept), so the
  -- message stays authored by 'deleted-xxxx' with sender_id intact and is_system false. An
  -- admin HARD delete of a participant cascades conversations -> messages, so the message
  -- is removed outright rather than left with a null sender. The ON DELETE SET NULL below
  -- is therefore a belt-and-suspenders default that in practice never fires for an authored
  -- message — but the UI must still treat is_system, never a null sender, as the signal.
  check (not is_system or sender_id is null)
);

create table blocks (
  blocker_id uuid not null references profiles(id) on delete cascade,
  blocked_id uuid not null references profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id),
  check (blocker_id <> blocked_id)
);

-- Blocks are symmetric for enforcement purposes: if either party has blocked the other,
-- they do not see each other's listings and cannot message each other.
--
-- This has to be SECURITY DEFINER. The blocks RLS policy deliberately only lets you read
-- blocks YOU created, so a policy subquery on blocks can never see "X blocked me" — which
-- is exactly the direction enforcement needs. Without this helper, blocking is decorative.
create or replace function is_blocked_between(p_a uuid, p_b uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from blocks
    where (blocker_id = p_a and blocked_id = p_b)
       or (blocker_id = p_b and blocked_id = p_a)
  );
$$;

-- Mutual opt-in identity reveal. One row = one party offering their first name inside one
-- conversation. Two rows = both offered, and only then does either name become readable.
-- Offers can be withdrawn while unmatched; once matched the reveal is permanent, because
-- you cannot un-know a name.
create table identity_reveals (
  conversation_id uuid not null references conversations(id) on delete cascade,
  profile_id      uuid not null references profiles(id) on delete cascade,
  offered_at      timestamptz not null default now(),
  primary key (conversation_id, profile_id)
);

-- ============================================================
-- 6. Trust, rewards, safety
-- ============================================================

create table ratings (
  id         uuid primary key default gen_random_uuid(),
  listing_id uuid not null references listings(id) on delete cascade,
  rater_id   uuid not null references profiles(id) on delete cascade,
  ratee_id   uuid not null references profiles(id) on delete cascade,
  stars      smallint not null check (stars between 1 and 5),
  comment    text check (char_length(comment) <= 300),
  created_at timestamptz not null default now(),
  unique (listing_id, rater_id),
  check (rater_id <> ratee_id)
);

-- append-only ledger; profiles.tokens is a cached sum
create table token_events (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references profiles(id) on delete cascade,
  kind       token_kind not null,
  amount     integer not null,
  ref_id     uuid,
  created_at timestamptz not null default now(),
  -- NULLS NOT DISTINCT so a retried grant cannot double-award. Every kind except
  -- admin_adjustment carries a ref_id, so this is the idempotency key.
  unique nulls not distinct (user_id, kind, ref_id)
);

create table reports (
  id            uuid primary key default gen_random_uuid(),
  university_id uuid not null references universities(id),
  reporter_id   uuid not null references profiles(id) on delete cascade,
  target_type   text not null check (target_type in ('listing','profile','message','request')),
  target_id     uuid not null,
  reason        text not null,
  detail        text,
  status        report_status not null default 'open',
  created_at    timestamptz not null default now(),
  -- one report per person per target. Without this one student can bury the admin queue.
  unique (reporter_id, target_type, target_id)
);

create table push_tokens (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references profiles(id) on delete cascade,
  token      text not null unique,
  platform   text not null check (platform in ('ios','android')),
  created_at timestamptz not null default now()
);

-- ============================================================
-- 7. Indexes
-- ============================================================

create index on listings (university_id, status, created_at desc);
create index on listings (seller_id, status);
create index on listings (university_id, status, bumped_at desc);
create index on listing_images (listing_id, position);
create index on requests (university_id, is_open, created_at desc);
create index on swipes (user_id, listing_id);
create index on bids (listing_id, status);
create index on bids (buyer_id, status);
create index on conversations (buyer_id, last_message_at desc nulls last);
create index on conversations (seller_id, last_message_at desc nulls last);
create index on messages (conversation_id, created_at desc);
create index on ratings (ratee_id);
create index on token_events (user_id, created_at desc);
create index on reports (university_id, status);
create index on reports (target_type, target_id);   -- the admin queue's primary lookup
create index on blocks (blocked_id);                -- "who blocked me" — the deck needs this
create index on push_tokens (user_id);              -- notification fan-out

-- Title search. Phase 5's search box is ILIKE '%x%' without this, which is a seq scan.
create extension if not exists pg_trgm;
create index on listings using gin (title gin_trgm_ops);

-- ============================================================
-- 8. Row Level Security
--
-- Read this before editing:
--   * Client isolation is HERE, not in app queries.
--   * user_identities has RLS on and ZERO policies. Deliberate, not an oversight.
--   * Every auth.uid() and current_university_id() call is wrapped in a subselect —
--     (select auth.uid()) — so Postgres evaluates it once as an InitPlan instead of
--     once per row. Unwrapped, these policies re-run the function for every row scanned.
--   * Tables whose only writes come from section 9 functions have NO write policy at all.
--     Those functions are SECURITY DEFINER and owned by the table owner, so they bypass
--     RLS. That is the mechanism: if a write must be validated, there is no client policy
--     for it, and the only door is a function that checks its caller.
-- ============================================================

alter table universities    enable row level security;
alter table user_identities enable row level security;
alter table profiles        enable row level security;
alter table listings        enable row level security;
alter table listing_images  enable row level security;
alter table requests        enable row level security;
alter table swipes          enable row level security;
alter table bids            enable row level security;
alter table conversations   enable row level security;
alter table messages        enable row level security;
alter table blocks          enable row level security;
alter table identity_reveals enable row level security;
alter table ratings         enable row level security;
alter table token_events    enable row level security;
alter table reports         enable row level security;
alter table push_tokens     enable row level security;

-- universities: readable by anon too — signup must map a domain to a school before the
-- user has a session.
create policy uni_read on universities for select using (is_active);

-- user_identities: intentionally no policies.

-- profiles: visible only within your own university.
-- Note the WRITE story is column grants + a trigger, not just this policy — see section 10.
create policy prof_read on profiles for select
  using (university_id = (select current_university_id()) and deleted_at is null);
create policy prof_update_own on profiles for update
  using (id = (select auth.uid()) and (select is_active_account()))
  with check (id = (select auth.uid()));

-- listings.
-- list_update_own now re-checks university_id and seller_id in WITH CHECK. Without that,
-- a seller could UPDATE their own listing's university_id and inject it into another
-- campus's deck — the one write that defeats the entire tenancy model.
-- There is no DELETE policy: removing a listing means status = 'removed', which preserves
-- the conversations and bids attached to it.
create policy list_read on listings for select
  using (university_id = (select current_university_id())
         and (status <> 'removed' or seller_id = (select auth.uid())));
create policy list_insert on listings for insert
  with check (seller_id = (select auth.uid())
              and university_id = (select current_university_id()));
create policy list_update_own on listings for update
  using (seller_id = (select auth.uid()))
  with check (seller_id = (select auth.uid())
              and university_id = (select current_university_id()));

create policy img_read on listing_images for select
  using (exists (select 1 from listings l
                 where l.id = listing_id
                   and l.university_id = (select current_university_id())));
create policy img_write on listing_images for all
  using ((select is_active_account())
         and exists (select 1 from listings l
                     where l.id = listing_id and l.seller_id = (select auth.uid())))
  with check ((select is_active_account())
              and exists (select 1 from listings l
                          where l.id = listing_id and l.seller_id = (select auth.uid())));

-- requests
create policy req_read on requests for select
  using (university_id = (select current_university_id()));
create policy req_write on requests for all
  using (author_id = (select auth.uid()))
  with check (author_id = (select auth.uid())
              and university_id = (select current_university_id()));

-- swipes: yours only. Nobody sees another user's swipe history except admin.
create policy swipe_own on swipes for all
  using (user_id = (select auth.uid()) and (select is_active_account()))
  with check (user_id = (select auth.uid()) and (select is_active_account()));

-- bids: readable by the buyer who placed it and the seller of the listing.
-- NO insert or update policy. place_bid / withdraw_bid / accept_bid are the only doors.
-- Revision 1 had bid_update_own with only a buyer_id check, which bypassed every guard on
-- insert: a rejected buyer could set their own bid back to 'pending' for one cent on a
-- listing that was already promised to someone else.
create policy bid_read on bids for select
  using ((select is_active_account())
         and (buyer_id = (select auth.uid())
             or exists (select 1 from listings l
                        where l.id = listing_id and l.seller_id = (select auth.uid()))));

-- conversations: the two participants only. Created by place_bid, never by a client.
create policy conv_read on conversations for select
  using ((select is_active_account())
         and (buyer_id = (select auth.uid()) or seller_id = (select auth.uid())));

create policy msg_read on messages for select
  using ((select is_active_account())
         and exists (select 1 from conversations c
                 where c.id = conversation_id
                   and (c.buyer_id = (select auth.uid()) or c.seller_id = (select auth.uid()))));
-- A blocked user's messages do not deliver: enforced here, at write time, not in the UI.
-- is_system is forced false because system messages are written by section 9 functions.
create policy msg_insert on messages for insert
  with check (sender_id = (select auth.uid())
              and (select is_active_account())
              and is_system = false
              and exists (select 1 from conversations c
                          where c.id = conversation_id
                            and ((c.buyer_id = (select auth.uid()) and not is_blocked_between(c.buyer_id, c.seller_id))
                              or (c.seller_id = (select auth.uid()) and not is_blocked_between(c.buyer_id, c.seller_id)))));

create policy block_own on blocks for all
  using (blocker_id = (select auth.uid()) and (select is_active_account()))
  with check (blocker_id = (select auth.uid()) and (select is_active_account()));

-- identity_reveals: both participants can see whether an offer exists — that is the whole
-- point of a two-sided handshake. Writes go through offer/withdraw functions so the
-- "listing must have an accepted bid" precondition is enforced in one place.
create policy reveal_read on identity_reveals for select
  using ((select is_active_account())
         and exists (select 1 from conversations c
                     where c.id = conversation_id
                       and (c.buyer_id = (select auth.uid()) or c.seller_id = (select auth.uid()))));

-- ratings: readable within university. NO insert policy — submit_rating enforces that the
-- rater actually transacted with the ratee. Revision 1 let anyone in the university
-- 1-star anyone else, and let two colluding accounts farm 10 tokens per fake 5-star.
create policy rate_read on ratings for select
  using (exists (select 1 from profiles p
                 where p.id = ratee_id and p.university_id = (select current_university_id())));

-- token ledger: read your own. Writes come from grant_tokens, which no client can call.
create policy token_read_own on token_events for select
  using (user_id = (select auth.uid()) and (select is_active_account()));

create policy report_insert on reports for insert
  with check (reporter_id = (select auth.uid())
              and university_id = (select current_university_id()));
create policy report_read_own on reports for select
  using (reporter_id = (select auth.uid()) and (select is_active_account()));

-- push_tokens: read/delete your own. Inserts go through register_push_token, because the
-- token column is globally unique and a device that changes hands produces a conflict row
-- the new user cannot see, let alone update. Left alone, that either breaks registration
-- or pushes one student's chat notifications to another student's phone.
create policy push_read_own on push_tokens for select
  using (user_id = (select auth.uid()) and (select is_active_account()));
-- DELETE is deliberately NOT gated on is_active_account(). A suspended user being force
-- logged out must still be able to clear their push token, or they keep receiving pushes
-- for an account they can no longer open.
create policy push_delete_own on push_tokens for delete
  using (user_id = (select auth.uid()));

-- ============================================================
-- 9. Server-side business logic
-- Tokens, bid lifecycle, conversation creation, and ratings must never be client-driven.
-- ============================================================

-- ---------- signup ----------
-- Fires on auth.users insert. Rejects unknown domains, creates the identity row and the
-- profile with a unique adjective-noun handle. Without this, Phase 3 cannot create either
-- row: user_identities has no policies and profiles has no INSERT policy.
create or replace function handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_domain text;
  v_uni    uuid;
  v_handle text;
  v_plate  text;
  v_tries  int := 0;
begin
  v_domain := lower(split_part(new.email, '@', 2));

  select id into v_uni from universities
   where email_domain = v_domain and is_active;

  if v_uni is null then
    raise exception 'unrecognized_domain' using errcode = '22023';
  end if;

  loop
    v_handle := generate_handle();
    exit when not exists (
      select 1 from profiles where university_id = v_uni and handle = v_handle);
    v_tries := v_tries + 1;
    if v_tries > 20 then
      raise exception 'handle_exhausted';
    end if;
  end loop;

  v_plate := upper(left(split_part(v_handle,'-',1),1) || left(split_part(v_handle,'-',2),1));

  insert into user_identities (id, university_id, email, first_name)
  values (new.id, v_uni, new.email, nullif(new.raw_user_meta_data->>'first_name',''));

  insert into profiles (id, university_id, handle, plate, plate_color)
  values (new.id, v_uni, v_handle, v_plate, plate_color_for(new.id));

  return new;
end;
$$;

create trigger trg_new_user
after insert on auth.users
for each row execute function handle_new_user();

-- ---------- tokens ----------
-- INTERNAL ONLY. Section 11 revokes EXECUTE from every client role. In revision 1 this
-- was callable over RPC by any authenticated user with any amount, for any user id.
create or replace function grant_tokens(p_user uuid, p_kind token_kind, p_amount int, p_ref uuid default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into token_events (user_id, kind, amount, ref_id)
  values (p_user, p_kind, p_amount, p_ref)
  on conflict do nothing;          -- idempotent: a retried grant is not a second grant

  if found then
    update profiles set tokens = tokens + p_amount where id = p_user;
  end if;
end;
$$;

-- ---------- listings ----------
create or replace function on_listing_updated()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  new.bumped_at := old.bumped_at;

  if new.price_cents < old.price_cents then
    new.bumped_at := now();
  elsif (new.title is distinct from old.title
      or new.description is distinct from old.description)
      and old.bumped_at < now() - interval '24 hours' then
    new.bumped_at := now();
  end if;

  if new.status = 'sold' and old.status <> 'sold' then
    new.sold_at := now();
  end if;

  return new;
end;
$$;

create trigger trg_listing_updated
before update on listings
for each row execute function on_listing_updated();

-- Listing-creation tokens, with a daily cap. Uncapped, this pays a user to create and
-- delete listings in a loop.
create or replace function on_listing_created()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare v_today int;
begin
  select count(*) into v_today
  from listings
  where seller_id = new.seller_id and created_at > now() - interval '24 hours';

  if v_today > 10 then
    raise exception 'listing_rate_limit' using errcode = '22023';
  end if;

  if v_today <= 3 then
    perform grant_tokens(new.seller_id, 'listing_created', 5, new.id);
  end if;

  return new;
end;
$$;

create trigger trg_listing_created
after insert on listings
for each row execute function on_listing_created();

-- ---------- the deck ----------
-- Block-aware, resurface-aware. This is an RPC rather than a client query because the
-- block filter needs to see blocks in BOTH directions and the blocks policy deliberately
-- only exposes one.
create or replace function deck_listings(p_limit int default 20, p_before timestamptz default null)
returns setof listings
language sql
stable
security definer
set search_path = public
as $$
  select l.*
  from listings l
  where l.university_id = (select current_university_id())
    and l.status = 'active'
    and l.seller_id <> (select auth.uid())
    and not is_blocked_between((select auth.uid()), l.seller_id)
    and not exists (
      select 1 from swipes s
      where s.user_id = (select auth.uid())
        and s.listing_id = l.id
        -- a right swipe is final; a left swipe lifts when the listing is bumped
        and (s.direction = 'right' or l.bumped_at <= s.created_at)
    )
    and (p_before is null or l.created_at < p_before)
  order by l.created_at desc
  limit least(coalesce(p_limit, 20), 50);
$$;

-- ---------- bids ----------
-- Places or replaces a bid, and creates the conversation + system message in the same
-- transaction. Phase 6 cannot do this from the client: conversations has no INSERT policy
-- and msg_insert forbids is_system = true.
create or replace function place_bid(p_listing uuid, p_amount int)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid   uuid := (select auth.uid());
  v_l     listings;
  v_conv  uuid;
  v_bid   uuid;
  v_prev  uuid;
begin
  if p_amount is null or p_amount <= 0 then
    raise exception 'bid_amount_invalid' using errcode = '22023';
  end if;

  select * into v_l from listings
   where id = p_listing
     and university_id = (select current_university_id())
     and status = 'active'
   for update;

  if v_l.id is null then
    raise exception 'listing_unavailable' using errcode = '22023';
  end if;
  if v_l.seller_id = v_uid then
    raise exception 'cannot_bid_on_own_listing' using errcode = '22023';
  end if;
  if is_blocked_between(v_uid, v_l.seller_id) then
    raise exception 'blocked' using errcode = '22023';
  end if;

  -- Three statements, in this order, for two separate reasons:
  --   1. bids_one_live_per_buyer is a non-deferrable partial unique index, so the old bid
  --      must stop being 'pending' BEFORE the new row lands.
  --   2. superseded_by is a self-FK, checked immediately, so it can only be set AFTER the
  --      row it points at exists.
  update bids set status = 'withdrawn'
   where listing_id = p_listing and buyer_id = v_uid and status = 'pending'
  returning id into v_prev;

  insert into bids (listing_id, buyer_id, amount_cents)
  values (p_listing, v_uid, p_amount)
  returning id into v_bid;

  if v_prev is not null then
    update bids set superseded_by = v_bid where id = v_prev;
  end if;

  insert into conversations (university_id, listing_id, buyer_id, seller_id)
  values (v_l.university_id, p_listing, v_uid, v_l.seller_id)
  on conflict (listing_id, buyer_id) do update set listing_id = excluded.listing_id
  returning id into v_conv;

  insert into messages (conversation_id, sender_id, body, is_system)
  values (v_conv, null,
          case when v_prev is not null then 'bid_updated' else 'bid_placed' end
            || ':' || p_amount::text,
          true);

  return v_bid;
end;
$$;

create or replace function withdraw_bid(p_bid uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update bids set status = 'withdrawn'
   where id = p_bid and buyer_id = (select auth.uid()) and status = 'pending';
  if not found then
    raise exception 'bid_not_withdrawable' using errcode = '22023';
  end if;
end;
$$;

-- Seller accepts one bid: listing goes pending, every other live bid is rejected.
-- Now takes a row lock. Revision 1 had no lock, so a seller double-tapping two bids could
-- have both calls observe status = 'active' and both proceed.
create or replace function accept_bid(p_bid uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_listing uuid;
begin
  select l.id into v_listing
  from bids b
  join listings l on l.id = b.listing_id
  where b.id = p_bid
    and b.status = 'pending'
    and l.seller_id = (select auth.uid())
    and l.status = 'active'
  for update of l;

  if v_listing is null then
    raise exception 'not your listing, or listing is not active, or bid is not live'
      using errcode = '22023';
  end if;

  update bids set status = 'rejected'
   where listing_id = v_listing and id <> p_bid and status = 'pending';
  update bids set status = 'accepted' where id = p_bid;
  update listings set status = 'pending' where id = v_listing;
end;
$$;

-- The deal-fell-through branch. Without this a listing sits in 'pending' forever, out of
-- every deck, with no path back. Called by the seller, and by the 48-hour job on "no".
create or replace function reopen_listing(p_listing uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update listings set status = 'active'
   where id = p_listing and seller_id = (select auth.uid()) and status = 'pending';
  if not found then
    raise exception 'listing_not_reopenable' using errcode = '22023';
  end if;

  update bids set status = 'rejected'
   where listing_id = p_listing and status = 'accepted';
end;
$$;

create or replace function mark_sold(p_listing uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_buyer uuid;
begin
  update listings set status = 'sold'
   where id = p_listing and seller_id = (select auth.uid()) and status in ('active','pending');
  if not found then
    raise exception 'listing_not_sellable' using errcode = '22023';
  end if;

  select buyer_id into v_buyer from bids
   where listing_id = p_listing and status = 'accepted' limit 1;

  -- Sale tokens require a real counterparty. A seller may mark a listing sold with no
  -- accepted bid (sold off-app, gave it away), but paying for that would let anyone farm
  -- 25 tokens in a loop: post a listing, mark it sold, repeat. No counterparty, no payout.
  if v_buyer is not null then
    perform grant_tokens((select auth.uid()), 'sale_completed', 25, p_listing);
    perform grant_tokens(v_buyer, 'sale_completed', 25, p_listing);
  end if;
end;
$$;

-- ---------- chat ----------
create or replace function on_message_inserted()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update conversations set last_message_at = new.created_at
   where id = new.conversation_id;
  return new;
end;
$$;

create trigger trg_message_inserted
after insert on messages
for each row execute function on_message_inserted();

-- ---------- identity reveal ----------
-- Offer is only possible once the deal is real (an accepted bid on the listing).
create or replace function offer_identity_reveal(p_conversation uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_uid uuid := (select auth.uid());
begin
  if not exists (
    select 1 from conversations c
    join bids b on b.listing_id = c.listing_id and b.buyer_id = c.buyer_id
    where c.id = p_conversation
      and (c.buyer_id = v_uid or c.seller_id = v_uid)
      and b.status = 'accepted'
  ) then
    raise exception 'reveal_not_available' using errcode = '22023';
  end if;

  insert into identity_reveals (conversation_id, profile_id)
  values (p_conversation, v_uid)
  on conflict do nothing;
end;
$$;

-- Withdrawable only while the handshake is incomplete.
create or replace function withdraw_identity_reveal(p_conversation uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if (select count(*) from identity_reveals where conversation_id = p_conversation) = 2 then
    raise exception 'reveal_already_mutual' using errcode = '22023';
  end if;
  delete from identity_reveals
   where conversation_id = p_conversation and profile_id = (select auth.uid());
end;
$$;

-- The only path from a client to a real name, and it returns null unless BOTH parties
-- have offered. user_identities itself stays unreadable.
create or replace function revealed_first_name(p_conversation uuid, p_profile uuid)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare v_uid uuid := (select auth.uid());
begin
  if not exists (
    select 1 from conversations c
    where c.id = p_conversation
      and (c.buyer_id = v_uid or c.seller_id = v_uid)
      and (c.buyer_id = p_profile or c.seller_id = p_profile)
  ) then
    return null;
  end if;

  if (select count(*) from identity_reveals where conversation_id = p_conversation) < 2 then
    return null;
  end if;

  return (select first_name from user_identities
           where id = p_profile and status = 'active');
end;
$$;

-- ---------- ratings ----------
-- Requires that the rater and ratee were the two sides of an accepted bid on a sold
-- listing. Revision 1 checked only "not myself", which made both the 1-star grief attack
-- and the 5-star token farm trivial.
create or replace function submit_rating(p_listing uuid, p_stars smallint, p_comment text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid   uuid := (select auth.uid());
  v_ratee uuid;
begin
  select case when l.seller_id = v_uid then b.buyer_id else l.seller_id end
    into v_ratee
  from listings l
  join bids b on b.listing_id = l.id and b.status = 'accepted'
  where l.id = p_listing
    and l.status = 'sold'
    and (l.seller_id = v_uid or b.buyer_id = v_uid);

  if v_ratee is null then
    raise exception 'not_a_participant_in_this_sale' using errcode = '22023';
  end if;

  insert into ratings (listing_id, rater_id, ratee_id, stars, comment)
  values (p_listing, v_uid, v_ratee, p_stars, p_comment);
end;
$$;

create or replace function on_rating_inserted()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update profiles p
  set rating_avg = sub.avg_stars, rating_count = sub.n
  from (select avg(stars)::numeric(3,2) avg_stars, count(*) n
        from ratings where ratee_id = new.ratee_id) sub
  where p.id = new.ratee_id;

  if new.stars = 5 then
    perform grant_tokens(new.ratee_id, 'five_star', 10, new.listing_id);
  end if;
  return new;
end;
$$;

create trigger trg_rating_inserted
after insert on ratings
for each row execute function on_rating_inserted();

-- ---------- push ----------
create or replace function register_push_token(p_token text, p_platform text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from push_tokens where token = p_token;
  insert into push_tokens (user_id, token, platform)
  values ((select auth.uid()), p_token, p_platform);
end;
$$;

-- ---------- account deletion ----------
-- Scrubs PII in place rather than deleting the identity row. Deleting it would remove the
-- status gate that current_university_id() checks, and the account would keep browsing
-- with a live session. The Edge Function that calls this must ALSO scrub and ban the
-- auth.users row through the admin API, and purge R2 keys — collect them BEFORE calling.
create or replace function delete_my_account()
returns table (r2_keys text[])
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid  uuid := (select auth.uid());
  v_keys text[];
begin
  select coalesce(array_agg(k), '{}') into v_keys from (
    select li.r2_key   as k from listing_images li join listings l on l.id = li.listing_id where l.seller_id = v_uid
    union all
    select li.thumb_key from listing_images li join listings l on l.id = li.listing_id where l.seller_id = v_uid
    union all
    select p.avatar_key from profiles p where p.id = v_uid and p.avatar_key is not null
  ) s;

  update listings set status = 'removed' where seller_id = v_uid and status <> 'sold';
  update requests set is_open = false where author_id = v_uid;
  update bids set status = 'withdrawn' where buyer_id = v_uid and status = 'pending';
  delete from push_tokens where user_id = v_uid;
  delete from identity_reveals where profile_id = v_uid;

  update profiles
     set handle = 'deleted-' || left(replace(v_uid::text,'-',''), 8),
         plate = '--', plate_color = '#5B6472', avatar_key = null, deleted_at = now()
   where id = v_uid;

  update user_identities
     set email = null, first_name = null, legal_name = null, phone = null,
         status = 'deleted', deleted_at = now()
   where id = v_uid;

  return query select v_keys;
end;
$$;

-- ============================================================
-- 10. Column-level protection on profiles
--
-- Two layers, deliberately. The grants are the real control; the trigger is there so the
-- failure is a legible error rather than a silently ignored column, and so a future
-- migration that re-grants UPDATE by accident does not reopen the hole.
-- ============================================================

revoke update on profiles from anon, authenticated;
grant  update (avatar_key) on profiles to authenticated;

create or replace function guard_profile_columns()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  -- Server functions run as the table owner and are trusted. Only constrain client roles.
  if current_user not in ('authenticated', 'anon') then
    return new;
  end if;

  if new.id            is distinct from old.id
  or new.university_id is distinct from old.university_id
  or new.handle        is distinct from old.handle
  or new.plate         is distinct from old.plate
  or new.plate_color   is distinct from old.plate_color
  or new.rating_avg    is distinct from old.rating_avg
  or new.rating_count  is distinct from old.rating_count
  or new.tokens        is distinct from old.tokens
  or new.deleted_at    is distinct from old.deleted_at
  or new.created_at    is distinct from old.created_at then
    raise exception 'profiles: avatar_key is the only client-writable column'
      using errcode = '42501';
  end if;
  return new;
end;
$$;

create trigger trg_guard_profile_columns
before update on profiles
for each row execute function guard_profile_columns();

-- ============================================================
-- 11. Function privileges
--
-- Postgres grants EXECUTE on a new function to PUBLIC, and PostgREST exposes every
-- public-schema function as an RPC endpoint. So a SECURITY DEFINER function is a public,
-- unauthenticated-by-default API unless you say otherwise. Revoke first, then grant back
-- deliberately. Any new function added below this line must appear in one of these lists.
-- ============================================================

revoke execute on all functions in schema public from public, anon, authenticated;

-- Called from inside RLS policies, so client roles need EXECUTE on them.
grant execute on function current_university_id()          to authenticated;
grant execute on function is_blocked_between(uuid, uuid)   to authenticated;
grant execute on function is_active_account()              to authenticated;

-- Client-callable RPCs. Each one checks auth.uid() internally; none takes a user id
-- from the caller.
grant execute on function is_admin()                                to authenticated;
grant execute on function my_account_status()                       to authenticated;
grant execute on function deck_listings(int, timestamptz)           to authenticated;
grant execute on function place_bid(uuid, int)                      to authenticated;
grant execute on function withdraw_bid(uuid)                        to authenticated;
grant execute on function accept_bid(uuid)                          to authenticated;
grant execute on function reopen_listing(uuid)                      to authenticated;
grant execute on function mark_sold(uuid)                           to authenticated;
grant execute on function submit_rating(uuid, smallint, text)       to authenticated;
grant execute on function register_push_token(text, text)           to authenticated;
grant execute on function offer_identity_reveal(uuid)               to authenticated;
grant execute on function withdraw_identity_reveal(uuid)            to authenticated;
grant execute on function revealed_first_name(uuid, uuid)           to authenticated;

-- Deliberately NOT granted to any client role:
--   grant_tokens        — the client cannot be trusted to award itself tokens
--   delete_my_account   — Edge Function only; it must sequence R2 purge and auth scrub
--   handle_new_user, on_*, guard_profile_columns — trigger functions; EXECUTE is checked
--                         at CREATE TRIGGER, not at fire time, so revoking is safe.

-- ============================================================
-- 12. Helper stubs implemented in the Phase 2 migration
-- ============================================================
-- generate_handle() returns text     -- adjective-noun from a curated word list
-- plate_color_for(uuid) returns text -- deterministic token color from the user id
