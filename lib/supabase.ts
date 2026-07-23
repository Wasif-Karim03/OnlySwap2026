/**
 * lib/supabase.ts — the one Supabase client the app shares.
 *
 * Phase 0 only stands the client up; no table is queried yet. It is created even when the
 * env is unconfigured (isSupabaseConfigured === false) so importing modules never crash — a
 * call against an empty URL simply fails at request time, which the Phase 2+ data layer
 * surfaces as an error state rather than a white screen.
 *
 * Only the anon key is used here. The service-role key never reaches the app (CLAUDE.md hard
 * rule 4). AsyncStorage-backed session persistence is wired in Phase 3 with auth; Phase 0
 * keeps the client storage-agnostic.
 */
import { createClient } from '@supabase/supabase-js';

import { env } from './env';

export const supabase = createClient(env.supabaseUrl, env.supabaseAnonKey, {
  auth: {
    autoRefreshToken: true,
    persistSession: false, // becomes true with an AsyncStorage adapter in Phase 3
    detectSessionInUrl: false,
  },
});
