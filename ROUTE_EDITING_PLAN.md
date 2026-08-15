# Editing a committed route — plan

**Status: FINAL.** All four open questions were settled on 2026-08-14. Nothing is
built yet; this is the spec to build against.

Raised 2026-08-12: *"If the route is selected in edit mode why can't I edit the
line or remove it or move the signs — it needs an overhaul."*

Right. Today a route's geometry is write-once: you draw it, you commit it, and
from then on the only things that can change are its metadata, its visibility and
whether it exists. This is the plan for making a committed route's **line** and
its **markers** editable.

---

## 1. What is actually there today

Grounded in the code, not from memory — these are the facts the design has to fit.

| Capability | State |
|---|---|
| Move a point of the **draft** line | `DrawController.movePoint(index, q)` — indexes `currentPoints` only |
| Append to the draft | `addPoint(p)` |
| Draft → route | `commitRoute()` moves `currentPoints`/`currentSymbols` into `routes`, **appending** a new entry |
| Add a symbol to a **committed** route | `placeSymbol()` already does this — selected route wins, else auto-selects `routes.last` |
| Move / remove a committed route's **points** | **missing** |
| Move / remove a committed route's **symbols** | **missing** |
| Handles painted for a committed route | **no** — `TopoPainter.showHandles` draws `currentScene`, i.e. the draft only |
| Hit-testing a committed route's handles | **no** — `_beginInteraction`'s `_hitTestHandle` tests draft points only |
| Selecting a whole route | `hitTestRoute` (proximity, `route_hit_test.dart`) — drives tap-to-select |
| Persistence | `_writeThrough` + `RouteRepository.upsertRoute` — a **whole-route** upsert, optimistic with rollback and `lastWriteFailure` |
| Undo/redo | `sealed class DrawOp` with exactly three subclasses: `AddPointOp`, `AddCurrentSymbolOp`, `AddCommittedSymbolOp` |
| Symbol visibility | A committed route's symbols render **only while it is selected** (feature #43) |
| Editing *someone else's* line | Already exists: `GeometryProposal` → `propose_line_screen.dart` → owner accepts/rejects |

Two of these are quietly good news. `placeSymbol` proves the write-through +
undo pattern already works against a committed route, so this is an extension of
an existing shape rather than a new one. And symbols already being
selection-gated means moving them is visible the moment the route is selected —
no new painting needed for that half.

## 2. The design decision: edit in place

Two credible models were considered.

**Model A — re-open the route into the draft.** Selecting a route pulls its
points back into `currentPoints`, you edit with the machinery that already
exists, and committing writes it back. Tempting, because it reuses
`addPoint`/`movePoint`/undo/redo/`commitRoute` wholesale.

**Rejected**, for three reasons in descending order of severity:
- **`commitRoute` appends.** The route would come back as a *new* route with a
  *new* number. Route numbers are how ascents and comments resolve to a line
  (`RouteRepository.routeDbIdsByNumber`), so editing a route would silently
  detach somebody's logged ascent from the line they climbed.
- **The route stops existing while you edit it.** It leaves `routes`, so the
  legend loses a row, numbering shifts under it, and its colour can change.
- **A crash or photo switch mid-edit loses the route**, because the only copy is
  in volatile draft state.

**Model B — edit in place. ✅ Chosen.** New controller operations mutate
`routes[i]` directly, each persisted through the existing write-through path. The
route keeps its identity, number, colour and DB row throughout; every edit is
independently persisted; there is no draft-versus-committed duality to reason
about. It costs more new API and needs handles painted and hit-tested for the
selected committed route.

Identity preservation is not a nicety here — it is the difference between editing
a route and replacing it with a lookalike.

## 3. Settled decisions

### 3.1 Undo granularity — one gesture, one undo

A drag emits a move event per frame; a two-second drag is ~120 of them. Undo
rewinds the **whole drag**, back to where the point was when you grabbed it. The
alternative (rewinding a frame at a time) is useless and is not built.

This is also the main performance trap. Mutate state per move, persist **once**
at drag end. That needs an explicit boundary — `endRouteGeometryEdit(routeId)` —
which is also the only place a `DrawOp` is pushed. The op captures the *pre-drag*
geometry, not the per-frame deltas. Without this, one drag is ~120 database
writes and ~120 undo entries.

### 3.2 Moderation — owner edits stay non-blocking

Two different paths, and only one of them is new work:

- **Editing someone else's line** → the existing `GeometryProposal` flow. The
  edit becomes a proposal (points + markers, percent-space, capped at
  `kMaxProposedPoints` 200 / `kMaxProposedSymbols` 64 to match the server), the
  owner accepts or rejects. The new editing UI must route into that flow rather
  than writing directly whenever the current user is not the owner. **No new
  moderation design needed** — wire to what exists.

  > **Built 2026-08-14, and the premise was wrong in one important way.** ⚠️
  > "Whenever the current user is not the owner" **was not computable** — that
  > predicate existed nowhere in the codebase. `readOnly` on the canvas route is
  > a URL query parameter (`router.dart`), a call-site convention that at least
  > six pushers omit, and `_wallQuery` has no owner predicate, so Library →
  > Organize → Areas → Sectors → Walls opens any locally-cached wall — including
  > other people's synced-down topos — in the fully editable canvas. So this
  > section's gate had to be *built*, not wired.
  >
  > What was built:
  > - `mayEditWallRoutes` / `canEditWallRoutesProvider`
  >   (`lib/features/topo/application/wall_route_edit_permission.dart`), matching
  >   `LibraryCrudRepository._ownOrUnowned`'s **own-OR-unowned** semantics. The
  >   unowned arm is load-bearing: rows drawn before a first sign-in carry a null
  >   `ownerId` until `claimOwnership` stamps them, so treating null as foreign
  >   would lock people out of their own topos — a worse failure than the one
  >   being fixed. Every ambiguous answer (missing row, failed read, not yet
  >   resolved) resolves to *editable*: refuse only what is positively proven
  >   foreign, the same posture as `PublicPhotoPruner`.
  > - **The gestures are identical for a non-owner.** They drag a point and watch
  >   it move exactly as an owner does; `endRouteGeometryEdit` is the single
  >   place the paths diverge, via `DrawState.proposalOnlyGeometryEdits` — into a
  >   write, or into an in-memory edit awaiting submission. Refusing the gesture
  >   was considered and rejected: you cannot judge a line you are not allowed to
  >   draw.
  > - A **suggest/discard bar** (`topo-proposal-bar`) files one
  >   `SuggestionKind.routeGeometry` per edited route through the existing
  >   `SuggestionService`, then restores the owner's geometry — the suggestion
  >   lives on the server, and a line left on screen that exists nowhere else
  >   reads as "accepted". It says **"not saved"** out loud, because the edit
  >   looks identical to an owner's and silence would read as saved.
  > - `GeometryProposal.fromEdit` decides `symbols` **null vs `[]` by comparison**
  >   against the pre-edit markers. Null means "says nothing about them"; `[]` is
  >   a deliberate removal this editor can now express and the phase-7b screen
  >   could not. Collapsing either direction is silent data loss.
  >
  > **Still open, deliberately out of scope** and filed separately: drawing a
  > *new* route on a foreign wall, renaming it, and the admin queue's five
  > unadorned pushes to an editable canvas. Only route GEOMETRY is gated here.
- **Editing your own published topo** → **blocks nothing.** No admin approval, no
  queue, no trust gate. This preserves the deliberate C-5c/C-5d design: publication
  is a one-time gate, and a structural change posts a *notice* to the admin queue
  while never interrupting the owner, with revert (C-8) and take down (C-7) as the
  remedies that carry consequence.

  An admin-approval gate was considered and **rejected on 2026-08-14**. The
  reasoning, recorded so it is not re-litigated blind: `TrustStanding` has two
  levels and needs three moderator-approved topos to reach trusted, so gating
  owner edits would put every correction to a new user's first three topos in a
  queue — and `material_change_notices.sql` states the failure mode being avoided
  outright, *"the queue filled with normal editing and admins stopped reading
  it"*, listing "nudging an existing line" among ordinary owner work.

  **Consequence for this feature: nothing.** Moving a point on your own route is
  exactly the "nudge" the existing detector deliberately ignores; only geometry
  *cleared* counts as material. If coverage ever needs widening (e.g. a line whose
  points moved beyond some threshold posts a notice), that is a change to the
  server-side detector, independent of everything below.

### 3.3 Removal — an eraser tool

An **eraser** joins the symbol palette beside Route / Anchor / Bolt / Top / Crux /
Off. With it active, tapping anything removes it: a point of the selected route,
or one of its markers.

Chosen over a long-press because it is visible in the palette rather than
hidden, it reuses the tool-selection model the palette already teaches, and it
covers points and markers with one affordance instead of two gestures. It also
avoids the awkwardness of long-pressing a target you are also meant to drag.

`assets/icons/masi/masi_eraser.svg` already exists — a tilted eraser block over a
baseline, two facets at 0.28/0.14 opacity, 1.8px strokes, round caps and miter
joins per `ICONS-README.md`.

**Selecting the eraser deselects every other palette tool** — exactly one control
is ever lit, and the eraser participates in that rule like anything else. In
particular, activating it must CLEAR `activeSymbol`, not merely shadow it: a
symbol left active underneath would silently return when the eraser is switched
off, and a tap would place a marker where the user expected to remove one.

**What it does NOT clear is the selected ROUTE**, and that is deliberate rather
than an oversight. A committed route's markers render only while that route is
selected (feature #43), and its point handles only appear for the selected route
(§4.2). Clearing the selection would leave the eraser with nothing visible to act
on. So: the eraser clears the palette, and keeps the route.

**The palette invariant this breaks, and the fix.** Today "exactly one tool is
selected" is expressed as `activeSymbol == null` meaning the Route tool. An
eraser is a third kind — a tool, not a placeable `SymbolType` — so
`activeSymbol == null` would no longer distinguish "Route" from "eraser". Add an
explicit tool selector to `DrawState` (e.g. `activeTool: route | symbol |
eraser`) and derive the palette's selected state from it, rather than adding an
`eraser` member to `SymbolType` — that enum feeds `TopoPainter`'s and
`topo_route.dart`'s symbol-rendering switches, and an eraser is never a thing
that gets drawn on a photo.

A test pins the mutual exclusion directly: activating the eraser leaves no symbol
active and no other palette control rendering selected, and switching back to
Route or a symbol turns the eraser off again.

### 3.4 Scope of "remove it"

Points and markers. Deleting a whole route already exists in the row menu and is
unchanged.

## 4. Work breakdown

### 4.1 Controller (`draw_controller.dart`)

New operations, all keyed by `routeId` (never by index into `routes`, which
shifts):

- `moveRoutePoint(int routeId, int index, Offset percent)`
- `insertRoutePointAfter(int routeId, int index, Offset percent)`
- `removeRoutePoint(int routeId, int index)` — refuses below **2 points**; a
  one-point route has no line to draw
- `moveRouteSymbol(int routeId, int symbolIndex, Offset percent)`
- `removeRouteSymbol(int routeId, int symbolIndex)`
- `endRouteGeometryEdit(int routeId)` — the drag boundary from §3.1: persists once
  and pushes exactly one `DrawOp`

New `DrawOp` subclasses (the class is `sealed`, so every `switch` over it fails to
compile until updated — a feature, not a chore): `MoveRoutePointOp`,
`InsertRoutePointOp`, `RemoveRoutePointOp`, `MoveRouteSymbolOp`,
`RemoveRouteSymbolOp`. Each stores routeId + index + before/after, so `undo` is a
straight inversion.

> **Built differently — one op, not five.** ⚠️ Implemented 2026-08-14 as a single
> `EditRouteGeometryOp` carrying routeId + a whole-geometry `before`/`after` pair.
> The five-op family contradicts §3.1 one section earlier: dragging out of the
> middle of a segment *inserts* a point and then *moves* it as one continuous
> motion, so a per-edit family records one gesture as two undo entries and the
> climber's first undo leaves a stray point on the line. A whole-geometry pair is
> correct for any gesture without index arithmetic, and undo/redo become plain
> assignment. Cost is memory proportional to the route, which is bounded by what
> a person draws by hand. The full argument is on the class itself in
> `draw_controller.dart`.

Plus the `activeTool` change from §3.3.

### 4.2 Painting (`topo_painter.dart`)

Handles for the selected committed route while in draw mode. `showHandles`
currently means "the draft"; rather than overload it, add `editableRouteId` and
paint that route's points with the same handle geometry. Symbols need no change
(already selection-gated).

### 4.3 Gestures (`topo_canvas.dart`) — the risky part

`_beginInteraction` decides what a touch means, and this adds new candidates. The
priority order has to be explicit or it will regress the existing draw flow:

1. **eraser active** → hit-test the selected route's symbols, then its points;
   remove whatever is hit (subject to the 2-point floor). Highest, because an
   explicitly-selected tool is explicit intent.
2. draft handle (an active draw always beats selection editing)
3. selected route's **symbol** (smaller target, so it must beat the line)
4. selected route's **point**
5. tap-to-select a different route
6. place a symbol / add a point (unchanged, lowest)

> **Built differently — two departures, both deliberate.** ⚠️ Implemented
> 2026-08-14 in `_beginInteraction`:
>
> - **Symbol placement stayed at the TOP, not at 6.** The list above assumed it
>   was already the lowest-priority fallback ("unchanged, lowest"); it is not —
>   `activeSymbol != null` has always short-circuited the whole method before
>   any handle hit-test. Demoting it below the draft handle would silently
>   change an existing, tested behaviour (placing a marker near a draft handle
>   would start dragging the handle instead) for no gain in this feature. It is
>   moot against the eraser in any case: `setEraserActive` clears
>   `activeSymbol`, so the two branches can never both be live.
> - **Tap-to-select-a-different-route (5) was NOT added in draw mode.** It does
>   not exist there today — a tap on empty canvas in draw mode ADDS A POINT,
>   which is the mode's primary action. Adding proximity-select above it would
>   make drawing a second line alongside an existing one select the old route
>   instead of drawing, which is a real regression against a common thing to
>   draw. Selection in draw mode comes from tapping the legend row, which
>   already works and is unambiguous. Tap-to-select stays what it is: a
>   **view**-mode gesture, in `_endViewTap`.
>
> So the order as built is: eraser → place symbol → draft handle → selected
> route's symbol → selected route's point → add a point.

### 4.4 Entry point

No new menu item. Selecting a route in edit mode *is* the gesture — handles
appear on it, and that is the affordance. (Alternative, if that proves too
implicit on a device: an "Edit line" row in the per-route menu that sets an
explicit editing target. Cheap to add later; hard to remove once learned.)

### 4.5 Tests

- Controller unit tests per operation: the 2-point floor, undo/redo inversion,
  write-through failure → rollback + `lastWriteFailure`.
- **One undo per drag**, not per frame — the assertion that pins §3.1's trap.
- Gesture-priority tests for the six-way order above, eraser included.
- A regression test that a route's `number` and its persisted DB id are unchanged
  after a geometry edit — the property Model A would have broken.
- Editing a route on a topo you do not own routes into `GeometryProposal` and
  writes nothing locally.

## 5. Sequencing

1. Controller ops + `DrawOp` subclasses + `activeTool` + unit tests (no UI) — the
   whole thing is testable headless at this point.
2. Painting handles for the selected route.
3. Gestures, priority order, and their tests.
4. The eraser tool in the palette.
5. Non-owner path → `GeometryProposal`.
6. Signed-in E2E pass on the canvas, then a device check.

Steps 1–2 are independently shippable and inert until step 3 wires the gestures,
so this can land in pieces rather than as one large change.
