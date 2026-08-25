import type { AuthRequest, OAuthHelpers } from "@cloudflare/workers-oauth-provider";

import { exchangePkceCode, type SupabaseConfig } from "./supabase";
import { sessionKey, type Env, type Props, type StoredSession } from "./types";

/**
 * The authorization half of the MCP server: signs the user in with Supabase,
 * then hands our own token back to Claude.
 *
 * ## The shape, and why it has this shape
 *
 * The MCP authorization spec has the server issue its own token to the client
 * even when a third party did the authenticating. So there are two OAuth flows
 * stacked here, and it is worth keeping them straight:
 *
 * 1. **Claude ⇄ this Worker** — handled almost entirely by
 *    `workers-oauth-provider`. It parses the request, registers Claude as a
 *    client dynamically, and mints the token. We only decide *who the user is*.
 * 2. **This Worker ⇄ Supabase** — the flow below. PKCE against Supabase's
 *    Google provider, ending in a real session for a real `auth.uid()`.
 *
 * The session from (2) is stored as the props of the grant in (1), so every
 * later tool call can act as that user.
 *
 * ## State travels in a cookie, not the redirect URL
 *
 * The obvious approach — hiding our state in `redirect_to`'s query string —
 * risks Supabase's redirect allowlist refusing the URL, and allowlist matching
 * is exactly the kind of thing that fails at the last hop with an unhelpful
 * error. `/authorize` and `/callback` are the same origin, so a `SameSite=Lax`
 * cookie survives the round trip through Google (a top-level GET navigation)
 * and keeps the registered redirect URL byte-for-byte what the allowlist has.
 */

const STATE_COOKIE = "masi_mcp_flow";

/** How long the user has to finish signing in before the flow is discarded. */
const FLOW_TTL_SECONDS = 600;

interface PendingFlow {
  /** The Claude-side request we must complete once we know the user. */
  authRequest: AuthRequest;
  /** PKCE verifier for the Supabase leg. */
  codeVerifier: string;
}

function base64Url(bytes: Uint8Array): string {
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function randomToken(byteLength = 32): string {
  const bytes = new Uint8Array(byteLength);
  crypto.getRandomValues(bytes);
  return base64Url(bytes);
}

async function pkceChallenge(verifier: string): Promise<string> {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(verifier),
  );
  return base64Url(new Uint8Array(digest));
}

function readCookie(request: Request, name: string): string | null {
  const header = request.headers.get("cookie");
  if (!header) return null;
  for (const part of header.split(";")) {
    const [k, ...rest] = part.trim().split("=");
    if (k === name) return rest.join("=");
  }
  return null;
}

function supabaseConfig(env: Env): SupabaseConfig {
  return { url: env.SUPABASE_URL, anonKey: env.SUPABASE_ANON_KEY };
}

function page(title: string, body: string, status = 200): Response {
  return new Response(
    `<!doctype html><meta charset="utf-8">` +
      `<meta name="viewport" content="width=device-width,initial-scale=1">` +
      `<title>${title}</title>` +
      `<style>body{font:16px/1.5 system-ui,sans-serif;margin:0;padding:2rem;` +
      `background:#141019;color:#eee}main{max-width:32rem;margin:3rem auto}` +
      `h1{font-size:1.25rem}a{color:#b9a3f0}</style>` +
      `<main><h1>${title}</h1>${body}</main>`,
    { status, headers: { "content-type": "text/html; charset=utf-8" } },
  );
}

export const SupabaseAuthHandler = {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === "/authorize") return handleAuthorize(request, env, url);
    if (url.pathname === "/callback") return handleCallback(request, env, url);

    if (url.pathname === "/" || url.pathname === "/health") {
      return new Response(
        JSON.stringify({
          server: "masi",
          mcp: "/mcp",
          note:
            "Masi's MCP server. Add it as a custom connector in Claude to " +
            "import guidebook pages into your topos.",
        }),
        { headers: { "content-type": "application/json" } },
      );
    }

    return new Response("Not found", { status: 404 });
  },
};

async function handleAuthorize(
  request: Request,
  env: Env,
  url: URL,
): Promise<Response> {
  let authRequest: AuthRequest;
  try {
    authRequest = await env.OAUTH_PROVIDER.parseAuthRequest(request);
  } catch {
    return page(
      "That sign-in link isn't valid",
      "<p>Try adding the connector again from your Claude settings.</p>",
      400,
    );
  }

  const codeVerifier = randomToken(48);
  const challenge = await pkceChallenge(codeVerifier);
  const stateKey = randomToken();

  const flow: PendingFlow = { authRequest, codeVerifier };
  await env.OAUTH_KV.put(`flow:${stateKey}`, JSON.stringify(flow), {
    expirationTtl: FLOW_TTL_SECONDS,
  });

  // The registered redirect URI, exactly as the Supabase allowlist holds it —
  // no query string, so allowlist matching cannot be what breaks the flow.
  const callback = `${url.origin}/callback`;

  const authorize = new URL(`${env.SUPABASE_URL}/auth/v1/authorize`);
  authorize.searchParams.set("provider", "google");
  authorize.searchParams.set("redirect_to", callback);
  authorize.searchParams.set("flow_type", "pkce");
  authorize.searchParams.set("code_challenge", challenge);
  authorize.searchParams.set("code_challenge_method", "s256");

  return new Response(null, {
    status: 302,
    headers: {
      location: authorize.toString(),
      "set-cookie":
        `${STATE_COOKIE}=${stateKey}; Path=/; HttpOnly; Secure; ` +
        `SameSite=Lax; Max-Age=${FLOW_TTL_SECONDS}`,
      "cache-control": "no-store",
    },
  });
}

async function handleCallback(
  request: Request,
  env: Env,
  url: URL,
): Promise<Response> {
  const supabaseError = url.searchParams.get("error_description") ??
    url.searchParams.get("error");
  if (supabaseError) {
    return page("Sign-in was cancelled", `<p>${escapeHtml(supabaseError)}</p>`, 400);
  }

  const code = url.searchParams.get("code");
  const stateKey = readCookie(request, STATE_COOKIE);
  if (!code || !stateKey) {
    return page(
      "That sign-in didn't complete",
      "<p>The link may have expired. Try connecting Masi again.</p>",
      400,
    );
  }

  const raw = await env.OAUTH_KV.get(`flow:${stateKey}`);
  if (!raw) {
    return page(
      "That sign-in took too long",
      "<p>Start again from your Claude settings.</p>",
      400,
    );
  }
  // One flow, one use — a replayed callback must not mint a second grant.
  await env.OAUTH_KV.delete(`flow:${stateKey}`);

  const flow = JSON.parse(raw) as PendingFlow;

  let session;
  try {
    session = await exchangePkceCode(
      supabaseConfig(env),
      code,
      flow.codeVerifier,
    );
  } catch (err) {
    return page(
      "Masi couldn't finish signing you in",
      `<p>${escapeHtml((err as Error).message)}</p>`,
      400,
    );
  }

  // The session goes in KV, not in the grant's props — see `Props`. Refresh
  // tokens rotate, and props are frozen when the grant is minted.
  await env.OAUTH_KV.put(
    sessionKey(session.uid),
    JSON.stringify({
      accessToken: session.accessToken,
      refreshToken: session.refreshToken,
      expiresAt: session.expiresAt,
    } satisfies StoredSession),
  );

  const props: Props = { uid: session.uid };

  const { redirectTo } = await env.OAUTH_PROVIDER.completeAuthorization({
    request: flow.authRequest,
    userId: session.uid,
    scope: flow.authRequest.scope,
    metadata: { provider: "supabase-google" },
    props,
  });

  return new Response(null, {
    status: 302,
    headers: {
      location: redirectTo,
      // Clear the flow cookie; it has done its one job.
      "set-cookie": `${STATE_COOKIE}=; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=0`,
      "cache-control": "no-store",
    },
  });
}

function escapeHtml(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

export type { OAuthHelpers };
