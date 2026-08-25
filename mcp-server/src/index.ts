import { McpServer } from "@modelcontextprotocol/server";
import OAuthProvider from "@cloudflare/workers-oauth-provider";
import { WorkerEntrypoint } from "cloudflare:workers";
import { createMcpHandler } from "agents/mcp/server";
import { z } from "zod";

import { SupabaseAuthHandler } from "./auth";
import { accessTokenFor } from "./session";
import { gradeSortKey, isValidGrade, normalizeGrade } from "./grades";
import {
  ReauthRequired,
  restGet,
  restInsert,
  restPatch,
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

interface RouteRow {
  id: string;
  number: number;
  name: string | null;
  wallId: string;
  gradeRaw: string | null;
  gradeSystem: string | null;
  stars: number | null;
  description: string | null;
}

interface AscentRow {
  id: string;
  routeId: string;
  wallId: string;
  climbedAt: number;
  style: string;
  notes: string | null;
  gradeOpinion: string | null;
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

/** How long the internal signed URL stays valid. Only this Worker uses it. */
const PHOTO_URL_TTL_SECONDS = 300;

/**
 * Longest edge of the photo actually sent to the model.
 *
 * Originals are 3024x4032 and 4-7 MB, which cannot be sent as tool output at
 * all. 1500 keeps the long edge just under the point where the model would
 * downscale it again anyway, so nothing is spent encoding detail that gets
 * thrown away — while leaving enough resolution to tell one line from the next.
 */
const PHOTO_MAX_EDGE = 1500;

/** Base64 for an ArrayBuffer, chunked so a large photo cannot blow the stack. */
function toBase64(buffer: ArrayBuffer): string {
  const bytes = new Uint8Array(buffer);
  let binary = "";
  const chunk = 0x8000;
  for (let i = 0; i < bytes.length; i += chunk) {
    binary += String.fromCharCode(...bytes.subarray(i, i + chunk));
  }
  return btoa(binary);
}

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

type ContentBlock =
  | { type: "text"; text: string }
  | { type: "image"; data: string; mimeType: string };

/**
 * Wraps a tool body so a lost session reads as an instruction, not a crash.
 *
 * A result may carry `_imagePayload`, which is lifted out into a real MCP image
 * content block. Returning a picture as a base64 string inside JSON would just
 * be a very long string to the model — it has to be its own block to be seen.
 */
async function tool(
  run: () => Promise<Record<string, unknown> | unknown>,
): Promise<{ content: ContentBlock[] }> {
  try {
    const value = await run();
    const content: ContentBlock[] = [];

    if (value && typeof value === "object" && "_imagePayload" in value) {
      const rest = { ...(value as Record<string, unknown>) };
      const image = rest._imagePayload as { data: string; mimeType: string };
      delete rest._imagePayload;
      content.push({ type: "text", text: JSON.stringify(rest) });
      content.push({ type: "image", data: image.data, mimeType: image.mimeType });
      return { content };
    }

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

        // Hand back the IMAGE, not a link to it.
        //
        // This tool used to return the signed URL and stop there, which was
        // useless: the model has no way to fetch an arbitrary URL, so it never
        // saw the rock and every import came back with `withLines: 0`. The
        // whole photo-first design — coordinates in the user's frame, not the
        // book's — depends on the model actually looking at this picture.
        const source = await fetch(url);
        if (!source.ok || !source.body) {
          return {
            error: "photo_unreadable",
            message:
              "Masi could not read that photo's image. Open Masi while " +
              "online so it re-uploads, then try again.",
          };
        }

        const shrunk = await env.IMAGES.input(source.body)
          // scale-down never upscales, and bounds BOTH edges, so portrait and
          // landscape photos are handled by one rule.
          .transform({
            width: PHOTO_MAX_EDGE,
            height: PHOTO_MAX_EDGE,
            fit: "scale-down",
          })
          .output({ format: "image/jpeg", quality: 80 });

        const bytes = await shrunk.response().arrayBuffer();

        return {
          _imagePayload: {
            data: toBase64(bytes),
            mimeType: "image/jpeg",
          },
          wallId,
          photoId: photo.id,
          originalWidth: photo.width,
          originalHeight: photo.height,
          note:
            "This is the user's own photo of the boulder. Place route lines " +
            "in ITS coordinate space: [0,0] top-left, [1,1] bottom-right. Do " +
            "not use coordinates read off the guidebook's picture.",
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

  server.registerTool(
    "list_routes",
    {
      description:
        "List the routes already recorded on one of the user's boulders, " +
        "with their ids, numbers, grades and descriptions. Use this to find " +
        "the route the user means before logging an ascent, and to see what " +
        "the topo already knows before reading a guidebook page onto it.",
      inputSchema: { wallId: z.string().describe("From list_recent_walls.") },
    },
    async ({ wallId }) =>
      tool(async () => {
        const cfg = cfgOf(env);
        const token = await accessTokenFor(env, props.uid, cfg);
        const rows = await restGet<RouteRow[]>(
          cfg,
          token,
          `routes?select=id,number,name,gradeRaw,gradeSystem,stars,description` +
            `&wallId=eq.${encodeURIComponent(wallId)}` +
            `&ownerId=eq.${encodeURIComponent(props.uid)}` +
            `&deletedAt=is.null&order=number.asc`,
        );
        return {
          routes: rows.map((r) => ({
            routeId: r.id,
            number: r.number,
            name: r.name ?? "(unnamed)",
            grade: r.gradeRaw,
            gradeSystem: r.gradeSystem,
            stars: r.stars,
            // Projected so a caller holding a guidebook page can tell an
            // EMPTY field (the book has something to add) from a filled one
            // (it does not). Without it, "does this page add anything?" is
            // unanswerable for the most commonly-missing field, and the only
            // safe move would be to suggest overwriting descriptions that
            // were already there.
            description: r.description,
          })),
        };
      }),
  );

  server.registerTool(
    "log_ascent",
    {
      description:
        "Record that the user climbed a route. Writes straight to their " +
        "logbook — no review step, because deleting a wrong entry is one tap " +
        "in the app. Use list_routes first to get the routeId.",
      inputSchema: {
        routeId: z.string().describe("From list_routes."),
        style: z
          .enum(["send", "onsight", "flash", "redpoint", "repeat", "attempt"])
          .describe(
            "send: climbed it, no claim about how — USE THIS unless the user " +
              "actually said which. onsight: first try, no prior knowledge. " +
              "flash: first try, with beta. redpoint: sent after previous " +
              "attempts. repeat: done before. attempt: tried, not sent.",
          ),
        climbedAt: z
          .string()
          .optional()
          .describe("ISO-8601 date, e.g. '2026-08-25'. Defaults to today."),
        notes: z.string().max(2000).optional(),
        gradeOpinion: z
          .string()
          .optional()
          .describe(
            "What the user thought it was worth, if they said — e.g. '7b'. " +
              "Their opinion, NOT the route's recorded grade.",
          ),
      },
    },
    async ({ routeId, style, climbedAt, notes, gradeOpinion }) =>
      tool(async () => {
        const cfg = cfgOf(env);
        const token = await accessTokenFor(env, props.uid, cfg);

        // The ascent needs its wall, and looking it up also proves the route
        // is really the caller's — a routeId invented by the model, or
        // belonging to someone else, finds nothing here rather than producing
        // an orphan ascent row.
        const routes = await restGet<RouteRow[]>(
          cfg,
          token,
          `routes?select=id,number,name,wallId` +
            `&id=eq.${encodeURIComponent(routeId)}` +
            `&ownerId=eq.${encodeURIComponent(props.uid)}` +
            `&deletedAt=is.null&limit=1`,
        );
        const route = routes[0];
        if (!route) {
          return {
            error: "no_such_route",
            message:
              "No route of yours has that id. Call list_routes on the " +
              "boulder and use an id from there.",
          };
        }

        const when = climbedAt ? Date.parse(climbedAt) : Date.now();
        if (Number.isNaN(when)) {
          return {
            error: "bad_date",
            message: `Could not read '${climbedAt}' as a date. Use YYYY-MM-DD.`,
          };
        }

        const now = Date.now();
        await restInsert(cfg, token, "ascents", {
          id: crypto.randomUUID(),
          ownerId: props.uid,
          routeId: route.id,
          wallId: route.wallId,
          climbedAt: when,
          style,
          notes: notes ?? null,
          gradeOpinion: gradeOpinion ?? null,
          // Private by default. Sharing a send is a deliberate act, and a tool
          // that published to the community feed because a sentence was
          // ambiguous would be a genuinely bad surprise.
          visibility: "private",
          createdAt: now,
          updatedAt: now,
          // Not dirty: this row was born on the server, so there is nothing
          // for the client to push back.
          dirty: false,
        });

        return {
          logged: true,
          route: route.name ?? `#${route.number}`,
          style,
          climbedAt: new Date(when).toISOString().slice(0, 10),
          message: "Logged, privately. It appears in your Masi logbook.",
        };
      }),
  );

  server.registerTool(
    "list_ascents",
    {
      description:
        "The user's own logbook — what they have climbed, most recent first. " +
        "Use for questions like 'what did I climb this year' or 'what have I " +
        "tried but not sent'.",
      inputSchema: {
        limit: z.number().int().min(1).max(200).optional(),
        sinceDays: z
          .number()
          .int()
          .min(1)
          .optional()
          .describe("Only ascents from the last N days."),
        style: z
          .enum(["onsight", "flash", "redpoint", "repeat", "attempt"])
          .optional(),
      },
    },
    async ({ limit, sinceDays, style }) =>
      tool(async () => {
        const cfg = cfgOf(env);
        const token = await accessTokenFor(env, props.uid, cfg);

        let filter =
          `ascents?select=id,routeId,wallId,climbedAt,style,notes,gradeOpinion` +
          `&ownerId=eq.${encodeURIComponent(props.uid)}` +
          `&deletedAt=is.null&order=climbedAt.desc&limit=${limit ?? 50}`;
        if (sinceDays) {
          filter += `&climbedAt=gte.${Date.now() - sinceDays * 86400000}`;
        }
        if (style) filter += `&style=eq.${style}`;

        const rows = await restGet<AscentRow[]>(cfg, token, filter);
        if (rows.length === 0) return { ascents: [] };

        // Resolve route names in one round trip rather than N.
        const ids = [...new Set(rows.map((r) => r.routeId))];
        const routes = await restGet<RouteRow[]>(
          cfg,
          token,
          `routes?select=id,number,name,gradeRaw,gradeSystem` +
            `&id=in.(${ids.map(encodeURIComponent).join(",")})`,
        );
        const byId = new Map(routes.map((r) => [r.id, r]));

        return {
          ascents: rows.map((a) => {
            const r = byId.get(a.routeId);
            return {
              route: r?.name ?? "(unknown route)",
              grade: r?.gradeRaw ?? null,
              style: a.style,
              climbedAt: new Date(a.climbedAt).toISOString().slice(0, 10),
              gradeOpinion: a.gradeOpinion,
              notes: a.notes,
            };
          }),
        };
      }),
  );

  server.registerTool(
    "update_route",
    {
      description:
        "Correct a route's name, grade, description or stars. Most useful " +
        "right after an import, when you still have the guidebook page in " +
        "context. Only the fields you pass are changed.",
      inputSchema: {
        routeId: z.string().describe("From list_routes."),
        name: z.string().max(120).optional(),
        gradeRaw: z
          .string()
          .optional()
          .describe("e.g. '7b'. Must be a real grade on the chosen ladder."),
        gradeSystem: z.enum(["french", "uiaa"]).optional(),
        description: z.string().max(2000).optional(),
        stars: z.number().int().min(0).max(3).optional(),
      },
    },
    async ({ routeId, name, gradeRaw, gradeSystem, description, stars }) =>
      tool(async () => {
        const cfg = cfgOf(env);
        const token = await accessTokenFor(env, props.uid, cfg);

        const patch: Record<string, unknown> = { updatedAt: Date.now() };
        if (name !== undefined) patch.name = name;
        if (description !== undefined) patch.description = description;
        if (stars !== undefined) patch.stars = stars;

        if (gradeRaw !== undefined) {
          const system = gradeSystem ?? "french";
          if (!isValidGrade(system, gradeRaw)) {
            return {
              error: "bad_grade",
              message:
                `'${gradeRaw}' is not a ${system} grade, so nothing was ` +
                "changed. Pass the grade exactly as the ladder writes it.",
            };
          }
          // The sort key is ALWAYS recomputed, never taken on trust — it is
          // what every difficulty sort and filter reads, and a wrong one is
          // invisible because the grade still displays correctly.
          patch.gradeRaw = normalizeGrade(system, gradeRaw);
          patch.gradeSystem = system;
          patch.gradeSortKey = gradeSortKey(system, gradeRaw);
        }

        if (Object.keys(patch).length === 1) {
          return { error: "nothing_to_do", message: "No fields were given." };
        }

        const updated = await restPatch<RouteRow[]>(
          cfg,
          token,
          "routes",
          `id=eq.${encodeURIComponent(routeId)}` +
            `&ownerId=eq.${encodeURIComponent(props.uid)}&deletedAt=is.null`,
          patch,
        );
        if (updated.length === 0) {
          return {
            error: "no_such_route",
            message: "No route of yours has that id. Call list_routes first.",
          };
        }

        return {
          updated: true,
          route: updated[0].name ?? `#${updated[0].number}`,
          changed: Object.keys(patch).filter((k) => k !== "updatedAt"),
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
