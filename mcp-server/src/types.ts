import type { OAuthHelpers } from "@cloudflare/workers-oauth-provider";

/**
 * What each authorized grant carries.
 *
 * **Only the uid.** The Supabase session deliberately lives in KV under
 * `session:<uid>` instead, because Supabase *rotates* refresh tokens: every
 * refresh returns a new one and invalidates the old. Grant props are fixed when
 * the grant is minted, so a session stored here would be correct exactly once
 * and then permanently stale — the second refresh would present a token
 * Supabase had already retired, and the connector would die a day later for no
 * visible reason.
 */
export interface Props extends Record<string, unknown> {
  /** The Supabase `auth.uid()` this grant acts as. */
  uid: string;
}

/** The Supabase session, as persisted in KV and rotated on refresh. */
export interface StoredSession {
  accessToken: string;
  refreshToken: string;
  /** Epoch millis after which `accessToken` must be refreshed. */
  expiresAt: number;
}

export interface Env {
  OAUTH_KV: KVNamespace;
  OAUTH_PROVIDER: OAuthHelpers;
  SUPABASE_URL: string;
  /** The publishable anon key — safe to ship, RLS-protected. */
  SUPABASE_ANON_KEY: string;
}

export const sessionKey = (uid: string) => `session:${uid}`;
