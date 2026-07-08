import 'dart:ui';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Whether the topo canvas is in passive viewing mode or active route
/// drawing mode.
enum DrawMode { view, draw }

/// Immutable state for the topo route drawing feature.
///
/// [currentPoints] and [completedRoutes] are expressed in percent space
/// (i.e. coordinates normalized to the image's width/height), so they stay
/// valid regardless of how the image is scaled or panned on screen.
class DrawState {
  const DrawState({
    this.mode = DrawMode.view,
    this.currentPoints = const [],
    this.completedRoutes = const [],
    this.redoStack = const [],
  });

  final DrawMode mode;
  final List<Offset> currentPoints;
  final List<List<Offset>> completedRoutes;

  /// Points popped off [currentPoints] by [undo], available to be replayed
  /// by [redo]. Any new point added via [addPoint] clears this stack.
  final List<Offset> redoStack;

  DrawState copyWith({
    DrawMode? mode,
    List<Offset>? currentPoints,
    List<List<Offset>>? completedRoutes,
    List<Offset>? redoStack,
  }) {
    return DrawState(
      mode: mode ?? this.mode,
      currentPoints: currentPoints ?? this.currentPoints,
      completedRoutes: completedRoutes ?? this.completedRoutes,
      redoStack: redoStack ?? this.redoStack,
    );
  }
}

/// Manages [DrawState] for the topo canvas: draw/view mode, the in-progress
/// route being drawn, undo/redo, and committing finished routes.
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

  /// If there are at least 2 current points, moves them into
  /// [DrawState.completedRoutes] as a new route and empties
  /// [DrawState.currentPoints] and the redo stack. No-op otherwise.
  void commitRoute() {
    if (state.currentPoints.length < 2) return;

    state = state.copyWith(
      completedRoutes: [
        ...state.completedRoutes,
        [...state.currentPoints],
      ],
      currentPoints: const [],
      redoStack: const [],
    );
  }

  /// Empties the in-progress route and the redo stack.
  void clearCurrent() {
    state = state.copyWith(currentPoints: const [], redoStack: const []);
  }
}

final drawControllerProvider = NotifierProvider<DrawController, DrawState>(
  DrawController.new,
);
