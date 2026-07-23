import type { ExpoConfig, ConfigContext } from 'expo/config';

/**
 * app.config.ts replaces app.json so configuration can read from the environment.
 *
 * The .env pattern (CLAUDE.md Phase 0): non-secret, build-time values are read from
 * process.env HERE and passed to the app through `extra`. At runtime the app reads them via
 * `expo-constants` — see lib/env.ts, which is the ONLY place `Constants.expoConfig.extra` is
 * touched. Nothing secret goes here: per CLAUDE.md hard rule 4, the R2 write credential and
 * the Supabase service-role key live in Edge Functions, never in the bundle. Only the
 * Supabase URL and the anon key (which is public by design) travel this path.
 */
export default ({ config }: ConfigContext): ExpoConfig => ({
  ...config,
  name: 'OnlySwap',
  slug: 'onlyswap',
  version: '1.0.0',
  orientation: 'portrait',
  icon: './assets/images/icon.png',
  scheme: 'onlyswap',
  userInterfaceStyle: 'automatic',
  // New Architecture (Fabric) is default-on in SDK 57, which Reanimated 4 requires. No flag
  // needed — it was removed from ExpoConfig once it became the default.
  ios: {
    supportsTablet: false,
    bundleIdentifier: 'app.onlyswap.mobile',
  },
  android: {
    package: 'app.onlyswap.mobile',
    adaptiveIcon: {
      backgroundColor: '#EEF0F2', // color.paper
      foregroundImage: './assets/images/android-icon-foreground.png',
      backgroundImage: './assets/images/android-icon-background.png',
      monochromeImage: './assets/images/android-icon-monochrome.png',
    },
    predictiveBackGestureEnabled: false,
  },
  web: {
    output: 'static',
    favicon: './assets/images/favicon.png',
  },
  plugins: [
    'expo-router',
    'expo-font',
    [
      'expo-splash-screen',
      {
        backgroundColor: '#EEF0F2', // color.paper — cool gray, never the template's blue
        image: './assets/images/splash-icon.png',
        imageWidth: 76,
      },
    ],
  ],
  experiments: {
    typedRoutes: true,
    reactCompiler: true,
  },
  extra: {
    // Read at runtime through lib/env.ts. Empty string when unset so the app can show a
    // legible "not configured" state instead of crashing on undefined during Phase 0.
    supabaseUrl: process.env.EXPO_PUBLIC_SUPABASE_URL ?? '',
    supabaseAnonKey: process.env.EXPO_PUBLIC_SUPABASE_ANON_KEY ?? '',
  },
});
