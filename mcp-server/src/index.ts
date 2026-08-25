import { McpServer } from "@modelcontextprotocol/server";
import OAuthProvider from "@cloudflare/workers-oauth-provider";
import { WorkerEntrypoint } from "cloudflare:workers";
import { createMcpHandler } from "agents/mcp/server";
import { z } from "zod";

import { SupabaseAuthHandler } from "./auth";
import { accessTokenFor } from "./session";
import { ReauthRequired, restGet, type SupabaseConfig } from "./supabase";
import type { Env, Props } from "./types";

/**
 * Masi's remote MCP server — stage 2B-2.
 *
 * Lets a chat app read a guidebook page and put the routes into the user's
 * topo. See MCP_SERVER_PLAN.md for the whole design.
 *
 * ## Authorization
 *
 * `OAuthProvider` fronts everything. `/mcp` is reachable only with a token it
 * issued, and every tool below acts as the **signed-in user's own Supabase
 * session** — never a service role. So RLS is what stops one person's chat app
 * reaching another person's library, and a tool cannot exceed the user's own
 * permissions even if the model asks it to.
 *
 * ## Why tools return JSON text
 *
 * Each tool answers with a JSON string rather than prose. The model is going to
 * feed these values back into a later call (`wallId` into `get_wall_photo`,
 * then into `create_import`), and prose invites it to paraphrase an id.
 */

const SERVER_NAME = "masi";
const SERVER_VERSION = "0.2.0";

/** Walls listed at once. Enough to find the boulder, short enough to read. */
const WALL_PAGE_SIZE = 25;

interface WallRow {
  id: string;
  name: string | null;
  updatedAt: number | null;
}

function cfgOf(env: Env): SupabaseConfig {
  return { url: env.SUPABASE_URL, anonKey: env.SUPABASE_ANON_KEY };
}

/** Wraps a tool body so a lost session reads as an instruction, not a crash. */
async function tool(
  run: () => Promise<unknown>,
): Promise<{ content: Array<{ type: "text"; text: string }> }> {
  try {
    const value = await run();
    return { content: [{ type: "text", text: JSON.stringify(value) }] };
  } catch (err) {
    if (err instanceof ReauthRequired) {
      // Deliberately not thrown: a model that sees an exception tends to retry,
      // and no number of retries fixes an expired session. Telling it plainly
      // what the human must do is the only useful answer.
      return {
        content: [
          {
            type: "text",
            text: JSON.stringify({ error: "reauth_required", message: err.message }),
          },
        ],
      };
    }
    throw err;
  }
}

function createServer(env: Env, props: Props) {
  const server = new McpServer({ name: SERVER_NAME, version: SERVER_VERSION });

  server.registerTool(
    "ping",
    {
      description:
        "Health check. Confirms the Masi connector is reachable and that " +
        "you are signed in. Returns your Masi user id and no other data.",
      inputSchema: {},
    },
    async () =>
      tool(async () => ({
        server: SERVER_NAME,
        version: SERVER_VERSION,
        signedInAs: props.uid,
      })),
  );

  server.registerTool(
    "list_recent_walls",
    {
      description:
        "List the user's own boulders/walls (topos) in Masi, most recently " +
        "updated first. Use this to find which boulder a guidebook page " +
        "belongs to, then pass its id to get_wall_photo.",
      inputSchema: {
        limit: z
          .number()
          .int()
          .min(1)
          .max(WALL_PAGE_SIZE)
          .optional()
          .describe(`How many to return (default ${WALL_PAGE_SIZE}).`),
      },
    },
    async ({ limit }) =>
      tool(async () => {
        const cfg = cfgOf(env);
        const token = await accessTokenFor(env, props.uid, cfg);

        // Scoped to the caller's OWN walls. RLS alone would also expose other
        // people's PUBLISHED walls, which are not candidates for an import —
        // you cannot draw on someone else's topo, so offering them here would
        // only invite the model to pick one and fail later.
        const rows = await restGet<WallRow[]>(
          cfg,
          token,
          `walls?select=id,name,updatedAt` +
            `&ownerId=eq.${encodeURIComponent(props.uid)}` +
            `&deletedAt=is.null` +
            `&order=updatedAt.desc` +
            `&limit=${limit ?? WALL_PAGE_SIZE}`,
        );

        return {
          walls: rows.map((r) => ({
            wallId: r.id,
            name: r.name ?? "(unnamed)",
            updatedAt: r.updatedAt,
          })),
        };
      }),
  );

  return server;
}

/**
 * The authenticated half. `OAuthProvider` routes `/mcp` here only after
 * validating its own token, and hands the grant's props through `ctx.props`.
 */
export class MasiMcpHandler extends WorkerEntrypoint<Env, Props> {
  override fetch(request: Request): Response | Promise<Response> {
    const props = this.ctx.props;
    const handler = createMcpHandler(() => createServer(this.env, props), {
      route: "/mcp",
    });
    return handler(request, this.env, this.ctx);
  }
}

export default new OAuthProvider({
  apiRoute: "/mcp",
  apiHandler: MasiMcpHandler,
  defaultHandler: SupabaseAuthHandler,
  authorizeEndpoint: "/authorize",
  tokenEndpoint: "/token",
  clientRegistrationEndpoint: "/register",
});
