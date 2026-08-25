import { McpServer } from "@modelcontextprotocol/server";
import OAuthProvider from "@cloudflare/workers-oauth-provider";
import { WorkerEntrypoint } from "cloudflare:workers";
import { createMcpHandler } from "agents/mcp/server";
import { z } from "zod";

import { SupabaseAuthHandler } from "./auth";
import { accessTokenFor } from "./session";
import {
  ReauthRequired,
  restGet,
  restInsert,
  signedUrl,
  type SupabaseConfig,
} from "./supabase";
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

interface PhotoRow {
  id: string;
  localPath: string | null;
  width: number | null;
  height: number | null;
  isPrimary: boolean | null;
  sortOrder: number | null;
}

/** Storage bucket holding each user's own photos, under `<uid>/`. */
const PHOTO_BUCKET = "topo-photos";

/** How long a photo URL handed to the model stays valid. */
const PHOTO_URL_TTL_SECONDS = 900;

/**
 * One route as read off a guidebook page.
 *
 * Mirrors the v1 payload contract the app's decoder already reads
 * (`lib/features/import/domain/guidebook_import.dart`). Declaring it as a real
 * schema rather than accepting free-form JSON is what makes the model emit the
 * right shape in the first place — and anything it still gets wrong degrades in
 * the client decoder rather than corrupting a topo.
 */
const importedRoute = z.object({
  name: z.string().optional().describe("The route name as printed."),
  gradeRaw: z
    .string()
    .optional()
    .describe("The grade exactly as printed, e.g. '6a+'. Do not convert it."),
  stars: z.number().int().min(0).max(3).optional().describe("Quality, 0-3."),
  description: z.string().optional().describe("The book's description."),
  positionHint: z
    .string()
    .optional()
    .describe("Where the line sits, e.g. 'leftmost, up the obvious arete'."),
  points: z
    .array(z.tuple([z.number(), z.number()]))
    .optional()
    .describe(
      "OPTIONAL. The line as [x, y] pairs, bottom to top, as fractions of " +
        "THE USER'S photo ([0,0] top-left, [1,1] bottom-right) — never of " +
        "the guidebook's picture. Three or four points is plenty. If you " +
        "cannot confidently match the route to a feature in the user's " +
        "photo, OMIT this field rather than guessing: a missing line takes " +
        "seconds to draw, a wrong one takes longer to find and fix.",
    ),
});

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

  server.registerTool(
    "get_wall_photo",
    {
      description:
        "Get a temporary link to the user's own photo of a boulder, so you " +
        "can see the rock they will draw on. Call this BEFORE create_import: " +
        "route lines must be placed against this photo, not against the " +
        "guidebook's picture, which is shot from a different angle.",
      inputSchema: {
        wallId: z.string().describe("From list_recent_walls."),
      },
    },
    async ({ wallId }) =>
      tool(async () => {
        const cfg = cfgOf(env);
        const token = await accessTokenFor(env, props.uid, cfg);

        const rows = await restGet<PhotoRow[]>(
          cfg,
          token,
          `photos?select=id,localPath,width,height,isPrimary,sortOrder` +
            `&wallId=eq.${encodeURIComponent(wallId)}` +
            `&ownerId=eq.${encodeURIComponent(props.uid)}` +
            `&deletedAt=is.null` +
            `&order=isPrimary.desc,sortOrder.asc` +
            `&limit=1`,
        );

        const photo = rows[0];
        if (!photo) {
          // Distinguish "no photo" from "photo exists but has not synced" as
          // far as we can, because the fix is different and the second case is
          // the common one: the app uploads on sync, so a boulder shot at the
          // crag and never opened online has no object here yet.
          return {
            error: "no_photo",
            message:
              "That boulder has no photo Masi can reach. If you added it " +
              "recently, open Masi while online so the photo syncs, then try " +
              "again.",
          };
        }

        const ext = extensionOf(photo.localPath);
        const url = await signedUrl(
          cfg,
          token,
          PHOTO_BUCKET,
          `${props.uid}/${photo.id}${ext}`,
          PHOTO_URL_TTL_SECONDS,
        );
        if (!url) {
          return {
            error: "photo_not_uploaded",
            message:
              "Masi knows about that photo but its image has not been " +
              "uploaded yet. Open Masi while online, then try again.",
          };
        }

        return {
          wallId,
          photoId: photo.id,
          width: photo.width,
          height: photo.height,
          url,
          expiresInSeconds: PHOTO_URL_TTL_SECONDS,
          note:
            "Place route lines in THIS photo's coordinate space: [0,0] is its " +
            "top-left, [1,1] its bottom-right.",
        };
      }),
  );

  server.registerTool(
    "create_import",
    {
      description:
        "Send the routes you read off a guidebook page to Masi, for the user " +
        "to review. This does NOT change their topo — it queues an import " +
        "which they approve in the app, where they can correct the lines. " +
        "Call get_wall_photo first and place points against that photo.",
      inputSchema: {
        wallId: z.string().describe("From list_recent_walls."),
        photoId: z.string().describe("From get_wall_photo."),
        boulder: z
          .string()
          .optional()
          .describe("The boulder or sector name from the page."),
        gradeSystem: z
          .enum(["french", "uiaa"])
          .optional()
          .describe(
            "Which ladder the book uses. Font grades (6a, 7b+) are " +
              "'french'. Omit if unsure — the user picks it in the app.",
          ),
        routes: z
          .array(importedRoute)
          .min(1)
          .describe("The routes, in left-to-right order as they sit on the rock."),
      },
    },
    async ({ wallId, photoId, boulder, gradeSystem, routes }) =>
      tool(async () => {
        const cfg = cfgOf(env);
        const token = await accessTokenFor(env, props.uid, cfg);

        // `v` is stamped here rather than asked of the model: it is the
        // contract's framing, not data the model has any way to know. Nothing
        // else is added, checked, or corrected — the client's decoder is the
        // one whose verdict the user actually sees, and a second validator
        // here would be two decoders obliged to agree forever.
        const payload = { v: 1, boulder, gradeSystem, routes };

        await restInsert(cfg, token, "guidebook_imports", {
          id: crypto.randomUUID(),
          ownerId: props.uid,
          wallId,
          photoId,
          payload,
          createdAt: Date.now(),
        });

        const unplaced = routes.filter((r) => !r.points || r.points.length < 2);
        return {
          queued: routes.length,
          withLines: routes.length - unplaced.length,
          toDraw: unplaced.length,
          message:
            `Sent ${routes.length} route(s) to Masi. Open the topo in Masi to ` +
            "review and approve them — nothing has changed yet.",
        };
      }),
  );

  return server;
}

/** The file extension of a stored photo, defaulting to `.jpg`. */
function extensionOf(localPath: string | null): string {
  if (!localPath) return ".jpg";
  const dot = localPath.lastIndexOf(".");
  if (dot < 0 || dot === localPath.length - 1) return ".jpg";
  return localPath.slice(dot);
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
