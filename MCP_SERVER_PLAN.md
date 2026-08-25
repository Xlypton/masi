# Masi MCP Server — Phase 2 Plan

Phase 2 of the guidebook import (see `ROUTE_IMPORT_PLAN.md`). Removes the copy-paste: the chat app
talks to Masi directly, so the user photographs a guidebook page and the routes appear in the app.

**Host:** Cloudflare Worker at `https://masi-mcp.xlypton.workers.dev`
**Added to Claude at:** claude.ai → Customize → Connectors → Add custom connector (web only; then
usable from the mobile app).

## What research settled, before any code

Three findings that changed the design. Each was checked rather than assumed, and each would have
produced a wrong build from memory alone.

1. **OAuth is mandatory.** claude.ai's custom-connector UI takes only OAuth 2.0 — Authorization
   URL, Token URL, Client ID, Client Secret. There is no field for a static bearer token, and the
   MCP authorization spec explicitly prohibits tokens in the query string. So the cheap
   "connector URL carrying a pairing token" design is out; the Worker must be a real OAuth 2.1
   authorization server.
2. **`McpAgent` is deprecated and feature-frozen.** The current path for a server like ours is
   `createMcpHandler` (stateless). Nothing here needs per-session server state.
3. **Connectors are added on the web, not on the phone**, and Anthropic's cloud — not the device —
   connects to the server. So the Worker must be publicly reachable, and a local or device-side
   server was never an option.

`@cloudflare/workers-oauth-provider` implements the provider side (`/authorize`, `/token`,
`/register` with dynamic client registration, PKCE), which is the bulk of the work. It supports a
"third-party provider" shape: authenticate the user elsewhere, then issue our own token to the MCP
client. Our third party is Supabase Auth.

## Identity: the user's own token, never a service role

The Worker authenticates the user through **Supabase Auth (Google)**, the same identity the app
uses, and stores that session in the OAuth grant:

```
Claude  ──/authorize──▶  Worker  ──redirect──▶  Supabase Auth (Google)
                            ▲                         │
                            └────── callback ─────────┘
                                     (code → access + refresh token, uid)
Claude  ◀── Worker's own token ── Worker   [grant props: uid, refresh token]
```

**Standing decision: the Worker holds the user's refresh token and never a service-role key.**
Every Supabase call it makes carries that user's JWT, so **RLS does the authorization** exactly as
it does for the app. A service-role key in a Worker would bypass RLS entirely and turn one leaked
secret into full read/write over every user's data — for a feature whose whole job is writing a
handful of routes to the caller's own wall. The refresh token is scoped to one user and revocable
from Supabase.

Consequence: `auth.uid()` is real inside every tool call, so no tool needs an owner argument, and
no tool can reach another user's data even if the model asks it to.

## Tools

| Tool | Does | Notes |
|---|---|---|
| `list_recent_walls()` | The caller's walls, newest first: id, name, photo count | RLS-scoped |
| `get_wall_photo(wallId)` | Short-lived signed URL to the user's own photo | So the model sees the real photo |
| `create_import(wallId, photoId, payload)` | Writes a **pending import** | Does not write routes |

**`create_import` deliberately does not write routes.** It stores the payload and the app shows it
for review. A model that misreads a page would otherwise silently mutate the user's topo with no
undo, and the review sheet already exists from Phase 1. The MCP path therefore has exactly the same
last step as the paste path.

## Storage: `guidebook_imports`

New table, additive, RLS owner-only:

```
id text pk · "ownerId" text · "wallId" text · "photoId" text
payload jsonb · createdAt bigint · consumedAt bigint null
```

Follows the live conventions verified in `CLAUDE.md`: quoted camelCase identifiers, `text` ids,
`bigint` millisecond timestamps, and owner policies of the form
`USING ("ownerId" = (auth.uid())::text)`.

The payload is stored **exactly as the model sent it** and validated by the existing Phase 1
decoder on the client. Validating on the server as well would mean two decoders that must agree
forever, and the client's is the one whose verdict actually reaches the user.

## Stages

- **2A** `guidebook_imports` table + RLS, applied live and verified.
- **2B** Worker scaffold + `workers-oauth-provider` + Supabase auth handler + `list_recent_walls`.
  This stage proves the whole auth chain; the remaining tools are easy once `auth.uid()` is real.
- **2C** `get_wall_photo` + `create_import`.
- **2D** Client: surface pending imports on the canvas, opening the Phase 1 review sheet.

## Assertions

1. An unauthenticated request to `/mcp` is refused.
2. A tool call as user A cannot see or write user B's walls — verified by RLS, not by tool code.
3. `create_import` writes a row and creates **no routes**.
4. The client applies a pending import through the same decoder and review sheet as a pasted one.
5. A malformed payload from the server degrades exactly as a pasted one does (same decoder).
6. Revoking the connector in Claude, or the session in Supabase, stops the server writing.
7. No service-role key exists anywhere in the Worker or its secrets.

## Risks

- **Supabase redirect allowlist.** The Worker's callback must be added to the project's allowed
  redirect URLs, or the OAuth flow dies at the last hop. Live-project settings change.
- **Refresh-token lifetime.** If the stored refresh token expires or is revoked, tools must fail
  with a re-authenticate message rather than a generic 500.
- **The photo must have synced** before `get_wall_photo` can return anything. Couch activity, not
  crag activity — the tool should say so explicitly rather than returning an empty URL.
