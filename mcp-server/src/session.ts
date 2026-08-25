import { ReauthRequired, refreshSession, type SupabaseConfig } from "./supabase";
import { sessionKey, type Env, type StoredSession } from "./types";

/**
 * Returns a usable Supabase access token for [uid], refreshing and persisting
 * the rotated session when the current one is spent.
 *
 * Supabase rotates refresh tokens — each refresh invalidates the one it
 * replaces — so the new pair MUST be written back before it is used. Skipping
 * that write is a bug with a delayed fuse: everything works until the first
 * expiry, then every later call presents a retired token and the connector
 * looks broken for reasons that have nothing to do with the request that
 * finally failed.
 */
export async function accessTokenFor(
  env: Env,
  uid: string,
  cfg: SupabaseConfig,
): Promise<string> {
  const raw = await env.OAUTH_KV.get(sessionKey(uid));
  if (!raw) {
    throw new ReauthRequired(
      "Masi has no sign-in stored for you any more. Reconnect the Masi " +
        "connector in your Claude settings.",
    );
  }

  const stored = JSON.parse(raw) as StoredSession;
  if (Date.now() < stored.expiresAt) return stored.accessToken;

  const fresh = await refreshSession(cfg, stored.refreshToken);
  await env.OAUTH_KV.put(
    sessionKey(uid),
    JSON.stringify({
      accessToken: fresh.accessToken,
      refreshToken: fresh.refreshToken,
      expiresAt: fresh.expiresAt,
    } satisfies StoredSession),
  );
  return fresh.accessToken;
}
