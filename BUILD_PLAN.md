# OnlySwap — Build Plan

Thirteen phases. Each is one Claude Code session, each ends with something you can run and
look at, and each has an exit test you must actually perform before moving on.

**Rules for working this way:**
- `CLAUDE.md` sits at the repo root. Claude Code reads it every session.
- One phase per session. Start a fresh session between phases — a long context degrades.
- Never let a phase end with something untested. "It compiles" is not the exit test.
- Commit at the end of every phase.

> **Renumbered in revision 2.** A new Phase 2 ("The server boundary") was inserted, and
> everything after it shifted by one. Old Phase 9 (settings/safety/deletion) is now
> Phase 10, which is what CLAUDE.md hard rule 6 refers to. Old Phase 11 is now Phase 12.

---

## Phase 0 — Foundations

**Prompt:**
> Read CLAUDE.md. Scaffold an Expo project with TypeScript strict, Expo Router,
> Reanimated 3, Gesture Handler, TanStack Query, and the Supabase JS client. Set up
> `theme/tokens.ts` with the exact palette and type scale from CLAUDE.md section 4, load
> Bricolage Grotesque, Inter Tight, and Martian Mono via @expo-google-fonts, and build a
> single `/theme-preview` route that renders every color swatch, every type size in each
> face, and sample money values in Martian Mono. Set up ESLint, Prettier, and a `.env`
> pattern using `expo-constants`. Do not build any product screens.

**Exit test:** open `/theme-preview` on a real phone. If the type doesn't feel right, fix
it here. Everything downstream inherits it.

---

## Phase 1 — Database

**Prompt:**
> Read CLAUDE.md and schema.sql. Create a Supabase project migration from schema.sql and
> apply it. Implement the two helper stubs named in schema.sql section 12:
> `generate_handle()` from a curated adjective/noun word list sized for at least 5,000
> collision-free handles per campus, and `plate_color_for(uuid)` returning a deterministic
> color. Write `seed.sql` inserting one real university, one `is_demo` university, and 12
> fake profiles per campus. Generate TypeScript types into `lib/database.types.ts`.
>
> Then write `scripts/rls-test.ts`. It must assert, as separate named cases:
> 1. two users at different universities each read only their own campus's listings
> 2. neither can read `user_identities` at all
> 3. a non-participant cannot read a conversation's messages
> 4. a client calling `grant_tokens` over RPC is denied
> 5. a client `UPDATE profiles SET tokens = 999999` is denied
> 6. a client `UPDATE profiles SET university_id = <other campus>` is denied
> 7. a client `UPDATE listings SET university_id = <other campus>` is denied
> 8. a client INSERT into `bids`, `conversations`, `ratings`, or `token_events` is denied
> 9. a client UPDATE of another user's bid status is denied
> 10. deleting a listing that has a conversation and bids succeeds (as service role)
> 11. a suspended user's `current_university_id()` returns null and they read nothing
> 12. **the suspension audit.** For every policy scoped by `auth.uid()` alone —
>     `conv_read`, `msg_read`, `msg_insert`, `swipe_own`, `block_own`, `bid_read`,
>     `reveal_read`, `token_read_own`, `report_read_own`, `push_read_own`, `img_write` — a
>     suspended user is denied. Assert as separate sub-cases that a suspended user (a) reads
>     zero rows from their own conversations, messages, bids, and token ledger, and (b) is
>     **denied INSERT** on `messages`, `swipes`, `blocks`, and `listing_images`. The write
>     cases matter most: a `FOR ALL` policy checks `WITH CHECK` on insert, not `USING`, so a
>     suspension gate on `USING` alone leaves the write path open. That exact gap existed and
>     this case is what catches its regression.
> 13. a suspended user can still `DELETE` their own `push_tokens` row (forced-logout cleanup
>     must not be blocked, or they keep receiving pushes for an account they can't open).
> 14. `my_account_status()` returns `'suspended'` for a suspended caller and `'active'` for
>     an active one — this is what lets session bootstrap show the suspended screen instead
>     of an empty app, since the client cannot read `user_identities`.
> 15. **deleted user with an authored message.** A buyer posts a real (non-system) message,
>     then deletes their account in-app. Assert the message still exists, `is_system` is
>     still false, and it renders as authored by the anonymized `deleted-xxxx` handle (its
>     `sender_id` is intact because in-app deletion anonymizes the profile rather than
>     dropping the row). Then, as service role, hard-delete the profile and assert the whole
>     conversation cascades away — so an authored message can never be left orphaned with a
>     null sender and mis-rendered as a system message.

**Exit test:** all fifteen cases pass. **Do not skip this.** Everything you build after this
assumes the database is the security boundary. If it leaks here, it leaks everywhere. Cases
4 through 9 are the holes that were in revision 1 of the schema; case 12's write sub-cases
are the suspension-gate gap found while hardening it. All are regression tests, not
hypotheticals.

---

## Phase 2 — The server boundary

Everything CLAUDE.md promises is server-side but the tables alone cannot deliver. Build it
before any screen depends on it, because every one of these has a client-side shortcut that
looks like it works.

**Prompt:**
> Read CLAUDE.md sections 2 and 5 and schema.sql sections 9 through 11. Implement, migrate,
> and test the server boundary. Nothing here is called from a component; everything is
> exercised by a test script.
>
> 1. **Signup trigger.** `handle_new_user()` on `auth.users` insert: reject unknown
>    domains, create the `user_identities` row and the `profiles` row with a unique handle,
>    plate, and deterministic plate color. The client has no INSERT policy on either table,
>    so this trigger is the only way a user comes into existence.
> 2. **Bid lifecycle.** `place_bid` (insert new + withdraw previous + create conversation +
>    insert the system message, one transaction), `withdraw_bid`, `accept_bid` with its row
>    lock, `reopen_listing`, `mark_sold`.
> 3. **Conversation creation and system messages.** Only `place_bid` creates a
>    conversation. `msg_insert` forbids `is_system = true`, so the client can never forge
>    one. Define the system message payload format here and document it — Phase 7 renders
>    it, and changing the format later means migrating existing rows.
> 4. **`last_message_at`.** The `trg_message_inserted` trigger. Two indexes sort by this
>    column; without the trigger it stays null forever and the conversation list is
>    unordered.
> 5. **Block-aware deck.** `deck_listings`, plus `is_blocked_between`. Blocking must work
>    in both directions, which is exactly what the `blocks` RLS policy cannot see — that is
>    why this is an RPC and not a client query.
> 6. **Token grants.** `grant_tokens` with its idempotency key, the listing-creation daily
>    cap, and the sale and five-star payouts. Confirm it has no client `EXECUTE` grant.
> 7. **Ratings.** `submit_rating` with the participation check, and `on_rating_inserted`.
> 8. **Reveal handshake.** `offer_identity_reveal`, `withdraw_identity_reveal`,
>    `revealed_first_name`.
> 9. **Push registration.** `register_push_token`, which reassigns a token that already
>    belongs to another user.
>
> Write `scripts/server-boundary-test.ts` covering, at minimum: a re-bid leaves exactly one
> live bid and one withdrawn row; `accept_bid` called twice concurrently accepts exactly
> one; a blocked user's listing is absent from `deck_listings` in both block directions; a
> retried `grant_tokens` awards once; a non-participant's `submit_rating` fails; the reveal
> returns null on one offer and a name on two; `register_push_token` moves a token between
> users cleanly.

**Exit test:** `server-boundary-test.ts` passes, and `select proname from pg_proc p join
pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public'` cross-checked against
schema.sql section 11 shows no function granted to `authenticated` that isn't on the closed
list in CLAUDE.md section 5. Every function you add for the rest of the build gets checked
against that list.

---

## Phase 3 — Auth, campus binding, and the App Review path

**Prompt:**
> Build signup and login on top of the Phase 2 trigger. Signup takes an email and a first
> name, rejects any domain not present in `universities` with `is_active`, and sends a
> Supabase magic link. The first name goes into `auth.users.raw_user_meta_data` so the
> trigger can write it to `user_identities.first_name`; it is never written to `profiles`.
> Build the session bootstrap that loads the profile and gates the app on it. Handle:
> unverified user, suspended account, deleted account, and unknown domain — each with its
> own screen and its own copy. A suspended or deleted user's `current_university_id()`
> returns null, so they will see empty data everywhere. **Do not infer the reason from
> empty data** — the client cannot read `user_identities`, so an empty deck and a
> suspension are indistinguishable from row counts. Call `my_account_status()` at bootstrap:
> `'suspended'` routes to a dedicated suspended-account screen that explains what happened
> and how to appeal, `'deleted'` to the deletion-confirmation screen, `'active'` (or a
> genuinely empty campus) to the app. A suspended user must see an explanation, never a
> silently empty app.
>
> At signup, disclose the identity model in one plain sentence before the email field:
> real names are hidden, and are shared only if both people choose to share after a deal is
> agreed. Link the privacy policy.
>
> **The App Review path.** App Review cannot create a `.edu` account, so design the way in
> now rather than discovering it in Phase 12:
> - Register a real domain you control and add it to `universities` as an `is_demo` row
>   with `is_active = true`. It is a real campus as far as every policy is concerned — no
>   bypass, no special case, no branch in the auth code.
> - **Reviewer login is password auth.** Enable Supabase email+password auth in addition to
>   magic links. Provision two demo accounts on the demo domain through the normal signup
>   flow, set a password on each, and put the email + password straight in the review notes
>   so a reviewer logs in in one step with no mailbox round-trip. Build the login screen to
>   accept either a magic link or a password; real `.edu` users can be steered to magic-link
>   in the signup UI, but the password grant is enabled account-wide and that is fine —
>   there is no separate reviewer code path, just a second credential type on one login form.
> - `is_demo` is used for exactly two things: excluding the campus from analytics, and
>   keeping demo seed content out of any real campus's deck. It must never appear in an
>   auth conditional.
> - Write down now what a reviewer has to be able to do end to end: browse, swipe, place a
>   bid, receive a bid, chat, report, block, and delete an account.

**Exit test:** sign up with `gmail.com` and get a clear, non-generic rejection. Sign up with
a valid domain and land on an empty home screen with your generated handle visible. Then, on
a device that has never run the app, **log in with the demo email and password from the
review notes** and confirm you land in a populated campus in one step — that is the exact
path a reviewer takes, and Phase 3 is where you confirm it works, not Phase 12. Finally,
suspend that demo account from the Supabase dashboard and confirm the app shows the
suspended-account screen with its explanation rather than an empty deck.

---

## Phase 4 — Images

**Prompt:**
> Build the image pipeline. A Supabase Edge Function issues presigned R2 upload URLs — the
> R2 credential never reaches the client. On the device, `expo-image-manipulator` resizes
> to 1080px longest edge, converts to WebP at quality 0.7, and produces a 300px thumbnail;
> both upload, and `listing_images` records both keys. Build a reusable `<RemoteImage>`
> that takes an R2 key, uses `expo-image` with disk caching and a blurhash placeholder.
> Include an upload progress state and a retry path for a failed upload.

**Exit test:** upload a 4MB photo, then check the R2 dashboard. If the stored object is
over ~200KB, the compression is wrong — fix it now, before you have a thousand of them.

---

## Phase 5 — Listings

**Prompt:**
> Build listing creation (photos, title, description, price, condition, meetup location)
> and the browse tab: a scrollable list of active listings in my university, newest first,
> with thumbnail, title, and price in Martian Mono, plus search and a condition filter.
> Search uses the trigram index on `listings.title`. Build the listing detail screen. Every
> list has explicit loading, empty, and error states per CLAUDE.md.
>
> Tokens for listing creation are awarded by the `trg_listing_created` trigger. Do not call
> `grant_tokens` from the app — it has no client EXECUTE grant and the call will fail.
> Surface the daily creation rate limit as a real error state, not a crash.
>
> Editing a listing must make the `bumped_at` consequence legible: a price drop returns the
> listing to decks that dismissed it, and a title or description edit does so at most once
> a day. Say this in the edit screen's copy.

**Exit test:** post three listings from one seeded account, see them from another. Then
drop the price on one and confirm `bumped_at` moved; edit a title twice in a row and
confirm the second edit did not move it.

---

## Phase 6 — The swipe deck and the bid seal

This is the phase that decides whether the app feels good. Budget real time for it.

**Prompt:**
> Build the swipe deck per CLAUDE.md section 4 "Motion". Deck comes from the
> `deck_listings` RPC — never a client-side query, because the block filter has to see
> blocks in both directions. Prefetch in pages of 20 with the next 3 cards' images
> preloaded. Gestures and animation entirely in Reanimated worklets on the UI thread:
> rotation tied to horizontal displacement, spring on release, velocity threshold for
> commit.
>
> Left swipe records via upsert (see CLAUDE.md section 3 — a plain insert fails on a
> resurfaced listing) and advances. Right swipe does NOT fling — the card lifts and turns
> to reveal the bid pad, with the asking price above as a struck-through anchor and the
> buyer's number entered in large Martian Mono. Submitting calls `place_bid` and only then
> records the right swipe; cancelling the bid pad records nothing and returns the card to
> the deck in place. On submit the card seals and settles into the bids tray. Honor
> reduced-motion with cross-fades. Handle the exhausted-deck state.

**Exit test:** two parts, and the second is the one people skip.
1. Flick twenty cards fast on a physical mid-range Android device. Watch for dropped
   frames. If it stutters, the gesture logic ran on the JS thread — fix it, don't ship it.
2. Open the bid pad, type a number, and submit — on the same device, with the keyboard
   animating. The card-to-bid-pad transition is the signature interaction and it is where
   the UI thread hands off to JS. Measure it, not just the swipe.

Also confirm a new user on the demo campus has at least 20 cards. If the deck empties in
under a minute of normal use, the deck is not viable as the primary surface and that is a
product finding worth having now.

---

## Phase 7 — Chat

**Prompt:**
> Build the conversation list and thread using Supabase Realtime, with optimistic send,
> failed-send retry, and pagination. Conversations and their opening system message are
> created by `place_bid` in Phase 2 — the client neither creates conversations nor inserts
> system messages, and both are blocked at the policy level. Render the system message from
> the payload format defined in Phase 2, carrying the listing thumbnail, title, and bid
> amount.
>
> Build the persistent bid bar above the composer per CLAUDE.md section 3 — buyer side
> shows the live bid and "Change bid", seller side shows the top bid with accept and
> reject. This is the only re-bid entry point once a card has left the deck.
>
> Build the mutual reveal handshake: offer, withdrawn-while-unmatched, and the revealed
> state. One-sided offers must not be visible to the other party. Use the copy in
> CLAUDE.md section 3 verbatim — it is deliberately non-coercive — and put a report entry
> point in the reveal sheet.
>
> Participants otherwise see each other only as handle and plate. Blocks are enforced by
> the `msg_insert` policy; surface the resulting failure as a clear state, not a silent
> no-op.

**Exit test:** two devices, one bid, message back and forth, kill the network mid-send and
confirm the failed message is recoverable rather than silently lost. Then have one side
offer a reveal and confirm the other side sees nothing until they offer too.

---

## Phase 8 — Notifications

**Prompt:**
> Register Expo push tokens on login via `register_push_token` and clear them on logout —
> a stale token on a shared or resold device pushes one student's chat to another student's
> phone, which in an anonymity-first app is a real leak. Build a Supabase Edge Function
> that sends push on: new bid received, bid accepted, bid rejected, new message, new
> rating, and a completed mutual reveal. Deep-link each type to the right screen.
>
> Build the 48-hour quiet-conversation job implementing the lifecycle rules in CLAUDE.md
> section 3: ask both parties, the seller's answer is authoritative, seller-yes calls
> `mark_sold`, seller-no calls `reopen_listing`, a buyer disagreement writes an admin flag,
> and no answer from either within 7 days auto-reopens. Build in-app notification
> preferences.

**Exit test:** background the app, receive a bid, tap the notification, land on that bid.
Then run the quiet-conversation job against a `pending` listing with no answers, advance
the clock 7 days, and confirm the listing is `active` again. A listing must never be able
to rot in `pending`.

---

## Phase 9 — Requests, ratings, tokens

**Prompt:**
> Build the requests tab as a read-only bulletin board per CLAUDE.md section 3: post an
> "I need X" with an optional budget, chronological list, three explicit states. The CTA on
> a request is "Post a listing", prefilled with the request title. There is no "I have
> this" and no conversation from a request in v1 — `conversations` has no `request_id`.
>
> Build post-sale rating through `submit_rating`, which requires that you were actually one
> of the two parties to an accepted bid on a sold listing. Surface the "you weren't part of
> this sale" failure honestly rather than hiding the control. Build the profile view showing
> handle, plate, rating average and count.
>
> Build the tokens screen: balance in amber, the ledger from `token_events`, and progress
> toward prize thresholds. Tokens are display-only — redemption is manual and handled by
> admin. Amber never touches a price or a bid.

**Exit test:** complete a full sale between two accounts and confirm tokens landed on both
sides via the ledger, not just the cached balance. Then try to rate a stranger's sale you
had no part in and confirm it fails at the database, not in the UI.

---

## Phase 10 — Settings, safety, deletion

Do not defer this. Two of these three items gate your App Store submission.

**Prompt:**
> Build settings: edit avatar (the only client-writable profile column), view my listings
> with mark-sold / delete, view my bids, notification preferences. "Delete" a listing sets
> `status = 'removed'` — listings are never hard-deleted from the client, because that
> would take the conversations and bids with them.
>
> Build report flows for listing, profile, message, and request, each writing to `reports`.
> One report per person per target is enforced by a unique constraint; show the already-
> reported state rather than letting it fail.
>
> Build block and unblock with a managed block list. Blocking is enforced in the database —
> `deck_listings` and the `msg_insert` policy — so verify it there, not just in the UI.
>
> Build in-app account deletion calling `delete_my_account`, which scrubs PII in place
> rather than deleting the identity row. The Edge Function wrapping it must, in order:
> collect the R2 keys the function returns, purge them from R2, then scrub and ban the
> `auth.users` row through the admin API. Deleting the identity row outright would remove
> the status gate that `current_university_id()` checks and leave a deleted account
> browsing on a live session. Add a confirmation step stating plainly what is erased, and a
> matching web deletion-request page for Google Play.

**Exit test:** delete an account and verify from the Supabase dashboard that the identity
row's PII columns are null, `status = 'deleted'`, the profile is anonymized rather than
orphaned, the R2 objects are gone, and the old session can no longer read a single row.
Then confirm the counterparty's chat history with that user still renders, and that the
deleted user's old messages are *not* styled as system messages.

---

## Phase 11 — Admin panel

**Prompt:**
> New Next.js app in `admin/`, deployed to Cloudflare Pages, using the Supabase service
> role key server-side only, with its own login restricted to `user_identities.is_admin`.
> Screens: users (real identity, status, suspend/reinstate, send email), listings (all,
> with force-remove), bids including withdrawn and superseded history, conversations with
> full message history, swipe analytics per user and per listing, and a reports queue with
> actioning — including the deal-disagreement flags raised in Phase 8. Every admin action
> writes to an audit log table. Server components only — the service role key must never
> reach a browser bundle.

**Exit test:** confirm with your browser devtools that no service role key appears in any
client bundle. Then suspend a test user and confirm they're locked out of the app — this
works because `current_university_id()` checks status, so verify it fails closed on every
tab, not just at login.

---

## Phase 12 — Store preparation

**Prompt:**
> Configure EAS Build for iOS and Android and EAS Update. Add Sentry. Set app icons,
> splash, bundle identifiers, and a 17+/Mature age rating. Generate screenshots at required
> device sizes. Write the store listing copy, the privacy policy covering .edu email, first
> names and the mutual reveal, images, chat content, and meetup locations, and fill Apple's
> App Privacy questionnaire and Google's Data Safety form consistently.
>
> Seed the demo campus provisioned in Phase 3 with 25 realistic listings, several active
> conversations, and live bids. Write review notes with the demo credentials and a
> walkthrough of the swipe-to-bid flow. For Guideline 1.2, state plainly where report,
> block, and account deletion live in the UI, and commit to acting on reports within 24
> hours — which is a commitment the Phase 11 reports queue has to be able to keep.

**Exit test:** TestFlight build installs on a phone that has never run the app, and a
reviewer-shaped run-through on the demo campus completes browse → swipe → bid → chat →
report → block → delete. Then start Google's closed test immediately — 12 testers, 14
continuous days, and that clock is what determines your launch date.

---

## What to do first, today

1. Start Apple Developer enrollment. It is the longest pole and it runs in parallel.
2. Register the demo campus domain. Phase 3 needs it, and DNS setup runs on someone else's
   clock. The two demo accounts use email+password (enable that grant type in Supabase Auth
   in Phase 3), so no mailbox provisioning is required for the reviewer path.
3. Decide the name. It affects the bundle identifier, and changing that after Phase 12 is
   painful.
4. Run Phase 0.

The sequencing that matters: Phase 1's RLS test and Phase 2's boundary test gate
everything, Phase 6 decides whether the product feels good, and Phase 10 gates whether you
can submit at all.
