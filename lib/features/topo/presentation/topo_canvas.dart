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
    this.activeCropXpct,
    this.activeCropWidthPct,
  });

  /// Filesystem path of the selected topo photo.
  final String imagePath;

  /// The natural (decoded) size of the image at [imagePath]. This is always
  /// the ORIGINAL image's size, even while a slice is the active view (see
  /// [activeCropXpct]) — scene space never shrinks to the slice, only the
  /// visible viewport is framed to it. That's what lets tap -> scene ->
  /// percent keep producing ORIGINAL-space percent coordinates with no
  /// reprojection, whether or not a crop is active.
  final Size imageSize;

  /// Shared with the owning screen so pan/zoom state (and coordinate
  /// mapping via [TransformationController.toScene]) persists across
  /// draw/view mode switches.
  final TransformationController transformationController;

  /// The left edge of the active crop band, as a fraction (0.0-1.0) of
  /// [imageSize]'s width, or null to view the full original image.
  ///
  /// When non-null (together with [activeCropWidthPct]), this widget frames
  /// the viewport to the band `[activeCropXpct * imageSize.width,
  /// (activeCropXpct + activeCropWidthPct) * imageSize.width]` (full height)
  /// instead of fitting the whole image — see [computeCropTransform] and
  /// [_TopoCanvasState._reframeIfNeeded].
  final double? activeCropXpct;

  /// The width of the active crop band, as a fraction (0.0-1.0) of
  /// [imageSize]'s width. See [activeCropXpct].
  final double? activeCropWidthPct;

  /// Pure computation of the [Matrix4] that frames the viewport to the crop
  /// band `[cropXpct * imageSize.width, (cropXpct + cropWidthPct) *
  /// imageSize.width]` (full height).
  ///
  /// CONTAIN-fits the band: `scale = min(viewportSize.width / (cropWidthPct
  /// * imageSize.width), viewportSize.height / imageSize.height)` — i.e.
  /// whichever axis is tighter wins, rather than always scaling by width.
  /// A width-only scale (the pre-Fix-3 behavior) made a thin/tall band
  /// overflow the viewport vertically; since `panEnabled` is false while
  /// drawing, the clipped top/bottom were then permanently unreachable.
  /// Using the smaller of the two candidate scales guarantees the ENTIRE
  /// band (full height, full band width) fits inside the viewport with
  /// nothing clipped, in any mode. The band is then centered in BOTH axes
  /// (not just top/bottom-letterboxed vertically as before): whichever axis
  /// has slack (band width < viewport width when height was the binding
  /// constraint, or vice versa) gets that slack split evenly.
  ///
  /// Exposed as a static, side-effect-free method (rather than only being
  /// reachable by pumping the full widget) so its math can be asserted
  /// directly and deterministically in tests.
  @visibleForTesting
  static Matrix4 computeCropTransform({
    required Size viewportSize,
    required Size imageSize,
    required double cropXpct,
    required double cropWidthPct,
  }) {
    final bandWidthPx = cropWidthPct * imageSize.width;
    final widthScale = bandWidthPx > 0 ? viewportSize.width / bandWidthPx : 1.0;
    final heightScale =
        imageSize.height > 0 ? viewportSize.height / imageSize.height : 1.0;
    final scale = widthScale < heightScale ? widthScale : heightScale;

    final bandLeftPx = cropXpct * imageSize.width;
    final scaledBandWidth = bandWidthPx * scale;
    final scaledHeight = imageSize.height * scale;
    final dx = (viewportSize.width - scaledBandWidth) / 2 - bandLeftPx * scale;
    final dy = (viewportSize.height - scaledHeight) / 2;

    return Matrix4.identity()
      ..setEntry(0, 0, scale)
      ..setEntry(1, 1, scale)
      ..setEntry(2, 2, scale)
      ..setEntry(0, 3, dx)
      ..setEntry(1, 3, dy);
  }

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

  /// Whether [_reframeIfNeeded] has framed the viewport at least once.
  /// Reframing (fit-to-viewport, or crop-band framing when a slice is
  /// active) is meant to run once PER distinct crop — see
  /// [_framedCropXpct]/[_framedCropWidthPct] — never stomping the user's
  /// subsequent manual pan/zoom within that same crop.
  bool _hasFramed = false;

  /// The `activeCropXpct`/`activeCropWidthPct` this widget was last framed
  /// for (mirrors [widget.activeCropXpct]/[widget.activeCropWidthPct] at the
  /// time of the last [_reframeIfNeeded] application), so a rebuild with the
  /// SAME crop doesn't re-apply (and stomp manual pan/zoom), while a
  /// genuinely NEW crop (e.g. the user picked a different slice, or
  /// switched back to Original) does.
  double? _framedCropXpct;
  double? _framedCropWidthPct;

  /// The `widget.imageSize` this widget was last framed for (Fix 1
  /// hardening). Tracked alongside [_framedCropXpct]/[_framedCropWidthPct]
  /// so a genuinely NEW image — even one with the SAME crop value as the
  /// previous image (most commonly null/null, i.e. both viewing "Original")
  /// — still forces a fresh reframe rather than being treated as
  /// "unchanged". Without this, [TopoCanvasScreen] handing this same,
  /// long-lived [_TopoCanvasState] a new photo (same crop state, different
  /// natural size) would silently keep showing the PREVIOUS photo's
  /// fit/crop transform forever.
  Size? _framedImageSize;

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

  /// Computes the `(minScale, maxScale)` pair to hand to [InteractiveViewer]
  /// for [viewportSize]: normally just [_minScaleFor]/[_maxScaleFor] of the
  /// full-image [_fitScale] (Fix 4). When a crop band is active, this is
  /// widened so the crop's OWN applied scale — [TopoCanvas
  /// .computeCropTransform]'s `scale`, i.e. what the viewport is actually
  /// framed to right now — always falls within `[minScale, maxScale]`:
  /// `maxScale` becomes at least `appliedCropScale * 4` and `minScale`
  /// becomes at most `appliedCropScale`.
  ///
  /// Without this, minScale/maxScale were derived purely from the
  /// full-image fit, so a thin slice's applied (necessarily larger) scale
  /// could exceed the full-image-derived maxScale; the first pinch then
  /// caused [InteractiveViewer] to snap the transform back down to its own
  /// maxScale, discarding the crop framing.
  (double, double) _scaleRangeFor(Size viewportSize) {
    final fitScale = _fitScale(viewportSize);
    var minScale = _minScaleFor(fitScale);
    var maxScale = _maxScaleFor(fitScale);

    final cropXpct = widget.activeCropXpct;
    final cropWidthPct = widget.activeCropWidthPct;
    if (cropXpct != null && cropWidthPct != null) {
      final cropMatrix = TopoCanvas.computeCropTransform(
        viewportSize: viewportSize,
        imageSize: widget.imageSize,
        cropXpct: cropXpct,
        cropWidthPct: cropWidthPct,
      );
      final appliedCropScale = cropMatrix.getMaxScaleOnAxis();
      if (appliedCropScale > 0) {
        final widenedMax = appliedCropScale * 4;
        maxScale = maxScale > widenedMax ? maxScale : widenedMax;
        minScale = minScale < appliedCropScale ? minScale : appliedCropScale;
      }
    }

    return (minScale, maxScale);
  }

  /// Builds the fit-to-viewport matrix: [widget.imageSize] uniformly scaled
  /// to fit entirely within [viewportSize] (letterboxed on whichever axis
  /// has slack) and centered.
  ///
  /// Equivalent to `Matrix4.identity()..translate(dx, dy)..scale(fitScale)`
  /// (translate-then-scale composition: scale first, then translate the
  /// scaled image into the centered position), built via setEntry instead
  /// since Matrix4.translate/scale are deprecated in favor of the
  /// ByVector3/ByDouble variants, none of which read as more legible here
  /// than writing the resulting matrix entries directly.
  Matrix4 _fitMatrix(Size viewportSize) {
    final fitScale = _fitScale(viewportSize);
    final scaledWidth = widget.imageSize.width * fitScale;
    final scaledHeight = widget.imageSize.height * fitScale;
    final dx = (viewportSize.width - scaledWidth) / 2;
    final dy = (viewportSize.height - scaledHeight) / 2;

    return Matrix4.identity()
      ..setEntry(0, 0, fitScale)
      ..setEntry(1, 1, fitScale)
      ..setEntry(2, 2, fitScale)
      ..setEntry(0, 3, dx)
      ..setEntry(1, 3, dy);
  }

  /// Frames [widget.transformationController] to whichever view is
  /// currently active: the crop band [widget.activeCropXpct]/
  /// [widget.activeCropWidthPct] when set (via
  /// [TopoCanvas.computeCropTransform]), or the whole image fit-to-viewport
  /// otherwise (via [_fitMatrix]).
  ///
  /// Only re-applies when the ACTIVE CROP actually changed since the last
  /// application (tracked via [_framedCropXpct]/[_framedCropWidthPct]) —
  /// e.g. the user picked a different slice, or switched back to Original —
  /// so this never stomps the user's manual pan/zoom within the same crop,
  /// mirroring the previous one-time fit-to-viewport behavior for the
  /// no-crop case.
  ///
  /// As a special case, on the very first frame with NO crop active, a
  /// pre-seeded/non-identity [widget.transformationController] (as some
  /// callers/tests supply) is left exactly as given rather than being
  /// overwritten with the fit transform — this preserves pre-M5 behavior.
  /// That escape hatch does not apply once a crop is active: crop framing is
  /// a deliberate, always-applied override whenever the active crop changes.
  ///
  /// Because [CoordinateTransformer.sceneToPercent]/`toScene` work off the
  /// controller's *live* matrix (see `TopoCanvas` doc comment / call sites
  /// in [_beginInteraction] etc.), initializing the controller to a pure
  /// scale+translate here does not change what "scene space" means — scene
  /// space is always `widget.imageSize`-sized pixels (the ORIGINAL image),
  /// `toScene` just now inverts a matrix that starts pre-zoomed/pre-centered
  /// (or pre-cropped) instead of at identity. Percent math
  /// (`sceneToPercent`/`percentToScene`) is unaffected either way since it
  /// never reads the transform directly — this is exactly what lets a tap
  /// while a slice is framed still yield ORIGINAL-space percent
  /// coordinates with no reprojection.
  void _reframeIfNeeded(Size viewportSize) {
    if (viewportSize.width <= 0 || viewportSize.height <= 0) return;

    final cropXpct = widget.activeCropXpct;
    final cropWidthPct = widget.activeCropWidthPct;
    final hasCrop = cropXpct != null && cropWidthPct != null;

    final unchanged =
        _hasFramed &&
        _framedCropXpct == cropXpct &&
        _framedCropWidthPct == cropWidthPct &&
        _framedImageSize == widget.imageSize;
    if (unchanged) return;

    if (!_hasFramed &&
        !hasCrop &&
        widget.transformationController.value != Matrix4.identity()) {
      // A test (or future caller) supplied a non-identity/pre-seeded
      // controller and no crop is active; leave it exactly as given.
      _hasFramed = true;
      _framedCropXpct = null;
      _framedCropWidthPct = null;
      _framedImageSize = widget.imageSize;
      return;
    }

    _hasFramed = true;
    _framedCropXpct = cropXpct;
    _framedCropWidthPct = cropWidthPct;
    _framedImageSize = widget.imageSize;

    final matrix = hasCrop
        ? TopoCanvas.computeCropTransform(
            viewportSize: viewportSize,
            imageSize: widget.imageSize,
            cropXpct: cropXpct,
            cropWidthPct: cropWidthPct,
          )
        : _fitMatrix(viewportSize);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
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
        _reframeIfNeeded(viewportSize);
        final (minScale, maxScale) = _scaleRangeFor(viewportSize);

        final viewer = InteractiveViewer(
          key: const Key('topo-interactive-viewer'),
          transformationController: widget.transformationController,
          panEnabled: !isDrawMode,
          scaleEnabled: !isDrawMode,
          minScale: minScale,
          maxScale: maxScale,
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
          return ClipRect(
            // When a crop band is active (see [_reframeIfNeeded]), the
            // transformed image extends beyond the viewport on either side
            // of the framed band; ClipRect ensures only the band itself is
            // ever painted. A no-op when no crop is active, since
            // InteractiveViewer already clips its child to its own bounds.
            child: Listener(
              key: const Key('topo-view-gesture-detector'),
              behavior: HitTestBehavior.opaque,
              onPointerDown: (event) =>
                  _beginViewTap(event.pointer, event.localPosition),
              onPointerUp: (event) =>
                  _endViewTap(event.pointer, event.localPosition),
              onPointerCancel: (event) => _cancelViewTap(event.pointer),
              child: viewer,
            ),
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
        return ClipRect(
          child: Listener(
            key: const Key('topo-draw-gesture-detector'),
            behavior: HitTestBehavior.opaque,
            onPointerDown: (event) =>
                _beginInteraction(event.pointer, event.localPosition),
            onPointerMove: (event) =>
                _updateInteraction(event.pointer, event.localPosition),
            onPointerUp: (event) => _endInteraction(event.pointer),
            onPointerCancel: (event) => _endInteraction(event.pointer),
            child: viewer,
          ),
        );
      },
    );
  }
}
