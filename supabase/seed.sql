-- seed.sql — runs after migrations on `supabase db reset` / `supabase start`.
--
-- Seeds two universities (one real campus, one demo campus for App Review) and 12 accounts
-- each. Accounts are created by inserting into auth.users so the handle_new_user trigger runs
-- and produces real generated handles + plates — exactly the production path. Every seed user
-- can sign in with email + password (BUILD_PLAN Phase 3: password auth enables the reviewer
-- login), so scripts/rls-test.ts can authenticate as them.
--
-- Dev credentials only. Never reuse this password anywhere real.

create extension if not exists pgcrypto;

-- ── Universities ────────────────────────────────────────────────────────────────────────
-- Fixed ids so the seed is idempotent and the test can reference campuses directly.
insert into universities (id, name, email_domain, is_active, is_demo) values
  ('a0000000-0000-4000-8000-000000000001', 'Case Western Reserve University', 'case.edu', true, false),
  -- DEMO campus. Replace 'demo.onlyswap.app' with a real domain you control before App Review;
  -- is_demo only affects analytics + deck isolation, never auth (BUILD_PLAN Phase 3).
  ('a0000000-0000-4000-8000-000000000002', 'OnlySwap Demo Campus', 'demo.onlyswap.app', true, true)
on conflict (email_domain) do nothing;

-- ── Accounts (12 per campus) via the real signup trigger ─────────────────────────────────
do $$
declare
  v_pw text := 'onlyswap-dev-pw';   -- DEV ONLY
  v_names text[] := array[
    'Ada','Ben','Cora','Dev','Esme','Finn','Gia','Hugo','Ivy','Jae','Kit','Lena'
  ];
  v_campus record;
  i int;
  v_email text;
begin
  for v_campus in
    select email_domain from universities where email_domain in ('case.edu','demo.onlyswap.app')
  loop
    for i in 1..12 loop
      v_email := 'u' || i || '@' || v_campus.email_domain;
      -- skip if already seeded (idempotent re-runs)
      if exists (select 1 from auth.users where email = v_email) then
        continue;
      end if;
      insert into auth.users (
        instance_id, id, aud, role, email, encrypted_password,
        email_confirmed_at, created_at, updated_at,
        raw_app_meta_data, raw_user_meta_data
      ) values (
        '00000000-0000-0000-0000-000000000000',
        gen_random_uuid(), 'authenticated', 'authenticated',
        v_email, crypt(v_pw, gen_salt('bf')),
        now(), now(), now(),
        '{"provider":"email","providers":["email"]}',
        jsonb_build_object('first_name', v_names[i])
      );
    end loop;
  end loop;
end;
$$;

-- Sanity: 2 universities, 24 profiles, 24 identities, all handles unique per campus.
do $$
declare v_profiles int; v_ids int;
begin
  select count(*) into v_profiles from profiles;
  select count(*) into v_ids from user_identities;
  raise notice 'seed complete: % profiles, % identities across % universities',
    v_profiles, v_ids, (select count(*) from universities);
end;
$$;
