/**
 * app/theme-preview.tsx — the Phase 0 deliverable. It renders, from tokens only:
 *   • every color swatch, with name + hex, grouped so the commerce/rewards split is visible
 *   • every type size (34/24/17/15/13) in each of the three faces
 *   • sample money values in Martian Mono, aligned in a tabular column
 *
 * This screen is the reference the whole app inherits (BUILD_PLAN Phase 0 exit test: open it
 * on a real phone and fix the type here before anything downstream depends on it). It uses no
 * hardcoded colors or sizes — if something looks wrong, the fix is in theme/tokens.ts.
 */
import { useMemo } from 'react';
import { ScrollView, StyleSheet, Text, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { type } from '@/theme/fonts';
import {
  color,
  fontFamily,
  fontSize,
  radius,
  space,
  hairlineWidth,
  type ColorName,
  type FontSizeName,
} from '@/theme/tokens';

const SWATCHES: { group: string; names: ColorName[]; note: string }[] = [
  {
    group: 'Ground & ink',
    names: ['paper', 'card', 'ink', 'slate', 'hairline'],
    note: 'cool gray, never cream',
  },
  { group: 'Commerce — cobalt', names: ['signal'], note: 'prices, bids, primary actions' },
  { group: 'States', names: ['mint', 'flag'], note: 'accepted / sold · rejected / destructive' },
  { group: 'Rewards — amber', names: ['token'], note: 'tokens only, never a price' },
];

const SIZE_ROWS: { size: FontSizeName; label: string }[] = [
  { size: 'display', label: '34 · display' },
  { size: 'title', label: '24 · title' },
  { size: 'body', label: '17 · body' },
  { size: 'callout', label: '15 · callout' },
  { size: 'caption', label: '13 · caption' },
];

// Deliberately varied magnitudes so tabular alignment is visible down the column.
const MONEY_CENTS = [500, 4500, 12000, 99900, 250000];

function centsToUsd(cents: number): string {
  return `$${(cents / 100).toFixed(2)}`;
}

function isLight(hex: string): boolean {
  const n = hex.replace('#', '');
  const r = parseInt(n.slice(0, 2), 16);
  const g = parseInt(n.slice(2, 4), 16);
  const b = parseInt(n.slice(4, 6), 16);
  // perceived luminance; pick a legible label color for the chip
  return (0.299 * r + 0.587 * g + 0.114 * b) / 255 > 0.6;
}

function SectionHeader({ children }: { children: string }) {
  return <Text style={styles.sectionHeader}>{children}</Text>;
}

function Swatch({ name }: { name: ColorName }) {
  const hex = color[name];
  const labelColor = isLight(hex) ? color.ink : color.card;
  return (
    <View style={styles.swatch}>
      <View style={[styles.swatchChip, { backgroundColor: hex }]}>
        <Text style={[styles.swatchName, { color: labelColor }]}>{name}</Text>
      </View>
      <Text style={styles.swatchHex}>{hex.toUpperCase()}</Text>
    </View>
  );
}

export default function ThemePreview() {
  const insets = useSafeAreaInsets();
  const faces = useMemo(
    () =>
      [
        { key: 'display' as const, label: 'Bricolage Grotesque 700', family: fontFamily.display },
        { key: 'bodyRegular' as const, label: 'Inter Tight 400', family: fontFamily.bodyRegular },
        { key: 'bodyMedium' as const, label: 'Inter Tight 500', family: fontFamily.bodyMedium },
        { key: 'bodySemiBold' as const, label: 'Inter Tight 600', family: fontFamily.bodySemiBold },
        { key: 'data' as const, label: 'Martian Mono 500', family: fontFamily.data },
      ] as const,
    [],
  );

  return (
    <ScrollView
      style={styles.screen}
      contentContainerStyle={[
        styles.content,
        { paddingTop: insets.top + space.lg, paddingBottom: insets.bottom + space.xxl },
      ]}
    >
      <Text style={styles.kicker}>ONLYSWAP · THEME</Text>
      <Text style={styles.h1}>The system, on one page.</Text>
      <Text style={styles.lede}>
        Every color and size below is imported from theme/tokens.ts. Nothing here is hardcoded —
        this page is the reference the app inherits.
      </Text>

      {/* ── Color ─────────────────────────────────────────────────────────── */}
      <SectionHeader>Color</SectionHeader>
      <Text style={styles.rule}>
        Cobalt is the commerce economy. Amber is the rewards economy. They never share a component.
      </Text>
      {SWATCHES.map((s) => (
        <View key={s.group} style={styles.swatchGroup}>
          <Text style={styles.swatchGroupTitle}>{s.group}</Text>
          <Text style={styles.swatchGroupNote}>{s.note}</Text>
          <View style={styles.swatchRow}>
            {s.names.map((n) => (
              <Swatch key={n} name={n} />
            ))}
          </View>
        </View>
      ))}

      {/* ── Type scale in every face ──────────────────────────────────────── */}
      <SectionHeader>Type — scale in every face</SectionHeader>
      {faces.map((face) => (
        <View key={face.key} style={styles.faceBlock}>
          <Text style={styles.faceLabel}>{face.label}</Text>
          {SIZE_ROWS.map((row) => (
            <View key={row.size} style={styles.typeRow}>
              <Text style={styles.typeMeta}>{row.label}</Text>
              <Text
                style={{
                  fontFamily: face.family,
                  fontSize: fontSize[row.size],
                  color: color.ink,
                }}
                numberOfLines={1}
              >
                Meet on campus
              </Text>
            </View>
          ))}
        </View>
      ))}

      {/* ── Money in Martian Mono, tabular ────────────────────────────────── */}
      <SectionHeader>Money — Martian Mono, tabular</SectionHeader>
      <Text style={styles.rule}>
        Every number that is money or a count renders in Martian Mono. Prices align down the column.
      </Text>
      <View style={styles.moneyCard}>
        {MONEY_CENTS.map((cents, i) => (
          <View
            key={cents}
            style={[styles.moneyRow, i < MONEY_CENTS.length - 1 && styles.moneyRowDivider]}
          >
            <Text style={styles.moneyLabel}>Listing {i + 1}</Text>
            <Text style={styles.moneyValue}>{centsToUsd(cents)}</Text>
          </View>
        ))}
      </View>

      {/* One commerce chip and one rewards chip, to show the two economies side by side but
          never blended within a single element. */}
      <View style={styles.economyRow}>
        <View style={[styles.economyChip, { backgroundColor: color.signal }]}>
          <Text style={styles.economyChipLabel}>Bid</Text>
          <Text style={styles.economyChipValue}>{centsToUsd(4200)}</Text>
        </View>
        <View style={[styles.economyChip, { backgroundColor: color.token }]}>
          <Text style={[styles.economyChipLabel, { color: color.ink }]}>Tokens</Text>
          <Text style={[styles.economyChipValue, { color: color.ink }]}>+25</Text>
        </View>
      </View>

      <Text style={styles.footer}>theme/tokens.ts · theme/fonts.ts</Text>
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: color.paper },
  content: { paddingHorizontal: space.lg },

  kicker: { ...type('caption', 'data'), color: color.slate, marginBottom: space.sm },
  h1: { ...type('display', 'display'), color: color.ink, marginBottom: space.md },
  lede: { ...type('body', 'bodyRegular'), color: color.slate, marginBottom: space.xl },

  sectionHeader: {
    ...type('title', 'display'),
    color: color.ink,
    marginTop: space.xl,
    marginBottom: space.sm,
  },
  rule: { ...type('callout', 'bodyRegular'), color: color.slate, marginBottom: space.lg },

  swatchGroup: { marginBottom: space.lg },
  swatchGroupTitle: { ...type('callout', 'bodySemiBold'), color: color.ink },
  swatchGroupNote: {
    ...type('caption', 'bodyRegular'),
    color: color.slate,
    marginBottom: space.sm,
  },
  swatchRow: { flexDirection: 'row', flexWrap: 'wrap', gap: space.sm },
  swatch: { width: 104 },
  swatchChip: {
    height: 72,
    borderRadius: radius.md,
    borderWidth: hairlineWidth,
    borderColor: color.hairline,
    padding: space.sm,
    justifyContent: 'flex-end',
  },
  swatchName: { ...type('caption', 'bodyMedium') },
  swatchHex: { ...type('caption', 'data'), color: color.slate, marginTop: space.xs },

  faceBlock: {
    backgroundColor: color.card,
    borderRadius: radius.lg,
    borderWidth: hairlineWidth,
    borderColor: color.hairline,
    padding: space.lg,
    marginBottom: space.md,
  },
  faceLabel: { ...type('caption', 'data'), color: color.slate, marginBottom: space.md },
  typeRow: { marginBottom: space.md },
  typeMeta: { ...type('caption', 'data'), color: color.slate, marginBottom: space.xs },

  moneyCard: {
    backgroundColor: color.card,
    borderRadius: radius.lg,
    borderWidth: hairlineWidth,
    borderColor: color.hairline,
    paddingHorizontal: space.lg,
  },
  moneyRow: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    paddingVertical: space.md,
  },
  moneyRowDivider: { borderBottomWidth: hairlineWidth, borderBottomColor: color.hairline },
  moneyLabel: { ...type('body', 'bodyRegular'), color: color.ink },
  moneyValue: { ...type('body', 'data'), color: color.signal },

  economyRow: { flexDirection: 'row', gap: space.md, marginTop: space.lg },
  economyChip: {
    flex: 1,
    borderRadius: radius.md,
    padding: space.lg,
    gap: space.xs,
  },
  economyChipLabel: { ...type('caption', 'data'), color: color.card },
  economyChipValue: { ...type('title', 'data'), color: color.card },

  footer: {
    ...type('caption', 'data'),
    color: color.slate,
    textAlign: 'center',
    marginTop: space.xxl,
  },
});
