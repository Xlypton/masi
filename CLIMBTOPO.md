# ClimbTopo — Route Documentation App for Rock Climbers

## Overview

ClimbTopo is a mobile app for climbers to **document, browse, and (later) share** climbing routes. The core differentiator is a **visual-first topo editor**: photograph a rock face, optionally slice a panorama into wall segments, and draw route lines directly onto the photo on a zoomable canvas. Route lines are stored as **vector data** (percentage-based coordinates, not burned into the image), so they stay zoomable, tappable, editable, and re-projectable across slices and screen sizes.

The reference point is **The Crag** (thecrag.com), but ClimbTopo optimizes one thing above all: **speed of contribution at the crag**. Target: a climber documents a new route in **under two minutes**, offline, one-handed.

**Design north star — the contribution flow:** open app → pick photo → draw line → name + grade → done.

## Target Platform

iOS and Android via **Flutter**. **iOS is the primary target for v1.** Phone form factor first; tablet is a nice-to-have the layout should not actively break.

---

## v1 vs v2 — Scope at a glance

| Capability | v1 (local-first) | v2 (cloud) |
|---|---|---|
| Photo ingestion (library/panorama) | ✅ | |
| Slice tool | ✅ | |
| Topo canvas: zoom/pan, draw, symbols, undo/redo | ✅ | |
| Route metadata (name, grade, style, description) | ✅ | |
| Area / Sector / Wall CRUD | ✅ | |
| Full offline persistence (Drift) | ✅ | |
| Grade systems: French + UIAA | ✅ | + YDS, V-scale/Font |
| Auth (email / OAuth) | | ✅ |
| Cloud sync (push/pull, conflict resolution) | | ✅ |
| Community discovery (map + search) | | ✅ |
| Image upload to Supabase Storage + thumbnails | | ✅ |
| Multi-pitch routes | | ✅ |
| AR route viewer (live camera overlay) | | ✅ |

**Why this split:** the topo editor is the differentiator and the riskiest UI. Shipping it standalone proves the core hypothesis (climbers will draw topos on a phone) before investing in the sync/moderation machinery that roughly doubles the engineering surface. The data model is built sync-ready so v2 is additive, not a rewrite.

---

## Platform Decision & AR Strategy

**Stay Flutter. Do not rewrite native.** Everything in v1 — canvas drawing (`CustomPainter` on Impeller/Metal), camera, image slicing, local storage — is a Flutter strength. Going native buys nothing here and costs Android plus a rewrite. AR is the *only* native-heavy piece, and it's one screen.

### Creation is on-photo (live-drawing is rejected)

Routes are drawn on a **freshly-captured still**, never on the live camera feed. Shoot-then-draw keeps creation as clean 2D percentage coordinates with no 3D math. Live-drawing on video is anti-UX: you can't draw precisely on a surface that moves with the camera, it's a two-hands task done one-handed at arm's length, you can't zoom into a section without losing the wall, foreshortening distorts the upward view, and it sneaks the hard 3D-anchoring problem into the creation flow. The "live" magic is delivered at **view** time (below), not draw time.

### AR route viewer (v2)

Point the phone at a wall and see stored routes draped on the live camera image.

- **Approach — planar image alignment (homography), not 3D world-anchoring.** Match the live frame against the route's **reference photo** (iOS Vision `VNHomographicImageRegistrationRequest`) → homography matrix → warp the stored % points onto the live feed, recomputed per tracked frame.
- **Manual ghost-overlay fallback.** When auto-alignment is low-confidence, freeze to a semi-transparent overlay the user pinch/drag/rotates to line up by hand.
- **Why not full 3D anchoring:** research-grade outdoors — no Apple VPS coverage at remote crags (`ARGeoAnchor` won't work), LiDAR is Pro-only and ~5 m range (walls are 20–30 m), and image tracking is fragile in variable outdoor light. Explicitly out of scope.
- **Build shape — hybrid.** Flutter app + a native iOS AR/CV module embedded via `PlatformView`; method/event channels pass the reference photo + route data in and alignment state out. Android AR is a separate, later effort.

### Why the data model is already AR-ready

Routes are stored as **percentages of the original photo**, and that photo *is* the alignment target — so the overlay is a direct homography warp of existing data. The reference photo's stored `width`/`height` and full-res original (already planned in the data model) are exactly what image registration needs. **No schema changes are required for AR.**

---

## Tech Stack

**v1 (local-first)**

| Concern | Choice | Notes |
|---|---|---|
| UI & canvas | **Flutter** | |
| Route drawing | **CustomPainter** | Full control, no drawing lib |
| Zoom/pan | **InteractiveViewer** | + `TransformationController` for coordinate mapping |
| State | **Riverpod** (v2, `Notifier`/`AsyncNotifier`) | code-gen optional |
| Local DB | **Drift** (SQLite) | Single source of truth, offline-first |
| Photo input | **image_picker** | Native camera/library — no custom camera |
| Image ops | **image** package | Crop / slice / EXIF normalization |
| Navigation | **go_router** | |
| IDs | **uuid** | Client-generated UUIDv4 PKs (sync-ready) |
| Geo (from EXIF) | **exif** package | Extract GPS lat/long from photos for future discovery |

**v2 additions:** `supabase_flutter` (Postgres, auth, storage), `connectivity_plus` (online/offline), `flutter_map` + OSM tiles (discovery map; avoids Google Maps billing/keys).

---

## Architecture

**Feature-first** layout with a light data → application → presentation layering inside each feature. Drift is the single source of truth; the UI reads/writes only through repositories exposed as Riverpod providers.

```
lib/
  main.dart
  app/
    app.dart                 # MaterialApp.router
    router.dart              # go_router config
    theme.dart
  core/
    db/                      # Drift database, tables, DAOs, migrations
    coordinates/             # percent <-> pixel <-> scene transforms (pure, tested)
    grades/                  # GradeSystem, conversion + ordering + color banding
    result/                  # Result/Failure types, shared utils
  features/
    areas/      { data/ application/ presentation/ }   # Area + Sector CRUD
    walls/      { data/ application/ presentation/ }   # Wall, photos, slicing
    topo/       { data/ application/ presentation/ }   # canvas, painters, draw ctrl
    routes/     { data/ application/ presentation/ }   # route + metadata form
  shared/
    widgets/                 # reusable UI
```

**Layer rules (kept pragmatic for solo dev):**
- `presentation` → `application` → `data`; never the reverse.
- Drift entities stay in `data`; map to plain domain models at the repository boundary so the UI never depends on generated DB classes.
- Pure logic (coordinate math, grade conversion) lives in `core` with no Flutter imports → fast, dependency-free unit tests.

---

## Data Model

Hierarchy unchanged from the draft, enhanced for offline-first correctness and v2 sync-readiness.

```
Area
  └── Sector
        └── Wall
              ├── Photo(s)      original + slices
              └── Route(s)      (single-pitch in v1)
```

**Conventions applied to every table (sync-ready):**
- `id`: client-generated **UUIDv4** (TEXT). Never use auto-increment ints — they collide across devices when sync lands.
- `createdAt`, `updatedAt`: timestamps (ms since epoch).
- `deletedAt`: nullable → **soft delete** (tombstones survive sync; hard-delete is local-only cleanup).
- `remoteId` / `dirty` flag: reserved nullable columns, unused in v1, ready for the v2 outbox sync.

### Entities

**Area** — `id, name, description?, latitude?, longitude?, <timestamps>`
Lat/long auto-filled from the first photo's EXIF GPS when available (powers v2 discovery map; harmless in v1).

**Sector** — `id, areaId(FK), name, sortOrder, <timestamps>`

**Wall** — `id, sectorId(FK), name, sortOrder, <timestamps>`

**Photo** — `id, wallId(FK), localPath, kind(original|slice), width, height, parentPhotoId?, cropXpct?, cropWidthPct?, <timestamps>`
- `width`/`height`: **original pixel dimensions** — required to interpret percentage coordinates.
- For a slice: `parentPhotoId` + `cropXpct`/`cropWidthPct` describe the crop window within the parent panorama, so route points stored against the original re-project onto any slice.

**Route** — `id, wallId(FK), photoId(FK), number, name?, gradeSystem, gradeRaw, gradeSortKey, style(sport|trad|boulder), description?, colorBand, points(JSON), symbols(JSON), createdBy?, sortOrder, <timestamps>`
- `points`: `List<Offset>` serialized as **percentages of the original (unsliced) photo** — `{x: 0.0–1.0, y: 0.0–1.0}`.
- `symbols`: `List<TopoSymbol>` → `{type, x, y}` (also percentage-based). Types: anchor `●`, bolt `✕`, top `△`, crux `★`, rest `⊙`.
- `gradeSortKey`: normalized numeric difficulty used for ordering + color banding (see Grade System). `gradeRaw` + `gradeSystem` preserve exactly what the user entered.
- `createdBy`: nullable in v1 (no auth); populated in v2.

> **Single-pitch note (v1):** a Route is exactly one line on one photo. Multi-pitch (v2) becomes a `Pitch` child table — additive, no migration of existing data needed.

### Coordinate System (formalized)

Three coordinate spaces, converted by pure functions in `core/coordinates`:

1. **Percent space** — `(0..1, 0..1)` relative to the **original unsliced image**. The only thing persisted.
2. **Scene/image-pixel space** — the CustomPainter's child coordinate space (image displayed at natural size inside InteractiveViewer). `pixel = percent * imageDimension`.
3. **Screen space** — pointer/tap coordinates. Mapped to scene space via the **inverse of `TransformationController.value`** (`controller.toScene(offset)` / `MatrixUtils.transformPoint(matrix.clone()..invert(), offset)`).

Storing percentages of the original means a route drawn on a full panorama renders correctly on any slice (re-project via the slice's `cropXpct`/`cropWidthPct`) and at any zoom/screen size. **This invariant is the backbone of the app** and is covered by unit tests.

---

## Core Features — v1

### 1. Photo ingestion
- Pick photo or panorama from native library via `image_picker` (no in-app camera).
- **Normalize EXIF orientation on import** (bake rotation into pixels) so coordinate math never has to reason about orientation flags.
- Store original dimensions; decode for display at a capped resolution (see Risks: memory).
- Extract EXIF GPS → Area lat/long when present.

### 2. Slice tool
- User drags **vertical cut lines** on the panorama.
- App splits into segments; each slice stored as a Photo with `parentPhotoId` + `cropXpct`/`cropWidthPct`.
- Original + slices linked under the same Wall. Routes can be drawn on either; coordinates stay valid across both.

### 3. Topo canvas (the core)
- Wall photo as background inside `InteractiveViewer` (pinch-zoom, pan).
- **Explicit mode toggle — View ↔ Draw** (see Risks): in View mode InteractiveViewer owns gestures; in Draw mode a `GestureDetector` captures tap/drag to place route points and InteractiveViewer pan is locked.
- Draw a route: tap/drag places points → rendered as a **smoothed Catmull-Rom spline** (converted to cubic bézier via `Path.cubicTo`).
- **Undo/redo stack** scoped to the in-progress route.
- **Point editing**: drag an existing point to nudge it (smoothing means raw taps rarely land perfectly).
- **Symbol placement**: anchor/bolt/top/crux/rest, positioned in percent space.
- Each route has a **grade-band color** + a **number label**.
- **Toggle individual routes on/off**; **tap a rendered route to select it** (hit-test = min distance from tap to polyline segments, threshold scaled to current zoom).

### 4. Route metadata
- **Draw first, fill second.** After the line is drawn, a sheet collects: name, grade (with grade-system picker: French | UIAA), style, description.
- Grade entry validates against the chosen system's ladder and computes `gradeSortKey` + `colorBand`.

### 5. Local persistence
- Full offline support via Drift. Areas, sectors, walls, photos (file paths + originals on disk), routes all stored locally.
- App is **fully functional with zero connectivity**.
- **Migration strategy set up from day one** — offline user data is precious; schema versioning + tested migrations from the first release.

---

## Grade System

A table-driven service in `core/grades`:
- **Ladders** for French (`…5c, 6a, 6a+, 6b…`) and UIAA (`…V, VI-, VI, VI+…`), each mapping a grade token to a canonical numeric `sortKey`.
- `gradeSortKey` enables consistent ordering and **color banding** regardless of which system the user typed.
- Adding YDS / V-scale / Font in v2 = adding ladder tables; no schema change.
- Boulder-style routes in v1 are tagged `style=boulder` but graded in French/UIAA (or left ungraded) until a bouldering ladder is added.

**Grade-band → color** (canonical difficulty ramp; tune to taste):

| Band | Approx (French) | Color |
|---|---|---|
| Beginner | ≤ 4 | green |
| Intermediate | 5–6a | blue |
| Advanced | 6a+–6c+ | orange |
| Hard | 7a–7c+ | red |
| Elite | ≥ 8a | purple |

---

## Key UX Principles

- **Draw first, fill metadata second** — never block the creative flow with a form.
- **Offline-first** — assume no signal at the crag.
- **Visual-first** — route lines *are* the UI, not a list of names.
- **Percentage-based coordinates always** — never persist pixels.
- **Explicit View/Draw mode** — predictable gestures beat clever gesture arbitration.

---

## Out of Scope for v1

Deferred to **v2**: auth, cloud sync, community discovery (map + search), image upload/thumbnails, multi-pitch, **AR route viewer** (see Platform Decision & AR Strategy). **Status: v2 has since shipped and is live** — Supabase auth, row-level sync (push/pull, tombstones), shared-topo discovery (map + search), photo upload/thumbnails, comments, likes, an ascent logbook, and the (2D homography) AR route viewer are all implemented and verified end-to-end (two-account live smoke test). Multi-pitch remains the one item here still out of scope.
Deferred indefinitely / not planned: in-app camera or panorama stitching (use native), grade voting / moderation, **3D world-anchored AR** / photogrammetry. (Ascent logbook / ticklist has since shipped as part of the v2 community suite — no longer out of scope.)

---

## Testing Strategy (pragmatic, solo)

Prioritized by value-per-effort:
1. **Pure-function unit tests** (highest value): coordinate transforms (percent↔pixel↔scene, slice re-projection round-trips), grade conversion + ordering + color banding. Fast, no Flutter.
2. **Drift DAO tests** against an in-memory SQLite DB: CRUD, soft-delete, cascade on Wall delete, migration round-trips.
3. **Riverpod provider tests**: draw controller (add/undo/redo), route selection.
4. **Golden test** for the topo `CustomPainter`: a known set of points + symbols renders to a stable image (catches regressions in the line/symbol rendering).
5. **Widget test** for the metadata sheet validation.

---

## Build Order (phased milestones)

**Milestone 0 — Walking skeleton (1 screen, no DB):** Flutter app boots → pick a photo → display it in `InteractiveViewer` with zoom/pan. Proves the riskiest plumbing first.

**Milestone 1 — Topo canvas:** View/Draw mode toggle → place points → Catmull-Rom/bézier render → undo/redo → point editing. *This is the differentiator; nail it before anything else.*

**Milestone 2 — Symbols + multi-route:** symbol placement, multiple routes per photo, per-route color + number, toggle on/off, tap-to-select (hit-testing).

**Milestone 3 — Persistence:** Drift schema (with UUIDs/timestamps/soft-delete + migration setup), repositories, save/load a wall with its routes.

**Milestone 4 — Metadata + grades:** metadata sheet, grade service (French + UIAA), validation, color banding.

**Milestone 5 — Slice tool:** vertical cuts, slice persistence with crop rects, route re-projection across original ↔ slices.

**Milestone 6 — CRUD & navigation:** Area / Sector / Wall lists + create/edit/delete, go_router wiring, empty/error states.

> **v2 (separate effort — shipped and live):** Supabase auth → outbox-pattern sync (dirty flags + `updatedAt` cursors, last-write-wins per record + tombstones) → Storage upload with thumbnails → discovery (flutter_map + EXIF GPS + search) → community features (comments, likes, ascent logbook) → AR route viewer. All implemented and verified end-to-end via a two-account live smoke test; only multi-pitch remains unbuilt from this list.

---

## Technical Risks & Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| **Gesture conflict**: InteractiveViewer pan/zoom vs draw-drag | High — core UX | Explicit **View/Draw mode toggle**; lock InteractiveViewer pan in Draw mode. Decided up front, not arbitrated per-gesture. |
| **Coordinate transform bugs** (screen↔scene↔percent, slice re-projection) | High — corrupts every saved route | Centralize in `core/coordinates` pure functions; round-trip unit tests; percentage-of-original invariant. |
| **Large panorama memory** (multi-MB images decoded full-res) | Med — OOM/jank on device | Decode display copy with `cacheWidth`/`ResizeImage`; keep original on disk only; cap working resolution. |
| **EXIF orientation** quirks | Med — rotated images break coords | Normalize orientation into pixels on import; store post-normalization dimensions. |
| **Spline fidelity** (smoothed line drifts from intended path) | Med | Catmull-Rom through actual points; allow point drag-editing; show raw points in Draw mode. |
| **Drift migrations** on precious offline data | Med | Schema versioning + tested migrations from v1 release; never destructive. |

---

## Open Questions (non-blocking)

- App display name / bundle id / branding → resolve at project init.
- Photo storage location on device (app documents dir vs media) and backup behavior.
- Whether boulder routes need a grade ladder in v1 or can ship ungraded until v2.

---

## Verification (for the implementation phase, post-v1 build)

- `flutter analyze` clean; `flutter test` green (coordinate + grade + DAO + golden suites).
- Manual end-to-end on iOS simulator/device: pick panorama → slice → draw two routes in Draw mode → switch to View mode, zoom/pan, tap to select each route → fill metadata (French + UIAA) → kill & relaunch app **with networking off** → routes reload from Drift at correct positions on both the original and a slice.
- Golden test stable across runs.
