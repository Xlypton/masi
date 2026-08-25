/**
 * Supabase calls made **as the signed-in user**.
 *
 * Every function here takes the user's own access token and sends it as the
 * `Authorization` bearer. That is the entire authorization model: RLS decides
 * what the caller can see, exactly as it does for the app.
 *
 * There is deliberately no service-role key anywhere in this Worker. A service
 * role would bypass RLS for every user at once, so one leaked secret would turn
 * a feature that writes a handful of routes to your own wall into read/write
 * over everybody's library. A refresh token is one user's, revocable, and still
 * subject to RLS on every call.
 */

export interface SupabaseSession {
  accessToken: string;
  refreshToken: string;
  /** Epoch millis after which `accessToken` is no longer usable. */
  expiresAt: number;
  uid: string;
}

export interface SupabaseConfig {
  url: string;
  anonKey: string;
}

/** Thrown when the user's session is gone and they must reconnect. */
export class ReauthRequired extends Error {
  constructor(message = "Masi needs you to reconnect this connector.") {
    super(message);
    this.name = "ReauthRequired";
  }
}

function sessionFrom(body: Record<string, unknown>): SupabaseSession {
  const user = body.user as { id?: string } | undefined;
  const uid = user?.id;
  const accessToken = body.access_token as string | undefined;
  const refreshToken = body.refresh_token as string | undefined;
  if (!uid || !accessToken || !refreshToken) {
    throw new ReauthRequired("Supabase did not return a usable session.");
  }
  // Deliberately pessimistic by 60s so a token cannot expire mid-request.
  const expiresIn = Number(body.expires_in ?? 3600);
  return {
    uid,
    accessToken,
    refreshToken,
    expiresAt: Date.now() + Math.max(0, expiresIn - 60) * 1000,
  };
}

/** Exchanges a PKCE authorization code for a session. */
export async function exchangePkceCode(
  cfg: SupabaseConfig,
  authCode: string,
  codeVerifier: string,
): Promise<SupabaseSession> {
  const res = await fetch(`${cfg.url}/auth/v1/token?grant_type=pkce`, {
    method: "POST",
    headers: {
      apikey: cfg.anonKey,
      "content-type": "application/json",
    },
    body: JSON.stringify({ auth_code: authCode, code_verifier: codeVerifier }),
  });
  if (!res.ok) {
    throw new ReauthRequired(
      `Sign-in did not complete (${res.status}). Try connecting again.`,
    );
  }
  return sessionFrom((await res.json()) as Record<string, unknown>);
}

/** Trades a refresh token for a fresh session. */
export async function refreshSession(
  cfg: SupabaseConfig,
  refreshToken: string,
): Promise<SupabaseSession> {
  const res = await fetch(`${cfg.url}/auth/v1/token?grant_type=refresh_token`, {
    method: "POST",
    headers: {
      apikey: cfg.anonKey,
      "content-type": "application/json",
    },
    body: JSON.stringify({ refresh_token: refreshToken }),
  });
  if (!res.ok) {
    // A revoked or expired refresh token is not a server fault, and must not
    // surface to the model as a generic failure it might retry forever.
    throw new ReauthRequired(
      "Your Masi connection has expired. Reconnect the Masi connector in " +
        "your Claude settings.",
    );
  }
  return sessionFrom((await res.json()) as Record<string, unknown>);
}

/**
 * A PostgREST GET as the user.
 *
 * `path` is everything after `/rest/v1/`, e.g. `walls?select=id,name`.
 */
export async function restGet<T>(
  cfg: SupabaseConfig,
  accessToken: string,
  path: string,
): Promise<T> {
  const res = await fetch(`${cfg.url}/rest/v1/${path}`, {
    headers: {
      apikey: cfg.anonKey,
      authorization: `Bearer ${accessToken}`,
      accept: "application/json",
    },
  });
  if (res.status === 401) throw new ReauthRequired();
  if (!res.ok) {
    throw new Error(`Supabase read failed (${res.status}): ${await res.text()}`);
  }
  return (await res.json()) as T;
}

/** A PostgREST insert as the user. */
export async function restInsert<T>(
  cfg: SupabaseConfig,
  accessToken: string,
  table: string,
  row: Record<string, unknown>,
): Promise<T> {
  const res = await fetch(`${cfg.url}/rest/v1/${table}`, {
    method: "POST",
    headers: {
      apikey: cfg.anonKey,
      authorization: `Bearer ${accessToken}`,
      "content-type": "application/json",
      prefer: "return=representation",
    },
    body: JSON.stringify(row),
  });
  if (res.status === 401) throw new ReauthRequired();
  if (!res.ok) {
    throw new Error(`Supabase write failed (${res.status}): ${await res.text()}`);
  }
  return (await res.json()) as T;
}

/** A PostgREST update as the user. `filter` is a PostgREST predicate string. */
export async function restPatch<T>(
  cfg: SupabaseConfig,
  accessToken: string,
  table: string,
  filter: string,
  patch: Record<string, unknown>,
): Promise<T> {
  const res = await fetch(`${cfg.url}/rest/v1/${table}?${filter}`, {
    method: "PATCH",
    headers: {
      apikey: cfg.anonKey,
      authorization: `Bearer ${accessToken}`,
      "content-type": "application/json",
      prefer: "return=representation",
    },
    body: JSON.stringify(patch),
  });
  if (res.status === 401) throw new ReauthRequired();
  if (!res.ok) {
    throw new Error(`Supabase update failed (${res.status}): ${await res.text()}`);
  }
  return (await res.json()) as T;
}

/**
 * A short-lived signed URL for an object in a private storage bucket.
 *
 * Used so the model can actually LOOK at the user's photo of the boulder — the
 * whole reason it can place lines in that photo's coordinate space rather than
 * the guidebook's.
 */
export async function signedUrl(
  cfg: SupabaseConfig,
  accessToken: string,
  bucket: string,
  objectPath: string,
  expiresInSeconds: number,
): Promise<string | null> {
  const res = await fetch(
    `${cfg.url}/storage/v1/object/sign/${bucket}/${objectPath}`,
    {
      method: "POST",
      headers: {
        apikey: cfg.anonKey,
        authorization: `Bearer ${accessToken}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({ expiresIn: expiresInSeconds }),
    },
  );
  if (res.status === 401) throw new ReauthRequired();
  if (!res.ok) return null;
  const body = (await res.json()) as { signedURL?: string };
  return body.signedURL ? `${cfg.url}/storage/v1${body.signedURL}` : null;
}
