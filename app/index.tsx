/**
 * app/index.tsx — Phase 0 has no product screens, so the entry route redirects straight to
 * the theme preview. This is replaced by the session gate / home in a later phase.
 */
import { Redirect } from 'expo-router';

export default function Index() {
  return <Redirect href="/theme-preview" />;
}
