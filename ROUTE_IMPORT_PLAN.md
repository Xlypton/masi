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

## The ordering that makes AI placement work

The model must place lines against **the user's photo**, never the book's — different angle,
different framing, curved glossy page. So the photo comes *first*:

1. **In Masi:** photograph the boulder, create the wall, no routes yet. It syncs.
   (`SyncService._uploadOwnPhotos` puts a private, owner-scoped copy in Supabase storage.)
2. **In the chat:** photograph the guidebook page. The model calls `masi.list_recent_walls()`,
   the user names the boulder, it calls `masi.get_wall_photo(wallId)` → a signed URL to the
   user's *actual* photo.
3. The model now sees both images and emits polylines **in the user's photo's coordinate space**.
4. It calls `masi.create_import(...)` → gets back `https://climb-masi.pages.dev/import/<id>`.
5. User taps → review sheet → approve → routes land as committed routes, correctable by hand.

No photo mismatch is possible, because the model is looking at the file Masi will draw on. This is
the difference between "roughly the right place" and "random lines".

**Phase 1 constraint:** the photo must have synced before the chat can see it. This is a couch
activity, not a crag activity. The UI must say so rather than silently failing.

## One contract, three doors

All three paths carry the **same payload**, so there is one schema, one validator, one review
screen.

| Door | Mechanism | Phase |
|---|---|---|
| **Deep link** | `/import?d=<base64url json>` — the model builds the URL | 1 |
| **Prompt template** | Copy-paste prompt for any LLM; output pastes into an import box | 1 |
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

### Phase 1 — deep link + prompt template + review (no infra)

- **1A** `GuidebookImport` / `ImportedRoute` domain model + decoder/validator + unit tests.
- **1B** `/import` route in `lib/app/router.dart`, `?d=` base64url payload, plus a paste box.
- **1C** Review screen: boulder name, grade-system dropdown, per-route rows, flagged fields.
- **1D** Apply: pick target wall + photo, then N × `RouteRepository.upsertRoute` numbered 1..N.
- **1E** Prompt-template screen with a copy button.

Fully usable with zero infra.

### Phase 2 — MCP server

Cloudflare Worker, OAuth against Supabase. Tools: `list_recent_walls`, `get_wall_photo`,
`create_import`. Writes a pending-import row and returns the deep link; it does **not** write
routes directly, so the review step is never bypassed.

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

- **Wall targeting in Phase 1.** Deep link has no wall id. Simplest: review screen asks the user
  to pick an existing wall+photo, or create a new wall and attach a photo inline. Phase 2's MCP
  path carries the `wallId` and skips the picker.
- **Multi-photo walls.** Routes are per-photo. The picker must choose a *photo*, not just a wall.
