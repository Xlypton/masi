import 'dart:ui';

import 'package:flutter_riverpod/flutter_riverpod.dart';

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
  });

  final DrawMode mode;
  final List<Offset> currentPoints;
  final List<TopoRoute> routes;

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
  void commitRoute() {
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
  void toggleRouteVisibility(int id) {
    final index = state.routes.indexWhere((r) => r.id == id);
    if (index == -1) return;

    final routes = [...state.routes];
    routes[index] = routes[index].copyWith(visible: !routes[index].visible);
    state = state.copyWith(routes: routes);
  }

  /// Removes the route with the given [id]. Clears [DrawState.selectedRouteId]
  /// if it pointed at the removed route. No-op if [id] does not match any
  /// route.
  void removeRoute(int id) {
    final exists = state.routes.any((r) => r.id == id);
    if (!exists) return;

    final routes = state.routes.where((r) => r.id != id).toList();
    final clearSelection = state.selectedRouteId == id;
    state = state.copyWith(
      routes: routes,
      selectedRouteIdSet: clearSelection,
      selectedRouteId: clearSelection ? null : state.selectedRouteId,
    );
  }

  /// Sets the symbol type that will be placed by [placeSymbol]. Passing
  /// null clears the active symbol.
  void setActiveSymbol(SymbolType? type) {
    state = state.copyWith(activeSymbolSet: true, activeSymbol: type);
  }

  /// Appends a [TopoSymbol] of [DrawState.activeSymbol]'s type at [percent]
  /// to the currently selected route. No-op if there is no selected route
  /// or no active symbol.
  void placeSymbol(Offset percent) {
    final selectedId = state.selectedRouteId;
    final symbolType = state.activeSymbol;
    if (selectedId == null || symbolType == null) return;

    final index = state.routes.indexWhere((r) => r.id == selectedId);
    if (index == -1) return;

    final route = state.routes[index];
    final routes = [...state.routes];
    routes[index] = route.copyWith(
      symbols: [...route.symbols, TopoSymbol(type: symbolType, position: percent)],
    );
    state = state.copyWith(routes: routes);
  }
}

final drawControllerProvider = NotifierProvider<DrawController, DrawState>(
  DrawController.new,
);
