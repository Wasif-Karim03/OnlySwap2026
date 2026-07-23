/**
 * theme/fonts.ts — the font map handed to `useFonts`, and a small helper to build a text
 * style from the tokens. The three faces come from Google Fonts via `@expo-google-fonts/*`
 * (CLAUDE.md section 4).
 */
import { BricolageGrotesque_700Bold } from '@expo-google-fonts/bricolage-grotesque';
import {
  InterTight_400Regular,
  InterTight_500Medium,
  InterTight_600SemiBold,
} from '@expo-google-fonts/inter-tight';
import { MartianMono_500Medium } from '@expo-google-fonts/martian-mono';
import type { TextStyle } from 'react-native';

import { fontFamily, fontSize, letterSpacing, lineHeight } from './tokens';
import type { FontSizeName } from './tokens';

// The exact object `useFonts` expects. Keys must match the family strings in tokens.ts.
export const fontMap = {
  BricolageGrotesque_700Bold,
  InterTight_400Regular,
  InterTight_500Medium,
  InterTight_600SemiBold,
  MartianMono_500Medium,
} as const;

type Face = keyof typeof fontFamily;

/**
 * Compose a text style from one size step and one face. Every size carries its matched
 * letter-spacing and line-height from the scale, so callers never set those by hand.
 *
 *   type('display', 'display')  → the big Bricolage heading
 *   type('body', 'bodyRegular') → default Inter Tight body
 *   type('body', 'data')        → a money value in Martian Mono at body size
 */
export function type(size: FontSizeName, face: Face): TextStyle {
  return {
    fontFamily: fontFamily[face],
    fontSize: fontSize[size],
    letterSpacing: letterSpacing[size],
    lineHeight: lineHeight[size],
  };
}
