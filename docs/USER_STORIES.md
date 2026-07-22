# masi (Masi) — User Stories & Use Cases

**Package:** `masi` · **Status:** v1 (M0–M6) + v2 AR code-complete on `main`; Supabase sync deferred.
**Source of truth for behavior:** `/Users/kerip/Projects/masi/MASI.md` and `/Users/kerip/Projects/masi/DESIGN.md`.
This document is the source of truth for UI test derivation — every story below is written so an
implementer can turn its acceptance criteria directly into `testWidgets` assertions.

> **Grounding note:** this document is deliberately **not** grounded in `lib/` — the current
> implementation is known-buggy. Every story cites spec line numbers. Where the two spec files are
> silent on a behavioral detail (e.g. "which mode does the canvas start in"), that is flagged
> explicitly as **(not stated verbatim in spec)** and the intended behavior is instead defined by
> the referenced intent test — those tests are themselves spec-derived, never implementation-derived.

---

## 1. Introduction

**One-liner:** masi is a visual-first topo editor for rock climbers — photograph a wall, draw route
lines directly on the photo, name and grade them, done. (MASI.md:L1, L5)

**North-star contribution flow:** *open app → pick photo → draw line → name + grade → done*, targeting
under two minutes, offline, one-handed. (MASI.md:L7, L9; DESIGN.md:L139)

**Personas:**
- **The climber at the crag** — no signal, one free hand, needs to document a new line before the
  next party arrives. This is the primary and only persona named in the spec. (MASI.md:L6-7)
- **The organizer** (same person, later, at home) — drills into Area→Sector→Wall to tidy up, rename,
  or delete stale entries. Secondary to the contribution flow by design: reachable via "Organize," not
  the home screen. (DESIGN.md:L102)

**Platform scope for v1 stories:**
- iOS-primary, Flutter, phone form factor first. (MASI.md:L11-13; DESIGN.md:L7)
- Fully local-first (Drift/SQLite); zero-connectivity functional. (MASI.md:L193-196)
- **Out of scope for this document** (spec marks v2 or not-planned; see "Out of scope" section at the
  end): AR live route viewer, cloud sync, auth, community discovery/map, image upload to Supabase,
  multi-pitch routes, in-app camera/panorama stitching, ascent logbook, grade voting. Everywhere below,
  such items are marked **"v2, not covered."**

---

## 2. Epics & User Stories

### Epic A — Home / Topo List

#000: The primary landing screen. DESIGN.md:L101-106 replaces the naive Area→Sector→Wall drill-down
home with a flat list of topos, keeping the drill-down reachable via "Organize."

#### US-HOME1: See an empty library and start my first topo
**As a** first-time user **I want** to see a clear empty state on Home **so that** I immediately know
how to create my first topo instead of facing a blank screen.
**Preconditions:** No topos exist in the local DB (fresh install, or all topos soft-deleted).
**Main flow:**
1. User launches the app.
2. App loads the topo list from Drift; the query returns zero rows.
3. Home renders "No topos yet" plus a "New topo" button.
**Acceptance criteria (Given/When/Then):**
- Given zero non-deleted topos exist, when Home first builds, then the text "No topos yet" is visible.
- Given the empty state is showing, then a "New topo" button is visible and enabled.
- Given the empty state is showing, then no topo list rows, thumbnails, or "Organize" placeholder rows
  are rendered.
**Covers spec:** DESIGN.md:L105 ("'No topos yet' + a 'New topo' button").
**Test:** library_ui_intent_test.dart → A6d.

#### US-HOME2: Browse my topos at a glance
**As a** returning user with multiple documented walls **I want** a flat scrollable list of every topo
with a thumbnail, name, grade, and route count **so that** I can find the one I want without drilling
through Area→Sector→Wall.
**Preconditions:** ≥1 non-deleted topo exists, each with a wall, an original photo, and 0+ routes.
**Main flow:**
1. User launches the app / returns to Home.
2. App queries all topos (one row per wall + its original photo + route count).
3. Each row renders: 52×52 rounded (radius 9) photo thumbnail (amethyst-gradient fallback if no
   photo), title (Headline style), subtitle showing a grade pill (grade-band color, white text) + "N
   routes", trailing chevron in `ink3`.
4. User taps a row → navigates to that topo's canvas (see Epic C).
**Acceptance criteria (Given/When/Then):**
- Given N topos exist, when Home builds, then exactly N rows render, each keyed to a distinct topo id.
- Given a topo has a photo, then its row thumbnail shows that photo, rounded to radius 9, 52×52.
- Given a topo has no photo, then its row thumbnail shows an amethyst-gradient placeholder, not a
  broken-image icon or empty box.
- Given a topo has routes, then the subtitle shows a grade pill colored by that topo's representative
  grade band and the literal text "N routes" (N = actual committed route count).
- Given a topo row is visible, then a chevron renders at the trailing edge in the `ink3` token color.
- When the user taps a row, then the app navigates to the canvas for that row's wall/topo.
**Covers spec:** DESIGN.md:L102-103 ("flat list of topos... 52×52 rounded (9) photo thumbnail...").
**Test:** library_ui_intent_test.dart → A6d.

#### US-HOME3: Reach the Area/Sector/Wall organizer from Home
**As a** user who wants to manage the underlying library structure **I want** a visible "Organize"
action from Home **so that** I can still reach Area→Sector→Wall CRUD without it cluttering the primary
contribution flow.
**Preconditions:** App is on the Home screen (topo list, empty or populated).
**Main flow:**
1. User taps the "Organize" trailing action on Home.
2. App navigates to the Areas list screen (top of the Area→Sector→Wall drill-down).
**Acceptance criteria (Given/When/Then):**
- Given Home is showing (empty or populated), then an "Organize" action is visible and reachable
  without scrolling.
- When the user taps "Organize", then the app pushes the Areas list screen.
- The data model underneath (Area→Sector→Wall) is unchanged; "Organize" is purely a navigation
  entry point, not a different data source.
**Covers spec:** DESIGN.md:L102 ("Drop the Area→Sector→Wall drill-down from the primary flow; keep it
reachable via a trailing 'Organize' action, and keep the data model intact.").
**Test:** library_ui_intent_test.dart → A6d.

#### US-HOME4: Create a new topo in one tap and a photo
**As a** climber at the crag **I want** one tap from Home to open a photo-source sheet and land
straight on the drawing canvas **so that** documenting a new wall costs the minimum possible friction.
**Preconditions:** App is on Home (any state). Camera/photo-library permissions are either already
granted or about to be requested by the OS.
**Main flow:**
1. User taps the filled amethyst "New topo" button (pinned bottom, or the `+` in the trailing nav
   slot).
2. App presents a `CupertinoActionSheet` titled "Add a photo" with three actions: "Take photo" (camera
   glyph), "Choose from library" (photo glyph), and "Cancel".
3a. User taps "Take photo" → OS camera capture (`ImageSource.camera`) → returns image.
3b. User taps "Choose from library" → OS photo picker (`ImageSource.gallery`) → returns image.
3c. User taps "Cancel" → sheet dismisses, no topo created, user remains on Home.
4. On successful capture/pick, app creates a new Wall + Photo (kind=original) record and pushes
   directly to the topo canvas for that new wall — no intermediate Area/Sector picker is shown in the
   primary flow.
**Acceptance criteria (Given/When/Then):**
- When the user taps "New topo", then a `CupertinoActionSheet` appears with title "Add a photo" and
  exactly three actions in this order: Take photo, Choose from library, Cancel.
- When the user selects "Take photo", then `ImageSource.camera` is requested (no custom in-app camera
  UI is shown).
- When the user selects "Choose from library", then `ImageSource.gallery` is requested.
- When the user selects "Cancel", then the sheet dismisses and no new topo/wall/photo record is
  created.
- Given a photo is successfully returned from either source, then exactly one new topo (wall + Photo
  kind=original) is created and the app navigates directly to that topo's canvas — one tap plus a
  photo, no extra screens.
**Covers spec:** DESIGN.md:L104 ("Primary action = a filled amethyst button 'New topo'... → opens the
photo-source action sheet → on capture, create the topo and push straight to the canvas."); DESIGN.md:
L114-120 (action sheet spec); MASI.md:L168-172 (`image_picker`, no in-app camera); MASI.md:
L73.
**Test:** library_ui_intent_test.dart → A6e. (Existing coverage today: photo_source_sheet_test.dart —
not part of the intent-test id map but exercises the same sheet.)

#### US-HOME5: Rename or delete a topo from the list
**As a** user tidying up my library **I want** to rename or soft-delete a topo directly from its Home
row **so that** I don't have to navigate into Organize for simple housekeeping.
**Preconditions:** ≥1 topo exists on Home.
**Main flow:**
1. User swipes a topo row, or long-presses to open a context menu.
2. User selects "Rename" → inline/dialog text field pre-filled with current name → confirms.
3. User selects "Delete" → confirmation dialog appears → user confirms → topo (its wall) is
   soft-deleted (`deletedAt` set), removed from the visible list, underlying rows retained for
   potential undo/sync history.
**Acceptance criteria (Given/When/Then):**
- Given a topo row, when the user swipes/opens its context menu, then Rename and Delete actions are
  available.
- When the user renames a topo and confirms, then the row's title updates immediately and the
  underlying wall's name is persisted.
- When the user taps Delete, then a confirmation dialog appears before any data is removed.
- When the user confirms Delete, then the topo disappears from the Home list and its wall's
  `deletedAt` is set (soft delete) — it is not hard-deleted from the DB.
- When the user cancels the Delete confirmation, then the topo remains unchanged and visible.
**Covers spec:** DESIGN.md:L106 ("Rename / delete from the row (swipe or a context menu), reusing
existing repo soft-delete.").
**Test:** library_ui_intent_test.dart → A6d.

#### US-HOME6: Reopening a topo always lands in View mode
**As a** returning user **I want** tapping into an already-documented topo to open in a safe,
non-destructive viewing state **so that** I never accidentally start drawing on a wall I only meant to
look at.
**Preconditions:** A topo with ≥1 committed route exists.
**Main flow:**
1. User taps a topo row on Home.
2. Canvas screen mounts for that wall.
3. Canvas is in View mode: pan/zoom enabled, no draw toolbar cluster visible.
**Acceptance criteria (Given/When/Then):**
- Given a wall with existing routes, when its canvas screen is freshly mounted, then
  `drawControllerProvider.mode == DrawMode.view`.
- Given the canvas just mounted, then the undo/redo/clear/commit toolbar cluster is absent.
- This holds even after the wall's photo finishes an async load — loading a photo must never itself
  flip the canvas into Draw mode.
**Covers spec:** Ties Home navigation (DESIGN.md:L104) to the canvas mode default. The specific
"starts in View" behavior is **not stated verbatim in either spec file**; it is defined canonically by
the intent test below, which frames it as fixing a regression (BUG-1a/BUG-1c).
**Test:** canvas_mode_intent_test.dart → A1a.

---

### Epic B — Library CRUD (Area / Sector / Wall)

Background: `Area → Sector → Wall → {Photo(s), Route(s)}` (MASI.md:L119-125), reached from Home
via "Organize" (DESIGN.md:L102). Every table follows sync-ready conventions: UUIDv4 id, createdAt/
updatedAt, soft-delete via `deletedAt` (MASI.md:L127-131).

#### US-LIB1: Create an Area
**As a** user organizing my library **I want** to create a new Area (e.g. a crag) **so that** I have a
place to file its sectors and walls.
**Preconditions:** User is on the Areas list screen (via Organize).
**Main flow:**
1. User taps the add action on the Areas list.
2. A create dialog/sheet asks for a name.
3. User enters a name and confirms.
4. New Area row appears in the list, persisted with a fresh UUIDv4 id.
**Acceptance criteria (Given/When/Then):**
- When the user submits a non-empty name, then a new Area is persisted and appears in the list.
- Given the name field is empty, then the confirm action is disabled or submission is rejected (no
  empty-named Area is ever created).
- Given the Areas list was empty, then after creation it shows exactly one row with the new name.
**Covers spec:** MASI.md:L119-125 (hierarchy), L135-136 (Area entity), L262 (Milestone 6: "Area /
Sector / Wall lists + create/edit/delete").
**Test:** library_ui_intent_test.dart → A6a.

#### US-LIB2: Rename an Area
**As a** user **I want** to rename an existing Area **so that** I can correct typos or reflect the
crag's real name.
**Preconditions:** ≥1 Area exists.
**Main flow:** 1. User selects an Area row's edit action. 2. Edits the name. 3. Confirms.
**Acceptance criteria (Given/When/Then):**
- When the user confirms a new non-empty name, then the Area's name is updated in place and
  `updatedAt` advances.
- Given the user cancels the rename dialog, then the Area's name is unchanged.
**Covers spec:** MASI.md:L262; MASI.md:L127-131 (updatedAt convention).
**Test:** library_ui_intent_test.dart → A6a.

#### US-LIB3: Delete an Area with confirmation (soft delete)
**As a** user **I want** a confirmation step before deleting an Area **so that** I don't lose a whole
crag's worth of sectors/walls/routes by a stray tap.
**Preconditions:** ≥1 Area exists.
**Main flow:**
1. User taps Delete on an Area row.
2. Confirmation dialog appears, naming the Area.
3. User confirms → Area's `deletedAt` is set; it disappears from the list.
4. User cancels → nothing changes.
**Acceptance criteria (Given/When/Then):**
- When the user taps Delete, then a confirmation dialog appears before any mutation.
- When confirmed, then the Area is soft-deleted (`deletedAt` set, row not physically removed) and no
  longer appears in the Areas list.
- When cancelled, then the Area remains fully intact and visible.
**Covers spec:** MASI.md:L127-131 (soft-delete convention); L262.
**Test:** library_ui_intent_test.dart → A6a.

#### US-LIB4: Drill down Area → Sector → Wall
**As a** user organizing my library **I want** to tap an Area to see its Sectors, and a Sector to see
its Walls **so that** I can navigate the hierarchy the data model implies.
**Preconditions:** An Area with ≥1 Sector, and a Sector with ≥1 Wall, exist.
**Main flow:**
1. User taps an Area row → Sectors list for that Area.
2. User taps a Sector row → Walls list for that Sector.
3. User taps a Wall row → that Wall's topo canvas (or a Wall detail screen listing its topo).
**Acceptance criteria (Given/When/Then):**
- When the user taps an Area, then only Sectors belonging to that Area are listed.
- When the user taps a Sector, then only Walls belonging to that Sector are listed.
- Back navigation from Walls returns to the same Sector's position in the Sectors list (state
  preserved, not reset to Areas root).
**Covers spec:** MASI.md:L119-125 (hierarchy); DESIGN.md:L102 ("keep it reachable via... Organize").
**Test:** library_ui_intent_test.dart → A6b.

#### US-LIB5: Create / rename / delete a Sector
**As a** user **I want** the same create/rename/delete-with-confirm capabilities on Sectors that Areas
have **so that** the whole hierarchy is manageable consistently.
**Preconditions:** An Area exists.
**Main flow:** Same shape as US-LIB1/2/3, scoped to a Sector under its parent Area.
**Acceptance criteria (Given/When/Then):**
- Create: a non-empty name persists a new Sector under the current Area.
- Rename: confirmed edits update the Sector's name in place.
- Delete: requires confirmation; on confirm, sets `deletedAt` and removes it from the visible Sectors
  list under that Area.
**Covers spec:** MASI.md:L138 (Sector entity); L262.
**Test:** library_ui_intent_test.dart → A6b.

#### US-LIB6: Create / rename a Wall
**As a** user **I want** to create and rename Walls under a Sector **so that** each physical rock face
has its own record to attach photos and routes to.
**Preconditions:** A Sector exists.
**Main flow:** Same shape as US-LIB1/2, scoped to a Wall under its parent Sector.
**Acceptance criteria (Given/When/Then):**
- Create: a non-empty name persists a new Wall under the current Sector.
- Rename: confirmed edits update the Wall's name in place, and (per US-NAV1) that name is what the
  canvas nav title subsequently shows.
**Covers spec:** MASI.md:L140 (Wall entity); DESIGN.md:L98-99 (canvas title = wall name).
**Test:** library_ui_intent_test.dart → A6c.

#### US-LIB7: Delete a Wall cascades to its Photos and Routes
**As a** user deleting a Wall **I want** its Photos and Routes to be removed from view along with it
**so that** the library never shows orphaned data.
**Preconditions:** A Wall exists with ≥1 Photo and ≥1 Route.
**Main flow:**
1. User taps Delete on a Wall row.
2. Confirmation names the Wall (and may warn about N routes/photos being removed).
3. User confirms → Wall is soft-deleted; its Photos and Routes are cascade-affected (excluded from all
   subsequent queries) even though physically retained for sync/undo purposes.
**Acceptance criteria (Given/When/Then):**
- When the user confirms deletion of a Wall, then that Wall no longer appears in its Sector's Walls
  list.
- Given that Wall had Photos and Routes, then after deletion none of them appear in any query scoped
  to non-deleted records (e.g. Home's topo list, the canvas).
- The cascade is a DAO-level guarantee, independently verified against an in-memory SQLite DB (not
  just a UI-level hide).
**Covers spec:** MASI.md:L241 ("Drift DAO tests against an in-memory SQLite DB: CRUD, soft-delete,
cascade on Wall delete, migration round-trips.").
**Test:** library_ui_intent_test.dart → A6c.

#### US-LIB8: See empty and error states with retry in the library lists
**As a** user **I want** clear empty states and a retry option on load failure at every level of
Area/Sector/Wall **so that** the library never appears to silently fail.
**Preconditions:** Varies — an empty Sectors/Walls list, or a simulated repository error.
**Main flow (empty):** User drills into a level with zero children → an empty-state message +
create action is shown (consistent with Home's "No topos yet" pattern).
**Main flow (error):** A query fails (e.g. DB error) → an error state renders with a "Retry" action →
tapping Retry re-issues the query.
**Acceptance criteria (Given/When/Then):**
- Given zero Sectors under an Area, then the Sectors screen shows an empty state with a create
  action, not a blank screen.
- Given zero Walls under a Sector, then the Walls screen shows the equivalent empty state.
- Given a query throws, then an error state with a visible "Retry" affordance renders instead of a
  crash or infinite spinner.
- When "Retry" is tapped, then the query re-runs and, on success, the normal list/empty state renders.
**Covers spec:** MASI.md:L262 ("...empty/error states."). Exact retry copy/mechanics are not
spelled out further in either spec file.
**Test:** library_ui_intent_test.dart → A6b, A6c (empty/error coverage split across Sectors/Walls).

---

### Epic C — Canvas Modes (View ↔ Draw)

The single highest-risk UX decision in the spec: gesture ownership is resolved by an **explicit,
binary mode toggle**, never per-gesture arbitration. (MASI.md:L226, L272)

#### US-MODE1: Toggle explicitly between View and Draw
**As a** user on the topo canvas **I want** an explicit toggle between View and Draw modes **so that**
I always know unambiguously whether my next touch will pan/zoom the photo or place a route point.
**Preconditions:** Canvas is open for a wall with a loaded photo.
**Main flow:**
1. Canvas opens in View mode (US-HOME6).
2. User taps the mode-toggle control.
3. Canvas switches to Draw mode: InteractiveViewer pan is locked, scale may remain available per
   implementation, and a GestureDetector now captures tap/drag for point placement.
4. User taps the toggle again (or commits/cancels, see Epic D) → returns to View mode.
**Acceptance criteria (Given/When/Then):**
- Given View mode, when the user taps `topo-mode-toggle`, then `drawControllerProvider.mode` becomes
  `DrawMode.draw`.
- Given Draw mode, then `InteractiveViewer.panEnabled == false` (pan is locked so single-finger
  gestures are unambiguously point-placement).
- Given View mode, then `InteractiveViewer.panEnabled == true` and `scaleEnabled == true`.
**Covers spec:** MASI.md:L181 ("Explicit mode toggle — View ↔ Draw... in View mode
InteractiveViewer owns gestures; in Draw mode a GestureDetector captures tap/drag... InteractiveViewer
pan is locked."); L226; L272.
**Test:** canvas_mode_intent_test.dart → A1b, A1f.

#### US-MODE2: View mode is pure pan/zoom, no accidental drawing
**As a** user inspecting a topo **I want** View mode to only pan and zoom the photo **so that** I can
freely explore a wall without ever accidentally creating a stray route point.
**Preconditions:** Canvas is in View mode.
**Main flow:** User drags/pinches on the photo. InteractiveViewer consumes the gesture; no point is
added to any route.
**Acceptance criteria (Given/When/Then):**
- Given View mode, when the user drags on the photo, then the viewport pans and no route/point is
  created or modified.
- Given View mode, when the user pinches, then the viewport zooms and no route/point is created or
  modified.
**Covers spec:** MASI.md:L181.
**Test:** canvas_mode_intent_test.dart → A1f.

#### US-MODE3: Draw mode locks panning so taps place points unambiguously
**As a** user actively drawing a route **I want** panning disabled in Draw mode **so that** every
touch on the photo is interpreted as placing or dragging a route point, never as an accidental pan.
**Preconditions:** Canvas is in Draw mode.
**Main flow:** User taps/drags on the photo; each gesture is routed to the draw controller as a point
placement/edit, never to InteractiveViewer's pan handler.
**Acceptance criteria (Given/When/Then):**
- Given Draw mode, then `InteractiveViewer.panEnabled == false`.
- Given Draw mode, when the user taps the photo, then a point is appended to the in-progress route
  (see Epic D), not interpreted as a pan gesture.
**Covers spec:** MASI.md:L181, L272 ("lock InteractiveViewer pan in Draw mode. Decided up front,
not arbitrated per-gesture.").
**Test:** canvas_mode_intent_test.dart → A1f.

#### US-MODE4: Opening or reopening a canvas always starts in View mode
**As a** user **I want** every fresh mount of the canvas — first open or reopen after navigating away
— to start in View mode **so that** I never land unexpectedly in a state that can mutate route data.
**Preconditions:** A wall exists (with or without an existing photo/routes).
**Main flow:**
1. User navigates to a wall's canvas (from Home or Organize).
2. Canvas mounts. Regardless of whether a photo is already attached or still loading, mode is View.
3. User navigates away (e.g. commits a route, dismisses metadata, backs out) and returns.
4. Canvas mounts again, fresh — mode is View again, not whatever mode it was left in previously.
**Acceptance criteria (Given/When/Then):**
- Given a fresh `TopoCanvasScreen` mount for any wall, then `mode == DrawMode.view` immediately, before
  and after the wall's photo finishes loading.
- Given the user committed a route (which returns to View, see US-DRAW6), dismissed the metadata
  sheet, unmounted, and re-mounted the same wall's canvas, then mode is View on the fresh mount (not
  persisted as Draw from the prior session).
**Covers spec:** Not stated verbatim in either spec file — this is the canonical default asserted by
the intent test suite (framed as fixing regressions BUG-1a/BUG-1c).
**Test:** canvas_mode_intent_test.dart → A1a, A1d.

#### US-MODE5: Attaching/loading a photo never silently flips the mode
**As a** user **I want** an async photo load to never change my current mode **so that** a slow disk/
network operation can't yank me into Draw mode while I'm just browsing.
**Preconditions:** Canvas is mounted in View mode; its photo has not finished loading yet.
**Main flow:** The wall's photo finishes loading asynchronously after the screen is already visible.
**Acceptance criteria (Given/When/Then):**
- Given View mode before a photo load completes, when the photo load completes, then mode remains
  `DrawMode.view` and the toolbar cluster remains absent.
**Covers spec:** Not stated verbatim in spec; canonicalized by the intent test (BUG-1c regression
guard).
**Test:** canvas_mode_intent_test.dart → A1a.

---

### Epic D — Draw Flow

"Draw first, fill metadata second — never block the creative flow with a form." (MASI.md:L222)

#### US-DRAW1: Place route points by tapping/dragging on the photo
**As a** user in Draw mode **I want** to tap or drag on the photo to lay down a sequence of points
**so that** I can trace the line of a climb as I see it on the rock.
**Preconditions:** Canvas is in Draw mode.
**Main flow:**
1. User taps a point on the photo → a point is appended to `currentPoints` (stored in percent-space,
   see US-PERSIST2).
2. User repeats for each subsequent point along the route.
**Acceptance criteria (Given/When/Then):**
- Given Draw mode, when the user taps the photo, then `drawControllerProvider.currentPoints` grows by
  one entry at the tapped location.
- Given Draw mode, when the user adds two or more points, then a preview line renders through them.
**Covers spec:** MASI.md:L182 ("Draw a route: tap/drag places points...").
**Test:** canvas_mode_intent_test.dart → A1b (setup precondition for A1c/A1e); no dedicated point-
placement geometry test in the current map — (gap — no coverage yet) for placement geometry itself.

#### US-DRAW2: Raw points render as a smoothed Catmull-Rom/bézier line
**As a** user drawing a route **I want** my raw taps rendered as a smooth curve **so that** the line
looks like a natural climbing line rather than a jagged polyline of exact tap positions.
**Preconditions:** ≥2 points placed in the current in-progress route.
**Main flow:** After each point is added, the renderer fits a Catmull-Rom spline through the raw
points and converts it to a cubic bézier (`Path.cubicTo`) for display.
**Acceptance criteria (Given/When/Then):**
- Given ≥2 raw points, then the rendered path is a smoothed curve through them (Catmull-Rom → cubic
  bézier), not a straight-segment polyline.
- Given Draw mode specifically, then the raw (un-smoothed) point positions are also visibly rendered
  (e.g. as handles/dots) alongside the smoothed curve, so the user can see where their actual taps
  landed.
**Covers spec:** MASI.md:L182 ("rendered as a smoothed Catmull-Rom spline (converted to cubic
bézier via Path.cubicTo)"); L276 ("show raw points in Draw mode").
**Test:** (gap — no coverage yet; no spline-fidelity assertions exist in the current intent-test map).

#### US-DRAW3: Nudge a placed point by dragging it
**As a** user who tapped slightly off the rock feature **I want** to drag an already-placed point to
adjust it **so that** I can correct the line without starting the route over.
**Preconditions:** ≥1 point exists in the in-progress route, Draw mode active.
**Main flow:** User drags an existing point handle; its position updates live; the smoothed curve
re-renders through the new position.
**Acceptance criteria (Given/When/Then):**
- Given an existing point, when the user drags its handle, then that point's coordinates update (not
  a new point appended) and the rendered curve reflects the new position.
**Covers spec:** MASI.md:L184 ("Point editing: drag an existing point to nudge it (smoothing
means raw taps rarely land perfectly).").
**Test:** (gap — no coverage yet).

#### US-DRAW4: Undo and redo are scoped to the in-progress route
**As a** user drawing **I want** undo/redo to step through only the points of my current, uncommitted
route **so that** I can correct mistakes without affecting already-committed routes.
**Preconditions:** Draw mode active, ≥1 point placed in the current in-progress route.
**Main flow:**
1. User taps Undo → the most recently placed point of the *current* route is removed.
2. User taps Redo → that point is restored.
3. Once the route is committed (Epic D, US-DRAW6), the undo/redo stack for it is cleared/retired —
   it never reaches back into previously committed routes.
**Acceptance criteria (Given/When/Then):**
- Given N points in the in-progress route, when Undo is tapped, then `currentPoints` has N-1 points.
- When Redo is tapped immediately after an Undo, then `currentPoints` returns to N points, identical
  to before the Undo.
- Given a previously committed route (already in `routes`), then Undo/Redo never mutates that
  committed route's points — only the in-progress (uncommitted) route is affected.
**Covers spec:** MASI.md:L183 ("Undo/redo stack scoped to the in-progress route."); DESIGN.md:
L127 (bottom pill: "undo / redo / commit").
**Test:** canvas_mode_intent_test.dart → A1b (buttons present in Draw mode); undo/redo *stack
semantics* specifically: (gap — no coverage yet).

#### US-DRAW5: Cancel the in-progress route
**As a** user who started drawing but changed my mind **I want** a cancel (✕) action **so that** I can
discard the current, uncommitted route entirely and return to View mode.
**Preconditions:** Draw mode active, ≥0 points placed in the current in-progress route.
**Main flow:** User taps the cancel/✕ action → all points in `currentPoints` are discarded → mode
returns to View → no new route is added to `routes`.
**Acceptance criteria (Given/When/Then):**
- When the user taps cancel with points already placed, then `currentPoints` is cleared and no entry
  is added to `routes`.
- After cancel, `mode == DrawMode.view` and the toolbar cluster is hidden.
**Covers spec:** Implied by the toolbar composition (DESIGN.md:L127 lists undo/redo/commit but not
an explicit cancel glyph) and by the "cluster" concept in the test harness's
`topo-clear-button`/`expectClusterPresent` (four buttons: undo, redo, clear, commit). The exact ✕
semantics (discard vs. "clear points but stay in draw mode") are **not stated verbatim in spec** —
treat `topo-clear-button` as the candidate control pending clarification.
**Test:** (gap — no coverage yet: A1a–A1f test the mode/toolbar/commit lifecycle but do not exercise
the clear/cancel button's discard semantics specifically).

#### US-DRAW6: Commit a route opens the metadata sheet and returns to View
**As a** user who has finished tracing a line **I want** to commit it with a single confirm action
**so that** the route is saved and I'm immediately prompted to name and grade it.
**Preconditions:** Draw mode active, ≥2 points placed in the current in-progress route (a route needs
at least two points to be a line).
**Main flow:**
1. User taps the commit (✓) action.
2. App appends a new entry to `routes` (from the current points), clears `currentPoints`, and sets
   `mode = DrawMode.view`.
3. The draw toolbar cluster hides (per Epic E).
4. `RouteMetadataSheet` opens for the just-committed route.
**Acceptance criteria (Given/When/Then):**
- Given ≥2 points in the in-progress route, when the user taps `topo-commit-button`, then
  `routes.length` increases by exactly 1 and `currentPoints` becomes empty.
- Immediately after commit, `mode == DrawMode.view` and the toolbar cluster (undo/redo/clear/commit)
  is absent.
- Immediately after commit, exactly one `RouteMetadataSheet` widget is present, scoped to the new
  route.
**Covers spec:** MASI.md:L189-191 ("Draw first, fill second... After the line is drawn, a sheet
collects: name, grade..."); L222.
**Test:** canvas_mode_intent_test.dart → A1c.

#### US-DRAW7: Dismissing the metadata sheet leaves the canvas in a clean View state
**As a** user who just committed a route and dismissed (or cancelled) its metadata sheet **I want**
the canvas to settle back into a normal View-mode state **so that** I can immediately continue
browsing or start the next route from a known-good baseline.
**Preconditions:** A route was just committed and its `RouteMetadataSheet` is open.
**Main flow:** User taps the sheet's cancel action (`topo-meta-cancel`) or completes/saves the form.
Sheet dismisses. Canvas remains in View mode with the toolbar cluster absent.
**Acceptance criteria (Given/When/Then):**
- When `topo-meta-cancel` is tapped, then the sheet dismisses, `mode` remains `DrawMode.view`, and the
  toolbar cluster remains absent.
- Given the sheet has been dismissed and the screen is unmounted then re-mounted for the same wall
  (simulating close+reopen), then the fresh mount also starts in View mode with the cluster absent
  (ties to US-MODE4).
**Covers spec:** MASI.md:L189-191; canonicalized further by intent test (BUG-1c).
**Test:** canvas_mode_intent_test.dart → A1d.

---

### Epic E — Editing Toolbar Scoping

A dedicated epic because toolbar mis-scoping was an actual regression class (BUG-1a/b/c/d in the
intent-test comments) — worth testing as its own contract, independent of the mode/draw-flow stories
above.

#### US-TOOLBAR1: The undo/redo/✕/✓ cluster appears only in Draw mode
**As a** user **I want** the editing toolbar (undo, redo, clear, commit) to be visible if and only if
I am in Draw mode **so that** View mode stays visually uncluttered and I never see controls that don't
apply to passive browsing.
**Preconditions:** Canvas mounted for any wall.
**Main flow:** Toggle between View and Draw repeatedly; observe the cluster's presence each time.
**Acceptance criteria (Given/When/Then):**
- Given View mode (fresh mount or after returning to View by any means), then
  `topo-undo-button`/`topo-redo-button`/`topo-clear-button`/`topo-commit-button` all resolve to
  `findsNothing`.
- Given Draw mode, then all four resolve to `findsOneWidget`.
**Covers spec:** DESIGN.md:L127 (toolbar composition); MASI.md:L181 (mode is the single source of
truth for which gesture/UI layer is active).
**Test:** canvas_mode_intent_test.dart → A1a, A1b.

#### US-TOOLBAR2: The cluster disappears immediately after a commit drops back to View
**As a** user who just committed a route **I want** the toolbar cluster to vanish the instant the
canvas returns to View mode **so that** there's no stale/dead-looking editing UI hanging around a
photo I'm now just viewing.
**Preconditions:** Draw mode active with a committable (≥2-point) route.
**Main flow:** Commit the route → mode flips to View as part of the same commit action → cluster
hides in the same frame/rebuild, not on a subsequent user action.
**Acceptance criteria (Given/When/Then):**
- Given a commit action, then in the very next pump after commit, `mode == DrawMode.view` AND the
  cluster is fully absent — there is no intermediate frame where mode is View but the cluster is
  still showing.
**Covers spec:** MASI.md:L189-191; DESIGN.md:L127. Regression tag: BUG-1b.
**Test:** canvas_mode_intent_test.dart → A1c.

#### US-TOOLBAR3: The toolbar cluster never occludes the route list/legend
**As a** user with existing routes visible while I'm drawing a new one **I want** the editing toolbar
to never overlap the route legend **so that** I can still see and interact with my existing routes
while adding a new one.
**Preconditions:** ≥1 committed route exists on the wall; Draw mode is (re-)entered afterward so both
"a route exists" and "Draw mode active" hold simultaneously.
**Main flow:** Commit one route, dismiss its metadata sheet, re-enter Draw mode. Both the toolbar
cluster and the (non-empty) route legend are on screen at once.
**Acceptance criteria (Given/When/Then):**
- Given ≥1 route exists and Draw mode is active, then `topo-route-legend` resolves to
  `findsOneWidget`.
- Given both are on screen, then the bounding rect of the toolbar cluster (union of undo/redo/clear/
  commit button rects) does not overlap the route legend's bounding rect.
**Covers spec:** Not stated verbatim in spec; canonicalized by intent test as a layout-collision
regression guard (BUG-1d).
**Test:** canvas_mode_intent_test.dart → A1e.

---

### Epic F — Route Legend

The spec never names a discrete "legend" widget — MASI.md:L186-187 only specifies the
*capabilities* (toggle on/off, tap-to-select). The stories below define the legend as the concrete UI
surface that satisfies those capabilities, per the `topo-route-legend` key already referenced by the
canvas-mode tests (Epic E) and the dedicated `route_legend_intent_test.dart` suite.

#### US-LEGEND1: The route legend is always fully visible, never clipped
**As a** user with any number of routes on a wall **I want** the legend to always render in full,
uncut by screen edges or other chrome **so that** I can always read every visible route's label.
**Preconditions:** ≥1 route exists on the wall.
**Main flow:** Legend mounts alongside the canvas in both View and Draw mode (its own visibility is
independent of mode — only the *toolbar cluster* is mode-scoped, per Epic E).
**Acceptance criteria (Given/When/Then):**
- Given ≥1 route, then `topo-route-legend` is mounted and its full rendered rect lies within the
  screen's safe-area bounds — no part is clipped by the screen edge or hidden behind other chrome.
**Covers spec:** MASI.md:L186-187 (routes must be inspectable/toggleable at all times); layout
guarantee is otherwise implementation-level, canonicalized by the dedicated legend intent-test suite.
**Test:** route_legend_intent_test.dart → A2a.

#### US-LEGEND2: The legend caps at roughly 40% of screen height
**As a** user with many routes documented on one wall **I want** the legend to stop growing past
about 40% of the screen **so that** it never swallows the photo it's supposed to be annotating.
**Preconditions:** Enough routes exist that an uncapped legend would exceed ~40% of screen height.
**Main flow:** Legend renders up to its max-height constraint; excess content is handled by internal
scrolling (US-LEGEND3), not by growing further.
**Acceptance criteria (Given/When/Then):**
- Given N routes where an unconstrained list would be taller than 0.4× screen height, then the
  legend's rendered height is clamped at ≈0.4× the screen height (within an implementation-defined
  tolerance).
- Given few enough routes that the natural list height is under the cap, then the legend shrinks to
  fit its content (it does not reserve the full 40% empty).
**Covers spec:** Not stated verbatim in either spec file; defined by the dedicated legend intent-test
suite as the concrete cap.
**Test:** route_legend_intent_test.dart → A2b.

#### US-LEGEND3: The legend scrolls internally once it hits its height cap
**As a** user with more routes than fit in the capped legend **I want** to scroll within the legend
**so that** I can still reach every route without the legend pushing the photo off-screen.
**Preconditions:** Route count exceeds what fits in the ~40%-height cap.
**Main flow:** User drags within the legend's bounds; the legend's internal list scrolls; the rest of
the canvas (photo, toolbar) does not move.
**Acceptance criteria (Given/When/Then):**
- Given the legend is at its height cap with overflowing content, when the user drags inside the
  legend, then the legend's internal scroll offset changes while the canvas viewport's transform is
  unaffected.
- All routes are reachable by scrolling — the Nth route's row can be scrolled into view and interacted
  with.
**Covers spec:** Not stated verbatim in spec; defined by the dedicated legend intent-test suite.
**Test:** route_legend_intent_test.dart → A2c.

#### US-LEGEND4: Toggle a route's visibility on/off from the legend
**As a** user comparing overlapping lines on a busy wall **I want** to hide individual routes **so
that** I can isolate the one I'm currently looking at.
**Preconditions:** ≥2 routes exist on the wall.
**Main flow:** User taps a route's visibility toggle in its legend row → that route's line/symbols
stop rendering on the canvas → toggling again restores it.
**Acceptance criteria (Given/When/Then):**
- When a route's toggle is tapped from visible→hidden, then that route's polyline and symbols are no
  longer painted on the canvas, while other routes are unaffected.
- When toggled hidden→visible again, then it re-renders exactly as before.
**Covers spec:** MASI.md:L186-187 ("Toggle individual routes on/off...").
**Test:** route_legend_intent_test.dart → A2d.

#### US-LEGEND5: Tap a legend row to select its route
**As a** user **I want** tapping a route's legend row to select it **so that** I have a reliable,
precision-independent way to select a route besides tapping its thin line on the photo.
**Preconditions:** ≥1 route exists.
**Main flow:** User taps a legend row → that route becomes the selected route (same selection state as
tapping the rendered line, see US-APPEAR3) → its row is visually marked as selected.
**Acceptance criteria (Given/When/Then):**
- When a legend row is tapped, then that route's id becomes the canvas's selected-route id.
- The selected row is visually distinguished (e.g. highlight) from unselected rows.
**Covers spec:** MASI.md:L187 ("tap a rendered route to select it") — extended by the legend as an
alternate, always-reliable selection entry point.
**Test:** route_legend_intent_test.dart → A2e.

#### US-LEGEND6: Delete a route from the legend
**As a** user **I want** to delete a route directly from its legend row **so that** I can remove a
mis-drawn or duplicate route without hunting for it on the photo.
**Preconditions:** ≥1 route exists.
**Main flow:** User taps a delete action on a legend row → confirmation (consistent with the
soft-delete pattern used elsewhere) → route removed from the legend and canvas.
**Acceptance criteria (Given/When/Then):**
- When the user confirms deletion of a route from its legend row, then that route no longer renders on
  the canvas and no longer appears in the legend.
- Other routes on the same wall are unaffected.
**Covers spec:** Not stated verbatim in spec; consistent with the soft-delete convention (MASI.md:
L127-131) applied at the route level. Defined concretely by the legend intent-test suite.
**Test:** route_legend_intent_test.dart → A2f.

#### US-LEGEND7: Each legend row shows the route's grade label and grade-band swatch
**As a** user scanning the legend **I want** each row to show the route's grade and a color swatch
matching its difficulty band **so that** I can gauge a wall's difficulty spread at a glance.
**Preconditions:** ≥1 route with a saved grade exists.
**Main flow:** Legend row renders: color swatch (grade-band color) + route name/number + grade label
(the raw grade as entered, e.g. "6a+").
**Acceptance criteria (Given/When/Then):**
- Given a route with `gradeRaw`/`colorBand` set, then its legend row's swatch color equals that band's
  mapped color (see US-GRADE5's band→color table) and its label text includes the route's `gradeRaw`.
- The swatch color is never the app's amethyst accent color — accent is reserved for interactive
  affordances, not grade information (see US-GRADE7).
**Covers spec:** MASI.md:L186 ("Each route has a grade-band color + a number label."); DESIGN.md:
L137 ("grade colors inform; the accent is spent on intent alone.").
**Test:** route_legend_intent_test.dart → A2g.

---

### Epic G — Route Appearance & Selection

#### US-APPEAR1: Route lines render at a constant on-screen weight regardless of zoom
**As a** user zooming in/out on a wall **I want** route lines to stay a consistent visual thickness on
screen **so that** they read clearly at every zoom level instead of vanishing when zoomed out or
overwhelming the photo when zoomed in.
**Preconditions:** ≥1 route exists; canvas is zoomable (View mode).
**Main flow:** User pinch-zooms the canvas across a range of scales; the route's stroke width in
screen pixels is measured at each scale.
**Acceptance criteria (Given/When/Then):**
- Given a route rendered at zoom scale S1 and again at a different scale S2, then its on-screen
  (device-pixel) stroke width is the same at both scales — the stroke width is divided by the current
  transform scale before painting, not left in scene-space units that would visually scale with zoom.
**Covers spec:** DESIGN.md:L128 ("Route lines render at a constant on-screen weight (fixed)..."); L138
("constant on-screen weight, grade-colored, handles you can grab.").
**Test:** (gap — no coverage yet; not covered by the six mapped intent-test files as scoped).

#### US-APPEAR2: Routes are colored by grade band and numbered
**As a** user looking at a wall with multiple routes **I want** each route colored by its difficulty
band and labeled with a number **so that** I can tell routes apart and gauge relative difficulty
without opening each one's metadata.
**Preconditions:** ≥1 graded, committed route exists.
**Main flow:** Canvas paints each route's polyline in its `colorBand`'s mapped color and renders a
numbered label near it (e.g. at its midpoint or start).
**Acceptance criteria (Given/When/Then):**
- Given a route with `colorBand == advanced`, then its rendered stroke color equals the advanced band
  color (`#E08A2B`, per US-GRADE5).
- Given N committed routes on a wall, then each has a distinct, visible number label.
**Covers spec:** MASI.md:L186 ("Each route has a grade-band color + a number label."); DESIGN.md:
L26-35 (band→hex table).
**Test:** (gap — no coverage yet).

#### US-APPEAR3: Tap a rendered route line to select it (distance-to-polyline hit test)
**As a** user **I want** to tap anywhere near a route's line on the photo to select it **so that** I
can inspect/edit it without needing pixel-perfect precision on a thin curve.
**Preconditions:** ≥1 route exists; canvas in View mode (selection is a view-mode/inspection action).
**Main flow:** User taps near a route's rendered curve. App computes the minimum distance from the tap
point to every route's polyline segments; the closest route within a zoom-scaled threshold becomes
selected.
**Acceptance criteria (Given/When/Then):**
- Given a tap within the hit-test threshold of exactly one route's polyline, then that route becomes
  selected.
- Given a tap between two close-together routes, then the route with the smaller minimum
  tap-to-segment distance is selected.
- Given a tap farther than the threshold from every route, then selection is cleared (no route
  selected) — the threshold itself scales with current zoom, so it represents a roughly constant
  on-screen hit radius regardless of zoom level.
**Covers spec:** MASI.md:L187 ("tap a rendered route to select it (hit-test = min distance from
tap to polyline segments, threshold scaled to current zoom)").
**Test:** (gap — no coverage yet).

#### US-APPEAR4: A selected route renders thicker with visible point handles
**As a** user who has selected a route **I want** clear visual feedback (thicker line + handles) **so
that** I know which route I'm about to edit or delete, and can grab its points.
**Preconditions:** A route is selected (via legend tap, US-LEGEND5, or line tap, US-APPEAR3).
**Main flow:** Canvas re-renders the selected route with an increased stroke width and draggable point
handles at each of its stored points; all other routes render at normal weight, no handles.
**Acceptance criteria (Given/When/Then):**
- Given a route becomes selected, then its rendered stroke width increases relative to unselected
  routes, and a handle renders at each of its points.
- Given the selection changes to a different route (or clears), then the previously selected route
  reverts to normal weight with no handles.
**Covers spec:** DESIGN.md:L128 ("Selected route = thicker + handles shown.").
**Test:** (gap — no coverage yet).

---

### Epic H — Symbols

#### US-SYM1: Place a symbol (anchor/bolt/top/crux/rest) on the photo
**As a** user documenting a route's key features **I want** to place typed symbols on the photo **so
that** other climbers can see where the anchor, bolts, crux, or rest points are.
**Preconditions:** Draw mode active (symbols are placed as part of documenting a route/wall).
**Main flow:**
1. User selects a symbol type from the symbol palette bar (anchor ●, bolt ✕, top △, crux ★, rest ⊙).
2. User taps a location on the photo.
3. A `TopoSymbol {type, x, y}` is created at that location, stored in percent-space (consistent with
   route points, see US-PERSIST2).
**Acceptance criteria (Given/When/Then):**
- Given a symbol type is selected and the user taps the photo, then a symbol of that type is added at
  the tapped location, stored as `{type, x, y}` in percent coordinates (0–1 or 0–100 of image
  dimensions, not raw pixels).
- Given the five symbol types, then each renders with its own distinct glyph (●, ✕, △, ★, ⊙).
**Covers spec:** MASI.md:L148 ("symbols: List<TopoSymbol> → {type, x, y}... Types: anchor ●, bolt
✕, top △, crux ★, rest ⊙."); L185 ("Symbol placement: anchor/bolt/top/crux/rest, positioned in percent
space."); L254.
**Test:** (gap — no coverage yet).

#### US-SYM2: The symbol palette bar is shown only in Draw mode
**As a** user in View mode **I want** the symbol palette hidden **so that** I'm not shown placement
tools I can't currently use (View mode has no gesture path to place anything).
**Preconditions:** Canvas mounted, mode toggled between View and Draw.
**Main flow:** Toggle modes; observe palette bar presence.
**Acceptance criteria (Given/When/Then):**
- Given View mode, then the symbol palette bar is absent.
- Given Draw mode, then the symbol palette bar is present alongside the editing toolbar cluster.
**Covers spec:** Inferred from DESIGN.md:L129 ("Tools (draw mode, symbols) use accent for the active
state.") which groups symbols with draw-mode tools; not an explicit standalone rule in either spec
file.
**Test:** (gap — no coverage yet).

#### US-SYM3: Symbols remain correctly positioned across original and slice photos
**As a** user who slices a panorama after placing symbols **I want** those symbols to still be
correctly positioned on every resulting slice **so that** the anchor/bolt markers stay accurate no
matter which photo variant is being viewed.
**Preconditions:** Symbols placed on a wall's original photo; the photo is later sliced (Epic K).
**Main flow:** Slice tool creates slice Photo rows with `cropXpct`/`cropWidthPct`; symbols (stored in
percent-of-original space, like route points) re-project correctly onto each slice's local coordinate
space.
**Acceptance criteria (Given/When/Then):**
- Given a symbol at original-percent coordinates `(x, y)` and a slice with `cropXpct`/`cropWidthPct`,
  then the symbol's position on that slice is computed by the same percent re-projection formula used
  for route points (US-SLICE2), and renders at the visually corresponding rock feature.
**Covers spec:** MASI.md:L162 (percent-of-original invariant, "the backbone of the app") applied
to symbols by the same percent-space design (L148, L185).
**Test:** (gap — no coverage yet).

---

### Epic I — Metadata & Grades

#### US-GRADE1: Fill in name, grade, style, and description after drawing
**As a** user who just committed a route **I want** a metadata sheet to collect its name, grade,
climbing style, and an optional description **so that** the route is fully documented right after
drawing it, without interrupting the drawing flow itself.
**Preconditions:** A route was just committed (US-DRAW6); `RouteMetadataSheet` is open.
**Main flow:**
1. Sheet shows fields: Name (text), Grade (with a French|UIAA system picker), Style
   (sport|trad|boulder), Description (optional text).
2. User fills in at least a name and a grade.
3. User saves → route record updates with the entered metadata plus computed `gradeSortKey` and
   `colorBand`.
**Acceptance criteria (Given/When/Then):**
- Given the sheet is open, then Name, Grade (with system picker), Style, and Description fields are
  all present.
- When the user saves with a valid name and grade, then the route's `name`, `gradeRaw`,
  `gradeSystem`, `style`, and `description` (if provided) persist, and `gradeSortKey` + `colorBand`
  are computed and persisted alongside them.
**Covers spec:** MASI.md:L189-191 ("a sheet collects: name, grade (with grade-system picker:
French | UIAA), style, description. Grade entry validates against the chosen system's ladder and
computes gradeSortKey + colorBand.").
**Test:** route_metadata_intent_test.dart → A5a.

#### US-GRADE2: Choose a grade system — exactly French or UIAA
**As a** user entering a grade **I want** to pick between French and UIAA systems **so that** I can
grade in whichever convention I actually climb with, while the app still normalizes difficulty for
sorting/coloring.
**Preconditions:** Metadata sheet is open.
**Main flow:** User taps a segmented control offering exactly two options: French, UIAA. Selecting one
changes which ladder subsequent grade-value entry validates against.
**Acceptance criteria (Given/When/Then):**
- Given the grade-system control, then it offers exactly two options — French and UIAA — no more, no
  fewer (v1 explicitly excludes YDS/V-scale/Font; those are v2-only per the scope table).
- When the user switches systems, then the grade-value input/picker is re-validated against the newly
  selected system's ladder.
**Covers spec:** MASI.md:L27 (scope table: v1 = French + UIAA only); L189-191; L200-206 (ladder
tables); DESIGN.md:L123 ("segmented control... for grade system (French / UIAA).").
**Test:** route_metadata_intent_test.dart → A5b.

#### US-GRADE3: Grade entry validates against the chosen system's ladder
**As a** user typing/selecting a grade **I want** invalid tokens rejected **so that** every stored
grade is a real, sortable value in its system rather than free-text garbage.
**Preconditions:** A grade system is selected.
**Main flow:** User enters a grade token (e.g. "6a+" for French, "VI-" for UIAA). App looks it up in
that system's ladder table. Valid tokens map to a canonical numeric `gradeSortKey`; invalid tokens are
rejected (save disabled, or inline error shown).
**Acceptance criteria (Given/When/Then):**
- Given French is selected and the user enters a value present in the French ladder (e.g. "6a+"),
  then it's accepted and mapped to its canonical `gradeSortKey`.
- Given UIAA is selected and the user enters a value present in the UIAA ladder (e.g. "VI-"), then
  it's accepted and mapped to its canonical `gradeSortKey`.
- Given a value not present in the currently selected system's ladder, then save is blocked / an
  error is shown — no route is persisted with an unrecognized grade token.
**Covers spec:** MASI.md:L200-206 ("table-driven service in core/grades; ladders for French...
and UIAA... each mapping token→canonical numeric sortKey."); L189-191.
**Test:** route_metadata_intent_test.dart → A5c.

#### US-GRADE4: The user's original grade entry is always preserved verbatim
**As a** user who graded a route in French **I want** the app to remember that I entered "6a+" in
French specifically **so that** my exact intent is never lossily converted or displayed in a
different system than I chose.
**Preconditions:** A route is saved with a grade.
**Main flow:** On save, both `gradeRaw` (the literal entered token, e.g. "6a+") and `gradeSystem`
(e.g. "french") are persisted verbatim, alongside the derived `gradeSortKey`.
**Acceptance criteria (Given/When/Then):**
- Given a route saved with system=French, raw="6a+", then re-loading that route shows "6a+" under
  French — never silently re-rendered as a UIAA-equivalent token.
- `gradeSortKey` is a derived/normalized field used only for ordering and color-banding; it never
  overwrites or is displayed in place of `gradeRaw`.
**Covers spec:** MASI.md:L149 ("gradeRaw + gradeSystem preserve exactly what the user entered.").
**Test:** route_metadata_intent_test.dart → A5d.

#### US-GRADE5: Difficulty is mapped to one of five color bands
**As a** user scanning a wall **I want** each route's difficulty visually banded by color **so that**
I can gauge a wall's difficulty spread at a glance, consistently across the whole app.
**Preconditions:** A route has a valid, ladder-validated grade.
**Main flow:** `gradeSortKey` is mapped to exactly one of five bands based on French-equivalent
difficulty ranges:

| Band | French range | Color | Hex |
|---|---|---|---|
| Beginner | ≤ 4 | green | `#2F9E6B` |
| Intermediate | 5 – 6a | blue | `#3B82C4` |
| Advanced | 6a+ – 6c+ | orange | `#E08A2B` |
| Hard | 7a – 7c+ | red | `#D6483B` |
| Elite | ≥ 8a | purple | `#8A5CD1` |

**Acceptance criteria (Given/When/Then):**
- Given a route with French-equivalent grade ≤4, then `colorBand == beginner` and its mapped color is
  `#2F9E6B`.
- Given a grade in 5–6a, then `colorBand == intermediate` / `#3B82C4`.
- Given a grade in 6a+–6c+, then `colorBand == advanced` / `#E08A2B`.
- Given a grade in 7a–7c+, then `colorBand == hard` / `#D6483B`.
- Given a grade ≥8a, then `colorBand == elite` / `#8A5CD1`.
- A UIAA-graded route maps to the same five bands via its ladder's normalized `gradeSortKey` — band
  boundaries are defined once, on the normalized scale, not duplicated per system.
**Covers spec:** MASI.md:L208-216 (band→color table); DESIGN.md:L26-35 (band hex values +
French ranges, "map to the existing grade-band logic in core/grades").
**Test:** route_metadata_intent_test.dart → A5e.

#### US-GRADE6: Boulder-style routes may be graded or left ungraded
**As a** user documenting a boulder problem **I want** to tag it as boulder style and optionally skip
grading **so that** I'm not forced to assign a route-grade convention to a problem I haven't graded
yet.
**Preconditions:** Metadata sheet open, style = boulder selected.
**Main flow:** User selects Style = boulder. Grade field remains optional for this style (French/UIAA
still usable if the user has a grade in mind) — save succeeds with or without a grade for boulder
style.
**Acceptance criteria (Given/When/Then):**
- Given style = boulder and no grade entered, then save succeeds and the route persists with
  `gradeRaw == null` (or equivalent ungraded sentinel).
- Given style = sport or trad, then a valid grade is required to save (per US-GRADE3's ladder
  validation) — boulder is the only style where grading is optional.
**Covers spec:** MASI.md:L206 ("boulder-style routes tagged style=boulder, graded in French/UIAA
or left ungraded.").
**Test:** route_metadata_intent_test.dart → A5a (folded into the general metadata-save assertion; no
boulder-specific sub-case currently isolated) — (gap — boulder-specific optionality not isolated yet).

#### US-GRADE7: Grade-band colors are semantic and never reused as the app's accent
**As a** user **I want** the app's single amethyst accent color to always mean "you can interact with
this" and never to double as a difficulty indicator **so that** color always has one unambiguous
meaning throughout the app.
**Preconditions:** Any screen showing both interactive controls and grade-banded content
simultaneously (e.g. the canvas with routes + an accent-colored FAB/toggle).
**Main flow:** Visual audit: grade-band colors (green/blue/orange/red/purple) appear only on
routes/legend swatches/grade pills; the amethyst accent (`#6E56C6` light / `#B7A2F0` dark) appears
only on buttons, links, the active tool, and the FAB.
**Acceptance criteria (Given/When/Then):**
- Given any of the five grade-band colors, then none of them equals the accent token's hex value in
  either light or dark theme.
- Given an interactive control (button, active-tool state, FAB), then its color is drawn from the
  `accent` token, never from a grade-band color.
**Covers spec:** DESIGN.md:L137 ("Amethyst is only for action... grade colors inform; the accent is
spent on intent alone."); DESIGN.md:L23, L26 ("NEVER used as the accent").
**Test:** route_metadata_intent_test.dart → A5e (color-table assertion doubles as the accent-
disjointness check); a dedicated cross-screen "no accent reuse" audit is (gap — no coverage yet).

---

### Epic J — Photo Ingestion

#### US-PHOTO1: Pick a photo from the native library
**As a** user **I want** to choose an existing photo from my device's library **so that** I can
document a wall from a photo I already took.
**Preconditions:** Photo-source action sheet is open (from Home's "New topo" or canvas "replace
photo").
**Main flow:** User taps "Choose from library" → `image_picker` opens the native library picker
(`ImageSource.gallery`) → user picks a photo → app receives the file.
**Acceptance criteria (Given/When/Then):**
- When "Choose from library" is tapped, then `ImageSource.gallery` is requested via `image_picker` —
  no custom in-app gallery UI is built.
- On a successful pick, the returned image becomes the new/replacement Photo (kind=original) for the
  target wall.
**Covers spec:** MASI.md:L168-172 ("Pick photo or panorama from native library via image_picker
(no in-app camera)."); L73; DESIGN.md:L114-120.
**Test:** (gap — no coverage yet against the six mapped intent-test files; existing
photo_source_sheet_test.dart exercises the sheet itself but is outside the given id map).

#### US-PHOTO2: Take a new photo with the native camera
**As a** user at the crag **I want** to snap a photo directly **so that** I can document a wall on the
spot without first saving to my library.
**Preconditions:** Photo-source action sheet is open.
**Main flow:** User taps "Take photo" → OS native camera opens (`ImageSource.camera`, not a custom
in-app camera) → user captures → app receives the file.
**Acceptance criteria (Given/When/Then):**
- When "Take photo" is tapped, then `ImageSource.camera` is requested — the app never renders its own
  camera preview/capture UI.
- On successful capture, the returned image becomes the new/replacement Photo for the target wall.
**Covers spec:** MASI.md:L168-172; L233 ("in-app camera or panorama stitching" is explicitly
"deferred indefinitely / not planned" — reinforcing that the native camera, not a custom one, is the
only capture path, now and in the future).
**Test:** (gap — no coverage yet).

#### US-PHOTO3: EXIF orientation is normalized on import
**As a** user importing a photo taken in any phone orientation **I want** the app to bake the correct
rotation into the stored pixels **so that** the photo always displays right-side-up and all downstream
coordinate math never has to special-case orientation flags.
**Preconditions:** A photo with a non-identity EXIF orientation tag is picked/captured.
**Main flow:** On import, the app reads the EXIF orientation, rotates/flips the pixel data to match,
and strips/normalizes the orientation tag before storing.
**Acceptance criteria (Given/When/Then):**
- Given a source image with EXIF orientation ≠ 1 (e.g. rotated 90°), then the stored image's pixel
  data is already correctly oriented — displaying it with no orientation flag produces the correct
  visual result.
- All subsequent percent-space coordinate math (route points, symbols, slice crops) operates against
  this normalized image, never needing to consult an orientation flag.
**Covers spec:** MASI.md:L170 ("Normalize EXIF orientation on import (bake rotation into pixels)
so coordinate math never has to reason about orientation flags.").
**Test:** (gap — no coverage yet).

#### US-PHOTO4: Replace an existing topo's photo
**As a** user who took a better photo of a wall I already documented **I want** to replace its photo
**so that** existing routes remain attached to the (better) new image without recreating the wall.
**Preconditions:** A wall with an existing original Photo and ≥1 route exists.
**Main flow:** User opens the canvas for that wall, triggers "replace photo" (reuses the same
photo-source action sheet as Home's New topo flow), picks/captures a new image, which replaces the
wall's original Photo record. Existing routes (stored in percent-space, US-PERSIST2) render against
the new image using the same percent coordinates.
**Acceptance criteria (Given/When/Then):**
- When "replace photo" is triggered from the canvas, then the same `CupertinoActionSheet` (Take
  photo / Choose from library / Cancel) opens as on Home.
- On successful replacement, the wall's original Photo is updated (not duplicated), and existing
  routes still render at their stored percent coordinates against the new image.
**Covers spec:** DESIGN.md:L120 ("Reuse from both the Topos-home 'New topo' flow and the canvas
'replace photo'.") — this flow is **not mentioned in MASI.md at all**, only in DESIGN.md.
**Test:** (gap — no coverage yet).

---

### Epic K — Slice Tool

#### US-SLICE1: Slice a panorama with vertical cut lines
**As a** user who photographed a wide wall as one panorama **I want** to drag vertical cut lines onto
it **so that** the wall is split into separate, individually-viewable segments (slices) I can draw
routes on more precisely.
**Preconditions:** A wall's original Photo is a wide panorama.
**Main flow:**
1. User opens the slice tool on the original photo.
2. User drags one or more vertical cut lines across the image.
3. App splits the image into segments; each becomes a new Photo row with `kind: 'slice'`,
   `parentPhotoId` pointing at the original, and `cropXpct`/`cropWidthPct` describing its crop window
   within the parent.
**Acceptance criteria (Given/When/Then):**
- Given N cut lines placed, then exactly N+1 slice Photo rows are created, each with `kind == 'slice'`
  and `parentPhotoId` equal to the original's id.
- Given the slices' `cropXpct`/`cropWidthPct` values, then they are contiguous and together span
  `[0, 1]` (or `[0, 100]`) of the original's width with no gaps or overlaps.
**Covers spec:** MASI.md:L174-177 ("User drags vertical cut lines on the panorama... each slice
stored as a Photo with parentPhotoId + cropXpct/cropWidthPct."); L142-145 (Photo entity fields);
L260.
**Test:** slice_tool_intent_test.dart → A4a.

#### US-SLICE2: Routes drawn on the original remain valid on every slice, and vice versa
**As a** user **I want** a route I drew on the full panorama to still render correctly if I later view
one of its slices (and a route I draw on a slice to render correctly on the original) **so that**
slicing is purely a viewing/editing convenience, never a data-migration event.
**Preconditions:** A wall has an original Photo, ≥1 slice, and ≥1 route with points stored as
percent-of-original.
**Main flow:** App re-projects a route's percent-of-original points onto a slice's local percent-space
using that slice's `cropXpct`/`cropWidthPct`: `slice_x = (orig_x - cropXpct) / cropWidthPct` (and the
inverse when drawing on a slice and storing back against the original).
**Acceptance criteria (Given/When/Then):**
- Given a route point at original-percent `x`, and a slice with `cropXpct = c`, `cropWidthPct = w`,
  then that point's position within the slice's own percent-space is `(x - c) / w`, and it renders at
  the visually correct location on the slice's cropped image.
- Given a point placed while viewing a slice, then it is stored back as a percent-of-original value
  (`c + local_x * w`) so it also renders correctly on the original and on any *other* slice.
**Covers spec:** MASI.md:L162 ("Storing percentages of the original means a route drawn on a full
panorama renders correctly on any slice... This invariant is the backbone of the app and is covered by
unit tests."); L177 ("Routes can be drawn on either; coordinates stay valid across both.").
**Test:** slice_tool_intent_test.dart → A4b.

#### US-SLICE3: A tap on a slice maps to the correct cut, relative to the image rect, not the widget rect
**As a** user tapping to place a cut line **I want** the tap-to-cut-position mapping to be relative to
where the image is actually drawn (its `imageRect`), not the full widget bounds **so that** cuts land
exactly where I tapped even when the image is letterboxed within a wider/taller widget.
**Preconditions:** The panorama's aspect ratio differs from the slice-tool widget's aspect ratio,
producing letterboxing (empty space) on one axis.
**Main flow:** User taps within the letterboxed widget. App computes the tap's position relative to
the actual rendered `imageRect` (excluding letterbox padding), then converts to percent-of-image before
storing as a cut position.
**Acceptance criteria (Given/When/Then):**
- Given a widget wider than the image's fitted aspect ratio (horizontal letterboxing), when the user
  taps at a widget-space point, then the resulting cut's `cropXpct` corresponds to that point's
  position *within the image's fitted rect*, correctly excluding the letterbox margins on the left/
  right.
- Given a tap that lands within the letterbox margin itself (outside the image rect), then it is
  clamped to the nearest image edge (0% or 100%), never producing an out-of-range or negative
  `cropXpct`.
**Covers spec:** MASI.md:L154-162 (general percent/scene/screen coordinate system) is the closest
spec grounding; the specific letterbox-correctness guarantee is **not spelled out verbatim** in either
file and is defined concretely by the dedicated slice-tool intent test.
**Test:** slice_tool_intent_test.dart → A4c.

#### US-SLICE4: Slice-tap mapping is also correct for tall (portrait) photos
**As a** user slicing a tall panorama (e.g. a very tall single-pitch face photographed in portrait)
**I want** the same imageRect-relative correctness on the vertical axis **so that** slicing tall photos
is exactly as accurate as slicing wide ones.
**Preconditions:** A tall/portrait-oriented photo is loaded into the slice tool, producing vertical
letterboxing (top/bottom margins) within the tool's widget.
**Main flow:** Same as US-SLICE3, mirrored for the vertical axis and for how it interacts with the
(inherently horizontal) vertical cut lines — i.e. verifying the *image rect's* full bounds (both axes)
are used to compute the fitted image area before mapping any tap.
**Acceptance criteria (Given/When/Then):**
- Given a tall photo with vertical letterboxing in the slice-tool widget, when the user drags a
  vertical cut line, then its horizontal (`cropXpct`) position is computed against the image's fitted
  width, unaffected by the vertical letterbox margins.
- The resulting slice Photo rows' `cropXpct`/`cropWidthPct` are identical to what they would be if the
  same photo were displayed without any letterboxing (e.g. in a perfectly matching widget) — letterbox
  margins never skew the crop math.
**Covers spec:** Same grounding as US-SLICE3 (MASI.md:L154-162, backbone invariant L162); tall-
photo correctness specifically is **not stated verbatim in spec**, defined by the intent test.
**Test:** slice_tool_intent_test.dart → A4d.

#### US-SLICE5: Slices and the original stay linked under the same Wall
**As a** user browsing a wall with slices **I want** the original panorama and every slice to remain
associated with the same Wall record **so that** switching between viewing the whole panorama and an
individual slice is just a photo selection, not a different wall.
**Preconditions:** A wall has been sliced (US-SLICE1).
**Main flow:** All Photo rows (original + slices) share the same `wallId`; a photo-picker/segment
selector on the canvas lets the user switch which Photo is currently displayed for that wall.
**Acceptance criteria (Given/When/Then):**
- Given a wall with an original and N slices, then all N+1 Photo rows share the same `wallId`.
- Switching the displayed photo between the original and any slice does not change which wall's data
  (routes, symbols) is in scope — only which image variant they're drawn against.
**Covers spec:** MASI.md:L177 ("Original + slices linked under the same Wall.").
**Test:** slice_tool_intent_test.dart → A4a (folded into slice-creation assertion; no isolated
wall-linkage assertion exists) — (gap — cross-photo wall-linkage not isolated).

---

### Epic L — Canvas Viewport Presentation

#### US-VIEW1: The photo's edges feather into the backdrop, panning/zooming with the photo
**As a** user opening and panning/zooming a wall's canvas **I want** the photo's own edges to feather
softly into the canvas backdrop instead of stopping at a hard bordered panel, and that feather to move
with the photo as I pan/zoom **so that** the rock reads as filling a continuous surface, not a photo
pasted inside a static picture frame.
**Preconditions:** Canvas opens for a wall with a loaded photo.
**Main flow:** The photo (`Image.file`, `BoxFit.contain` sized to `imageSize`) is stacked inside
`InteractiveViewer`'s transformed content alongside a four-strip edge vignette
(`topo-canvas-edge-vignette`) that fades each of the photo's own edges from opaque `kCanvasBackdrop` to
transparent. The fixed viewport panel (`topo-canvas-viewport-frame`) behind it is a flat, rounded
`kCanvasBackdrop` backing with no border, shadow, or gradient of its own — the fade belongs to the
photo's content space, not the screen-space frame, so it pans and zooms together with the image.
**Acceptance criteria (Given/When/Then):**
- Given a freshly opened canvas, then `topo-canvas-viewport-frame`'s `BoxDecoration` has
  `MasiRadii.large` rounded corners and no `border`, `boxShadow`, or `gradient` of its own.
- The edge-fade vignette exists, is a descendant of `topo-interactive-viewer` (the photo's transformed
  content, not the fixed frame), is wrapped in an actively-ignoring `IgnorePointer`, and is built from
  four `kCanvasBackdrop` → `Colors.transparent` gradient strips, one per edge.
- Given the user pans/zooms the photo, then the vignette's on-screen rect moves/scales consistent with
  the applied transform — it tracks the photo rather than staying pinned to the viewport.
**Covers spec:** DESIGN.md:L126 ("Its own edges softly feather to `kCanvasBackdrop`... lives inside
`InteractiveViewer`'s transformed content... pans and zooms together with the photo.").
**Test:** canvas_viewport_intent_test.dart → A3a (rewritten), V1, V2.

#### US-VIEW2: The viewport re-fits when layout settles
**As a** user **I want** the canvas to correct its fit if the available layout size changes after
first paint (e.g. safe-area insets resolving, orientation change, keyboard dismiss) **so that** the
photo is never left mis-fit from a stale initial measurement.
**Preconditions:** Canvas is mounted; a layout-affecting event occurs after first paint.
**Main flow:** A `LayoutBuilder`/`didChangeMetrics`-style callback detects the new available size and
recomputes the fit transform, re-applying it so the image is again edge-to-edge and centered.
**Acceptance criteria (Given/When/Then):**
- Given the viewport's available size changes after first paint, then the fit transform recomputes
  and the image remains edge-to-edge/centered under the new size — it does not stay pinned to the
  stale first-paint fit.
**Covers spec:** DESIGN.md:L135 ("re-fitting when layout settles").
**Test:** canvas_viewport_intent_test.dart → A3b.

#### US-VIEW3: The viewport does not jump when slice/symbol bars appear or disappear
**As a** user toggling auxiliary bars (slice tool, symbol palette) while working on a wall **I want**
the photo's position/scale to remain visually stable **so that** I don't lose my place or get
disoriented every time a tool bar shows or hides.
**Preconditions:** Canvas is mounted with the photo fitted; user toggles a bar (e.g. enters Draw mode,
revealing the symbol palette — Epic H — or opens the slice tool).
**Main flow:** The bar's appearance/disappearance changes the height available to the photo viewport;
the fit/transform logic must absorb this without producing a visible jump/snap in the photo's
position or scale.
**Acceptance criteria (Given/When/Then):**
- Given the photo is fitted and centered, when a bar (slice tool, symbol palette) appears or
  disappears, then the visual change in the photo's on-screen position/scale between consecutive
  frames stays within an implementation-defined small tolerance — no abrupt re-center/re-scale "jump."
**Covers spec:** DESIGN.md:L126, L135 (re-fit/stability principles) applied specifically to bar
show/hide transitions — this exact trigger (bars appearing/disappearing) is **not named verbatim** in
either spec file; it is the concrete regression this story guards against.
**Test:** canvas_viewport_intent_test.dart → A3c.

#### US-VIEW4: Chrome is a floating panel in screen space, unaffected by zoom/pan
**As a** user panning/zooming the photo **I want** the toolbar chrome (nav bar, editing cluster,
legend, symbol palette) to stay fixed in screen space, styled as a floating panel over the photo **so
that** UI controls never scale, rotate, or drift away as I manipulate the image beneath them.
**Preconditions:** Canvas mounted; user pans/zooms.
**Main flow:** Chrome widgets render outside the `InteractiveViewer`'s transformed subtree (i.e. as
screen-space overlays), styled per DESIGN.md's floating-panel tokens: large corner radius, soft purple
ambient shadow, hairline separator edge, translucent blurred background.
**Acceptance criteria (Given/When/Then):**
- Given the user pans/zooms the photo, then chrome widgets' screen-space rects are unchanged — they
  are not children of the zoom/pan transform.
- Chrome panels render with the large-card radius token (20, per DESIGN.md's radius scale), a soft
  shadow (`0 1px 2px rgba(38,26,72,.06), 0 8px 24px rgba(38,26,72,.08)` light-theme values), a
  hairline `separator`-token edge, and a backdrop blur over the photo rather than an opaque fill.
**Covers spec:** DESIGN.md:L127 ("Chrome floats on translucent glass over the photo... Blur the photo
behind the glass; don't cover it with opaque bars."); L136 ("Chrome floats, content is king."); L90-91
(radius/shadow/blur tokens).
**Test:** canvas_viewport_intent_test.dart → A3d.

---

### Epic M — Persistence / Offline

#### US-PERSIST1: The app is fully functional with zero connectivity
**As a** climber at the crag with no signal **I want** every core flow (create topo, draw routes,
enter metadata, slice photos, manage library) to work fully offline **so that** connectivity is never
a blocker to documenting a route.
**Preconditions:** Device networking is disabled.
**Main flow:** User performs the full contribution flow (Home → New topo → draw → metadata → done)
and all library CRUD flows with networking off throughout.
**Acceptance criteria (Given/When/Then):**
- Given networking is off, then creating a topo, drawing a route, saving its metadata, and all
  Area/Sector/Wall CRUD operations succeed exactly as they would online.
- No flow in this document blocks on or silently fails due to a network check.
**Covers spec:** MASI.md:L193-196 ("Full offline support via Drift... App is fully functional
with zero connectivity."); L223 ("Offline-first — assume no signal at the crag.").
**Test:** (gap — no coverage yet against the six mapped intent-test files; this is best exercised as
an integration_test flow per the project's verification loop, not a widget-test file).

#### US-PERSIST2: Routes are stored as percentages of the original photo, never pixels
**As a** developer/tester verifying data integrity **I want** every stored coordinate (route points,
symbols) to be a percentage of the original image dimensions **so that** the same data renders
correctly regardless of photo resolution, zoom, screen size, or which slice is being viewed.
**Preconditions:** A route/symbol has been placed on any photo variant (original or slice).
**Main flow:** All coordinate writes to Drift store `x`/`y` as percentages (0–1 or 0–100) of the
*original* photo's dimensions, computed via the percent/scene/screen coordinate system, regardless of
which photo variant was being viewed when the point was placed.
**Acceptance criteria (Given/When/Then):**
- Given a point placed while viewing any photo variant, then its persisted `x`/`y` are percentages of
  the *original* photo's dimensions, never raw pixel values and never percentages of a slice's
  cropped dimensions.
- Given the same persisted point, then it renders at the correct location on the original, on every
  slice (via US-SLICE2's re-projection), and at any zoom/screen size.
**Covers spec:** MASI.md:L225 ("Percentage-based coordinates always — never persist pixels.");
L162 ("This invariant is the backbone of the app and is covered by unit tests.").
**Test:** slice_tool_intent_test.dart → A4b (shared with US-SLICE2, since it's the same underlying
invariant).

#### US-PERSIST3: Routes reload at the correct position after a kill-and-relaunch
**As a** user **I want** my drawn routes to still be exactly where I left them after fully closing and
reopening the app **so that** my work is durably saved, not just held in memory.
**Preconditions:** A route has been drawn and its metadata saved (French or UIAA) on a wall that has
both an original photo and at least one slice.
**Main flow:**
1. User documents a route (draw → metadata → save) on the original photo.
2. App is killed and relaunched with networking off.
3. User navigates back to the same wall's canvas, viewing the original — route renders at the correct
   position.
4. User switches to viewing a slice — the same route renders at the correct re-projected position on
   the slice too.
**Acceptance criteria (Given/When/Then):**
- Given a route saved before a kill+relaunch, then after relaunch (networking off) it reloads from
  Drift and renders at the same visual position on the original photo as before the relaunch.
- Given the same relaunch, then the route also renders at the correct re-projected position when the
  user views a slice of that same wall.
**Covers spec:** MASI.md:L292 ("...fill metadata (French + UIAA) → kill & relaunch app with
networking off → routes reload from Drift at correct positions on both the original and a slice.").
**Test:** (gap — no coverage yet against the six mapped widget-test files; this is explicitly an
integration_test-shaped verification per MASI.md:L292 and the project's kill/relaunch
verification loop, not a pure widget test).

---

### Epic N — Navigation / Chrome

#### US-NAV1: The canvas nav title shows the wall/topo's name, never the app name
**As a** user with multiple walls open across sessions **I want** the canvas's nav title to show the
specific wall/topo's name **so that** I always know which wall I'm looking at, especially when
switching between several.
**Preconditions:** Canvas is open for a named wall.
**Main flow:** Nav bar renders a large title below a slim bar; the title text is the wall's (topo's)
name, sourced from the Wall record — never the literal string "Masi" or "masi".
**Acceptance criteria (Given/When/Then):**
- Given a wall named "The Diamond", when its canvas opens, then the nav title text is "The Diamond" —
  not "Masi", "masi", or any other app-level constant.
- Given a wall name long enough to risk overflow, then the title text uses `overflow: ellipsis` and is
  wrapped in a `Flexible`, so it truncates gracefully instead of overflowing the row when trailing
  icons (draw/slice/AR glyphs) are present.
**Covers spec:** DESIGN.md:L98-99 ("Title text must overflow: ellipsis and be Flexible so it never
overflows when trailing icons appear (fixes the 'Climb…' truncation — but more importantly the canvas
title should be the topo/wall name, not 'Masi').").
**Test:** library_ui_intent_test.dart → A6f.

#### US-NAV2: The amethyst accent is reserved for actionable elements
**As a** user **I want** the app's one saturated accent color to consistently mean "this is
interactive" **so that** I can visually scan any screen and immediately know what I can tap.
**Preconditions:** Any screen with both navigation chrome and non-interactive content.
**Main flow:** Back chevron + previous-screen title render in `accent`; trailing nav actions render as
`accent` text/glyphs, never as a filled button in the bar; active-tool states use `accent`.
**Acceptance criteria (Given/When/Then):**
- Given the nav bar's back action, then it renders in the `accent` token color (chevron + previous
  title).
- Given trailing nav actions, then they render as `accent`-colored text/glyphs, never as an opaque
  filled button sitting in the bar.
- Given an active tool (e.g. the currently selected symbol type, or Draw mode's active indicator),
  then it is colored with `accent`, and this is visually and programmatically distinct from any
  grade-band color (US-GRADE7).
**Covers spec:** DESIGN.md:L98 ("Back = chevron + previous title in accent. Trailing actions are
accent text or accent glyphs, never a filled button in the bar."); L23 (`accent` = "action only");
L129 ("Tools (draw mode, symbols) use accent for the active state.").
**Test:** library_ui_intent_test.dart → A6f (nav-chrome coverage shared with US-NAV1's title
assertion); the tool-active-state half of this story is (gap — no coverage yet).

---

## 3. Traceability Matrix

| Story | Covering assertion(s) | Status |
|---|---|---|
| US-HOME1 | library_ui_intent_test.dart A6d | — |
| US-HOME2 | library_ui_intent_test.dart A6d | — |
| US-HOME3 | library_ui_intent_test.dart A6d | — |
| US-HOME4 | library_ui_intent_test.dart A6e | — |
| US-HOME5 | library_ui_intent_test.dart A6d | — |
| US-HOME6 | canvas_mode_intent_test.dart A1a | — |
| US-LIB1 | library_ui_intent_test.dart A6a | — |
| US-LIB2 | library_ui_intent_test.dart A6a | — |
| US-LIB3 | library_ui_intent_test.dart A6a | — |
| US-LIB4 | library_ui_intent_test.dart A6b | — |
| US-LIB5 | library_ui_intent_test.dart A6b | — |
| US-LIB6 | library_ui_intent_test.dart A6c | — |
| US-LIB7 | library_ui_intent_test.dart A6c | — |
| US-LIB8 | library_ui_intent_test.dart A6b, A6c | — |
| US-MODE1 | canvas_mode_intent_test.dart A1b, A1f | — |
| US-MODE2 | canvas_mode_intent_test.dart A1f | — |
| US-MODE3 | canvas_mode_intent_test.dart A1f | — |
| US-MODE4 | canvas_mode_intent_test.dart A1a, A1d | — |
| US-MODE5 | canvas_mode_intent_test.dart A1a | — |
| US-DRAW1 | (gap — no coverage yet) | — |
| US-DRAW2 | (gap — no coverage yet) | — |
| US-DRAW3 | (gap — no coverage yet) | — |
| US-DRAW4 | canvas_mode_intent_test.dart A1b (partial; stack semantics gap) | — |
| US-DRAW5 | (gap — no coverage yet) | — |
| US-DRAW6 | canvas_mode_intent_test.dart A1c | — |
| US-DRAW7 | canvas_mode_intent_test.dart A1d | — |
| US-TOOLBAR1 | canvas_mode_intent_test.dart A1a, A1b | — |
| US-TOOLBAR2 | canvas_mode_intent_test.dart A1c | — |
| US-TOOLBAR3 | canvas_mode_intent_test.dart A1e | — |
| US-LEGEND1 | route_legend_intent_test.dart A2a | — |
| US-LEGEND2 | route_legend_intent_test.dart A2b | — |
| US-LEGEND3 | route_legend_intent_test.dart A2c | — |
| US-LEGEND4 | route_legend_intent_test.dart A2d | — |
| US-LEGEND5 | route_legend_intent_test.dart A2e | — |
| US-LEGEND6 | route_legend_intent_test.dart A2f | — |
| US-LEGEND7 | route_legend_intent_test.dart A2g | — |
| US-APPEAR1 | (gap — no coverage yet) | — |
| US-APPEAR2 | (gap — no coverage yet) | — |
| US-APPEAR3 | (gap — no coverage yet) | — |
| US-APPEAR4 | (gap — no coverage yet) | — |
| US-SYM1 | (gap — no coverage yet) | — |
| US-SYM2 | (gap — no coverage yet) | — |
| US-SYM3 | (gap — no coverage yet) | — |
| US-GRADE1 | route_metadata_intent_test.dart A5a | — |
| US-GRADE2 | route_metadata_intent_test.dart A5b | — |
| US-GRADE3 | route_metadata_intent_test.dart A5c | — |
| US-GRADE4 | route_metadata_intent_test.dart A5d | — |
| US-GRADE5 | route_metadata_intent_test.dart A5e | — |
| US-GRADE6 | route_metadata_intent_test.dart A5a (partial; boulder case gap) | — |
| US-GRADE7 | route_metadata_intent_test.dart A5e (partial; cross-screen audit gap) | — |
| US-PHOTO1 | (gap — no coverage yet) | — |
| US-PHOTO2 | (gap — no coverage yet) | — |
| US-PHOTO3 | (gap — no coverage yet) | — |
| US-PHOTO4 | (gap — no coverage yet) | — |
| US-SLICE1 | slice_tool_intent_test.dart A4a | — |
| US-SLICE2 | slice_tool_intent_test.dart A4b | — |
| US-SLICE3 | slice_tool_intent_test.dart A4c | — |
| US-SLICE4 | slice_tool_intent_test.dart A4d | — |
| US-SLICE5 | slice_tool_intent_test.dart A4a (partial; linkage gap) | — |
| US-VIEW1 | canvas_viewport_intent_test.dart A3a (rewritten), V1, V2 | — |
| US-VIEW2 | canvas_viewport_intent_test.dart A3b | — |
| US-VIEW3 | canvas_viewport_intent_test.dart A3c | — |
| US-VIEW4 | canvas_viewport_intent_test.dart A3d | — |
| US-PERSIST1 | (gap — no coverage yet) | — |
| US-PERSIST2 | slice_tool_intent_test.dart A4b | — |
| US-PERSIST3 | (gap — no coverage yet) | — |
| US-NAV1 | library_ui_intent_test.dart A6f | — |
| US-NAV2 | library_ui_intent_test.dart A6f (partial; active-tool-state gap) | — |

**Status column** is intentionally left as "—" pending an actual test run; fill in Pass/Fail/Gap once
the six intent-test files exist and have been executed against `lib/`.

---

## 4. Out of Scope (v2)

The following are explicitly deferred to v2 (or, in a few cases, not planned at all) per
MASI.md:L17-35 and L230-233, and are **not covered by any story above**:

- **Auth & cloud sync** — Supabase auth, outbox-pattern sync (dirty flags, `updatedAt` cursors,
  last-write-wins + tombstones). MASI.md:L28-29, L264. *v2, not covered.*
- **Community discovery** — map + search over public topos. MASI.md:L30. v1 stores the
  supporting EXIF-GPS data (US-PHOTO area touches this only incidentally) but the discovery UI itself
  is *v2, not covered.*
- **Image upload to Supabase Storage + thumbnails.** MASI.md:L31, L264. *v2, not covered.*
- **Multi-pitch routes** — a v1 Route is exactly one line on one photo; multi-pitch becomes a `Pitch`
  child table in v2. MASI.md:L32, L152, L232. *v2, not covered.*
- **AR live route viewer** — homography-based overlay + manual fallback via
  `VNHomographicImageRegistrationRequest`; explicitly not full 3D world-anchored AR. MASI.md:L33,
  L39-58, L232. *v2 per spec — note: the repo's git history shows this has since been merged
  ("v2: AR live route viewer") independent of this document, but it is out of scope for the stories
  above, which are grounded in the v1 spec text.*
- **In-app camera / panorama stitching** — deferred indefinitely, not just to v2; native camera/
  library only, permanently. MASI.md:L233.
- **Ascent logbook / ticklist.** MASI.md:L233. *Not planned.*
- **Grade voting / moderation.** MASI.md:L233. *Not planned.*
- **3D world-anchored AR / photogrammetry** — explicitly rejected due to lack of outdoor VPS coverage,
  LiDAR range/availability limits, and fragile outdoor image tracking. MASI.md:L53, L233.
  *Permanently out of scope, not merely deferred.*
- **Additional grade systems** (YDS, V-scale/Font) — v1 supports exactly French + UIAA; adding more
  ladders is additive in v2, no schema change required. MASI.md:L27, L205.
