import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:climbtopo/core/db/database_provider.dart';
import 'package:climbtopo/core/grades/grade_system.dart';
import 'package:climbtopo/features/topo/domain/topo_route.dart';

/// Whether the topo canvas is in passive viewing mode or active route
/// drawing mode.
enum DrawMode { view, draw }

/// Immutable state for the topo route drawing feature.
///
/// [currentPoints] and the points inside [routes] are expressed in percent
/// space (i.e. coordinates normalized to the image's width/height), so they
/// stay valid regardless of how the image is scaled or panned on screen.
class DrawState {
  const DrawState({
    this.mode = DrawMode.view,
    this.currentPoints = const [],
    this.routes = const [],
    this.redoStack = const [],
    this.selectedRouteId,
    this.activeSymbol,
    this.nextId = 1,
    this.nextNumber = 1,
    this.activeWallId,
    this.activePhotoId,
  });

  final DrawMode mode;
  final List<Offset> currentPoints;
  final List<TopoRoute> routes;

  /// The wall this controller is currently loaded/persisting against, or
  /// null if [loadForWall] has never been called (in which case all
  /// persistence write-through is a no-op — see [DrawController]).
  final String? activeWallId;

  /// The photo (within [activeWallId]) routes are persisted against.
  final String? activePhotoId;

  /// Points popped off [currentPoints] by [undo], available to be replayed
  /// by [redo]. Any new point added via [addPoint] clears this stack.
  final List<Offset> redoStack;

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
    List<TopoRoute>? routes,
    List<Offset>? redoStack,
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
  }) {
    return DrawState(
      mode: mode ?? this.mode,
      currentPoints: currentPoints ?? this.currentPoints,
      routes: routes ?? this.routes,
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
    );
  }
}

/// Manages [DrawState] for the topo canvas: draw/view mode, the in-progress
/// route being drawn, undo/redo, committing finished routes, route
/// selection/visibility, and placing symbols on the selected route.
class DrawController extends Notifier<DrawState> {
  @override
  DrawState build() => const DrawState();

  /// Flips between [DrawMode.view] and [DrawMode.draw].
  void toggleMode() {
    setMode(state.mode == DrawMode.view ? DrawMode.draw : DrawMode.view);
  }

  void setMode(DrawMode mode) {
    state = state.copyWith(mode: mode);
  }

  /// Appends [p] to the in-progress route and clears the redo stack.
  void addPoint(Offset p) {
    state = state.copyWith(
      currentPoints: [...state.currentPoints, p],
      redoStack: const [],
    );
  }

  /// Pops the last point off [DrawState.currentPoints] onto the redo stack.
  /// No-op if there are no current points.
  void undo() {
    if (state.currentPoints.isEmpty) return;

    final points = [...state.currentPoints];
    final popped = points.removeLast();
    state = state.copyWith(
      currentPoints: points,
      redoStack: [...state.redoStack, popped],
    );
  }

  /// Pushes the last undone point back onto [DrawState.currentPoints].
  /// No-op if the redo stack is empty.
  void redo() {
    if (state.redoStack.isEmpty) return;

    final redo = [...state.redoStack];
    final restored = redo.removeLast();
    state = state.copyWith(
      currentPoints: [...state.currentPoints, restored],
      redoStack: redo,
    );
  }

  /// Replaces the point at [index] with [q], leaving all other points
  /// unchanged. No-op if [index] is out of range.
  void movePoint(int index, Offset q) {
    if (index < 0 || index >= state.currentPoints.length) return;

    final points = [...state.currentPoints];
    points[index] = q;
    state = state.copyWith(currentPoints: points);
  }

  /// If there are at least 2 current points, moves them into [DrawState.routes]
  /// as a new [TopoRoute] and empties [DrawState.currentPoints] and the redo
  /// stack. No-op otherwise.
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
      colorIndex: routeColorIndexFor(state.nextNumber),
    );

    state = state.copyWith(
      routes: [...state.routes, route],
      currentPoints: const [],
      redoStack: const [],
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

  /// Empties the in-progress route and the redo stack.
  void clearCurrent() {
    state = state.copyWith(currentPoints: const [], redoStack: const []);
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
  /// if it pointed at the removed route. No-op if [id] does not match any
  /// route.
  ///
  /// Persistence write-through: see [commitRoute] doc for the sync-mutation
  /// / no-op-without-a-wall contract shared by all write-through methods.
  Future<void> removeRoute(int id) async {
    final removedIndex = state.routes.indexWhere((r) => r.id == id);
    if (removedIndex == -1) return;
    final removedRoute = state.routes[removedIndex];

    final routes = state.routes.where((r) => r.id != id).toList();
    final clearSelection = state.selectedRouteId == id;
    state = state.copyWith(
      routes: routes,
      selectedRouteIdSet: clearSelection,
      selectedRouteId: clearSelection ? null : state.selectedRouteId,
    );

    final wallId = state.activeWallId;
    if (wallId == null) return;
    try {
      await ref
          .read(routeRepositoryProvider)
          .softDeleteRoute(wallId, removedRoute.number);
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
  /// to the currently selected route. No-op if there is no selected route
  /// or no active symbol.
  ///
  /// Persistence write-through: see [commitRoute] doc for the sync-mutation
  /// / no-op-without-a-wall contract shared by all write-through methods.
  Future<void> placeSymbol(Offset percent) async {
    final selectedId = state.selectedRouteId;
    final symbolType = state.activeSymbol;
    if (selectedId == null || symbolType == null) return;

    final index = state.routes.indexWhere((r) => r.id == selectedId);
    if (index == -1) return;

    final route = state.routes[index];
    final routes = [...state.routes];
    final updatedRoute = route.copyWith(
      symbols: [
        ...route.symbols,
        TopoSymbol(type: symbolType, position: percent),
      ],
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
      debugPrint('placeSymbol: persistence write-through failed: $e\n$st');
    }
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
  /// [DrawState.redoStack], and [DrawState.selectedRouteId], and — crucially
  /// — nulls out [DrawState.activeWallId]/[DrawState.activePhotoId]. Since
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
  void beginPhotoSwitch() {
    state = state.copyWith(
      routes: const [],
      currentPoints: const [],
      redoStack: const [],
      selectedRouteIdSet: true,
      selectedRouteId: null,
      activeWallIdSet: true,
      activeWallId: null,
      activePhotoIdSet: true,
      activePhotoId: null,
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
  Future<void> loadForWall(String wallId, String photoId) async {
    final loaded = await ref.read(routeRepositoryProvider).loadRoutes(wallId);

    final maxNumber = loaded.isEmpty
        ? 0
        : loaded.map((r) => r.number).reduce((a, b) => a > b ? a : b);
    // loadRoutes assigns sequential ids 1..n, so the largest id is always
    // loaded.length.
    final nextId = loaded.length + 1;

    state = state.copyWith(
      routes: loaded,
      currentPoints: const [],
      redoStack: const [],
      selectedRouteIdSet: true,
      selectedRouteId: null,
      nextId: nextId,
      nextNumber: maxNumber + 1,
      activeWallIdSet: true,
      activeWallId: wallId,
      activePhotoIdSet: true,
      activePhotoId: photoId,
    );
  }
}

final drawControllerProvider = NotifierProvider<DrawController, DrawState>(
  DrawController.new,
);
