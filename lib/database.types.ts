/**
 * lib/database.types.ts — GENERATED FILE, regeneration pending.
 *
 * CLAUDE.md §5: "Supabase types are generated (`supabase gen types typescript`) ... and
 * committed. Never hand-write a row type." So this file is intentionally NOT hand-authored.
 * It could not be generated in the Phase 1 build environment because `supabase gen types`
 * runs the `postgres-meta` image in a container (Docker/Podman), which was unavailable.
 *
 * Regenerate it in an environment that has Docker or a linked Supabase project, then commit:
 *
 *   # against a linked cloud project
 *   npx supabase gen types typescript --linked --schema public > lib/database.types.ts
 *
 *   # or against the local stack
 *   npx supabase start
 *   npx supabase gen types typescript --local --schema public > lib/database.types.ts
 *
 * Until then this exports a permissive `Database` shape so imports typecheck. It provides NO
 * table typing on purpose — replace it wholesale with the generated output; do not extend it
 * by hand, or the "never hand-write a row type" rule is quietly broken. The enum literals
 * below mirror schema.sql §1 only so enum-typed code has something real to compile against.
 */

type Any = any;

export type Database = {
  public: {
    Tables: { [key: string]: Any };
    Views: { [key: string]: Any };
    Functions: { [key: string]: Any };
    Enums: {
      listing_status: 'active' | 'pending' | 'sold' | 'removed';
      item_condition: 'new' | 'like_new' | 'good' | 'fair' | 'parts';
      bid_status: 'pending' | 'accepted' | 'rejected' | 'withdrawn';
      swipe_direction: 'left' | 'right';
      report_status: 'open' | 'reviewing' | 'actioned' | 'dismissed';
      account_status: 'active' | 'suspended' | 'deleted';
      token_kind: 'listing_created' | 'sale_completed' | 'five_star' | 'admin_adjustment';
    };
    CompositeTypes: { [key: string]: Any };
  };
};
