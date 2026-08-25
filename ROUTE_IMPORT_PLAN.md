# Guidebook Import — Plan

Import the *facts* from a printed guidebook topo (route names, grades, descriptions, and a
best-effort line placement) onto **the user's own photo**, using **the user's own ChatGPT/Claude
subscription** to do the vision work.

**Masi never calls an LLM.** It only ever receives structured JSON. That is the whole cost model:
inference happens inside the user's own chat session, billed to them, invisible to us. The MCP
server (Phase 2) is a thin authenticated write endpoint with no model in it.

## Why this is cheap to build

Three things already exist on `main` and carry most of the weight:

- **Correction UI is done.** `DrawController.moveRoutePoint` / `insertRoutePointAfter` /
  `removeRoutePoint` / `endRouteGeometryEdit` (`lib/features/topo/application/draw_controller.dart`)
  are the drag handles that shipped in `ba42fce`/`bc94d86`. An AI-placed route lands as an ordinary
  committed route and is corrected with the handles that are already there. **We build zero
  correction UI.**
- **`TopoRoute.points` is normalized percent space (0–1)** — precisely what an LLM can emit
  reliably. Best-effort placement is a JSON schema, not a research project.
- **`RouteRepository.upsertRoute(wallId, photoId, route)`** keyed on `(photoId, number)` is the
  persistence seam. An import is N upserts numbered 1..N.

Every payload field maps 1:1 onto an existing `TopoRoute` field. **No schema change, no migration.**

## The flow

The model must place lines against **the user's photo**, never the book's — different angle,
different framing, curved glossy page. So the photo comes *first*, and the import is reached from
inside the topo you are already editing:

1. **New topo as usual:** photograph the boulder, or pick one from the gallery. That creates the
   Area→Sector→Wall→Photo chain (the existing photo-first flow,
   `library_crud_repository.dart:1916`).
2. **Enter edit mode on the canvas.** An **Import from guidebook** button sits in the draw-mode
   action row, beside `topo-edit-location-button`.
3. It hands over the prompt and opens the chat app, where the user photographs the guidebook page.
4. The reply returns to Masi — pasted in Phase 1, written directly by the MCP server in Phase 2.
5. Review sheet → approve → routes land as committed routes on this photo, correctable with the
   drag handles that already exist.

**Entering from the canvas is what keeps this simple.** The wall and photo are already chosen, so
there is no target picker, no wall matching, and no ambiguity about which photo the coordinates
belong to. It also means Phase 1 needs no deep link at all: the user never leaves the wall's
context, so the reply is pasted on the same screen. A deep link only matters when a *chat app*
initiates the write, which is Phase 2.

**Phase 2 constraint:** the photo must have synced before a chat app can fetch it
(`SyncService._uploadOwnPhotos` puts a private, owner-scoped copy in Supabase storage). That makes
the MCP path a couch activity, not a crag activity, and the UI must say so rather than failing
silently. Phase 1 has no such constraint — nothing leaves the device but text the user pastes.

## Admin-only, for now

The button is gated on `isAdminProvider` via the established idiom
(`ref.watch(isAdminProvider).asData?.value ?? false`), which **fails closed**: false while loading,
false on error.

Be precise about what that gate is. Every other admin surface in this app fronts a
`SECURITY DEFINER` RPC that re-checks `is_admin()` server-side, so hiding the control there is
mere convenience. **Here there is no server call to re-check.** An import writes the user's own
routes to their own wall through the ordinary local repository — exactly what they are already
entitled to do by drawing by hand. So this gate hides an unfinished feature; it does not protect a
privileged one, and nothing is at risk if it is bypassed. That is the right level for "not ready
for ordinary people yet", and it must not be mistaken for a security boundary later.

## One contract, three doors

All three paths carry the **same payload**, so there is one schema, one validator, one review
screen.

| Door | Mechanism | Phase |
|---|---|---|
| **Prompt + paste** | Copy the prompt, photograph the page in the chat app, paste the reply back on the canvas | 1 |
| **Deep link** | `/import?d=<base64url json>` — the model builds the URL | 1b |
| **MCP server** | Cloudflare Worker + OAuth against Supabase | 2 |

Cloudflare hosts Phase 2: Pages is already the deploy target, the `agents-sdk` skill has
first-class remote-MCP + OAuth support, and it is free tier.

## Payload contract (v1)

```json
{
  "v": 1,
  "boulder": "Cul de Chien",
  "gradeSystem": "french",
  "routes": [
    {
      "number": 1,
      "name": "Le Toit",
      "gradeRaw": "6a+",
      "stars": 2,
      "description": "Sit start, undercling to the lip",
      "positionHint": "leftmost, up the obvious arête",
      "points": [[0.21, 0.94], [0.24, 0.55], [0.22, 0.16]]
    }
  ]
}
```

`gradeSystem` is per-import, not per-route: guidebooks use one system throughout, the model often
can't name it, and one correctable dropdown beats N wrong guesses.

### The model is not trusted

Everything below is enforced by the decoder, because a hallucinated payload must degrade, never
corrupt:

| Field | Rule |
|---|---|
| `v` | Must be `1`. Unknown version → reject whole payload with a readable message. |
| `gradeSystem` | `"french"` \| `"uiaa"` only (`GradeSystem` has exactly these). Absent/unknown → `null`, user picks. |
| `gradeRaw` | Kept **only** if `isValidGrade(system, raw)`; else dropped to `null` and flagged in the review sheet. Stored via `normalizeGrade`. |
| `gradeSortKey` | **Never read from the payload.** Always computed locally via `gradeSortKey(system, raw)`. |
| `points` | Each coord clamped to `0.0..1.0`. Non-finite → route becomes unplaced. `< 2` points → unplaced (falls back to the draw queue). Capped at 64 points. |
| `stars` | Integer `0..3`, else `null`. |
| `number` | Ignored for identity. Routes are renumbered `1..N` in payload order on apply. |
| `name` / `description` / `positionHint` | Trimmed; capped at 120 / 2000 / 200 chars. Empty → `null`. |
| `routes` | Capped at 60 per import. |
| unknown keys | Ignored, never an error (forward compatibility). |

`points` is **optional**. Present → drawn best-effort. Absent or invalid → the route is created
unplaced and the user draws it from the guided queue. Same code path, no branching feature.

## Copyright — hard rules

Extracting names and grades is fine; they are facts. The book's *photo and drawn lines* are not.

- The guidebook page image is an **on-device reference only**: shown while correcting, discarded
  when the import finishes.
- **It never receives a `photoId`, never enters the sync set, never reaches Supabase storage,
  never appears in the Community feed.** Encode this as a test, not a convention.

## Phases

### Phase 1 — prompt, paste, review, apply (no infra) ✅ logic done

- **1A** ✅ `GuidebookImport` / `ImportedRoute` domain model + decoder/validator + unit tests.
- **1D** ✅ `GuidebookImportApplier` — N × `RouteRepository.upsertRoute`, appending.
- **1E** ✅ Prompt template, its example checked against the production decoder.
- **1C** Import sheet on the canvas: hand over the prompt → open the chat app → paste the reply →
  review (boulder name, grade-system dropdown, per-route rows, problems vs advisory) → apply.
- **1B** Admin-gated **Import from guidebook** button in the draw-mode action row.

Fully usable with zero infra and nothing leaving the device but text the user pastes.

### Phase 1b — deep link

`/import?d=<base64url>` in `lib/app/router.dart`, landing on the same review sheet. The decoder
already handles this (`decodeGuidebookImportLink`); what is missing is the route and a target
picker, since a link arriving cold has no wall context the way the canvas entry does.

### Phase 2 — MCP server ✅ built

Cloudflare Worker at `https://masi-mcp.xlypton.workers.dev`, OAuth against Supabase. Tools:
`list_recent_walls`, `get_wall_photo`, `create_import`. It writes a pending-import row and does
**not** write routes directly, so the review step is never bypassed — the connected path ends
exactly like the pasted one.

Full design, stage status, and the split between what is verified and what still needs a human:
**`MCP_SERVER_PLAN.md`**.

### Phase 3 — book page as on-screen reference

Collapsible panel beside the canvas while correcting. On-device, discarded on finish.

## Assertions (the verify gate)

A change is done when all of these hold, checked by an agent that did not write the code:

1. `flutter analyze` → 0 issues; `flutter test` → green (no drop in collected count).
2. A payload with an invalid grade imports the route **with `gradeRaw == null`**, not a bad grade.
3. `gradeSortKey` on every imported route equals `gradeSortKey(system, gradeRaw)` recomputed
   locally — never a payload-supplied value.
4. A payload with `points` outside `0..1`, non-finite, or fewer than 2 entries yields an
   **unplaced** route, never a corrupt polyline.
5. `v: 2` (or absent) is rejected with a readable message and writes nothing.
6. Applying an import to a wall produces routes numbered `1..N` in payload order, each round-
   tripping through `loadRoutes` with its metadata intact.
7. Applying an import to a photo that already has routes **appends after them and overwrites
   none** — numbered above the existing maximum, not the existing count.

   *Revised during 1D.* This assertion originally demanded idempotency ("applying the same
   import twice does not duplicate"). That turned out to be the wrong guarantee: `upsertRoute`
   keys on `(photoId, number)`, so any scheme that made a re-import land on the same numbers
   would also make a *first* import land on top of the user's hand-drawn routes and destroy
   them silently, with no undo. Protecting existing work beats de-duplicating a button press —
   a doubled import is visible immediately and deleted in a few taps, whereas overwritten
   routes are neither. The review screen guards the double tap instead.
8. The guidebook reference image never acquires a `photoId` and never enters the sync set.
9. A route imported without `points` is created unplaced and is drawable from the queue.
10. `flutter build web` still passes `tool/build_web.sh`'s gates (no `dart:io` leak).

## Open questions

- **Handing off to the chat app.** Opening ChatGPT/Claude from a PWA with a *pre-filled prompt and
  two attached images* is not something either app supports. `https://claude.ai/new?q=…` and
  `https://chatgpt.com/?q=…` prefill text on web and may deep-link into the installed app, but the
  photos still have to be attached by hand. So Phase 1 copies the prompt to the clipboard and opens
  the app; the user pastes and attaches. Worth confirming on the actual phone which of those URLs
  opens the app rather than a browser tab.
- **MCP on mobile.** Claude's mobile apps do support connectors on paid plans, which is what Phase
  2 would target — but this needs confirming on the user's own phone and plan before the Worker is
  built, because it decides whether Phase 2 is worth it at all. If mobile MCP turns out not to
  work, Phase 1b (deep link) is the fallback that still avoids copy-paste in one direction.
- **Wall targeting for the deep link (1b).** A link arriving cold has no wall context, so it needs
  a picker that the canvas entry does not. Routes are per-photo, so it must pick a *photo*, not
  just a wall.
