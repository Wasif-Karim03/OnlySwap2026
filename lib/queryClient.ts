/**
 * lib/queryClient.ts — the app's single TanStack Query client (CLAUDE.md section 5: TanStack
 * Query for server state, no global store in v1). Defaults are conservative for a mobile app
 * on flaky campus wifi: a short stale window and a couple of retries.
 */
import { QueryClient } from '@tanstack/react-query';

export const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      staleTime: 30_000,
      retry: 2,
      refetchOnWindowFocus: false,
    },
  },
});
