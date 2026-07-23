/**
 * theme/tokens.ts — the single source of every color, size, and type decision in the app.
 *
 * CLAUDE.md section 4 is the spec. Nothing in the app hardcodes a hex value, a font size, or
 * a font family: it imports from here. If a value is not in this file, it does not exist.
 *
 * The one rule that makes the palette specific (CLAUDE.md section 4): cobalt is the COMMERCE
 * economy (prices, bids, accept), amber is the REWARDS economy (tokens, streaks, prizes), and
 * the two never appear in the same component. `color.signal` and `color.token` are kept in
 * separate exported groups below to make an accidental mix visible in a diff.
 */

// ── Palette (CLAUDE.md section 4 — do not add or alter a value without updating that section)
export const color = {
  ink: '#14161A', // primary text, near-black with a blue cast
  slate: '#5B6472', // secondary text, metadata
  hairline: '#D6DAE0', // 1px rules and borders
  paper: '#EEF0F2', // app background — cool gray, never cream, never white
  card: '#FFFFFF', // surfaces lift off the cool ground
  signal: '#1B3FE0', // cobalt. Bids and primary actions. Used as FILL, not accent dots.
  mint: '#00A878', // accepted, sold, confirmed
  flag: '#E03131', // rejected, reported, destructive
  token: '#F2B705', // the rewards economy ONLY — never touches a price or a bid
} as const;

export type ColorName = keyof typeof color;

/**
 * Semantic economy groupings. Import from `commerce` for anything on the money path and from
 * `rewards` for anything on the token path — a component that reaches into both is the bug the
 * color rule exists to prevent.
 */
export const commerce = {
  fill: color.signal,
  accepted: color.mint,
  rejected: color.flag,
} as const;

export const rewards = {
  fill: color.token,
} as const;

// ── Type scale (CLAUDE.md section 4). Sizes: 34/24/17/15/13, letter-spacing tightens with size.
// Letter-spacing in RN is an absolute point value, not em. These are px equivalents of the
// spec's em targets against each size (−0.02em at 34 ≈ −0.68; 0 at 13).
export const fontSize = {
  display: 34,
  title: 24,
  body: 17,
  callout: 15,
  caption: 13,
} as const;

export type FontSizeName = keyof typeof fontSize;

export const letterSpacing = {
  display: -0.68, // −0.02em × 34
  title: -0.36, // ≈ −0.015em × 24
  body: -0.17, // ≈ −0.01em × 17
  callout: -0.08, // ≈ −0.005em × 15
  caption: 0, // 0 at 13
} as const;

// Nudged line heights — tight on the display face, roomier for body copy.
export const lineHeight = {
  display: 38,
  title: 28,
  body: 24,
  callout: 21,
  caption: 18,
} as const;

/**
 * Font families. The string values are the names the fonts register under via
 * `@expo-google-fonts/*` — see theme/fonts.ts. Three faces, each with a fixed role:
 *   display — Bricolage Grotesque 700: headings, listing titles, empty-state lines
 *   body    — Inter Tight 400/500/600: everything else
 *   data    — Martian Mono 500: EVERY number that is money or a count, plus timestamps + plates
 */
export const fontFamily = {
  display: 'BricolageGrotesque_700Bold',
  bodyRegular: 'InterTight_400Regular',
  bodyMedium: 'InterTight_500Medium',
  bodySemiBold: 'InterTight_600SemiBold',
  data: 'MartianMono_500Medium',
} as const;

export type FontFamilyName = keyof typeof fontFamily;

// ── Spacing. A small, deliberately non-uniform scale — CLAUDE.md section 4 warns against
// "uniform 16px everything", so the steps are irregular on purpose.
export const space = {
  xs: 4,
  sm: 8,
  md: 12,
  lg: 20,
  xl: 32,
  xxl: 52,
} as const;

export type SpaceName = keyof typeof space;

export const radius = {
  sm: 6,
  md: 10,
  lg: 16,
  pill: 999,
} as const;

export const hairlineWidth = 1;

export const theme = {
  color,
  commerce,
  rewards,
  fontSize,
  letterSpacing,
  lineHeight,
  fontFamily,
  space,
  radius,
  hairlineWidth,
} as const;

export type Theme = typeof theme;
