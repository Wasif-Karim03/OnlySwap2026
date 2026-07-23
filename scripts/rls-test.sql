-- scripts/rls-test.sql — the Phase 1 exit test as pure SQL, runnable against Postgres with
-- no Supabase auth stack (CI, or when Docker is unavailable). It mirrors scripts/rls-test.ts
-- case-for-case (BUILD_PLAN Phase 1, cases 1–15). Both must pass.
--
-- Preconditions: schema.sql applied, plus a minimal auth stub providing schema `auth`, table
-- `auth.users(id, email, raw_user_meta_data)`, function `auth.uid()` reading
-- current_setting('test.uid'), and roles `anon` / `authenticated`. Supabase grants SELECT/
-- INSERT/UPDATE/DELETE on public tables to `authenticated` by default; the runner replicates
-- that and re-applies the section-10 profiles column restriction before running.
--
-- Output: one row per case in _t with passed = true/false, then a final failure count. A
-- nonzero failure count means STOP and fix — do not proceed to Phase 2.

\set ON_ERROR_STOP 0
\pset pager off

-- ── Assertion helpers (SECURITY INVOKER → run with the caller's role + RLS) ────────────────
reset role;
drop table if exists _t;
create table _t (case_id text, passed boolean, note text);
grant insert on _t to authenticated;

create or replace function _assert_denied(p_case text, p_sql text)
returns void language plpgsql security invoker as $$
begin
  begin
    execute p_sql;
    insert into _t values (p_case, false, 'expected denial, but statement succeeded');
  exception when others then
    insert into _t values (p_case, true, 'denied: ' || sqlerrm);
  end;
end $$;

create or replace function _assert_bool(p_case text, p_expr text)
returns void language plpgsql security invoker as $$
declare b boolean;
begin
  execute 'select (' || p_expr || ')' into b;
  insert into _t values (p_case, coalesce(b, false), 'expr=' || coalesce(b::text, 'null'));
end $$;

create or replace function _assert_affected(p_case text, p_sql text, p_expected int)
returns void language plpgsql security invoker as $$
declare n int;
begin
  begin
    execute p_sql;
    get diagnostics n = row_count;
    insert into _t values (p_case, n = p_expected, 'rows affected=' || n || ' expected=' || p_expected);
  exception when others then
    insert into _t values (p_case, false, 'unexpected error: ' || sqlerrm);
  end;
end $$;

grant execute on function _assert_denied(text, text) to authenticated;
grant execute on function _assert_bool(text, text) to authenticated;
grant execute on function _assert_affected(text, text, int) to authenticated;

-- Supabase's default grants + the section-10 profiles restriction.
grant usage on schema public to authenticated, anon;
grant select, insert, update, delete on all tables in schema public to authenticated;
revoke update on profiles from anon, authenticated;
grant update (avatar_key) on profiles to authenticated;
-- Real Supabase grants `authenticated`/`anon` access to auth.uid(); the local auth stub must
-- too, or policies that call auth.uid() directly (push_delete_own, swipe_own, msg_insert, …)
-- error instead of evaluating. No-op against a real Supabase database.
grant usage on schema auth to authenticated, anon;
grant execute on function auth.uid() to authenticated, anon;

-- ── Seed two campuses + users (owner; RLS bypassed) ───────────────────────────────────────
insert into universities (id, name, email_domain, is_active, is_demo) values
  ('a0000000-0000-4000-8000-000000000001','Case','case.edu',true,false),
  ('a0000000-0000-4000-8000-000000000002','Demo','demo.onlyswap.app',true,true);

insert into auth.users (id, email, raw_user_meta_data) values
  ('11111111-0000-4000-8000-0000000000a1','u1@case.edu','{"first_name":"Ada"}'),   -- seller A
  ('11111111-0000-4000-8000-0000000000a2','u2@case.edu','{"first_name":"Ben"}'),   -- buyer  A
  ('11111111-0000-4000-8000-0000000000a3','u3@case.edu','{"first_name":"Cora"}'),  -- third  A
  ('22222222-0000-4000-8000-0000000000b1','u1@demo.onlyswap.app','{"first_name":"Dev"}'); -- campus B

-- ── Fixtures as the acting users (RLS applies) ────────────────────────────────────────────
set role authenticated;

set "test.uid" = '11111111-0000-4000-8000-0000000000a1';   -- seller posts
insert into listings (id, university_id, seller_id, title, price_cents, condition)
values ('dddddddd-0000-4000-8000-00000000000a','a0000000-0000-4000-8000-000000000001',
        '11111111-0000-4000-8000-0000000000a1','Mini fridge',4500,'good');

set "test.uid" = '11111111-0000-4000-8000-0000000000a2';   -- buyer bids + messages
select place_bid('dddddddd-0000-4000-8000-00000000000a', 4000);
insert into messages (conversation_id, sender_id, body)
select id, '11111111-0000-4000-8000-0000000000a2', 'can you do 40?'
from conversations where listing_id = 'dddddddd-0000-4000-8000-00000000000a';

-- ════════════════════════════════════════════════════════════════════════════════════════
-- CASES
-- ════════════════════════════════════════════════════════════════════════════════════════

-- 1. cross-campus isolation: campus B user sees 0 of campus A's listings
set "test.uid" = '22222222-0000-4000-8000-0000000000b1';
select _assert_bool('01 cross-campus isolation', '(select count(*) from listings) = 0');

-- 2. user_identities unreadable by any client
set "test.uid" = '11111111-0000-4000-8000-0000000000a2';
select _assert_bool('02 user_identities unreadable', '(select count(*) from user_identities) = 0');

-- 3. non-participant cannot read a conversation's messages
set "test.uid" = '11111111-0000-4000-8000-0000000000a3';
select _assert_bool('03 non-participant reads 0 messages', '(select count(*) from messages) = 0');

-- 4. grant_tokens RPC denied
set "test.uid" = '11111111-0000-4000-8000-0000000000a2';
select _assert_denied('04 grant_tokens RPC denied',
  $q$ select grant_tokens('11111111-0000-4000-8000-0000000000a2','admin_adjustment',999999) $q$);

-- 5. UPDATE profiles.tokens denied
select _assert_denied('05 profiles.tokens write denied',
  $q$ update profiles set tokens = 999999 where id = '11111111-0000-4000-8000-0000000000a2' $q$);

-- 6. UPDATE profiles.university_id denied (campus hop)
select _assert_denied('06 profiles.university_id change denied',
  $q$ update profiles set university_id = 'a0000000-0000-4000-8000-000000000002'
      where id = '11111111-0000-4000-8000-0000000000a2' $q$);

-- 7. UPDATE listings.university_id denied (WITH CHECK violation)
set "test.uid" = '11111111-0000-4000-8000-0000000000a1';
select _assert_denied('07 listings.university_id change denied',
  $q$ update listings set university_id = 'a0000000-0000-4000-8000-000000000002'
      where id = 'dddddddd-0000-4000-8000-00000000000a' $q$);

-- 8. direct client INSERT into protected tables denied (4 sub-cases)
set "test.uid" = '11111111-0000-4000-8000-0000000000a2';
select _assert_denied('08a bids insert denied',
  $q$ insert into bids (listing_id, buyer_id, amount_cents)
      values ('dddddddd-0000-4000-8000-00000000000a','11111111-0000-4000-8000-0000000000a2',1) $q$);
select _assert_denied('08b conversations insert denied',
  $q$ insert into conversations (university_id, listing_id, buyer_id, seller_id)
      values ('a0000000-0000-4000-8000-000000000001','dddddddd-0000-4000-8000-00000000000a',
              '11111111-0000-4000-8000-0000000000a2','11111111-0000-4000-8000-0000000000a1') $q$);
select _assert_denied('08c ratings insert denied',
  $q$ insert into ratings (listing_id, rater_id, ratee_id, stars)
      values ('dddddddd-0000-4000-8000-00000000000a','11111111-0000-4000-8000-0000000000a2',
              '11111111-0000-4000-8000-0000000000a1',5) $q$);
select _assert_denied('08d token_events insert denied',
  $q$ insert into token_events (user_id, kind, amount)
      values ('11111111-0000-4000-8000-0000000000a2','five_star',10) $q$);

-- 9. UPDATE of another user's bid denied (bids has NO update policy → 0 rows affected)
set "test.uid" = '11111111-0000-4000-8000-0000000000a3';
select _assert_affected('09 update another user bid denied',
  $q$ update bids set status = 'rejected'
      where listing_id = 'dddddddd-0000-4000-8000-00000000000a' $q$, 0);

-- 10. service role can delete a listing that has a conversation + bids
reset role;
select _assert_affected('10 delete listing w/ conversation+bids (service role)',
  $q$ delete from listings where id = 'dddddddd-0000-4000-8000-00000000000a' $q$, 1);
-- rebuild the fixture the delete just cascaded away, for the remaining cases
set role authenticated;
set "test.uid" = '11111111-0000-4000-8000-0000000000a1';
insert into listings (id, university_id, seller_id, title, price_cents, condition)
values ('dddddddd-0000-4000-8000-00000000000a','a0000000-0000-4000-8000-000000000001',
        '11111111-0000-4000-8000-0000000000a1','Mini fridge',4500,'good');
set "test.uid" = '11111111-0000-4000-8000-0000000000a2';
select place_bid('dddddddd-0000-4000-8000-00000000000a', 4000);
insert into messages (conversation_id, sender_id, body)
select id, '11111111-0000-4000-8000-0000000000a2', 'can you do 40?'
from conversations where listing_id = 'dddddddd-0000-4000-8000-00000000000a';

-- Capture the conversation id (owner view) so case 12c can aim a real INSERT at it.
reset role;
select id as conv_id from conversations
 where listing_id = 'dddddddd-0000-4000-8000-00000000000a' \gset
set role authenticated;

-- 11. suspended user: current_university_id() null and reads nothing
reset role;
update user_identities set status = 'suspended' where id = '11111111-0000-4000-8000-0000000000a3';
set role authenticated;
set "test.uid" = '11111111-0000-4000-8000-0000000000a3';
select _assert_bool('11 suspended current_university_id() null', 'current_university_id() is null');
select _assert_bool('11 suspended reads 0 profiles', '(select count(*) from profiles) = 0');
select _assert_bool('11 suspended reads 0 listings', '(select count(*) from listings) = 0');

-- 12. suspension write-gate: suspended user denied INSERT on messages/swipes/blocks/images.
--     (a3 is the suspended one; give it a conversation to aim at via the seller's fixture.)
select _assert_denied('12a suspended swipe insert denied',
  $q$ insert into swipes (user_id, listing_id, direction)
      values ('11111111-0000-4000-8000-0000000000a3','dddddddd-0000-4000-8000-00000000000a','left') $q$);
select _assert_denied('12b suspended block insert denied',
  $q$ insert into blocks (blocker_id, blocked_id)
      values ('11111111-0000-4000-8000-0000000000a3','11111111-0000-4000-8000-0000000000a1') $q$);
-- A suspended user aiming a real row at a real conversation: msg_insert WITH CHECK denies on
-- is_active_account() (a3 also isn't a participant — either way it must be blocked).
select _assert_denied('12c suspended message insert denied',
  format($q$ insert into messages (conversation_id, sender_id, body)
             values (%L, '11111111-0000-4000-8000-0000000000a3', 'x') $q$, :'conv_id'));
select _assert_denied('12d suspended listing_image insert denied',
  $q$ insert into listing_images (listing_id, r2_key, thumb_key)
      values ('dddddddd-0000-4000-8000-00000000000a','k','t') $q$);
-- and reads are denied too (folds the read half of the audit into case 12)
select _assert_bool('12e suspended reads 0 conversations', '(select count(*) from conversations) = 0');

-- 13. suspended user CAN delete their own push token (forced-logout cleanup)
reset role;
insert into push_tokens (user_id, token, platform)
values ('11111111-0000-4000-8000-0000000000a3','tok-a3','ios');
set role authenticated;
set "test.uid" = '11111111-0000-4000-8000-0000000000a3';
select _assert_affected('13 suspended can delete own push token',
  $q$ delete from push_tokens where token = 'tok-a3' $q$, 1);

-- 14. my_account_status distinguishes suspended from active
select _assert_bool('14 my_account_status = suspended (a3)', $q$ my_account_status() = 'suspended' $q$);
set "test.uid" = '11111111-0000-4000-8000-0000000000a2';
select _assert_bool('14 my_account_status = active (a2)', $q$ my_account_status() = 'active' $q$);

-- 15. deleted user with an authored message: message survives, is_system false; then a hard
--     delete of the profile cascades the conversation away (never orphaned as a system msg).
reset role;
-- in-app deletion path (anonymize) — call the function as the buyer a2
create or replace function _del_as(u uuid) returns void language plpgsql as $$
begin perform set_config('test.uid', u::text, false); perform delete_my_account(); end $$;
select _del_as('11111111-0000-4000-8000-0000000000a2');
reset role;
select _assert_bool('15a in-app delete: message survives, not system',
  $q$ exists (select 1 from messages
             where body = 'can you do 40?' and is_system = false and sender_id is not null) $q$);
-- admin hard delete cascades conversations -> messages
delete from profiles where id = '11111111-0000-4000-8000-0000000000a2';
select _assert_bool('15b hard delete cascades conversation away',
  $q$ not exists (select 1 from messages where body = 'can you do 40?') $q$);

-- ── Results ───────────────────────────────────────────────────────────────────────────────
reset role;
\echo ''
\echo '================ RLS TEST RESULTS ================'
select case_id, case when passed then 'PASS' else 'FAIL' end as result, note from _t order by case_id;
\echo ''
select count(*) filter (where not passed) as failures, count(*) as total from _t;
