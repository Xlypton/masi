import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:climbtopo/core/db/database_provider.dart';
import 'package:climbtopo/core/grades/grade_system.dart';
import 'package:climbtopo/features/topo/domain/topo_route.dart';

/// Whether the topo canvas is in passive viewing mode or active route
/// drawing mode.
enum DrawMode { view, draw }

/// The result of a [DrawController.placeSymbol] call, distinguishing the
/// four cases callers (currently just `_TopoCanvasState._beginInteraction`)
/// need to react to differently -- specifically, whether a hint should be
/// shown to the user.
enum SymbolPlacementOutcome {
  /// The symbol was placed on the route [DrawState.selectedRouteId] already
  /// pointed at (it was explicitly selected before this call).
  placed,

  /// No route was selected, but [DrawState.routes] was non-empty, so
  /// [DrawController.placeSymbol] auto-selected `routes.last` (the most
  /// recently committed route) and placed the symbol on it.
  autoSelectedAndPlaced,

  /// No route was selected and [DrawState.routes] was empty, so there was
  /// nothing to place the symbol on. Callers should surface a hint (e.g. "draw
  /// a route first") rather than silently doing nothing.
  noRouteAvailable,

  /// [DrawState.activeSymbol] was null, so there was no symbol type to
  /// place. This is a plain no-op with no user-facing feedback -- symmetric
  /// with the pre-existing no-active-symbol no-op behavior.
  noActiveSymbol,
}

/// A single undoable/redoable drawing operation. [DrawState.undoStack] and
/// [DrawState.redoStack] are unified LIFO histories of these, so undo/redo
/// cover BOTH points and symbols -- previously undo/redo only knew about
/// points (a bug: placing a crux/bolt/anchor symbol could never be undone,
/// see this file's usage docs for the bug report this fixes) -- whether the
/// symbol landed on the in-progress route ([AddCurrentSymbolOp]) or an
/// already-committed one ([AddCommittedSymbolOp]).
sealed class DrawOp {
  const DrawOp();
}

/// A point appended to [DrawState.currentPoints] via
/// [DrawController.addPoint].
class AddPointOp extends DrawOp {
  const AddPointOp(this.point);

  final Offset point;
}

/// A symbol appended to [DrawState.currentSymbols] -- the in-progress,
/// uncommitted route -- via [DrawController.placeSymbol].
class AddCurrentSymbolOp extends DrawOp {
  const AddCurrentSymbolOp(this.symbol);

  final TopoSymbol symbol;
}

/// A symbol appended to an already-committed route (identified by
/// [routeId]) via [DrawController.placeSymbol].
class AddCommittedSymbolOp extends DrawOp {
  const AddCommittedSymbolOp(this.routeId, this.symbol);

  final int routeId;
  final TopoSymbol symbol;
}

/// Shared by [DrawController.commitRoute]'s undo/redo-stack filtering (FIX
/// #9): `true` for the two [DrawOp] variants that describe the CURRENT,
/// not-yet-committed draft ([DrawState.currentPoints]/
/// [DrawState.currentSymbols]) rather than an already-committed route's
/// symbols. A commit consumes the draft these ops refer to (clearing both
/// fields to empty), so they must be dropped along with it; an
/// [AddCommittedSymbolOp] describes a placement on a route that already
/// exists independently of any draft and is unaffected by a later commit,
/// so it is never matched here.
bool _isInProgressDraftOp(DrawOp op) =>
    op is AddPointOp || op is AddCurrentSymbolOp;

/// Immutable state for the topo route drawing feature.
///
/// [currentPoints] and the points inside [routes] are expressed in percent
/// space (i.e. coordinates normalized to the image's width/height), so they
/// stay valid regardless of how the image is scaled or panned on screen.
class DrawState {
  const DrawState({
    this.mode = DrawMode.view,
    this.currentPoints = const [],
    this.currentSymbols = const [],
    this.routes = const [],
    this.undoStack = const [],
    this.redoStack = const [],
    this.selectedRouteId,
    this.activeSymbol,
    this.nextId = 1,
    this.nextNumber = 1,
    this.activeWallId,
    this.activePhotoId,
    this.isSwitchingPhoto = false,
    this.switchGeneration = 0,
    this.switchTargetPhotoId,
  });

  final DrawMode mode;
  final List<Offset> currentPoints;

  /// Symbols placed (via [DrawController.placeSymbol]) on the in-progress,
  /// uncommitted route while [currentPoints] is non-empty -- the "place a
  /// symbol while still drawing the line" fix. [DrawController.commitRoute]
  /// folds these into the new [TopoRoute.symbols]; [DrawController
  /// .clearCurrent]/[DrawController.beginPhotoSwitch] discard them.
  final List<TopoSymbol> currentSymbols;

  final List<TopoRoute> routes;

  /// The wall this controller is currently loaded/persisting against, or
  /// null if [loadForWall] has never been called (in which case all
  /// persistence write-through is a no-op — see [DrawController]).
  final String? activeWallId;

  /// The photo (within [activeWallId]) routes are persisted against.
  final String? activePhotoId;

  /// FIX #4 (HIGH, CONFIRMED — "route committed during photo-switch is
  /// discarded"): `true` from the moment [DrawController.beginPhotoSwitch]
  /// runs until the corresponding [DrawController.loadForWall] call for the
  /// NEW photo finishes applying its result. `false` the rest of the time
  /// (including the default/initial state, and after any [loadForWall] call
  /// that DIDN'T follow a [beginPhotoSwitch] — see that method's doc for why
  /// that distinction matters).
  ///
  /// This is deliberately a SEPARATE flag from `activeWallId == null`: that
  /// condition is ALSO true for the ordinary "no photo attached yet" case
  /// (see [DrawController]'s many pre-M3 tests), where a commit is expected
  /// to succeed in-memory (just without persistence). This flag exists so
  /// [loadForWall] can tell "this is the second half of a switch that just
  /// started" apart from "some unrelated wall/photo has simply never been
  /// loaded" — only the former should have any leftover [routes] merged
  /// into the freshly-loaded list; the latter must keep fully REPLACING
  /// [routes], which existing tests (e.g. the "switching walls" test)
  /// depend on.
  final bool isSwitchingPhoto;

  /// FIX #4 (continued) — monotonic counter bumped by every
  /// [DrawController.beginPhotoSwitch] call. [DrawController.loadForWall]
  /// captures this value at entry (before its `await`) and, once that
  /// `await` resolves, only APPLIES its result (replacing/merging
  /// [routes], setting [activeWallId]/[activePhotoId], etc.) if this
  /// counter is still the same value — i.e. no NEWER [beginPhotoSwitch] ran
  /// while it was awaiting. This closes the out-of-order-resolution race:
  /// without it, two overlapping switches (tap photo A, then tap photo B
  /// before A's [loadForWall] finishes) could see A's load resolve AFTER
  /// B's and clobber B's freshly-loaded state with stale data for the
  /// wrong photo. A call to [loadForWall] not preceded by any
  /// [beginPhotoSwitch] (e.g. the very first load, or the "switching
  /// walls" test) simply sees this counter unchanged across its own
  /// `await` and applies normally, exactly as before this fix.
  final int switchGeneration;

  /// FIX #4 (continued, CONFIRMED — "deleting the photo you are currently
  /// switching TO is unaware its target is gone"): the photoId a currently
  /// in-flight [DrawController.loadForWall] call is loading, or null when no
  /// [loadForWall] call is between its capture of [switchGeneration] and
  /// applying its result. Set by [loadForWall] itself, synchronously, before
  /// its internal repository `await` — i.e. for the ENTIRE window during
  /// which [activePhotoId] is null but a real destination photo is already
  /// known — and cleared back to null either when that same [loadForWall]
  /// call settles (applies its result — at which point the destination IS
  /// [activePhotoId], so there's no separate "target" left to track) or when
  /// [cancelPhotoSwitch] settles the switch without a [loadForWall] ever
  /// coming.
  ///
  /// This exists as a SEPARATE field from [activePhotoId] because
  /// [beginPhotoSwitch] deliberately nulls [activePhotoId] for the entire
  /// switch, which previously made "the photo I'm switching TO" and "no
  /// photo is relevant right now" indistinguishable from outside this
  /// controller. Concretely, this is what lets
  /// `TopoCanvasScreen._handleDeletePhoto` tell "the photo being deleted is
  /// the one an in-flight switch is headed towards" (this field) apart from
  /// "the photo being deleted is unrelated to any in-flight switch" (neither
  /// this field nor [activePhotoId] matches) — see that method's doc for the
  /// full regression this closes: without it, deleting a switch's target
  /// mid-flight read as the latter, silently returning without settling
  /// [isSwitchingPhoto] or redirecting the canvas anywhere, even though the
  /// photo the switch was about to land on no longer exists.
  ///
  /// [beginPhotoSwitch] always resets this to null at the start of a new
  /// switch (the new switch's own destination isn't known yet — only the
  /// [loadForWall] call that follows it will know that).
  final String? switchTargetPhotoId;

  /// Operations applied so far, available to be inverted by [undo]. See
  /// [DrawOp].
  final List<DrawOp> undoStack;

  /// Operations popped off [undoStack] by [undo], available to be
  /// re-applied by [redo]. Any new mutation (via [addPoint] or
  /// [placeSymbol]) clears this stack.
  final List<DrawOp> redoStack;

  /// The id of the currently selected route, or null if none is selected.
  /// Always either null or the id of a route present in [routes].
  final int? selectedRouteId;

  /// The symbol type that will be placed on the selected route by
  /// [DrawController.placeSymbol], or null if no symbol is active.
  final SymbolType? activeSymbol;

  /// The id to assign to the next committed route.
  final int nextId;

  /// The number to assign to the next committed route.
  final int nextNumber;

  DrawState copyWith({
    DrawMode? mode,
    List<Offset>? currentPoints,
    List<TopoSymbol>? currentSymbols,
    List<TopoRoute>? routes,
    List<DrawOp>? undoStack,
    List<DrawOp>? redoStack,
    int? selectedRouteId,
    bool selectedRouteIdSet = false,
    SymbolType? activeSymbol,
    bool activeSymbolSet = false,
    int? nextId,
    int? nextNumber,
    String? activeWallId,
    bool activeWallIdSet = false,
    String? activePhotoId,
    bool activePhotoIdSet = false,
    bool? isSwitchingPhoto,
    int? switchGeneration,
    String? switchTargetPhotoId,
    bool switchTargetPhotoIdSet = false,
  }) {
    return DrawState(
      mode: mode ?? this.mode,
      currentPoints: currentPoints ?? this.currentPoints,
      currentSymbols: currentSymbols ?? this.currentSymbols,
      routes: routes ?? this.routes,
      undoStack: undoStack ?? this.undoStack,
      redoStack: redoStack ?? this.redoStack,
      selectedRouteId: selectedRouteIdSet
          ? selectedRouteId
          : (selectedRouteId ?? this.selectedRouteId),
      activeSymbol: activeSymbolSet
          ? activeSymbol
          : (activeSymbol ?? this.activeSymbol),
      nextId: nextId ?? this.nextId,
      nextNumber: nextNumber ?? this.nextNumber,
      activeWallId: activeWallIdSet
          ? activeWallId
          : (activeWallId ?? this.activeWallId),
      activePhotoId: activePhotoIdSet
          ? activePhotoId
          : (activePhotoId ?? this.activePhotoId),
      isSwitchingPhoto: isSwitchingPhoto ?? this.isSwitchingPhoto,
      switchGeneration: switchGeneration ?? this.switchGeneration,
      switchTargetPhotoId: switchTargetPhotoIdSet
          ? switchTargetPhotoId
          : (switchTargetPhotoId ?? this.switchTargetPhotoId),
    );
  }
}

/// Manages [DrawState] for the topo canvas: draw/view mode, the in-progress
/// route being drawn, undo/redo, committing finished routes, route
/// selection/visibility, and placing symbols on the selected route.
class DrawController extends Notifier<DrawState> {
  /// FIX #6 (HIGH, CONFIRMED — multi-instance state bleed): [wallId] is the
  /// family key [drawControllerProvider] was looked up with (see that
  /// provider's doc) — required by [NotifierProvider.family]'s factory
  /// signature (`NotifierT Function(ArgT arg)`), so every wall gets its own
  /// [DrawController] instance instead of one shared app-lifetime global.
  /// Not currently read by any method below (every wall-scoped operation
  /// already takes/derives its wallId explicitly via [loadForWall]'s
  /// argument and [DrawState.activeWallId]), but kept as a field so each
  /// instance's own identity is inspectable (e.g. in a debugger) and so a
  /// future defensive assert has somewhere to read it from.
  DrawController(this.wallId);

  final String wallId;

  @override
  DrawState build() => const DrawState();

  /// Flips between [DrawMode.view] and [DrawMode.draw].
  void toggleMode() {
    setMode(state.mode == DrawMode.view ? DrawMode.draw : DrawMode.view);
  }

  void setMode(DrawMode mode) {
    state = state.copyWith(mode: mode);
  }

  /// Appends [p] to the in-progress route, pushes an [AddPointOp] onto
  /// [DrawState.undoStack], and clears [DrawState.redoStack].
  void addPoint(Offset p) {
    state = state.copyWith(
      currentPoints: [...state.currentPoints, p],
      undoStack: [...state.undoStack, AddPointOp(p)],
      redoStack: const [],
    );
  }

  /// Pops the last operation off [DrawState.undoStack] and inverts it,
  /// pushing it onto [DrawState.redoStack] for [redo] to re-apply. No-op if
  /// [DrawState.undoStack] is empty.
  ///
  /// - [AddPointOp]: removes the last element of [DrawState.currentPoints]
  ///   (the pre-existing point-undo behavior).
  /// - [AddCurrentSymbolOp]: removes the last element of
  ///   [DrawState.currentSymbols] -- undoes a symbol placed mid-draw.
  /// - [AddCommittedSymbolOp]: removes the LAST symbol from the named
  ///   route's `symbols` and re-persists that route -- see [commitRoute]'s
  ///   doc for the sync-mutation / no-op-without-a-wall write-through
  ///   contract shared by every persisting method, including this one. This
  ///   is the fix for the reported bug: placing a crux/bolt/anchor on an
  ///   already-committed route can now be undone, including on disk.
  ///
  /// The in-memory mutation always happens synchronously, before any
  /// `await`, so callers that don't await this method still observe the
  /// state change immediately (only the [AddCommittedSymbolOp] case has
  /// anything left to `await` afterwards: the DB write-through).
  Future<void> undo() async {
    if (state.undoStack.isEmpty) return;

    final undoStack = [...state.undoStack];
    final op = undoStack.removeLast();

    switch (op) {
      case AddPointOp():
        final points = [...state.currentPoints];
        if (points.isNotEmpty) points.removeLast();
        state = state.copyWith(
          currentPoints: points,
          undoStack: undoStack,
          redoStack: [...state.redoStack, op],
        );
        return;

      case AddCurrentSymbolOp():
        final symbols = [...state.currentSymbols];
        if (symbols.isNotEmpty) symbols.removeLast();
        state = state.copyWith(
          currentSymbols: symbols,
          undoStack: undoStack,
          redoStack: [...state.redoStack, op],
        );
        return;

      case AddCommittedSymbolOp(routeId: final routeId):
        final index = state.routes.indexWhere((r) => r.id == routeId);
        if (index == -1) {
          // Route no longer exists (e.g. removed since it was placed on);
          // still consume the op so the undo/redo stacks stay consistent.
          state = state.copyWith(
            undoStack: undoStack,
            redoStack: [...state.redoStack, op],
          );
          return;
        }

        final route = state.routes[index];
        final symbols = [...route.symbols];
        if (symbols.isNotEmpty) symbols.removeLast();
        final updatedRoute = route.copyWith(symbols: symbols);
        final routes = [...state.routes];
        routes[index] = updatedRoute;
        state = state.copyWith(
          routes: routes,
          undoStack: undoStack,
          redoStack: [...state.redoStack, op],
        );

        final wallId = state.activeWallId;
        final photoId = state.activePhotoId;
        if (wallId == null || photoId == null) return;
        try {
          await ref
              .read(routeRepositoryProvider)
              .upsertRoute(wallId, photoId, updatedRoute);
        } catch (e, st) {
          debugPrint('undo: persistence write-through failed: $e\n$st');
        }
        return;
    }
  }

  /// Pops the last operation off [DrawState.redoStack] and RE-applies it —
  /// the exact inverse of [undo] — pushing it back onto
  /// [DrawState.undoStack]. No-op if [DrawState.redoStack] is empty.
  ///
  /// Mirrors [undo]'s three cases (re-adding the point/current-symbol, or
  /// re-appending the symbol to its committed route and re-persisting it),
  /// with the same synchronous-mutation-before-`await` contract.
  Future<void> redo() async {
    if (state.redoStack.isEmpty) return;

    final redoStack = [...state.redoStack];
    final op = redoStack.removeLast();

    switch (op) {
      case AddPointOp(point: final point):
        state = state.copyWith(
          currentPoints: [...state.currentPoints, point],
          redoStack: redoStack,
          undoStack: [...state.undoStack, op],
        );
        return;

      case AddCurrentSymbolOp(symbol: final symbol):
        state = state.copyWith(
          currentSymbols: [...state.currentSymbols, symbol],
          redoStack: redoStack,
          undoStack: [...state.undoStack, op],
        );
        return;

      case AddCommittedSymbolOp(routeId: final routeId, symbol: final symbol):
        final index = state.routes.indexWhere((r) => r.id == routeId);
        if (index == -1) {
          state = state.copyWith(
            redoStack: redoStack,
            undoStack: [...state.undoStack, op],
          );
          return;
        }

        final route = state.routes[index];
        final updatedRoute = route.copyWith(
          symbols: [...route.symbols, symbol],
        );
        final routes = [...state.routes];
        routes[index] = updatedRoute;
        state = state.copyWith(
          routes: routes,
          redoStack: redoStack,
          undoStack: [...state.undoStack, op],
        );

        final wallId = state.activeWallId;
        final photoId = state.activePhotoId;
        if (wallId == null || photoId == null) return;
        try {
          await ref
              .read(routeRepositoryProvider)
              .upsertRoute(wallId, photoId, updatedRoute);
        } catch (e, st) {
          debugPrint('redo: persistence write-through failed: $e\n$st');
        }
        return;
    }
  }

  /// Replaces the point at [index] with [q], leaving all other points
  /// unchanged. No-op if [index] is out of range.
  void movePoint(int index, Offset q) {
    if (index < 0 || index >= state.currentPoints.length) return;

    final points = [...state.currentPoints];
    points[index] = q;
    state = state.copyWith(currentPoints: points);
  }

  /// If there are at least 2 current points, moves them (and any
  /// [DrawState.currentSymbols] placed on them mid-draw) into
  /// [DrawState.routes] as a new [TopoRoute], and empties
  /// [DrawState.currentPoints] and [DrawState.currentSymbols]. No-op
  /// otherwise.
  ///
  /// FIX #9 (MED, CONFIRMED — same fix as [removeRoute], see that method's
  /// doc): [DrawState.undoStack]/[DrawState.redoStack] are filtered (not
  /// wholesale cleared) via [_isInProgressDraftOp] to drop ONLY the
  /// [AddPointOp]/[AddCurrentSymbolOp] entries for the draft this call is
  /// finishing — they're consumed by the commit and would otherwise dangle
  /// against the now-empty [DrawState.currentPoints]/[DrawState.currentSymbols].
  /// Any [AddCommittedSymbolOp] already on either stack (from a placement
  /// on a DIFFERENT, previously-committed route) has nothing to do with
  /// this draft and survives untouched, so undoing/redoing that unrelated
  /// placement still works immediately after committing a new route.
  ///
  /// Persistence write-through: if [DrawState.activeWallId] is set (i.e.
  /// [loadForWall] has been called), the new route is also upserted to the
  /// repository. The in-memory mutation above happens synchronously, before
  /// any `await`, so callers that don't await this method still observe the
  /// state change immediately (preserving pre-M3 unit test behavior).
  Future<void> commitRoute() async {
    if (state.currentPoints.length < 2) return;

    final route = TopoRoute(
      id: state.nextId,
      number: state.nextNumber,
      points: [...state.currentPoints],
      symbols: [...state.currentSymbols],
      colorIndex: routeColorIndexFor(state.nextNumber),
    );

    state = state.copyWith(
      routes: [...state.routes, route],
      currentPoints: const [],
      currentSymbols: const [],
      undoStack: state.undoStack.where((op) => !_isInProgressDraftOp(op)).toList(),
      redoStack: state.redoStack.where((op) => !_isInProgressDraftOp(op)).toList(),
      nextId: state.nextId + 1,
      nextNumber: state.nextNumber + 1,
    );

    final wallId = state.activeWallId;
    final photoId = state.activePhotoId;
    if (wallId == null || photoId == null) return;
    try {
      await ref
          .read(routeRepositoryProvider)
          .upsertRoute(wallId, photoId, route);
    } catch (e, st) {
      debugPrint('commitRoute: persistence write-through failed: $e\n$st');
    }
  }

  /// Empties the in-progress route (points and symbols) and the undo/redo
  /// stacks.
  void clearCurrent() {
    state = state.copyWith(
      currentPoints: const [],
      currentSymbols: const [],
      undoStack: const [],
      redoStack: const [],
    );
  }

  /// Selects the route with the given [id], or clears the selection if
  /// [id] is null. No-op if [id] does not match any route in
  /// [DrawState.routes] (selectedRouteId always references a real route or
  /// is null).
  void selectRoute(int? id) {
    if (id == null) {
      state = state.copyWith(selectedRouteIdSet: true, selectedRouteId: null);
      return;
    }

    final exists = state.routes.any((r) => r.id == id);
    if (!exists) return;

    state = state.copyWith(selectedRouteIdSet: true, selectedRouteId: id);
  }

  /// Flips the `visible` flag on the route with the given [id]. No-op if
  /// [id] does not match any route.
  ///
  /// Persistence write-through: see [commitRoute] doc for the sync-mutation
  /// / no-op-without-a-wall contract shared by all write-through methods.
  Future<void> toggleRouteVisibility(int id) async {
    final index = state.routes.indexWhere((r) => r.id == id);
    if (index == -1) return;

    final routes = [...state.routes];
    routes[index] = routes[index].copyWith(visible: !routes[index].visible);
    state = state.copyWith(routes: routes);

    final wallId = state.activeWallId;
    final photoId = state.activePhotoId;
    if (wallId == null || photoId == null) return;
    try {
      await ref
          .read(routeRepositoryProvider)
          .upsertRoute(wallId, photoId, routes[index]);
    } catch (e, st) {
      debugPrint(
        'toggleRouteVisibility: persistence write-through failed: $e\n$st',
      );
    }
  }

  /// Removes the route with the given [id]. Clears [DrawState.selectedRouteId]
  /// if it pointed at the removed route.
  ///
  /// FIX #9 (MED, CONFIRMED — "removeRoute wipes the entire undo/redo
  /// history"): [DrawState.undoStack]/[DrawState.redoStack] are filtered
  /// (not wholesale cleared) to drop ONLY the [AddCommittedSymbolOp] entries
  /// that reference [id] — the ones that would otherwise dangle, since they
  /// point at a route that no longer exists (see [undo]/[redo]'s
  /// `AddCommittedSymbolOp` case, which already defensively no-ops on a
  /// missing route, but there is no reason to also discard EVERY other
  /// unrelated pending op just because one route was deleted). Every
  /// [AddPointOp], [AddCurrentSymbolOp], and any [AddCommittedSymbolOp] for
  /// a DIFFERENT route survives untouched, so undoing/redoing an unrelated
  /// in-progress draw still works immediately after a delete.
  ///
  /// No-op if [id] does not match any route.
  ///
  /// Persistence write-through: see [commitRoute] doc for the sync-mutation
  /// / no-op-without-a-wall contract shared by all write-through methods.
  Future<void> removeRoute(int id) async {
    final removedIndex = state.routes.indexWhere((r) => r.id == id);
    if (removedIndex == -1) return;
    final removedRoute = state.routes[removedIndex];

    final routes = state.routes.where((r) => r.id != id).toList();
    final clearSelection = state.selectedRouteId == id;
    bool referencesRemovedRoute(DrawOp op) =>
        op is AddCommittedSymbolOp && op.routeId == id;
    state = state.copyWith(
      routes: routes,
      selectedRouteIdSet: clearSelection,
      selectedRouteId: clearSelection ? null : state.selectedRouteId,
      undoStack: state.undoStack.where((op) => !referencesRemovedRoute(op)).toList(),
      redoStack: state.redoStack.where((op) => !referencesRemovedRoute(op)).toList(),
    );

    final wallId = state.activeWallId;
    final photoId = state.activePhotoId;
    if (wallId == null || photoId == null) return;
    try {
      await ref
          .read(routeRepositoryProvider)
          .softDeleteRoute(wallId, photoId, removedRoute.number);
    } catch (e, st) {
      debugPrint('removeRoute: persistence write-through failed: $e\n$st');
    }
  }

  /// Sets the symbol type that will be placed by [placeSymbol]. Passing
  /// null clears the active symbol.
  void setActiveSymbol(SymbolType? type) {
    state = state.copyWith(activeSymbolSet: true, activeSymbol: type);
  }

  /// Appends a [TopoSymbol] of [DrawState.activeSymbol]'s type at [percent]
  /// to a route (committed or in-progress), and returns which of the five
  /// [SymbolPlacementOutcome] cases occurred:
  ///
  /// - No [DrawState.activeSymbol] (regardless of selection/routes/
  ///   currentPoints): no-op, returns [SymbolPlacementOutcome.noActiveSymbol].
  /// - A route is already explicitly selected (via [selectRoute]) and it
  ///   still exists in [DrawState.routes]: the symbol is placed on THAT
  ///   route, [DrawState.selectedRouteId] is left unchanged, and this
  ///   returns [SymbolPlacementOutcome.placed]. Explicit intent always wins,
  ///   regardless of the two cases below.
  /// - [DrawState.mode] is [DrawMode.draw] and [DrawState.currentPoints] is
  ///   non-empty (i.e. a NEW route is actively being drawn right now):
  ///   appends the symbol to [DrawState.currentSymbols] (the in-progress,
  ///   uncommitted route) instead of any committed route, and returns
  ///   [SymbolPlacementOutcome.placed]. This is the "place a symbol while
  ///   still drawing the line" fix -- previously a symbol could only ever
  ///   attach to an already-committed route. [DrawController.commitRoute]
  ///   later folds [DrawState.currentSymbols] into the new route's
  ///   `symbols`. This case is checked BEFORE the routes.last auto-select
  ///   below -- an active in-progress draw always beats it, otherwise the
  ///   instant a wall had >=1 committed route, every draw-time placement
  ///   would silently (and incorrectly) land on `routes.last` instead of
  ///   the route actually being drawn (the reported misattribution bug).
  /// - No route is selected (or the selected id no longer exists) and the
  ///   above in-progress-draw case didn't apply (e.g. right after
  ///   [commitRoute], when [DrawState.currentPoints] is empty again), but
  ///   [DrawState.routes] is non-empty: auto-selects `routes.last` (the
  ///   most recently committed route), places the symbol there, updates
  ///   [DrawState.selectedRouteId] to point at it, and returns
  ///   [SymbolPlacementOutcome.autoSelectedAndPlaced]. This is the "auto-
  ///   select + hint" fix -- previously this case silently no-oped, leaving
  ///   a user who activated a symbol without first selecting a route stuck
  ///   with an apparently unresponsive canvas. This is how "annotate the
  ///   route I just committed" keeps working: [commitRoute] empties
  ///   [DrawState.currentPoints], so the in-progress-draw case above no
  ///   longer applies and this auto-select takes over.
  /// - Otherwise (no committed routes AND no in-progress route to attach
  ///   to): nothing to place onto, no state change, returns
  ///   [SymbolPlacementOutcome.noRouteAvailable] so the caller (see
  ///   `_TopoCanvasState._beginInteraction`) can show a hint instead of
  ///   silently doing nothing.
  ///
  /// Undo/redo: every placement (committed or in-progress) pushes a
  /// [DrawOp] onto [DrawState.undoStack] and clears [DrawState.redoStack],
  /// so [undo]/[redo] can invert/replay it like any other drawing action —
  /// see [DrawOp]'s doc for the bug this fixes.
  ///
  /// Persistence write-through: see [commitRoute] doc for the sync-mutation
  /// / no-op-without-a-wall contract shared by all write-through methods.
  Future<SymbolPlacementOutcome> placeSymbol(Offset percent) async {
    final symbolType = state.activeSymbol;
    if (symbolType == null) return SymbolPlacementOutcome.noActiveSymbol;

    final explicitId = state.selectedRouteId;
    final explicitIndex = explicitId == null
        ? -1
        : state.routes.indexWhere((r) => r.id == explicitId);

    if (explicitId != null && explicitIndex != -1) {
      return _placeOnCommittedRoute(
        index: explicitIndex,
        targetRouteId: explicitId,
        symbolType: symbolType,
        percent: percent,
        outcome: SymbolPlacementOutcome.placed,
      );
    }

    if (state.mode == DrawMode.draw && state.currentPoints.isNotEmpty) {
      final symbol = TopoSymbol(type: symbolType, position: percent);
      state = state.copyWith(
        currentSymbols: [...state.currentSymbols, symbol],
        undoStack: [...state.undoStack, AddCurrentSymbolOp(symbol)],
        redoStack: const [],
      );
      return SymbolPlacementOutcome.placed;
    }

    if (state.routes.isNotEmpty) {
      final index = state.routes.length - 1;
      return _placeOnCommittedRoute(
        index: index,
        targetRouteId: state.routes[index].id,
        symbolType: symbolType,
        percent: percent,
        outcome: SymbolPlacementOutcome.autoSelectedAndPlaced,
      );
    }

    return SymbolPlacementOutcome.noRouteAvailable;
  }

  /// Shared implementation for [placeSymbol]'s two committed-route cases
  /// (explicit selection and auto-select-`routes.last`): appends a
  /// [TopoSymbol] of [symbolType] at [percent] to the route at [index],
  /// pushes an [AddCommittedSymbolOp] onto [DrawState.undoStack] (so
  /// [undo]/[redo] know how to invert/replay it), sets
  /// [DrawState.selectedRouteId] according to [outcome] (auto-select writes
  /// it; an explicit selection is left as-is per [placeSymbol]'s doc),
  /// persists the change, and returns [outcome].
  Future<SymbolPlacementOutcome> _placeOnCommittedRoute({
    required int index,
    required int targetRouteId,
    required SymbolType symbolType,
    required Offset percent,
    required SymbolPlacementOutcome outcome,
  }) async {
    final route = state.routes[index];
    final symbol = TopoSymbol(type: symbolType, position: percent);
    final routes = [...state.routes];
    final updatedRoute = route.copyWith(symbols: [...route.symbols, symbol]);
    routes[index] = updatedRoute;
    state = state.copyWith(
      routes: routes,
      selectedRouteIdSet: outcome == SymbolPlacementOutcome.autoSelectedAndPlaced,
      selectedRouteId: targetRouteId,
      undoStack: [
        ...state.undoStack,
        AddCommittedSymbolOp(targetRouteId, symbol),
      ],
      redoStack: const [],
    );

    final wallId = state.activeWallId;
    final photoId = state.activePhotoId;
    if (wallId == null || photoId == null) return outcome;
    try {
      await ref
          .read(routeRepositoryProvider)
          .upsertRoute(wallId, photoId, updatedRoute);
    } catch (e, st) {
      debugPrint('placeSymbol: persistence write-through failed: $e\n$st');
    }
    return outcome;
  }

  /// AUTHORITATIVELY replaces free-form/grade metadata (name, grade, style,
  /// description) on the route with the given [routeId]: the resulting
  /// route's name/gradeSystem/gradeRaw/style/description are set to EXACTLY
  /// the arguments passed here, including `null` — this is a full
  /// replacement, not a partial patch. No-op if [routeId] does not match
  /// any route in [DrawState.routes].
  ///
  /// This method assumes its only caller is [RouteMetadataSheet], which
  /// always sends the sheet's complete current state on Save (every field,
  /// pre-filled from the route being edited and edited in place) — so
  /// "omitted" and "the user cleared this field" are indistinguishable and
  /// both correctly mean "clear it". Concretely: passing `name: null`
  /// clears the route's name even if it previously had one; a caller that
  /// wants to edit only one field must first read the current route and
  /// pass its other fields through unchanged (see
  /// [RouteMetadataSheet._save] for the reference caller).
  ///
  /// [TopoRoute.gradeSortKey] is always recomputed to match [gradeSystem]/
  /// [gradeRaw]: if both are provided (`gradeProvided`) and [gradeRaw] is a
  /// valid grade for [gradeSystem] (per [isValidGrade] — checked to avoid
  /// [gradeSortKey]'s `ArgumentError` on invalid input), it's recomputed
  /// from them; otherwise (grade omitted or invalid) it's cleared to
  /// `null`. This uses [TopoRoute.copyWith]'s sentinel flags (`nameSet`,
  /// `gradeSystemSet`, `gradeRawSet`, `setGradeSortKey`, `styleSet`,
  /// `descriptionSet`, all passed as `true` here) so every field —
  /// including ones passed as `null` — is written verbatim rather than
  /// falling back to the route's previous value.
  ///
  /// Persistence write-through: see [commitRoute] doc for the sync-mutation
  /// / no-op-without-a-wall contract shared by all write-through methods.
  Future<void> setRouteMetadata(
    int routeId, {
    String? name,
    GradeSystem? gradeSystem,
    String? gradeRaw,
    String? style,
    String? description,
    String? betaVideoUrl,
    List<String>? styleTags,
    int? stars,
  }) async {
    final index = state.routes.indexWhere((r) => r.id == routeId);
    if (index == -1) return;

    final gradeProvided = gradeSystem != null && gradeRaw != null;
    final newGradeSortKey = (gradeProvided && isValidGrade(gradeSystem, gradeRaw))
        ? gradeSortKey(gradeSystem, gradeRaw)
        : null;

    final routes = [...state.routes];
    final updatedRoute = routes[index].copyWith(
      name: name,
      nameSet: true,
      gradeSystem: gradeSystem,
      gradeSystemSet: true,
      gradeRaw: gradeRaw,
      gradeRawSet: true,
      gradeSortKey: newGradeSortKey,
      setGradeSortKey: true,
      style: style,
      styleSet: true,
      description: description,
      descriptionSet: true,
      betaVideoUrl: betaVideoUrl,
      betaVideoUrlSet: true,
      styleTags: styleTags ?? const [],
      styleTagsSet: true,
      stars: stars,
      starsSet: true,
    );
    routes[index] = updatedRoute;
    state = state.copyWith(routes: routes);

    final wallId = state.activeWallId;
    final photoId = state.activePhotoId;
    if (wallId == null || photoId == null) return;
    try {
      await ref
          .read(routeRepositoryProvider)
          .upsertRoute(wallId, photoId, updatedRoute);
    } catch (e, st) {
      debugPrint('setRouteMetadata: persistence write-through failed: $e\n$st');
    }
  }

  /// Synchronously clears drawing/persistence state in preparation for
  /// switching to a new photo. Callers (see [TopoCanvasScreen]) must invoke
  /// this the MOMENT a new image path is selected — synchronously, before
  /// the async `ensureDefaultForImage` → [loadForWall] chain for that photo
  /// even starts — so there is no window where [DrawState] still reflects
  /// the previous photo while a new one is visible.
  ///
  /// Clears [DrawState.routes], [DrawState.currentPoints],
  /// [DrawState.currentSymbols], [DrawState.undoStack]/
  /// [DrawState.redoStack], and [DrawState.selectedRouteId], and —
  /// crucially — nulls out [DrawState.activeWallId]/
  /// [DrawState.activePhotoId]. Since
  /// every write-through method ([commitRoute], [toggleRouteVisibility],
  /// [removeRoute], [placeSymbol]) no-ops its persistence step when
  /// [DrawState.activeWallId] is null, this closes the race where a route
  /// committed after a new photo is shown but before [loadForWall] resolves
  /// would otherwise persist against the PREVIOUS wall: with
  /// [activeWallId] null, that commit only mutates in-memory state (which
  /// [loadForWall] then overwrites once it resolves), and never reaches the
  /// database.
  ///
  /// [DrawState.mode] and [DrawState.activeSymbol] are deliberately left
  /// as-is: they're tool/UI choices, not per-photo state, so switching
  /// photos shouldn't reset draw mode or the selected symbol.
  ///
  /// FIX #4 (HIGH, CONFIRMED): also sets [DrawState.isSwitchingPhoto], so
  /// the corresponding [loadForWall] call for the new photo knows any
  /// [DrawState.routes] present when IT resolves were necessarily committed
  /// during its own await (this method just cleared [DrawState.routes] to
  /// empty) and must be merged/preserved rather than silently discarded —
  /// see [loadForWall]'s doc for the full fix.
  ///
  /// FIX #4 (continued, CONFIRMED — "second switch before the first
  /// resolves loses the pending commit"): always bumps
  /// [DrawState.switchGeneration] (see that field's doc — this is what lets
  /// [loadForWall] detect an out-of-order/superseded resolution). AND, if
  /// [DrawState.isSwitchingPhoto] is ALREADY `true` when this runs, [routes]
  /// is deliberately left alone (NOT wiped to `[]`) rather than
  /// unconditionally cleared: `isSwitchingPhoto` already being `true` means
  /// a PREVIOUS switch's [loadForWall] hasn't resolved yet, so anything in
  /// [DrawState.routes] right now can only be a route [DrawController
  /// .commitRoute] committed in-memory during that still-pending switch
  /// (never persisted — [DrawState.activeWallId] has been null since the
  /// first [beginPhotoSwitch] in the chain) — wiping it here would discard
  /// it with no way to recover it. It is instead carried forward as-is;
  /// whichever [loadForWall] call turns out to be CURRENT when it resolves
  /// (per [DrawState.switchGeneration]) merges it in exactly like the
  /// single-switch case, so a route survives being committed across any
  /// number of rapid-fire photo switches, not just one. When
  /// [DrawState.isSwitchingPhoto] is already `false` (the ordinary case —
  /// no switch was in flight), [routes] holds the previous, fully-settled
  /// photo's own routes and is cleared exactly as before, so the canvas
  /// never shows a stale mix while the new photo loads.
  ///
  /// IMPORTANT for callers: every call to this method must eventually be
  /// followed by either [loadForWall] (the normal case) or [cancelPhotoSwitch]
  /// (if it turns out there is nothing to load) — see [cancelPhotoSwitch]'s
  /// doc for why skipping both leaves [DrawState.isSwitchingPhoto] stuck
  /// `true` forever, corrupting the NEXT switch's routes handling above.
  ///
  /// Returns the [DrawState.switchGeneration] value this call just set —
  /// callers that may later call [cancelPhotoSwitch] (across an `await`
  /// gap) should hold onto it and pass it there, so that call can detect
  /// whether a NEWER switch has since superseded this one.
  int beginPhotoSwitch() {
    final alreadySwitching = state.isSwitchingPhoto;
    state = state.copyWith(
      routes: alreadySwitching ? state.routes : const [],
      currentPoints: const [],
      currentSymbols: const [],
      undoStack: const [],
      redoStack: const [],
      selectedRouteIdSet: true,
      selectedRouteId: null,
      activeWallIdSet: true,
      activeWallId: null,
      activePhotoIdSet: true,
      activePhotoId: null,
      isSwitchingPhoto: true,
      switchGeneration: state.switchGeneration + 1,
      // FIX #4 (continued): the new switch's destination isn't known yet
      // (only the loadForWall call that follows this one will know it, and
      // set it itself) -- so any leftover switchTargetPhotoId from whatever
      // switch was previously in flight is stale the moment a NEWER switch
      // starts, and must not be misread as "still heading towards the old
      // target". See DrawState.switchTargetPhotoId's doc.
      switchTargetPhotoIdSet: true,
      switchTargetPhotoId: null,
    );
    return state.switchGeneration;
  }

  /// FIX #4 (continued, CONFIRMED — "a switch nothing ever settles leaves
  /// isSwitchingPhoto stuck true, wrongly preserving a LATER stray route
  /// into an unrelated wall"): call this when a [beginPhotoSwitch]-opened
  /// switch turns out to have nothing to load, so [loadForWall] — the
  /// only other place that clears [DrawState.isSwitchingPhoto] — will
  /// never run for it. Concretely: [TopoCanvasScreen.loadWallOriginalPhoto]
  /// calls this when the target wall has no photo at all, and
  /// [TopoCanvasScreen._handleDeletePhoto] calls this when deleting the
  /// active photo leaves the wall with none.
  ///
  /// Without this, [DrawState.isSwitchingPhoto] would stay `true` forever,
  /// and the NEXT [beginPhotoSwitch] call — for a completely unrelated
  /// LATER wall — would misread that stale `true` as "a real switch is
  /// still in flight" and wrongly carry forward whatever ended up in
  /// [DrawState.routes] in the meantime (see that method's doc), instead
  /// of clearing it like the ordinary case. Concretely, this is the fix
  /// for a reproduced regression: enter a photo-less wall B (nothing to
  /// load) and commit a stray route there (in-memory only, since
  /// [DrawState.activeWallId] is null) — without this call, that stray
  /// route would survive into whichever wall is entered NEXT and get
  /// persisted there.
  ///
  /// Only ever flips [DrawState.isSwitchingPhoto] back to `false` —
  /// [DrawState.routes] is deliberately left exactly as-is; it's the NEXT
  /// [beginPhotoSwitch] call that clears it, now correctly seeing
  /// `isSwitchingPhoto == false`. No-op if a switch isn't actually open
  /// (idempotent / safe to call defensively).
  ///
  /// [generation] must be the value [beginPhotoSwitch] returned for the
  /// switch being cancelled. If [DrawState.switchGeneration] has since
  /// moved on (i.e. a NEWER [beginPhotoSwitch] ran in the `await` gap
  /// between that call and this one — the exact same out-of-order hazard
  /// [loadForWall] guards against, see that method's doc), this is a no-op:
  /// that newer switch is the one now in flight, and settling it is
  /// whichever [loadForWall]/[cancelPhotoSwitch] call corresponds to IT,
  /// not this stale one. Calling this unconditionally (ignoring
  /// [generation]) would risk wrongly marking that unrelated newer switch
  /// as settled while its own [loadForWall] is still genuinely pending.
  void cancelPhotoSwitch(int generation) {
    if (state.switchGeneration != generation) return;
    if (!state.isSwitchingPhoto) return;
    // FIX #4 (continued): also clears switchTargetPhotoId -- with no
    // loadForWall coming for this switch, whatever target it may have
    // acquired (or, more likely, the null it still holds since loadForWall
    // never ran) is settled along with isSwitchingPhoto itself. See
    // DrawState.switchTargetPhotoId's doc.
    state = state.copyWith(
      isSwitchingPhoto: false,
      switchTargetPhotoIdSet: true,
      switchTargetPhotoId: null,
    );
  }

  /// Loads persisted routes for [wallId]/[photoId] from the repository,
  /// replacing [DrawState.routes] and resetting in-progress drawing state
  /// (current points, redo stack, selection). Seeds [DrawState.nextNumber]
  /// / [DrawState.nextId] from the loaded routes so subsequently committed
  /// routes continue the existing numbering.
  ///
  /// After this call, [DrawState.activeWallId]/[DrawState.activePhotoId] are
  /// set, which switches on write-through persistence for
  /// [commitRoute]/[placeSymbol]/[toggleRouteVisibility]/[removeRoute].
  ///
  /// FIX #4 (HIGH, CONFIRMED — "route committed during photo-switch is
  /// discarded"): if [DrawState.isSwitchingPhoto] is set (i.e. this call is
  /// the second half of a [beginPhotoSwitch]-started switch — see that
  /// method's doc), any [DrawState.routes] present the moment [loadRoutes]
  /// resolves were necessarily COMMITTED during this very `await` (
  /// [beginPhotoSwitch] cleared [DrawState.routes] to empty right before
  /// this call started, and nothing else can populate it in between) and
  /// are preserved: merged after the freshly-[loaded] list — re-issued
  /// fresh ids/numbers continuing after `loaded`'s own (which are
  /// independently sequential 1..n for THIS photo, so a pending route's own
  /// leftover id/number could otherwise collide) — and, now that a real
  /// [wallId]/[photoId] is finally known, persisted for real (their
  /// original [commitRoute] call could only mutate in-memory state, since
  /// [DrawState.activeWallId] was null at the time — see that method's
  /// doc).
  ///
  /// When [DrawState.isSwitchingPhoto] is NOT set (e.g. this is the very
  /// first load, or a caller invokes this directly without a preceding
  /// [beginPhotoSwitch]), [DrawState.routes] is unconditionally REPLACED by
  /// [loaded] exactly as before — this is relied on by the "switching
  /// walls" test, which calls this back-to-back without
  /// [beginPhotoSwitch] and expects the previous wall's routes to be fully
  /// discarded, not merged in.
  ///
  /// FIX #4 (continued, CONFIRMED — "out-of-order loadForWall resolution
  /// clobbers the newer photo"): captures [DrawState.switchGeneration] the
  /// moment this call starts (before the `await` below), and re-checks it
  /// once the repository read resolves. If some OTHER [beginPhotoSwitch]
  /// ran in the meantime (i.e. the user switched to yet another photo
  /// while this call was still awaiting), the counter will have moved on
  /// and this call's result is stale: applying it now would clobber
  /// whichever photo the user has since moved to (routes AND
  /// [DrawState.activeWallId]/[DrawState.activePhotoId]) with THIS call's
  /// wrong-photo data, purely because it happened to resolve later. This
  /// call bails out instead, leaving whatever the current/newer switch has
  /// already applied (or will apply) completely untouched — no state
  /// mutation, no persistence write-through, nothing lost: any route
  /// pending merge from a mid-switch commit is still sitting in
  /// [DrawState.routes] (carried forward across [beginPhotoSwitch] calls —
  /// see that method's doc) and will be picked up by whichever
  /// [loadForWall] call IS current when it resolves.
  ///
  /// FIX #4 (continued, CONFIRMED — "deleting the photo you are currently
  /// switching TO is unaware its target is gone"): sets
  /// [DrawState.switchTargetPhotoId] to [photoId] synchronously, before the
  /// `await` below, so [DrawState.activePhotoId] being null for this call's
  /// entire duration doesn't ALSO mean "no photo is relevant right now" —
  /// see that field's doc. Cleared back to null below once this call
  /// actually applies its result (the generation check having passed),
  /// since the destination is [DrawState.activePhotoId] by then and there's
  /// no separate in-flight target left to track. Left untouched on the
  /// stale/superseded early return just below: this call's target may
  /// already have been overwritten by a newer [beginPhotoSwitch]/
  /// [loadForWall] pair, and that newer state must not be clobbered by a
  /// stale call bailing out.
  Future<void> loadForWall(String wallId, String photoId) async {
    final myGeneration = state.switchGeneration;
    state = state.copyWith(
      switchTargetPhotoIdSet: true,
      switchTargetPhotoId: photoId,
    );
    final loaded = await ref
        .read(routeRepositoryProvider)
        .loadRoutes(wallId, photoId);

    if (state.switchGeneration != myGeneration) {
      return;
    }

    final wasSwitching = state.isSwitchingPhoto;
    final pending = wasSwitching ? state.routes : const <TopoRoute>[];

    final loadedMaxId = loaded.isEmpty
        ? 0
        : loaded.map((r) => r.id).reduce((a, b) => a > b ? a : b);
    final loadedMaxNumber = loaded.isEmpty
        ? 0
        : loaded.map((r) => r.number).reduce((a, b) => a > b ? a : b);

    final preserved = <TopoRoute>[
      for (var i = 0; i < pending.length; i++)
        pending[i].copyWith(
          id: loadedMaxId + 1 + i,
          number: loadedMaxNumber + 1 + i,
        ),
    ];

    final routes = [...loaded, ...preserved];
    final maxNumber = routes.isEmpty
        ? 0
        : routes.map((r) => r.number).reduce((a, b) => a > b ? a : b);
    // loadRoutes assigns sequential ids 1..loaded.length, and `preserved`
    // continues immediately after (loadedMaxId + 1, + 2, ...), so the
    // combined list's ids are still exactly 1..routes.length.
    final nextId = routes.length + 1;

    state = state.copyWith(
      routes: routes,
      currentPoints: const [],
      currentSymbols: const [],
      undoStack: const [],
      redoStack: const [],
      selectedRouteIdSet: true,
      selectedRouteId: null,
      nextId: nextId,
      nextNumber: maxNumber + 1,
      activeWallIdSet: true,
      activeWallId: wallId,
      activePhotoIdSet: true,
      activePhotoId: photoId,
      isSwitchingPhoto: false,
      switchTargetPhotoIdSet: true,
      switchTargetPhotoId: null,
    );

    for (final route in preserved) {
      try {
        await ref
            .read(routeRepositoryProvider)
            .upsertRoute(wallId, photoId, route);
      } catch (e, st) {
        debugPrint(
          'loadForWall: persisting a route committed mid-switch failed: '
          '$e\n$st',
        );
      }
    }
  }
}

/// FIX #6 (HIGH, CONFIRMED — "family-key the canvas providers by wallId"):
/// keyed by wallId (the same string [TopoCanvasScreen.wallId] carries) so
/// two simultaneously-mounted [TopoCanvasScreen]s (e.g. the read-only
/// embedded canvas inside a community topo-detail page for wall A, plus a
/// pushed editor for wall B) each get their OWN [DrawController]/[DrawState]
/// instead of clobbering a single shared app-lifetime global. `autoDispose`
/// so a wall's controller (and all its in-memory draw/undo/redo state) is
/// torn down once nothing is watching it anymore (i.e. its screen is
/// popped) and a fresh one is built the next time that wall (or any wall)
/// is opened — preserving the pre-family "opens in a clean state" behavior
/// instead of leaking state across re-opens forever.
final drawControllerProvider =
    NotifierProvider.autoDispose.family<DrawController, DrawState, String>(
  DrawController.new,
);
