/**
 * app/_layout.tsx — the root layout. It does four things and nothing product-specific
 * (Phase 0 ships no product screens):
 *   1. holds the splash screen until the three font faces are loaded
 *   2. mounts GestureHandlerRootView (required by Gesture Handler / Reanimated 4, and the
 *      swipe deck in Phase 6 will not work without it at the root)
 *   3. provides SafeAreaProvider and the TanStack Query client
 *   4. renders the Expo Router Stack with a headerless, paper-colored screen default
 */
import { useFonts } from 'expo-font';
import { Stack } from 'expo-router';
import * as SplashScreen from 'expo-splash-screen';
import { StatusBar } from 'expo-status-bar';
import { useEffect } from 'react';
import { GestureHandlerRootView } from 'react-native-gesture-handler';
import { SafeAreaProvider } from 'react-native-safe-area-context';
import { QueryClientProvider } from '@tanstack/react-query';

import { queryClient } from '@/lib/queryClient';
import { color } from '@/theme/tokens';
import { fontMap } from '@/theme/fonts';

SplashScreen.preventAutoHideAsync().catch(() => {
  /* a failed preventAutoHide is non-fatal; the splash just hides early */
});

export default function RootLayout() {
  const [fontsLoaded, fontError] = useFonts(fontMap);

  useEffect(() => {
    if (fontsLoaded || fontError) {
      SplashScreen.hideAsync().catch(() => {});
    }
  }, [fontsLoaded, fontError]);

  // Hold the (paper-colored) splash until the type is ready. Rendering body copy in a system
  // fallback for a frame and then swapping to Inter Tight is exactly the cheap-looking flash
  // CLAUDE.md section 4 wants to avoid.
  if (!fontsLoaded && !fontError) {
    return null;
  }

  return (
    <GestureHandlerRootView style={{ flex: 1 }}>
      <SafeAreaProvider>
        <QueryClientProvider client={queryClient}>
          <StatusBar style="dark" />
          <Stack
            screenOptions={{
              headerShown: false,
              contentStyle: { backgroundColor: color.paper },
            }}
          />
        </QueryClientProvider>
      </SafeAreaProvider>
    </GestureHandlerRootView>
  );
}
