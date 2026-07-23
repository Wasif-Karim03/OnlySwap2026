/**
 * lib/env.ts — the single, typed reader for build-time config injected via app.config.ts.
 *
 * Nothing else in the app touches `Constants.expoConfig.extra`. Keeping that access in one
 * place means a missing or renamed key is a compile/lookup error here, not a scattered
 * `undefined` somewhere deep in a query. Values arrive from process.env at build time (see
 * app.config.ts) and are public by design — no secret is ever read through this path.
 */
import Constants from 'expo-constants';

type Extra = {
  supabaseUrl: string;
  supabaseAnonKey: string;
};

const extra = (Constants.expoConfig?.extra ?? {}) as Partial<Extra>;

export const env = {
  supabaseUrl: extra.supabaseUrl ?? '',
  supabaseAnonKey: extra.supabaseAnonKey ?? '',
} as const;

/** True only when both Supabase values are present. Screens can gate on this in Phase 0. */
export const isSupabaseConfigured = env.supabaseUrl.length > 0 && env.supabaseAnonKey.length > 0;
