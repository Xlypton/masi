import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:climbtopo/core/coordinates/coordinate_transformer.dart';
import 'package:climbtopo/features/topo/application/draw_controller.dart';
import 'package:climbtopo/features/topo/domain/route_hit_test.dart';
import 'package:climbtopo/features/topo/presentation/grade_colors.dart';
import 'package:climbtopo/features/topo/presentation/route_palette.dart';
import 'package:climbtopo/features/topo/presentation/topo_painter.dart';

/// Logical-pixel radius (independent of zoom level) within which a tap or
/// drag-start is considered to have hit an existing point handle rather than
/// starting a brand new point. Also reused (converted to percent space) as
/// the route-hit-test threshold for view-mode tap-to-select.
const double _handleHitRadiusPx = 20.0;

/// Maximum movement (in logical px, between pointer-down and pointer-up)
/// for a view-mode gesture to be treated as a tap (route select/deselect)
/// rather than the start of an [InteractiveViewer] pan/zoom drag.
const double _tapMovementSlopPx = 8.0;

/// The interactive topo image canvas: renders the selected photo with the
/// current/completed routes painted on top via [TopoPainter], and, while in
/// [DrawMode.draw], lets the user tap to add points or drag existing points
/// to reposition them.
///
/// [imageSize] is the *decoded* natural size of the image at [imagePath].
/// It's passed in explicitly (rather than resolved internally by this
/// widget) for two reasons: it's needed to build the [TopoPainter] and to
/// convert between percent-space route coordinates (see [DrawState]) and
/// scene/pixel coordinates, and — importantly for testability — it lets
/// this widget be pumped directly in widget tests with a fixed, known size
/// and an identity [transformationController], giving deterministic
/// coordinate math without ever needing a real decodable image file on
/// disk. [TopoCanvasScreen] owns resolving the real image's natural size
/// (asynchronously, via an [ImageStream]) and only builds this widget once
/// that size is known.
class TopoCanvas extends ConsumerStatefulWidget {
  const TopoCanvas({
    super.key,
    required this.imagePath,
    required this.imageSize,
    required this.transformationController,
  });

  /// Filesystem path of the selected topo photo.
  final String imagePath;

  /// The natural (decoded) size of the image at [imagePath].
  final Size imageSize;

  /// Shared with the owning screen so pan/zoom state (and coordinate
  /// mapping via [TransformationController.toScene]) persists across
  /// draw/view mode switches.
  final TransformationController transformationController;

  @override
  ConsumerState<TopoCanvas> createState() => _TopoCanvasState();
}

class _TopoCanvasState extends ConsumerState<TopoCanvas> {
  /// Index into `DrawState.currentPoints` currently being dragged, or null
  /// if the user isn't mid-drag on an existing handle.
  int? _draggingIndex;

  /// The pointer id that started the current down/move/up interaction, or
  /// null when no interaction is in progress. Guards against a second
  /// finger touching down mid-drag from hijacking or prematurely ending it:
  /// only move/up/cancel events whose `event.pointer` matches this id are
  /// honored (see [_beginInteraction]/[_updateInteraction]/[_endInteraction]).
  int? _activePointer;

  /// Whether [_applyFitScaleOnce] has already run. Fit-to-viewport is a
  /// one-time initialization: it must never stomp the user's subsequent
  /// manual pan/zoom, so it's guarded both by this flag and by only firing
  /// when the controller is still at identity (see [_applyFitScaleOnce]).
  bool _didApplyInitialFit = false;

  /// The pointer id that started the current view-mode down/up interaction
  /// (see [_beginViewTap]/[_endViewTap]), or null when none is in progress.
  int? _viewTapPointer;

  /// The viewport-local position at which [_viewTapPointer] went down, used
  /// by [_endViewTap] to measure total movement and decide tap vs. drag.
  Offset? _viewTapDownPosition;

  double get _currentScale =>
      widget.transformationController.value.getMaxScaleOnAxis();

  /// Computes the scale at which [widget.imageSize] fits entirely within a
  /// viewport of [viewportSize] (letterboxed on whichever axis has slack).
  double _fitScale(Size viewportSize) {
    if (widget.imageSize.width <= 0 || widget.imageSize.height <= 0) {
      return 1.0;
    }
    final widthScale = viewportSize.width / widget.imageSize.width;
    final heightScale = viewportSize.height / widget.imageSize.height;
    final scale = widthScale < heightScale ? widthScale : heightScale;
    return scale > 0 ? scale : 1.0;
  }

  /// The `minScale` to hand to [InteractiveViewer]: normally the fit scale
  /// (so the user can always zoom out to see the whole wall), but clamped
  /// to (0, 1.0] and — if the image already fits at 1x (fitScale >= 1,
  /// i.e. a small image in a big viewport) — capped at the previous
  /// hardcoded default of 0.5 rather than allowing zooming *out* past the
  /// image's natural size.
  double _minScaleFor(double fitScale) {
    if (fitScale >= 1.0) return fitScale < 0.5 ? fitScale : 0.5;
    return fitScale > 0 ? fitScale : 0.5;
  }

  /// The `maxScale` to hand to [InteractiveViewer]: at least 5.0 (the
  /// previous hardcoded default), but scaled up relative to a very small
  /// fit scale so zooming in still spans a meaningful range for huge
  /// photos fit into a small viewport.
  double _maxScaleFor(double fitScale) {
    final scaled = fitScale * 20;
    return scaled > 5.0 ? scaled : 5.0;
  }

  /// Runs exactly once (per [_didApplyInitialFit]), the first time both
  /// [widget.imageSize] and the [InteractiveViewer]'s viewport
  /// [constraints] are known, to initialize
  /// [widget.transformationController] to [fitScale] centered in the
  /// viewport. Only applies if the controller is still at its default
  /// identity matrix, so a caller that seeds/injects a
  /// non-identity/pre-seeded controller (as widget tests do) is left
  /// alone, and so this never overwrites a user's manual pan/zoom that may
  /// have happened between frames.
  ///
  /// Because [CoordinateTransformer.sceneToPercent]/`toScene` work off the
  /// controller's *live* matrix (see `TopoCanvas` doc comment / call sites
  /// in [_beginInteraction] etc.), initializing the controller to a pure
  /// scale+translate here does not change what "scene space" means — scene
  /// space is still `widget.imageSize`-sized pixels, `toScene` just now
  /// inverts a matrix that starts pre-zoomed/pre-centered instead of at
  /// identity. Percent math (`sceneToPercent`/`percentToScene`) is
  /// unaffected either way since it never reads the transform directly.
  void _applyFitScaleOnce(Size viewportSize) {
    if (_didApplyInitialFit) return;
    if (viewportSize.width <= 0 || viewportSize.height <= 0) return;
    if (widget.transformationController.value != Matrix4.identity()) {
      // A test (or future caller) supplied a non-identity/pre-seeded
      // controller; leave it exactly as given.
      _didApplyInitialFit = true;
      return;
    }
    _didApplyInitialFit = true;

    final fitScale = _fitScale(viewportSize);
    final scaledWidth = widget.imageSize.width * fitScale;
    final scaledHeight = widget.imageSize.height * fitScale;
    final dx = (viewportSize.width - scaledWidth) / 2;
    final dy = (viewportSize.height - scaledHeight) / 2;

    // Equivalent to `Matrix4.identity()..translate(dx, dy)..scale(fitScale)`
    // (translate-then-scale composition: scale first, then translate the
    // scaled image into the centered position), built via setEntry instead
    // since Matrix4.translate/scale are deprecated in favor of the
    // ByVector3/ByDouble variants, none of which read as more legible here
    // than writing the resulting matrix entries directly.
    final matrix = Matrix4.identity()
      ..setEntry(0, 0, fitScale)
      ..setEntry(1, 1, fitScale)
      ..setEntry(2, 2, fitScale)
      ..setEntry(0, 3, dx)
      ..setEntry(1, 3, dy);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.transformationController.value = matrix;
    });
  }

  /// Returns the index of the `currentPoints` handle under [sceneTap], if
  /// any, within a zoom-adjusted hit radius (so the handle stays roughly
  /// the same tappable size on screen regardless of zoom level). If more
  /// than one handle is within the threshold, the NEAREST one wins (rather
  /// than the first one encountered in iteration order).
  int? _hitTestHandle(Offset sceneTap, List<Offset> currentPointsPercent) {
    final scale = _currentScale;
    final thresholdScenePx = _handleHitRadiusPx / (scale == 0 ? 1 : scale);
    int? nearestIndex;
    double nearestDistance = double.infinity;
    for (var i = 0; i < currentPointsPercent.length; i++) {
      final scenePoint = CoordinateTransformer.percentToScene(
        currentPointsPercent[i],
        widget.imageSize,
      );
      final distance = (scenePoint - sceneTap).distance;
      if (distance <= thresholdScenePx && distance < nearestDistance) {
        nearestIndex = i;
        nearestDistance = distance;
      }
    }
    return nearestIndex;
  }

  /// Handles a pointer going down: hit-test against existing points and
  /// either begin dragging the hit point, or add a brand new one at the
  /// tapped location. Used for both a plain tap (down immediately followed
  /// by up with no movement) and the start of a drag.
  ///
  /// Claims [pointerId] as the sole active pointer for this interaction
  /// (see [_activePointer] doc) so a second finger touching down while this
  /// one is still down/dragging is ignored by
  /// [_updateInteraction]/[_endInteraction] rather than being able to
  /// hijack or prematurely end it.
  void _beginInteraction(int pointerId, Offset viewportLocalPosition) {
    // A pointer is already down/dragging: ignore this second (or later)
    // finger entirely rather than re-latching onto it. Without this guard,
    // a second finger's down event would overwrite `_activePointer`,
    // letting it hijack an in-progress drag or (worse) place an extra
    // point/symbol of its own — see class-level doc + Fix 1 for the bug
    // this prevents. The first finger keeps sole ownership of the gesture
    // until its own up/cancel clears `_activePointer` (see
    // [_endInteraction]).
    if (_activePointer != null) return;
    _activePointer = pointerId;
    final scene = widget.transformationController.toScene(
      viewportLocalPosition,
    );
    final drawState = ref.read(drawControllerProvider);

    if (drawState.activeSymbol != null) {
      // Symbol-placement mode: a tap places a symbol of the active type
      // onto the selected route (the controller no-ops if none is
      // selected) rather than adding/dragging a route point. Fires on
      // pointer-down (mirroring addPoint below) rather than waiting for
      // pointer-up, so a plain tap (down immediately followed by up with
      // no movement, as `tester.tapAt` simulates) places exactly one
      // symbol; dragging isn't a supported symbol-placement gesture.
      _draggingIndex = null;
      final percent = CoordinateTransformer.sceneToPercent(
        scene,
        widget.imageSize,
      );
      ref.read(drawControllerProvider.notifier).placeSymbol(percent);
      return;
    }

    final hitIndex = _hitTestHandle(scene, drawState.currentPoints);
    if (hitIndex != null) {
      _draggingIndex = hitIndex;
      return;
    }
    _draggingIndex = null;
    final percent = CoordinateTransformer.sceneToPercent(
      scene,
      widget.imageSize,
    );
    ref.read(drawControllerProvider.notifier).addPoint(percent);
  }

  /// Handles pointer movement: ignored if [pointerId] isn't the pointer
  /// that started the current interaction, or if [_beginInteraction] didn't
  /// start a drag on an existing point (i.e. [_draggingIndex] is unset).
  void _updateInteraction(int pointerId, Offset viewportLocalPosition) {
    if (pointerId != _activePointer) return;
    final draggingIndex = _draggingIndex;
    if (draggingIndex == null) return;
    final scene = widget.transformationController.toScene(
      viewportLocalPosition,
    );
    final percent = CoordinateTransformer.sceneToPercent(
      scene,
      widget.imageSize,
    );
    ref.read(drawControllerProvider.notifier).movePoint(draggingIndex, percent);
  }

  /// Ends the current interaction, but only if [pointerId] is the pointer
  /// that started it — an up/cancel from an unrelated second pointer must
  /// not clear the in-progress drag.
  void _endInteraction(int pointerId) {
    if (pointerId != _activePointer) return;
    _activePointer = null;
    _draggingIndex = null;
  }

  /// Records the pointer id and position that started a potential
  /// view-mode tap. Deliberately does nothing else (no hit-testing, no
  /// state mutation) so [InteractiveViewer]'s own gesture recognizers —
  /// which also see this same raw pointer event, per the [Listener] doc
  /// below — remain free to start a pan/zoom drag uninterrupted.
  void _beginViewTap(int pointerId, Offset viewportLocalPosition) {
    // Mirror of the guard in [_beginInteraction]: a second finger touching
    // down while one is already tracked (e.g. the second contact point of
    // a pinch-zoom gesture) must not re-latch `_viewTapPointer` onto it —
    // otherwise that second finger's eventual up (which InteractiveViewer
    // is simultaneously treating as part of a pan/zoom, not a tap) could
    // be misread by [_endViewTap] as a genuine tap and spuriously
    // select/deselect a route. The first finger owns the gesture until its
    // own up/cancel clears `_viewTapPointer`.
    if (_viewTapPointer != null) return;
    _viewTapPointer = pointerId;
    _viewTapDownPosition = viewportLocalPosition;
  }

  /// Ends a potential view-mode tap: if [pointerId] matches the pointer
  /// that went down and the total movement since then is within
  /// [_tapMovementSlopPx], treats it as a genuine tap (as opposed to a
  /// pan/zoom drag that InteractiveViewer is handling itself) and performs
  /// route hit-testing + selection at the release position. A tap that
  /// doesn't land on any visible route (or lands far from all of them)
  /// clears the selection, matching [hitTestRoute] returning null.
  void _endViewTap(int pointerId, Offset viewportLocalPosition) {
    if (pointerId != _viewTapPointer) return;
    final downPosition = _viewTapDownPosition;
    _viewTapPointer = null;
    _viewTapDownPosition = null;
    if (downPosition == null) return;

    final movement = (viewportLocalPosition - downPosition).distance;
    if (movement > _tapMovementSlopPx) return;

    final scene = widget.transformationController.toScene(
      viewportLocalPosition,
    );
    final percent = CoordinateTransformer.sceneToPercent(
      scene,
      widget.imageSize,
    );
    final scale = _currentScale;
    final thresholdScenePx = _handleHitRadiusPx / (scale == 0 ? 1 : scale);
    final thresholdPercent = thresholdScenePx /
        (widget.imageSize.width == 0 ? 1 : widget.imageSize.width);

    final drawState = ref.read(drawControllerProvider);
    final hitId = hitTestRoute(percent, drawState.routes, thresholdPercent);
    ref.read(drawControllerProvider.notifier).selectRoute(hitId);
  }

  /// Clears any in-progress view-mode tap tracking for [pointerId] without
  /// performing a select — used for pointer-cancel, where there is no
  /// meaningful release position.
  void _cancelViewTap(int pointerId) {
    if (pointerId != _viewTapPointer) return;
    _viewTapPointer = null;
    _viewTapDownPosition = null;
  }

  @override
  Widget build(BuildContext context) {
    final drawState = ref.watch(drawControllerProvider);
    final isDrawMode = drawState.mode == DrawMode.draw;

    return LayoutBuilder(
      builder: (context, constraints) {
        final viewportSize = Size(
          constraints.maxWidth,
          constraints.maxHeight,
        );
        _applyFitScaleOnce(viewportSize);
        final fitScale = _fitScale(viewportSize);

        final viewer = InteractiveViewer(
          key: const Key('topo-interactive-viewer'),
          transformationController: widget.transformationController,
          panEnabled: !isDrawMode,
          scaleEnabled: !isDrawMode,
          minScale: _minScaleFor(fitScale),
          maxScale: _maxScaleFor(fitScale),
          boundaryMargin: const EdgeInsets.all(double.infinity),
          child: SizedBox(
            width: widget.imageSize.width,
            height: widget.imageSize.height,
            child: Stack(
              children: [
                Image.file(
                  File(widget.imagePath),
                  fit: BoxFit.contain,
                  width: widget.imageSize.width,
                  height: widget.imageSize.height,
                  // Swallow decode errors (e.g. a path that doesn't resolve
                  // to a real file, as widget tests use) instead of letting
                  // them propagate as an unhandled exception — see class
                  // doc for why tests can pump this widget without a real
                  // image file.
                  errorBuilder: (context, error, stackTrace) =>
                      const SizedBox.shrink(),
                ),
                CustomPaint(
                  size: widget.imageSize,
                  painter: TopoPainter(
                    imageSize: widget.imageSize,
                    routes: drawState.routes,
                    currentPoints: drawState.currentPoints,
                    showHandles: isDrawMode && drawState.activeSymbol == null,
                    selectedRouteId: drawState.selectedRouteId,
                    palette: kRoutePalette,
                    // Wires grade-band coloring into the canvas itself (not
                    // just the legend, see route_legend.dart): a stable
                    // top-level function reference — not a closure allocated
                    // fresh per build — so TopoPainter.shouldRepaint's
                    // reference comparison of routeColorResolver stays
                    // stable across rebuilds (see topoRouteColor's doc).
                    routeColorResolver: topoRouteColor,
                  ),
                ),
              ],
            ),
          ),
        );

        if (!isDrawMode) {
          // Same rationale as the draw-mode Listener below: wrapping (not
          // replacing) InteractiveViewer with a raw-pointer Listener lets
          // this widget observe every down/up to disambiguate a tap from a
          // pan/zoom drag, without stealing anything from IV's own gesture
          // recognizers — they still see and act on the same events, so
          // pan/zoom keeps working exactly as before. Only a genuine tap
          // (see _endViewTap's movement-slop check) triggers a
          // select/deselect; a real drag is left entirely to IV.
          return Listener(
            key: const Key('topo-view-gesture-detector'),
            behavior: HitTestBehavior.opaque,
            onPointerDown: (event) =>
                _beginViewTap(event.pointer, event.localPosition),
            onPointerUp: (event) =>
                _endViewTap(event.pointer, event.localPosition),
            onPointerCancel: (event) => _cancelViewTap(event.pointer),
            child: viewer,
          );
        }

        // A plain GestureDetector (onTapUp/onPanStart/onPanUpdate) does NOT
        // work here: InteractiveViewer always installs its own internal
        // scale gesture recognizer on this same subtree, even when
        // panEnabled and scaleEnabled are both false — those flags only
        // suppress the *effect* (no actual pan/zoom happens), not the
        // recognizer's participation in the gesture arena. For a real drag
        // (movement past the pan/scale slop), that internal recognizer
        // competes with — and can win against — an outer GestureDetector's
        // pan recognizer, silently swallowing the gesture (onPanStart never
        // fires, only onPanCancel).
        //
        // Listener sidesteps this entirely: it observes raw pointer events
        // directly via hit-testing rather than through gesture-arena
        // disambiguation, so it reliably sees every down/move/up regardless
        // of what InteractiveViewer's internal recognizer decides to do
        // with them. Wrapping the InteractiveViewer itself (rather than its
        // child) means event.localPosition here is a "viewport point"
        // relative to InteractiveViewer's own untransformed box — exactly
        // what TransformationController.toScene expects.
        return Listener(
          key: const Key('topo-draw-gesture-detector'),
          behavior: HitTestBehavior.opaque,
          onPointerDown: (event) =>
              _beginInteraction(event.pointer, event.localPosition),
          onPointerMove: (event) =>
              _updateInteraction(event.pointer, event.localPosition),
          onPointerUp: (event) => _endInteraction(event.pointer),
          onPointerCancel: (event) => _endInteraction(event.pointer),
          child: viewer,
        );
      },
    );
  }
}
