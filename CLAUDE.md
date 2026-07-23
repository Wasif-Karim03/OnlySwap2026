# OnlySwap — Project Context

A campus-only marketplace. Students verify with a `.edu` address, get locked to their
university, and trade physical goods with each other in person. Anonymous until they meet.

Read this file completely before writing any code. It is the source of truth for stack,
conventions, and design. When something here conflicts with a prompt, say so and stop.

---

## 1. Stack — do not substitute

| Layer | Choice | Notes |
|---|---|---|
| App | Expo (managed), React Native, TypeScript strict | iOS + Android from one codebase |
| Routing | Expo Router (file-based) | |
| Animation | Reanimated 4 + `react-native-worklets` + Gesture Handler | On the New Architecture (Fabric). Swipe deck runs on the UI thread via worklets. No `Animated` from RN core. Was pinned to Reanimated 3; moved to 4 to stay on the current Expo SDK (57) — the worklet/gesture model Phase 6 relies on is unchanged, only imports (`react-native-worklets`) and setup differ. |
| Styling | StyleSheet + a typed token module | No Tailwind/NativeWind. Tokens are imported, never hardcoded. |
| Database, auth, realtime | Supabase (Postgres) | |
| Image storage | Cloudflare R2 | **Never Supabase Storage.** R2 egress is free; Supabase's is not. |
| Push | `expo-notifications` + Expo push service | Free, unlimited. No Twilio, no SMS in v1. |
| Errors | Sentry (free tier) | |
| Admin | Separate Next.js app, Cloudflare Pages | Shares generated Supabase types with the app |
| Builds | EAS Build + EAS Update | |

---

## 2. Hard rules

These are non-negotiable. Violating any of them is a correctness bug, not a style issue.

1. **University isolation lives in Row Level Security, not in queries.** Every row-bearing
   table has `university_id`. RLS policies enforce visibility. Never write
   `.eq('university_id', x)` in client code as your security boundary — it is at best a
   redundant optimization and at worst a false sense of safety.

2. **Real identity is never readable by the client.** `user_identities` holds email, legal
   name, and phone, and has RLS denying all client access. `profiles` holds the public
   handle, plate, rating, and tokens. Client code joins to `profiles` only. Admin reads
   `user_identities` through the service role, server-side, never from the mobile app.

3. **Images are compressed on device before upload.** `expo-image-manipulator`: longest edge
   1080px, WebP, quality 0.7, plus a 300px thumbnail. A 4MB camera photo must leave the
   phone at roughly 120KB. Uploading a raw camera roll asset is a bug.

4. **No secrets in the app bundle.** The R2 write credential and the Supabase service role
   key live in Supabase Edge Functions only. The app gets presigned upload URLs.

5. **Money is `integer` cents.** Never a float. Never a string. Column names end in `_cents`.

6. **Account deletion must work from inside the app.** Apple requires it. Build it in Phase
   10 (Settings, safety, deletion), not "later."

7. **Report and block ship in v1.** Apple Guideline 1.2 gates the whole submission on them.
   Both land in Phase 10 alongside deletion. Blocking is enforced in the database — the
   deck RPC and the message insert policy — never only in the UI.

8. **Tokens are earned, never sold.** The moment tokens are purchasable, Apple's in-app
   purchase rules apply at 15–30%. Keep them off the money path entirely.

---

## 3. Product rules — decided

These are settled. They are not defaults to be improved on. If a prompt asks for behaviour
that contradicts one of these, say so and stop, per section 6.

### Bidding

- Many buyers may hold a live bid on one listing at once. A buyer holds **at most one live
  bid per listing**, enforced by a partial unique index on `status = 'pending'`.
- **Bids are append-only.** Re-bidding inserts a new row and marks the previous one
  `withdrawn` with `superseded_by` set. Never update a bid amount in place — the history is
  what an admin reads when two students dispute what was agreed. `place_bid` does both
  writes in one transaction; the client never inserts into `bids`.
- The seller sees all **live** bids ranked by amount and accepts exactly one. That sets the
  listing to `pending` and rejects every other live bid. Withdrawn and rejected bids are
  never shown to the seller.
- **A rejected buyer may bid again**, but only while the listing is `active`. Once it is
  `pending` or `sold`, `place_bid` refuses. So a rejected bid becomes re-biddable only if
  the seller reopens the listing.
- **A price edit does not touch live bids.** Each bid stores its own `amount_cents`, so
  nothing goes stale. No notification fires on a price change in v1. A seller who drops the
  price below a standing bid can still accept or reject it.
- **No structured counter-offers.** Counter-offering happens in chat, and the buyer re-bids
  from there — see the bid bar below.

### The re-bid entry point

Every conversation thread has a **persistent bid bar pinned above the composer**. This is
the only way back to a bid pad once the card has left the deck, and it is not optional.

- As the buyer: shows your live bid in Martian Mono, or "No live bid". Action is
  "Change bid", which opens the same bid pad component the deck uses.
- As the seller: shows the highest live bid and the count of others. Actions are "Accept"
  and "Reject".
- When the listing is `pending` or `sold`, the bar shows status and no actions.

### Swiping

- **Left swipe hides permanently.** A dismissed listing returns to that user's deck only
  when its `bumped_at` moves: a price *drop* always bumps it; a material edit to title,
  description, or photos bumps it at most once per 24 hours. The cooldown exists so a
  seller cannot churn edits to re-enter every deck on campus.
- **A right swipe is recorded only on successful bid submission**, not when the card turns.
  Opening the bid pad and cancelling is not a swipe: the card returns to the deck in place,
  unresolved. To get rid of it the user swipes left.
- A right swipe is final. A bid-on listing never returns to that user's deck, bumped or not.
- Because a resurfaced listing can be swiped a second time, **the client must upsert**:
  `on conflict (user_id, listing_id) do update set direction = excluded.direction,
  created_at = now()`. A plain insert works the first time and fails the second.

### Identity — mutual opt-in reveal

- Handles are a stable generated `adjective-noun` (`quiet-otter`) plus a two-letter locker
  plate, fixed for the account's life because ratings need continuity.
- Real names are hidden by default and **revealed only when both parties independently
  offer**, inside one conversation, and only after a bid on that listing has been accepted.
  One offer alone reveals nothing — not even that an offer was made by the other side,
  until they make one.
- An offer can be withdrawn while unmatched. Once both have offered, the reveal is
  permanent: you cannot un-know a name.
- Only `first_name` is ever revealed. `legal_name`, email, and phone are never readable by
  any client, revealed or not. The single path is `revealed_first_name()`, which returns
  null unless both offers exist.
- **The copy must not create pressure.** The offer button reads "Share my first name", the
  supporting line is "Only shared if they share theirs. You don't have to." Declining is
  never surfaced to the other party, and the reveal sheet carries a report entry point.
- This is disclosed at signup, in the privacy policy, and in the App Privacy questionnaire.

### Requests

- The requests tab is a **read-only bulletin board** in v1: post an "I need X" with an
  optional budget, browse chronologically. That is all.
- **There is no conversation from a request.** The CTA on a request is "Post a listing",
  prefilled with the request title. `conversations` has no `request_id` — which means the
  buyer/seller roles never invert anywhere in the schema.
- Requests exist in v1 to attack the cold-start supply problem, not to be a second
  marketplace. Conversations-from-requests is v1.1.

### Listing lifecycle and the deal that fell through

- A listing is never hard-deleted by a client. "Delete" sets `status = 'removed'`, which
  preserves the conversations, bids, and ratings hanging off it.
- `pending` must always have an exit. The 48-hour quiet-conversation job asks both parties
  "Did this sell?" and resolves as follows:
  - **The seller's answer is authoritative.** Only the seller can call `mark_sold` or
    `reopen_listing`; the schema enforces this and the product rule matches it.
  - Seller says yes → `sold`, sale tokens to both sides, rating prompt to both.
  - Seller says no → `reopen_listing`: the accepted bid becomes `rejected` and the listing
    returns to `active`. Reopening does **not** bump `bumped_at` — it returns to the decks
    of people who never saw it, not to the decks of people who dismissed it.
  - Buyer disagrees with the seller → the listing follows the seller, and the disagreement
    writes an admin flag for the Phase 11 reports queue. Do not build an arbitration flow.
  - **Neither answers within 7 days** → auto-reopen. A listing may not rot in `pending`.
- **Reopening kills every bid.** The winning bid was rejected by `reopen_listing`, and the
  runner-ups were already rejected when it was accepted. A reopened listing therefore has
  zero live bids and interested buyers must place a new one. Do not auto-resurrect the
  runner-up — days may have passed and they may have bought elsewhere. Notify everyone who
  had a live bid when it was accepted that the item is available again.
- **A sale with no counterparty pays no tokens.** A seller may `mark_sold` a listing with
  no accepted bid (sold off-app, gave it away), but no `sale_completed` tokens are granted
  to anyone. Paying for a self-declared sale is a farm: post, mark sold, repeat.

### Campus

- **v1 is one campus, gated by `universities.is_active`.** There is no campus env var.
  Adding or retiring a school is a database row, and a build must never change to do it.
- A **demo campus** with a real domain we control ships in the same table, flagged
  `is_demo`. See BUILD_PLAN Phase 3 — App Review cannot create a `.edu` account, and that
  path is designed in Phase 3, not improvised in Phase 12.

---

## 4. Design direction

The brief: minimalistic, animated, and it must not look AI-generated. That last one is a
real constraint, so here is what to avoid and what to build instead.

### Avoid — these read as machine output

Cream `#F4F1EA` backgrounds with a serif display and a terracotta accent. Violet-to-blue
gradients. Pure white on `gray-50`. Emoji standing in for icons. Uniform 16px everything.
Untouched component-library defaults. Drop shadows on every card. Centered hero text.

### The world we're borrowing from

Campus wayfinding signage, ID cards, locker plates, laundry room tags, the bulletin board
by the mailroom. Objects that are institutional but worn-in. Cool light, not warm.

### Tokens

```ts
// theme/tokens.ts — every color and size in the app comes from here
export const color = {
  ink:     '#14161A',  // primary text, near-black with a blue cast
  slate:   '#5B6472',  // secondary text, metadata
  hairline:'#D6DAE0',  // 1px rules and borders
  paper:   '#EEF0F2',  // app background — cool gray, never cream, never white
  card:    '#FFFFFF',  // surfaces lift off the cool ground
  signal:  '#1B3FE0',  // cobalt. Bids and primary actions. Used as FILL, not accent dots.
  mint:    '#00A878',  // accepted, sold, confirmed
  flag:    '#E03131',  // rejected, reported, destructive
  token:   '#F2B705',  // the rewards economy ONLY — never touches a price or a bid
}
```

The color rule that makes this specific: **cobalt is the commerce economy, amber is the
rewards economy, and they never appear in the same component.** Prices, bids, and accept
buttons are cobalt. Token counts, streaks, and prize progress are amber. A user can tell
at a glance whether something costs them or earns them.

### Type

```
Display  Bricolage Grotesque   700   headings, listing titles, empty-state lines
Body     Inter Tight           400/500/600   everything else
Data     Martian Mono          500   prices, bid amounts, token counts, timestamps, plates
```

All three are on Google Fonts, so use `@expo-google-fonts/*`. **Every number that
represents money or a count renders in Martian Mono.** This is the app's texture — prices
align in tabular columns down the browse list, and a bid typed into the bid pad looks like
it is being entered into a machine rather than a text field.

Scale: 34/24/17/15/13. Letter-spacing tightens as size grows (`-0.02em` at 34, `0` at 13).
No font size exists outside this scale.

### Motion

Restraint. Two orchestrated moments, and nothing else animates for decoration.

1. **The swipe card has weight.** Rotation tied to horizontal displacement, spring physics
   on release, a velocity threshold rather than a distance threshold so a fast flick
   commits. All on the UI thread via Reanimated 4 worklets (`useSharedValue`,
   `useAnimatedStyle`, `withSpring`, Gesture Handler's `Gesture.Pan()`). It must never drop
   a frame. Under Reanimated 4 the worklet runtime is `react-native-worklets`; that is an
   import detail, not a behavioural change.
2. **The bid seal.** Right-swipe doesn't fling the card away — the card lifts and turns to
   reveal the bid pad, the asking price sits above as a struck-through anchor, and the
   buyer types their number in large Martian Mono. On submit the card seals and drops into
   the bids tray with a physical settle. This is the signature interaction of the product.
   Spend the animation budget here.

Everything else: 150ms opacity and transform, standard easing, done. Respect reduced motion
— read it with `AccessibilityInfo.isReduceMotionEnabled()` / the `useReducedMotion()` hook
(RN has no `prefers-reduced-motion`; that is a web media query) and swap both moments for
cross-fades.

### Copy

Sentence case everywhere. Active voice. A button names the thing that happens: "Place bid,"
not "Submit." The toast afterward says "Bid placed," matching the verb. Empty states are
invitations, not apologies: an empty deck says "You've seen everything on campus. New
listings show up here first." — not "No items found."

---

## 5. Conventions

- `app/` routes, `components/` shared UI, `features/<domain>/` domain logic, `lib/` clients,
  `theme/` tokens.
- Supabase types are generated (`supabase gen types typescript`) into `lib/database.types.ts`
  and committed. Never hand-write a row type.
- Every mutation goes through a function in `features/<domain>/api.ts`. Components never
  call `supabase` directly.
- TanStack Query for server state. No global store in v1.
- Every list screen has three explicit states: loading skeleton, empty state, error state.
  A screen shipped without all three is incomplete.
- Server-side logic (token grants, bid acceptance, notification fan-out) lives in Postgres
  functions or Edge Functions, never in the client. The client cannot be trusted to award
  itself tokens.
- **The client-callable RPC surface is a closed list.** These and only these:
  `deck_listings`, `place_bid`, `withdraw_bid`, `accept_bid`, `reopen_listing`, `mark_sold`,
  `submit_rating`, `register_push_token`, `offer_identity_reveal`,
  `withdraw_identity_reveal`, `revealed_first_name`, `is_admin`, `my_account_status`. Every
  one takes no user id from the caller and checks `auth.uid()` itself. (`my_account_status`
  exists because the client cannot read `user_identities`, so it is the only way session
  bootstrap can tell a suspended account from an empty campus.)
- The RLS policy helpers `current_university_id`, `is_active_account`, and
  `is_blocked_between` are also granted to `authenticated`, because policies execute as the
  calling role. They are not product RPCs — the app never calls them directly.
- **`grant_tokens` is never called from the app.** It has no `EXECUTE` grant to any client
  role. If a phase prompt tells you to call it from the client, that prompt is wrong — say
  so and stop.
- Adding a Postgres function is adding a public API endpoint: Postgres grants `EXECUTE` to
  `PUBLIC` by default and PostgREST exposes every public-schema function over RPC. Any new
  function must be added to the revoke/grant block in `schema.sql` section 11 in the same
  change that creates it.

---

## 6. When you are unsure

Ask before inventing. Specifically: do not invent business rules about bids, tokens, or
moderation. Do not add a dependency without saying why. Do not restructure the schema
without flagging the migration cost.
