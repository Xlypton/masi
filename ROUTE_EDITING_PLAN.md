# Editing a committed route — plan

**Status:** proposal, nothing built. Raised 2026-08-12: *"If the route is selected
in edit mode why can't I edit the line or remove it or move the signs — it needs
an overhaul."*

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

Two of these are quietly good news. `placeSymbol` proves the write-through +
undo pattern already works against a committed route, so this is an extension of
an existing shape rather than a new one. And symbols already being
selection-gated means moving them is visible the moment the route is selected —
no new painting needed for that half.

## 2. The design decision

Two credible models.

### Model A — re-open the route into the draft
Selecting a route in edit mode pulls its points back into `currentPoints`, you
edit with the machinery that already exists, and committing writes it back.

*For:* reuses `addPoint`/`movePoint`/undo/redo/`commitRoute` wholesale; almost no
new controller surface.

*Against —* and this is what rules it out:
- **The route stops existing while you edit it.** It leaves `routes`, so the
  legend loses a row, the numbering shifts under it, and its colour can change.
- **`commitRoute` appends.** It would come back as a *new* route with a *new*
  number. Route numbers are how ascents and comments resolve to a route
  (`RouteRepository.routeDbIdsByNumber`), so renumbering silently detaches
  somebody's logged ascent from the line they climbed.
- **A crash or a photo switch mid-edit loses the route entirely**, because the
  only copy is in volatile draft state.

### Model B — edit in place ✅ recommended
New controller operations mutate `routes[i]` directly, each persisted through the
existing write-through path.

*For:* the route keeps its identity, number, colour and DB row throughout; every
edit is independently persisted, so nothing is lost if the app dies; no
draft-versus-committed duality to reason about.

*Against:* more new API, and it needs handles painted and hit-tested for the
selected committed route.

**Recommendation: B.** Identity preservation is not a nicety here — it is the
difference between editing a route and replacing it with a lookalike.

## 3. Work breakdown

### 3.1 Controller (`draw_controller.dart`)

New operations, all keyed by `routeId` (never by index into `routes`, which
shifts):

- `moveRoutePoint(int routeId, int index, Offset percent)`
- `insertRoutePointAfter(int routeId, int index, Offset percent)`
- `removeRoutePoint(int routeId, int index)` — refuses below **2 points**; a
  one-point route has no line to draw
- `moveRouteSymbol(int routeId, int symbolIndex, Offset percent)`
- `removeRouteSymbol(int routeId, int symbolIndex)`

**The drag-economy trap, and it is the main one.** A drag emits a move event per
frame. If each one writes through, a single two-second drag is ~120 database
writes and ~120 undo-stack entries, and undo becomes useless because each press
rewinds one frame. So: mutate state per move, persist **once** at drag end. That
needs an explicit boundary — `endRouteGeometryEdit(routeId)` — which is also the
natural place to push exactly one `DrawOp`. The op must capture the *pre-drag*
geometry, not the per-frame deltas.

New `DrawOp` subclasses (the class is `sealed`, so every `switch` over it will
fail to compile until updated — a feature, not a chore): `MoveRoutePointOp`,
`InsertRoutePointOp`, `RemoveRoutePointOp`, `MoveRouteSymbolOp`,
`RemoveRouteSymbolOp`. Each stores routeId + index + before/after, so `undo` is a
straight inversion.

### 3.2 Painting (`topo_painter.dart`)

Handles for the selected committed route while in draw mode. `showHandles`
currently means "the draft"; rather than overload it, add `editableRouteId` and
paint that route's points with the same handle geometry. Symbols need no change
(already selection-gated).

### 3.3 Gestures (`topo_canvas.dart`) — the risky part

`_beginInteraction` decides what a touch means, and this adds two new candidates.
The priority order has to be explicit or it will regress the existing draw flow:

1. draft handle (unchanged, highest — an active draw always wins)
2. selected route's **symbol** (smaller target, so it must beat the line)
3. selected route's **point**
4. tap-to-select a different route
5. place a symbol / add a point (unchanged, lowest)

Removing a point: **long-press a handle**, subject to the 2-point floor. A tap
can't mean "remove" — tapping a handle is how you'd naturally start a drag.

### 3.4 Entry point

No new menu item. Selecting a route in edit mode *is* the gesture — handles
appear on it, and that is the affordance. (Alternative, if that proves too
implicit on a device: an "Edit line" row in the per-route menu that sets an
explicit editing target. Cheap to add later; hard to remove once learned.)

### 3.5 Tests

- Controller unit tests per operation: the 2-point floor, undo/redo inversion,
  write-through failure → rollback + `lastWriteFailure`.
- **One undo per drag**, not per frame — the assertion that pins §3.1's trap.
- Gesture-priority tests for the five-way order above.
- A regression test that a route's `number` and its persisted DB id are unchanged
  after a geometry edit — the property Model A would have broken.

## 4. Open questions — worth deciding before building

1. **Undo granularity.** One undo step per drag is what §3.1 assumes. Confirm
   that matches expectation: it means a drag cannot be partially rewound.
2. **Does editing a *published* route's geometry need review?** The community
   editing phases have a whole suggestion flow for changing *someone else's* line
   (`propose_line_screen.dart`). Whether changing your *own* published route
   silently updates what everybody sees, or re-enters review, is a product call I
   should not guess at. Needs checking against the moderation triggers before
   this ships.
3. **Symbol removal.** Long-press, same as points? Or via the route menu, given
   symbols are small targets?
4. **Scope of "remove it".** The original request said "edit the line or remove
   it" — deleting the whole route already exists in the row menu, so I have read
   this as removing *points/markers*. Worth confirming.

## 5. Rough sequencing

1. Controller ops + `DrawOp` subclasses + unit tests (no UI) — the whole thing is
   testable headless at this point.
2. Painting handles for the selected route.
3. Gestures, priority order, and their tests.
4. Long-press removal.
5. Signed-in E2E pass on the canvas, then device check.

Steps 1–2 are independently shippable and inert until step 3 wires the gestures,
so this can land in pieces rather than as one large change.
