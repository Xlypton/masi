import { McpServer } from "@modelcontextprotocol/server";
import { createMcpHandler } from "agents/mcp/server";
import { z } from "zod";

/**
 * Masi's remote MCP server.
 *
 * Phase 2 of the guidebook import (see MCP_SERVER_PLAN.md). It lets a chat app
 * photograph a guidebook page and put the routes into the user's topo without
 * the copy-paste that Phase 1 needs.
 *
 * ## Stage 2B-1 — this file, right now
 *
 * Deliberately AUTHLESS and deliberately unable to touch any data. It exists to
 * prove the deploy path end to end (build, upload, workers.dev route, MCP
 * handshake) before OAuth and Supabase are wired in, so that when the auth
 * chain misbehaves there is no doubt about whether the plumbing underneath it
 * works.
 *
 * That is only safe because there is nothing here to protect: the Worker holds
 * no credentials, has no Supabase binding, and its one tool returns a constant.
 *
 * **Nothing that reads or writes user data may be added to this file until the
 * OAuth provider in stage 2B-2 is in front of it.** The moment a tool can reach
 * a Supabase row, an unauthenticated endpoint stops being a test fixture and
 * becomes a way for anyone on the internet to write to somebody's library.
 *
 * ## Why stateless
 *
 * `McpAgent` is deprecated and feature-frozen; `createMcpHandler` is the
 * current path. Nothing here needs per-session server state — each tool call is
 * a self-contained read or write against Supabase — so the stateless handler is
 * both the recommended and the simpler choice.
 */

/** Server identity reported in the MCP handshake. */
const SERVER_NAME = "masi";
const SERVER_VERSION = "0.1.0";

function createServer() {
  const server = new McpServer({
    name: SERVER_NAME,
    version: SERVER_VERSION,
  });

  // The only tool at this stage. It takes no input that reaches anything and
  // returns no data that came from anywhere — it answers exactly one question:
  // "is the deployed Worker speaking MCP?"
  server.registerTool(
    "ping",
    {
      description:
        "Health check. Confirms the Masi MCP server is reachable and " +
        "speaking MCP. Returns no user data.",
      inputSchema: { note: z.string().optional() },
    },
    async ({ note }) => ({
      content: [
        {
          type: "text",
          text: JSON.stringify({
            server: SERVER_NAME,
            version: SERVER_VERSION,
            stage: "2B-1 (authless scaffold; no data access)",
            note: note ?? null,
          }),
        },
      ],
    }),
  );

  return server;
}

const mcp = createMcpHandler(createServer, { route: "/mcp" });

// The Worker entrypoint stays an OBJECT. Wrangler treats a function default
// export as a WorkerEntrypoint class, so `export default createMcpHandler(...)`
// would be misread — the handler is callable for composition, not for exporting.
export default {
  async fetch(request: Request, env: unknown, ctx: ExecutionContext) {
    const url = new URL(request.url);

    // A plain browser-visitable page, so opening the host in a browser explains
    // itself instead of returning an MCP protocol error to a human.
    if (url.pathname === "/" || url.pathname === "/health") {
      return new Response(
        JSON.stringify({
          server: SERVER_NAME,
          version: SERVER_VERSION,
          stage: "2B-1",
          mcp: "/mcp",
          note: "Authless scaffold. No data access. See MCP_SERVER_PLAN.md.",
        }),
        { headers: { "content-type": "application/json" } },
      );
    }

    return mcp(request, env, ctx);
  },
} satisfies ExportedHandler;
