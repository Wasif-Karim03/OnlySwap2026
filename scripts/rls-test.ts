/**
 * scripts/rls-test.ts — the Phase 1 exit test, run against a real Supabase stack.
 *
 * This is the integration version: it signs in seeded users through GoTrue and exercises the
 * 15 RLS cases from BUILD_PLAN Phase 1 the way the app will. It needs a running Supabase
 * (local `supabase start` or a linked project) and the seed applied.
 *
 * Run: SUPABASE_URL=... SUPABASE_ANON_KEY=... SUPABASE_SERVICE_ROLE_KEY=... npx tsx scripts/rls-test.ts
 *
 * A pure-SQL sibling, scripts/rls-test.sql, verifies the same 15 cases directly against
 * Postgres with no auth stack — useful in CI or when Docker isn't available. Both must pass.
 */
import { createClient, type SupabaseClient } from '@supabase/supabase-js';

const URL = process.env.SUPABASE_URL;
const ANON = process.env.SUPABASE_ANON_KEY;
const SERVICE = process.env.SUPABASE_SERVICE_ROLE_KEY;
const DEV_PW = process.env.SEED_PASSWORD ?? 'onlyswap-dev-pw';

if (!URL || !ANON || !SERVICE) {
  console.error('Set SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY.');
  process.exit(2);
}

const admin = createClient(URL, SERVICE, { auth: { persistSession: false } });

let passed = 0;
let failed = 0;
function ok(name: string, cond: boolean, detail = '') {
  if (cond) {
    passed++;
    console.log(`  ✓ ${name}`);
  } else {
    failed++;
    console.log(`  ✗ ${name}${detail ? ` — ${detail}` : ''}`);
  }
}

async function signIn(email: string): Promise<SupabaseClient> {
  const c = createClient(URL!, ANON!, { auth: { persistSession: false } });
  const { error } = await c.auth.signInWithPassword({ email, password: DEV_PW });
  if (error) throw new Error(`sign-in failed for ${email}: ${error.message}`);
  return c;
}

async function main() {
  // Two campuses, distinct users. Seed created u1..u12 on each domain.
  const aSeller = await signIn('u1@case.edu');
  const aBuyer = await signIn('u2@case.edu');
  const aThird = await signIn('u3@case.edu');
  const bUser = await signIn('u1@demo.onlyswap.app');

  const uid = async (c: SupabaseClient) => (await c.auth.getUser()).data.user!.id;
  const aSellerId = await uid(aSeller);
  const aBuyerId = await uid(aBuyer);

  // Fixture: seller posts a listing, buyer bids (creates conversation + system message),
  // buyer sends a real message.
  const { data: listing, error: le } = await aSeller
    .from('listings')
    .insert({
      seller_id: aSellerId,
      university_id: (
        await aSeller.from('profiles').select('university_id').eq('id', aSellerId).single()
      ).data!.university_id,
      title: 'Mini fridge',
      price_cents: 4500,
      condition: 'good',
    })
    .select()
    .single();
  if (le) throw new Error(`fixture listing failed: ${le.message}`);
  await aBuyer.rpc('place_bid', { p_listing: listing!.id, p_amount: 4000 });
  const { data: conv } = await aBuyer
    .from('conversations')
    .select('id')
    .eq('listing_id', listing!.id)
    .single();
  await aBuyer
    .from('messages')
    .insert({ conversation_id: conv!.id, sender_id: aBuyerId, body: 'can you do 40?' });

  console.log('\nRLS cases:');

  // 1. cross-campus isolation
  {
    const { data } = await bUser.from('listings').select('id');
    ok('1 cross-campus: campus B sees 0 of campus A listings', (data?.length ?? 0) === 0);
  }
  // 2. user_identities unreadable
  {
    const { data } = await aBuyer.from('user_identities').select('id');
    ok('2 user_identities unreadable', (data?.length ?? 0) === 0);
  }
  // 3. non-participant cannot read messages
  {
    const { data } = await aThird.from('messages').select('id');
    ok('3 non-participant reads 0 messages', (data?.length ?? 0) === 0);
  }
  // 4. grant_tokens RPC denied
  {
    const { error } = await aBuyer.rpc('grant_tokens', {
      p_user: aBuyerId,
      p_kind: 'admin_adjustment',
      p_amount: 999999,
    });
    ok('4 grant_tokens RPC denied', !!error);
  }
  // 5. UPDATE profiles.tokens denied
  {
    const { error } = await aBuyer.from('profiles').update({ tokens: 999999 }).eq('id', aBuyerId);
    ok('5 UPDATE profiles.tokens denied', !!error);
  }
  // 6. UPDATE profiles.university_id denied (campus hop)
  {
    const other = 'a0000000-0000-4000-8000-000000000002';
    const { error } = await aBuyer
      .from('profiles')
      .update({ university_id: other })
      .eq('id', aBuyerId);
    ok('6 profiles.university_id change denied', !!error);
  }
  // 7. UPDATE listings.university_id denied
  {
    const other = 'a0000000-0000-4000-8000-000000000002';
    const { error, data } = await aSeller
      .from('listings')
      .update({ university_id: other })
      .eq('id', listing!.id)
      .select();
    ok('7 listings.university_id change denied', !!error || (data?.length ?? 0) === 0);
  }
  // 8. direct client INSERT into protected tables denied
  {
    const r1 = await aBuyer
      .from('bids')
      .insert({ listing_id: listing!.id, buyer_id: aBuyerId, amount_cents: 1 });
    const r2 = await aBuyer.from('conversations').insert({
      listing_id: listing!.id,
      buyer_id: aBuyerId,
      seller_id: aSellerId,
      university_id: '00000000-0000-0000-0000-000000000000',
    });
    const r3 = await aBuyer
      .from('ratings')
      .insert({ listing_id: listing!.id, rater_id: aBuyerId, ratee_id: aSellerId, stars: 5 });
    const r4 = await aBuyer
      .from('token_events')
      .insert({ user_id: aBuyerId, kind: 'five_star', amount: 10 });
    ok(
      '8 direct INSERT into bids/conversations/ratings/token_events denied',
      !!r1.error && !!r2.error && !!r3.error && !!r4.error,
    );
  }
  // 9. UPDATE another user's bid denied (no bid UPDATE policy at all)
  {
    const { data: bid } = await admin
      .from('bids')
      .select('id')
      .eq('listing_id', listing!.id)
      .limit(1)
      .single();
    const { error, data } = await aThird
      .from('bids')
      .update({ status: 'pending' })
      .eq('id', bid!.id)
      .select();
    ok('9 UPDATE another user bid denied', !!error || (data?.length ?? 0) === 0);
  }
  // 10. service role can delete a listing that has a conversation + bids
  {
    const { data: l2 } = await admin
      .from('listings')
      .insert({
        seller_id: aSellerId,
        university_id: (
          await admin.from('profiles').select('university_id').eq('id', aSellerId).single()
        ).data!.university_id,
        title: 'Deletable',
        price_cents: 100,
        condition: 'good',
      })
      .select()
      .single();
    await aBuyer.rpc('place_bid', { p_listing: l2!.id, p_amount: 50 });
    const { error } = await admin.from('listings').delete().eq('id', l2!.id);
    ok('10 delete listing with conversation+bids (service role) succeeds', !error, error?.message);
  }
  // 11. suspended user: current_university_id null, reads nothing
  {
    await admin
      .from('user_identities')
      .update({ status: 'suspended' })
      .eq('id', aThird.auth ? await uid(aThird) : '');
    const susp = await signIn('u3@case.edu').catch(() => aThird);
    const { data: profs } = await susp.from('profiles').select('id');
    const { data: st } = await susp.rpc('my_account_status');
    ok('11 suspended reads nothing', (profs?.length ?? 0) === 0);
    // 14 folded in: status readable as 'suspended'
    ok('14 my_account_status = suspended', st === 'suspended');
    await admin
      .from('user_identities')
      .update({ status: 'active' })
      .eq('id', await uid(aThird));
  }
  // 12. suspension write-gate: suspended user denied inserts on messages/swipes/blocks/images
  {
    const meId = aBuyerId;
    await admin.from('user_identities').update({ status: 'suspended' }).eq('id', meId);
    const s = await signIn('u2@case.edu').catch(() => aBuyer);
    const m = await s
      .from('messages')
      .insert({ conversation_id: conv!.id, sender_id: meId, body: 'x' });
    const sw = await s
      .from('swipes')
      .insert({ user_id: meId, listing_id: listing!.id, direction: 'left' });
    const bl = await s.from('blocks').insert({ blocker_id: meId, blocked_id: aSellerId });
    ok(
      '12 suspended INSERT on messages/swipes/blocks denied',
      !!m.error && !!sw.error && !!bl.error,
    );
    await admin.from('user_identities').update({ status: 'active' }).eq('id', meId);
  }
  // 13. suspended user can still delete their own push token
  {
    const meId = aBuyerId;
    await admin.from('push_tokens').insert({ user_id: meId, token: 'seed-tok', platform: 'ios' });
    await admin.from('user_identities').update({ status: 'suspended' }).eq('id', meId);
    const s = await signIn('u2@case.edu').catch(() => aBuyer);
    await s.from('push_tokens').delete().eq('token', 'seed-tok');
    const { data } = await admin.from('push_tokens').select('token').eq('token', 'seed-tok');
    ok('13 suspended can delete own push token', (data?.length ?? 0) === 0);
    await admin.from('user_identities').update({ status: 'active' }).eq('id', meId);
  }
  // 15. authored-message invariant. Full account deletion runs through an Edge Function that
  // calls delete_my_account (no client EXECUTE grant — Phase 10), so it is not driven from a
  // user client here; scripts/rls-test.sql exercises the anonymize + hard-delete-cascade paths
  // directly. What the client CAN verify is the structural invariant deletion relies on: a
  // real authored message has is_system = false and a non-null sender, so it can never be
  // mistaken for a system message even after its sender is later anonymized.
  {
    const { data } = await admin
      .from('messages')
      .select('is_system, sender_id')
      .eq('body', 'can you do 40?')
      .single();
    ok(
      '15 authored message is_system=false with a real sender (deletion invariant)',
      data != null && data.is_system === false && data.sender_id != null,
    );
  }

  console.log(`\n${passed} passed, ${failed} failed`);
  process.exit(failed === 0 ? 0 : 1);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
