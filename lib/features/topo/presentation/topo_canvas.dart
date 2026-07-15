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

/// Minimum viewport dimension (in logical px, either axis) below which
/// [_TopoCanvasState._reframeIfNeeded] treats the viewport as transient/
/// degenerate and skips framing entirely, rather than committing to
/// whatever (necessarily tiny) fit scale that viewport would imply.
///
/// [LayoutBuilder] can report a spurious near-zero-size viewport during the
/// very first layout pass, before a surrounding `Scaffold`'s `AppBar`/
/// `BottomAppBar` have settled to their final extents. Without this guard,
/// `_hasFramed` would flip true against that bogus size and — absent the
/// reframe-on-resize logic below — the resulting minuscule scale could
/// stick forever. Chosen well below any real device's or test's usable
/// canvas area so it never fires for a genuinely small (but real) viewport.
const double _minFrameableViewportDimensionPx = 8.0;

/// The per-axis viewport-size delta (in logical px) below which a changed
/// viewport is still treated by [_TopoCanvasState._reframeIfNeeded] as "the
/// same" viewport — guards against spurious re-frames from float jitter
/// between [LayoutBuilder] passes (e.g. 399.999999 vs 400.0) while still
/// catching a genuine resize.
const double _viewportChangeEpsilonPx = 1.0;

/// Factor applied to the full-image CONTAIN [TopoCanvas.computeFitScale] to
/// derive [_TopoCanvasState._scaleRangeFor]'s `minScale`, letting the user
/// pinch the image down to HALF the "whole wall visible" contain size for an
/// overview-with-margins — rather than being floored at contain (which, for
/// a typical portrait photo, equals or exceeds the fill-width default scale
/// and so left the user unable to zoom out below screen width at all).
const double kMinZoomOutFactor = 0.5;

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
    final heightScale = imageSize.height > 0
        ? viewportSize.height / imageSize.height
        : 1.0;
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

  /// Pure computation of the scale at which [imageSize] fits entirely
  /// within a viewport of [viewportSize] (CONTAIN-fit: `min` of the two
  /// axis scales, letterboxed on whichever axis has slack) — the "see the
  /// whole wall" scale.
  ///
  /// Exposed as a static, side-effect-free method (mirroring
  /// [computeCropTransform]) so its math can be asserted directly and
  /// deterministically in tests, independent of any widget/layout timing.
  /// NOT `@visibleForTesting` (unlike its siblings below): besides tests,
  /// this is also a genuine production dependency of
  /// [_TopoCanvasState._scaleRangeFor] (via [_TopoCanvasState._fitScale]),
  /// which needs this same fit-scale math to compute [InteractiveViewer]'s
  /// `minScale` — a real second production caller, not a test reaching in.
  static double computeFitScale({
    required Size imageSize,
    required Size viewportSize,
  }) {
    if (imageSize.width <= 0 || imageSize.height <= 0) return 1.0;
    final widthScale = viewportSize.width / imageSize.width;
    final heightScale = viewportSize.height / imageSize.height;
    final scale = widthScale < heightScale ? widthScale : heightScale;
    return scale > 0 ? scale : 1.0;
  }

  /// Pure computation of the scale at which [imageSize] entirely COVERS a
  /// viewport of [viewportSize] (`max` of the two axis scales — the opposite
  /// of [computeFitScale]'s `min`): the image fills the viewport on both
  /// axes, with whichever axis has slack cropped off rather than
  /// letterboxed.
  ///
  /// This is the "open filling the space" scale used by
  /// [computeFitTransform] for the initial/reframe transform — deliberately
  /// a SEPARATE function from [computeFitScale] rather than a parameter on
  /// it, because [computeFitScale] must keep returning the CONTAIN scale:
  /// it's also depended on by [_TopoCanvasState._scaleRangeFor] (via
  /// [_TopoCanvasState._fitScale]) to compute [InteractiveViewer]'s
  /// `minScale`, so the user can always pinch back out to see the WHOLE
  /// wall even though the photo now opens cropped-to-fill.
  ///
  /// Exposed as a static, side-effect-free method (mirroring
  /// [computeFitScale]/[computeCropTransform]) so its math can be asserted
  /// directly and deterministically in tests.
  @visibleForTesting
  static double computeFillScale({
    required Size imageSize,
    required Size viewportSize,
  }) {
    if (imageSize.width <= 0 || imageSize.height <= 0) return 1.0;
    final widthScale = viewportSize.width / imageSize.width;
    final heightScale = viewportSize.height / imageSize.height;
    final scale = widthScale > heightScale ? widthScale : heightScale;
    return scale > 0 ? scale : 1.0;
  }

  /// Pure computation of the fit-to-viewport [Matrix4]: [imageSize]
  /// uniformly scaled by [computeFillScale] to COVER [viewportSize] entirely
  /// (cropped on whichever axis has slack, rather than letterboxed) and
  /// centered in BOTH axes.
  ///
  /// Uses the COVER/fill scale (not [computeFitScale]'s CONTAIN scale) so
  /// the photo opens filling the whole viewport rather than letterboxed —
  /// [_TopoCanvasState._reframeIfNeeded] writes exactly this as the initial/
  /// reframe transform. [computeFitScale] itself is UNCHANGED (still
  /// CONTAIN) so [InteractiveViewer]'s `minScale` still lets the user zoom
  /// back out to see the whole, uncropped wall — see [computeFillScale]'s
  /// doc.
  ///
  /// Equivalent to `Matrix4.identity()..translate(dx, dy)..scale(fillScale)`
  /// (translate-then-scale composition: scale first, then translate the
  /// scaled image into the centered position), built via setEntry instead
  /// since Matrix4.translate/scale are deprecated in favor of the
  /// ByVector3/ByDouble variants, none of which read as more legible here
  /// than writing the resulting matrix entries directly.
  ///
  /// Exposed as a static, side-effect-free method (mirroring
  /// [computeCropTransform]/[computeFitScale]/[computeFillScale]) for
  /// direct, deterministic testing.
  @visibleForTesting
  static Matrix4 computeFitTransform({
    required Size imageSize,
    required Size viewportSize,
  }) {
    final fillScale = computeFillScale(
      imageSize: imageSize,
      viewportSize: viewportSize,
    );
    final scaledWidth = imageSize.width * fillScale;
    final scaledHeight = imageSize.height * fillScale;
    final dx = (viewportSize.width - scaledWidth) / 2;
    final dy = (viewportSize.height - scaledHeight) / 2;

    return Matrix4.identity()
      ..setEntry(0, 0, fillScale)
      ..setEntry(1, 1, fillScale)
      ..setEntry(2, 2, fillScale)
      ..setEntry(0, 3, dx)
      ..setEntry(1, 3, dy);
  }

  /// Pure computation of the CONTAIN-fit-to-viewport [Matrix4]: [imageSize]
  /// uniformly scaled by [computeFitScale] to fit ENTIRELY within
  /// [viewportSize] (letterboxed on whichever axis has slack) and centered
  /// in BOTH axes — i.e. the "see the whole wall" framing.
  ///
  /// This was formerly the canvas-look-rework's DEFAULT open-framing
  /// transform (see DESIGN.md "Topo canvas"), superseded by
  /// [computeFillWidthTransform] (fill-width, vertically centered — see that
  /// method's doc for why). This CONTAIN transform is RETAINED as the
  /// reference "whole wall visible" framing: [_TopoCanvasState._scaleRangeFor]
  /// uses its scale ([computeFitScale]) as [InteractiveViewer]'s `minScale`,
  /// so the user can always pinch OUT from the fill-width default to see the
  /// entire photo letterboxed. [computeCropTransform] (the slice/crop
  /// framing) is untouched, and so is [computeFitTransform] (the
  /// pre-existing COVER/fill transform, kept alongside this rather than
  /// replaced — see that method's doc).
  ///
  /// Exposed as a static, side-effect-free method (mirroring
  /// [computeFitTransform]/[computeCropTransform]) for direct, deterministic
  /// testing.
  @visibleForTesting
  static Matrix4 computeContainTransform({
    required Size imageSize,
    required Size viewportSize,
  }) {
    final scale = computeFitScale(
      imageSize: imageSize,
      viewportSize: viewportSize,
    );
    final scaledWidth = imageSize.width * scale;
    final scaledHeight = imageSize.height * scale;
    final dx = (viewportSize.width - scaledWidth) / 2;
    final dy = (viewportSize.height - scaledHeight) / 2;

    return Matrix4.identity()
      ..setEntry(0, 0, scale)
      ..setEntry(1, 1, scale)
      ..setEntry(2, 2, scale)
      ..setEntry(0, 3, dx)
      ..setEntry(1, 3, dy);
  }

  /// Pure computation of the DEFAULT open-framing [Matrix4]: [imageSize]
  /// scaled by WIDTH ALONE so it spans the full viewport width exactly, then
  /// VERTICALLY CENTERED within whatever slack remains — a portrait photo
  /// taller (once scaled to width) than the viewport is left top-anchored
  /// instead (the clamp below), its remainder reachable by panning rather
  /// than being shrunk further to fit height too.
  ///
  /// This is the canvas-look-rework's (2026-07-15 revision) DEFAULT
  /// (no-crop) open-framing transform: [_TopoCanvasState._fitMatrix] applies
  /// this in place of the older [computeContainTransform] (contain/
  /// letterboxed/centered) so the photo reads as filling the screen width on
  /// open instead of floating centered with gray bands on the sides — but,
  /// unlike the transform's previous (top-anchored-always) revision, a
  /// short/landscape photo's leftover vertical slack is now split evenly
  /// above and below rather than dumped entirely below the image.
  /// [computeCropTransform] (the slice/crop framing) is untouched, and
  /// [computeContainTransform] is RETAINED — not deleted — as the CONTAIN
  /// reference [_TopoCanvasState._scaleRangeFor] uses for
  /// [InteractiveViewer]'s `minScale`: the user can always pinch OUT past
  /// this fill-width default to see the whole photo letterboxed.
  ///
  /// Exposed as a static, side-effect-free method (mirroring
  /// [computeContainTransform]/[computeCropTransform]) for direct,
  /// deterministic testing.
  @visibleForTesting
  static Matrix4 computeFillWidthTransform({
    required Size imageSize,
    required Size viewportSize,
  }) {
    final rawScale = imageSize.width > 0
        ? viewportSize.width / imageSize.width
        : 1.0;
    final scale = rawScale > 0 ? rawScale : 1.0;
    final scaledHeight = imageSize.height * scale;
    // Positive slack (scaledHeight < viewport) is split evenly top/bottom
    // (vertical centering). Clamped at 0 when the scaled image is TALLER
    // than the viewport, so that case stays top-anchored — panning down
    // still reaches the remainder — rather than going negative and
    // panning up into empty space.
    final dy = ((viewportSize.height - scaledHeight) / 2).clamp(
      0.0,
      double.infinity,
    );
    return Matrix4.identity()
      ..setEntry(0, 0, scale)
      ..setEntry(1, 1, scale)
      ..setEntry(2, 2, scale)
      ..setEntry(1, 3, dy);
    // translation-X stays 0: scale-to-width already spans the full
    // viewport width exactly, so there's never horizontal slack to center.
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
  /// finger touching down mid-drag/mid-tap from hijacking it: only
  /// move/up/cancel events whose `event.pointer` matches this id are
  /// honored (see [_beginInteraction]/[_updateInteraction]/
  /// [_endInteraction]/[_cancelInteraction]).
  ///
  /// A second finger touching down while this one is active doesn't just
  /// get ignored, though — see [_beginInteraction]'s early-return branch,
  /// which uses that second down as the signal to ABORT whatever the first
  /// finger was doing (a pending tap-to-add, or a handle drag), clearing
  /// [_draggingIndex]/[_pendingTapDownPosition] so a two-finger pinch/pan
  /// (now enabled in draw mode — see the `InteractiveViewer.scaleEnabled`
  /// doc in [build]) never drops a stray point or nudges a handle.
  int? _activePointer;

  /// The viewport-local position at which [_activePointer] went down, IF no
  /// existing handle was hit on that down (see [_beginInteraction]) — i.e.
  /// a single-finger gesture that might still turn out to be a tap-to-add.
  ///
  /// Null whenever there's no pending tap to commit: no interaction is in
  /// progress, the current interaction is a handle drag instead
  /// ([_draggingIndex] set), or the pending tap has already been cancelled
  /// — either by moving past [_tapMovementSlopPx] ([_updateInteraction]) or
  /// by a second finger touching down ([_beginInteraction]'s abort branch).
  /// Only a pointer-up that still finds this non-null ([_endInteraction])
  /// actually commits the new point — mirroring [_viewTapDownPosition]/
  /// [_endViewTap]'s tap semantics in view mode.
  Offset? _pendingTapDownPosition;

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

  /// The `viewportSize` this widget was last framed for (reframe-on-resize
  /// fix). A [LayoutBuilder] viewport can be transient/degenerate on its
  /// first pass (e.g. ~110x70, before a surrounding `Scaffold`'s `AppBar`/
  /// `BottomAppBar` settle to their final extents) — without tracking this,
  /// [_hasFramed] flipping true against that bogus size meant the resulting
  /// tiny fit scale stuck forever, rendering the wall photo as a tiny
  /// top-left thumbnail. Tracked alongside [_framedCropXpct]/
  /// [_framedCropWidthPct]/[_framedImageSize] so a later, settled viewport
  /// (differing by more than [_viewportChangeEpsilonPx] on either axis)
  /// forces a fresh reframe even when the crop/image haven't changed.
  Size? _framedViewportSize;

  /// The [Matrix4] this widget last wrote into
  /// [TopoCanvas.transformationController] via [_reframeIfNeeded]'s own
  /// auto-frame (fit-to-viewport or crop-band framing), or null if it has
  /// never auto-framed.
  ///
  /// Used to distinguish "the viewport changed but the controller's value
  /// is still exactly what WE last set" (safe to replace with a fresh fit
  /// for the new viewport) from "the user has since manually panned/zoomed"
  /// (must NOT be stomped by a resize) — see the viewport-changed branch of
  /// [_reframeIfNeeded]. A crop/image change always reframes unconditionally
  /// regardless of this, matching the pre-existing (M5) behavior.
  Matrix4? _lastAutoFrameMatrix;

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
  /// Delegates to [TopoCanvas.computeFitScale] (the pure, directly-testable
  /// form of this same math).
  double _fitScale(Size viewportSize) => TopoCanvas.computeFitScale(
    imageSize: widget.imageSize,
    viewportSize: viewportSize,
  );

  /// The `maxScale` to hand to [InteractiveViewer]: at least 5.0 (the
  /// previous hardcoded default), but scaled up relative to a very small
  /// fit scale so zooming in still spans a meaningful range for huge
  /// photos fit into a small viewport.
  double _maxScaleFor(double fitScale) {
    final scaled = fitScale * 20;
    return scaled > 5.0 ? scaled : 5.0;
  }

  /// Computes the `(minScale, maxScale)` pair to hand to [InteractiveViewer]
  /// for [viewportSize].
  ///
  /// `minScale` is the full-image CONTAIN [_fitScale] (i.e.
  /// [TopoCanvas.computeFitScale]) scaled down further by
  /// [kMinZoomOutFactor] — not clamped/capped — so the user can pinch out
  /// PAST [TopoCanvas.computeContainTransform]'s "whole wall visible"
  /// framing to an overview-with-margins, no matter what the DEFAULT
  /// open-framing ([_fitMatrix], now [TopoCanvas.computeFillWidthTransform]
  /// — fill-width/vertically-centered, generally a LARGER scale than contain
  /// for a portrait photo) applied on open. Without the [kMinZoomOutFactor]
  /// reduction, `minScale` == contain, which for a typical 3:4 portrait photo
  /// equals the fill-width scale too — flooring the user at exactly the
  /// fill-width default with no room to zoom out below screen width at all.
  /// `maxScale` is [_maxScaleFor] of the (un-reduced) full-image fit scale,
  /// unchanged.
  ///
  /// When a crop band is active, this is further widened so the crop's OWN
  /// applied scale — [TopoCanvas.computeCropTransform]'s `scale`, i.e. what
  /// the viewport is actually framed to right now — always falls within
  /// `[minScale, maxScale]`: `maxScale` becomes at least
  /// `appliedCropScale * 4` and `minScale` becomes at most
  /// `appliedCropScale`.
  ///
  /// Without this, minScale/maxScale were derived purely from the
  /// full-image fit, so a thin slice's applied (necessarily larger) scale
  /// could exceed the full-image-derived maxScale; the first pinch then
  /// caused [InteractiveViewer] to snap the transform back down to its own
  /// maxScale, discarding the crop framing.
  ///
  /// When NO crop is active, the DEFAULT framing's applied scale
  /// ([TopoCanvas.computeFillWidthTransform]'s fill-width scale) is
  /// STRICTLY GREATER than or equal to `minScale` (which is now at most
  /// `kMinZoomOutFactor` of the contain scale — itself the smaller of the
  /// two axis scales, and fill-width IS the width-axis scale) and always
  /// well under `maxScale` (derived the same way as before), so the applied
  /// initial scale is always in-range.
  (double, double) _scaleRangeFor(Size viewportSize) {
    final fitScale = _fitScale(viewportSize);
    var minScale = fitScale * kMinZoomOutFactor;
    var maxScale = _maxScaleFor(fitScale);
    // Defensive guard (pathological/degenerate image or viewport sizes):
    // keep the fill-width default scale always within [minScale, maxScale]
    // even if _maxScaleFor's *20/floor-5.0 heuristic were ever to land below
    // it — never expected in practice (maxScale is derived from the same
    // fitScale and is always >> minScale), but cheap to guard.
    final fillWidthScale = TopoCanvas.computeFillWidthTransform(
      imageSize: widget.imageSize,
      viewportSize: viewportSize,
    ).getMaxScaleOnAxis();
    if (fillWidthScale > maxScale) {
      maxScale = fillWidthScale;
    }

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

  /// Builds the DEFAULT (no-crop) fit-to-viewport matrix: [widget.imageSize]
  /// scaled by WIDTH ALONE to span [viewportSize]'s full width, then
  /// vertically centered within any leftover slack (fill-width — not
  /// CONTAIN/letterboxed on both axes). Delegates to
  /// [TopoCanvas.computeFillWidthTransform] (the pure, directly-testable
  /// form of this same math) — see that method's doc for why the default
  /// open-framing is fill-width/vertically-centered rather than the
  /// CONTAIN/centered-on-both-axes behavior
  /// ([TopoCanvas.computeContainTransform], still used elsewhere as the
  /// zoom-out reference — see [_scaleRangeFor]) or the older COVER/fill
  /// behavior ([TopoCanvas.computeFitTransform]).
  Matrix4 _fitMatrix(Size viewportSize) => TopoCanvas.computeFillWidthTransform(
    imageSize: widget.imageSize,
    viewportSize: viewportSize,
  );

  /// Frames [widget.transformationController] to whichever view is
  /// currently active: the crop band [widget.activeCropXpct]/
  /// [widget.activeCropWidthPct] when set (via
  /// [TopoCanvas.computeCropTransform]), or the whole image fit-to-viewport
  /// otherwise (via [_fitMatrix]).
  ///
  /// Re-applies whenever the ACTIVE CROP, the image, OR the viewport size
  /// itself has changed materially (by more than [_viewportChangeEpsilonPx]
  /// on either axis) since the last application (tracked via
  /// [_framedCropXpct]/[_framedCropWidthPct]/[_framedImageSize]/
  /// [_framedViewportSize]).
  ///
  /// The viewport-size trigger (the fix for the "tiny top-left thumbnail"
  /// bug) exists because a [LayoutBuilder] viewport can be transient/
  /// degenerate on its very first pass — e.g. ~110x70 before a surrounding
  /// `Scaffold`'s `AppBar`/`BottomAppBar` settle to their final extents —
  /// and without re-checking on resize, [_hasFramed] flipping true against
  /// that bogus size meant the resulting tiny fit scale stuck forever, even
  /// once the viewport settled to its real (much larger) size. A viewport
  /// below [_minFrameableViewportDimensionPx] on either axis is skipped
  /// entirely (not framed, `_hasFramed` left untouched) as an extra guard
  /// against committing to a genuinely degenerate (near-zero) size.
  ///
  /// Because a resize must NOT stomp a genuine user pan/zoom, a
  /// viewport-only change only reframes if the controller's LIVE value is
  /// still exactly the matrix this method itself last wrote (tracked via
  /// [_lastAutoFrameMatrix]) — i.e. nothing (in particular, no manual
  /// pan/zoom) has touched it since. A crop or image change, in contrast,
  /// always reframes unconditionally (matching pre-existing M5 behavior):
  /// those are deliberate, always-applied overrides.
  ///
  /// As a special case, on the very first frame with NO crop active, a
  /// pre-seeded/non-identity [widget.transformationController] (as some
  /// callers/tests supply) is left exactly as given rather than being
  /// overwritten with the fit transform — this preserves pre-M5 behavior.
  /// That escape hatch does not apply once a crop is active, nor once this
  /// widget has already framed at least once.
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
    if (viewportSize.width < _minFrameableViewportDimensionPx ||
        viewportSize.height < _minFrameableViewportDimensionPx) {
      // Transient/degenerate viewport: skip framing entirely rather than
      // committing to whatever tiny scale it would imply. `_hasFramed` is
      // deliberately left untouched so the next (hopefully real) viewport
      // is treated as the genuine first frame.
      return;
    }

    final cropXpct = widget.activeCropXpct;
    final cropWidthPct = widget.activeCropWidthPct;
    final hasCrop = cropXpct != null && cropWidthPct != null;

    final sameCropAndImage =
        _framedCropXpct == cropXpct &&
        _framedCropWidthPct == cropWidthPct &&
        _framedImageSize == widget.imageSize;
    final viewportChanged =
        _framedViewportSize == null ||
        (_framedViewportSize!.width - viewportSize.width).abs() >
            _viewportChangeEpsilonPx ||
        (_framedViewportSize!.height - viewportSize.height).abs() >
            _viewportChangeEpsilonPx;

    if (_hasFramed && sameCropAndImage && !viewportChanged) {
      return; // Truly unchanged: never stomp a manual pan/zoom.
    }

    if (_hasFramed && sameCropAndImage && viewportChanged) {
      // Only the viewport moved (the reframe-on-resize fix): re-fit to the
      // NEW viewport unless the user has manually panned/zoomed since the
      // last auto-frame, detected by the controller's live value having
      // drifted away from the matrix WE last wrote. A stale auto-frame
      // must never block a later, larger viewport's fit; a genuine user
      // adjustment must never be stomped by a resize.
      final stillAutoFramed =
          _lastAutoFrameMatrix != null &&
          widget.transformationController.value == _lastAutoFrameMatrix;
      if (!stillAutoFramed) return;
    } else if (!_hasFramed &&
        !hasCrop &&
        widget.transformationController.value != Matrix4.identity()) {
      // First frame ever, no crop active, and a test/caller pre-seeded a
      // non-identity controller: leave it exactly as given.
      _hasFramed = true;
      _framedCropXpct = null;
      _framedCropWidthPct = null;
      _framedImageSize = widget.imageSize;
      _framedViewportSize = viewportSize;
      _lastAutoFrameMatrix = null;
      return;
    }

    _hasFramed = true;
    _framedCropXpct = cropXpct;
    _framedCropWidthPct = cropWidthPct;
    _framedImageSize = widget.imageSize;
    _framedViewportSize = viewportSize;

    final matrix = hasCrop
        ? TopoCanvas.computeCropTransform(
            viewportSize: viewportSize,
            imageSize: widget.imageSize,
            cropXpct: cropXpct,
            cropWidthPct: cropWidthPct,
          )
        : _fitMatrix(viewportSize);

    _lastAutoFrameMatrix = matrix;

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
  /// either begin dragging the hit point, or record a PENDING tap-to-add at
  /// the tapped location (resolved later, on pointer-up, by
  /// [_endInteraction] — see [_pendingTapDownPosition]'s doc for why adding
  /// is deferred rather than happening here on down).
  ///
  /// Claims [pointerId] as the sole active pointer for this interaction
  /// (see [_activePointer] doc). A second finger touching down while this
  /// one is still down/dragging/pending does NOT just get ignored: it
  /// actively ABORTS whatever the first finger was doing (clearing
  /// [_draggingIndex]/[_pendingTapDownPosition], which is what actually
  /// turns the first finger's later [_updateInteraction]/[_endInteraction]
  /// calls into no-ops) — see the early-return branch below — so a
  /// two-finger pinch/pan (now enabled in draw mode; see [build]'s
  /// `InteractiveViewer.scaleEnabled` doc) never drops a stray point or
  /// nudges a handle out from under the user.
  Future<void> _beginInteraction(
    int pointerId,
    Offset viewportLocalPosition,
  ) async {
    if (_activePointer != null) {
      // A second (or later) finger touching down while the first is still
      // active: abort the first finger's pending tap / in-progress handle
      // drag. `_activePointer` itself is deliberately left alone (still the
      // FIRST finger's id) so that finger's own eventual up/cancel is still
      // correctly matched in [_endInteraction]/[_cancelInteraction] and
      // cleanly clears state; clearing `_draggingIndex`/
      // `_pendingTapDownPosition` here is what actually neutralizes it.
      _draggingIndex = null;
      _pendingTapDownPosition = null;
      return;
    }
    _activePointer = pointerId;
    final scene = widget.transformationController.toScene(
      viewportLocalPosition,
    );
    final drawState = ref.read(drawControllerProvider);

    if (drawState.activeSymbol != null) {
      // Symbol-placement mode: a tap places a symbol of the active type
      // onto the selected route (auto-selecting `routes.last` if none is
      // selected yet — see [DrawController.placeSymbol]'s doc) rather than
      // adding/dragging a route point. Still fires on pointer-down (NOT
      // deferred to up like the tap-to-add-a-point path below) so a plain
      // tap (down immediately followed by up with no movement, as
      // `tester.tapAt` simulates) places exactly one symbol; dragging isn't
      // a supported symbol-placement gesture.
      _draggingIndex = null;
      _pendingTapDownPosition = null;
      final percent = CoordinateTransformer.sceneToPercent(
        scene,
        widget.imageSize,
      );
      final outcome = await ref
          .read(drawControllerProvider.notifier)
          .placeSymbol(percent);
      // This method is now async (awaiting placeSymbol above), so `mounted`
      // must be re-checked before touching `context` below — the widget may
      // have been unmounted while that await was in flight.
      if (!mounted) return;
      if (outcome == SymbolPlacementOutcome.noRouteAvailable) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Draw a route first to place symbols'),
          ),
        );
      }
      return;
    }

    final hitIndex = _hitTestHandle(scene, drawState.currentPoints);
    if (hitIndex != null) {
      _draggingIndex = hitIndex;
      _pendingTapDownPosition = null;
      return;
    }
    // No handle hit: this MIGHT be a tap-to-add, but don't commit it yet —
    // record it as pending and decide on pointer-up (mirroring
    // [_beginViewTap]/[_endViewTap]'s view-mode tap semantics). This is
    // what lets a single-finger DRAG starting on empty space (moved past
    // the slop before release) add nothing instead of always placing a
    // point at the down location.
    _draggingIndex = null;
    _pendingTapDownPosition = viewportLocalPosition;
  }

  /// Handles pointer movement: ignored if [pointerId] isn't the pointer
  /// that started the current interaction. Dragging an existing handle
  /// ([_draggingIndex] set) moves it on every move, as before. Otherwise,
  /// if a tap-to-add is still pending ([_pendingTapDownPosition] set), this
  /// is where that pending tap gets CANCELLED once movement exceeds
  /// [_tapMovementSlopPx] — a single-finger drag starting on empty space
  /// must add no point (and must not fall back to panning, since
  /// `panEnabled` is false in draw mode: it simply does nothing).
  void _updateInteraction(int pointerId, Offset viewportLocalPosition) {
    if (pointerId != _activePointer) return;
    final draggingIndex = _draggingIndex;
    if (draggingIndex != null) {
      final scene = widget.transformationController.toScene(
        viewportLocalPosition,
      );
      final percent = CoordinateTransformer.sceneToPercent(
        scene,
        widget.imageSize,
      );
      ref
          .read(drawControllerProvider.notifier)
          .movePoint(draggingIndex, percent);
      return;
    }

    final downPosition = _pendingTapDownPosition;
    if (downPosition == null) return;
    final movement = (viewportLocalPosition - downPosition).distance;
    if (movement > _tapMovementSlopPx) {
      _pendingTapDownPosition = null;
    }
  }

  /// Ends the current interaction, but only if [pointerId] is the pointer
  /// that started it — an up from an unrelated second pointer must not
  /// affect it. A handle drag simply stops (its moves already applied). A
  /// still-PENDING tap (no handle was hit on down, and no move since has
  /// exceeded the tap slop — see [_updateInteraction]) is what actually
  /// commits the new point here, at [viewportLocalPosition] (the release
  /// point, mirroring [_endViewTap]'s use of the release position rather
  /// than the down position).
  void _endInteraction(int pointerId, Offset viewportLocalPosition) {
    if (pointerId != _activePointer) return;
    _activePointer = null;
    final draggingIndex = _draggingIndex;
    _draggingIndex = null;
    final pendingTapDownPosition = _pendingTapDownPosition;
    _pendingTapDownPosition = null;

    if (draggingIndex != null) return; // Handle drag: already applied.
    if (pendingTapDownPosition == null) {
      return; // Cancelled: moved past the slop, or aborted by a 2nd finger.
    }

    final scene = widget.transformationController.toScene(
      viewportLocalPosition,
    );
    final percent = CoordinateTransformer.sceneToPercent(
      scene,
      widget.imageSize,
    );
    ref.read(drawControllerProvider.notifier).addPoint(percent);
  }

  /// Clears any in-progress draw interaction (pending tap-to-add or handle
  /// drag) for [pointerId] WITHOUT committing it — used for pointer-cancel,
  /// which (unlike pointer-up, see [_endInteraction]) must never add a
  /// point. Mirrors [_cancelViewTap]'s split from [_endViewTap] in view
  /// mode.
  void _cancelInteraction(int pointerId) {
    if (pointerId != _activePointer) return;
    _activePointer = null;
    _draggingIndex = null;
    _pendingTapDownPosition = null;
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
    final thresholdPercent =
        thresholdScenePx /
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
        final viewportSize = Size(constraints.maxWidth, constraints.maxHeight);
        _reframeIfNeeded(viewportSize);
        final (minScale, maxScale) = _scaleRangeFor(viewportSize);

        final viewer = InteractiveViewer(
          key: const Key('topo-interactive-viewer'),
          transformationController: widget.transformationController,
          // `constrained: false` is required because the child below is
          // deliberately OVERSIZED relative to the viewport (a full-res
          // photo, often much larger than the screen) and this widget drives
          // its scale/position entirely itself via `_fitMatrix`/
          // `computeCropTransform` written into `transformationController`.
          //
          // With the default `constrained: true`, InteractiveViewer does NOT
          // give the child an unbounded box (no `OverflowBox`) — the child
          // is laid out directly under the fit `Transform`, so it receives
          // the AMBIENT viewport constraints and gets clamped down to
          // (viewportWidth, viewportHeight) — losing the image's aspect
          // ratio — *before* the fit matrix is even applied. The fit matrix
          // (correctly computed against the true `imageSize`) then scales
          // that ALREADY-viewport-sized box down AGAIN, compounding into a
          // roughly `fitScale²` visual scale pinned to the top-left (the
          // `Transform`'s default alignment/origin) — exactly the "tiny
          // top-left thumbnail" bug. `constrained: false` wraps the child in
          // an `OverflowBox` with unbounded max constraints instead, so the
          // `SizedBox(width: imageSize.width, height: imageSize.height)`
          // below lays out at its TRUE natural size, and `_fitMatrix`/
          // `computeCropTransform`'s scale+translate is the only scaling
          // ever applied.
          constrained: false,
          // Draw mode: `panEnabled` stays OFF — single-finger movement is
          // reserved for tap-to-add-a-point / drag-an-existing-handle,
          // tracked by the raw `Listener` below — but `scaleEnabled` is
          // ALWAYS on, so a two-finger pinch still pans+zooms even while
          // drawing. The `Listener` branch below explains how the two are
          // kept from colliding (the raw pointer stream lets this widget
          // track the first finger for tap/drag while InteractiveViewer's
          // own recognizer independently handles a second finger's
          // pinch/pan). View mode: both stay on (unchanged).
          panEnabled: !isDrawMode,
          scaleEnabled: true,
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
                    currentSymbols: drawState.currentSymbols,
                    showHandles: isDrawMode && drawState.activeSymbol == null,
                    selectedRouteId: drawState.selectedRouteId,
                    palette: kRoutePalette,
                    // Live view-transform scale so TopoPainter can divide
                    // its scene-space sizes by it and render at a constant
                    // ON-SCREEN size instead of shrinking to a sub-pixel
                    // hairline at small fit scales (see TopoPainter.scale).
                    scale: _currentScale,
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

        // Full-bleed canvas rework: the viewport used to be VISUALLY clipped
        // to MasiRadii.large rounded corners via a `ClipRRect` spliced
        // between each branch's `Listener` and `viewer` (rather than an
        // ancestor of `Listener` — see git history for the corner-tap
        // hit-testing rationale that used to live here, since superseded).
        // The user asked for the photo/canvas to fill the whole screen
        // edge-to-edge, under the floating chrome and status bar, so there
        // is no rounding and no clip at all now: `viewer` is used directly
        // as each branch's `Listener` child, with nothing wrapping it.
        final Widget gestureLayer;
        if (!isDrawMode) {
          // Same rationale as the draw-mode Listener below: wrapping (not
          // replacing) InteractiveViewer with a raw-pointer Listener lets
          // this widget observe every down/up to disambiguate a tap from a
          // pan/zoom drag, without stealing anything from IV's own gesture
          // recognizers — they still see and act on the same events, so
          // pan/zoom keeps working exactly as before. Only a genuine tap
          // (see _endViewTap's movement-slop check) triggers a
          // select/deselect; a real drag is left entirely to IV.
          gestureLayer = Listener(
            key: const Key('topo-view-gesture-detector'),
            behavior: HitTestBehavior.opaque,
            onPointerDown: (event) =>
                _beginViewTap(event.pointer, event.localPosition),
            onPointerUp: (event) =>
                _endViewTap(event.pointer, event.localPosition),
            onPointerCancel: (event) => _cancelViewTap(event.pointer),
            child: viewer,
          );
        } else {
          // A plain GestureDetector (onTapUp/onPanStart/onPanUpdate) does
          // NOT work here: InteractiveViewer always installs its own
          // internal scale gesture recognizer on this same subtree
          // regardless of `panEnabled`/`scaleEnabled` — those flags only
          // suppress the *effect* (no actual pan/zoom happens), not the
          // recognizer's participation in the gesture arena. For a real
          // drag, that internal recognizer competes with — and can win
          // against — an outer GestureDetector's pan recognizer, silently
          // swallowing the gesture (onPanStart never fires, only
          // onPanCancel).
          //
          // Listener sidesteps this entirely: it observes raw pointer
          // events directly via hit-testing rather than through gesture-
          // arena disambiguation, so it reliably sees every down/move/up
          // for EVERY pointer, regardless of what InteractiveViewer's
          // internal recognizer decides to do with them — exactly what the
          // gesture model below needs: draw mode has `scaleEnabled: true`
          // (see the `InteractiveViewer` doc above), so a genuine
          // two-finger gesture IS handled by InteractiveViewer itself
          // (pan+zoom), while this Listener independently tracks the FIRST
          // finger to decide tap-add-a-point vs. drag-an-existing-handle,
          // and ABORTS that tracking the moment a second finger arrives
          // (see `_beginInteraction`'s early-return branch) so the two
          // behaviors never collide — a pinch never drops a stray point or
          // nudges a handle. Wrapping the InteractiveViewer itself (rather
          // than its child) means event.localPosition here is a "viewport
          // point" relative to InteractiveViewer's own untransformed box —
          // exactly what TransformationController.toScene expects.
          gestureLayer = Listener(
            key: const Key('topo-draw-gesture-detector'),
            behavior: HitTestBehavior.opaque,
            onPointerDown: (event) =>
                _beginInteraction(event.pointer, event.localPosition),
            onPointerMove: (event) =>
                _updateInteraction(event.pointer, event.localPosition),
            onPointerUp: (event) =>
                _endInteraction(event.pointer, event.localPosition),
            onPointerCancel: (event) => _cancelInteraction(event.pointer),
            child: viewer,
          );
        }

        // Full-bleed canvas rework: the viewport used to be wrapped in a
        // fixed, SCREEN-SPACE `DecoratedBox` (keyed
        // 'topo-canvas-viewport-frame') giving it rounded corners so the
        // photo read as a floating panel rather than filling the screen.
        // The user asked for the image/canvas to be edge-to-edge instead —
        // filling the whole screen and going UNDER the floating chrome and
        // status bar — so that frame is gone entirely: `gestureLayer` is
        // returned directly and fills whatever this `LayoutBuilder` is
        // given (ultimately the whole screen — see
        // `TopoCanvasBody.build`, which no longer reserves a top-clearance
        // `SizedBox` above this widget either). `BoxFit.contain` on the
        // `Image.file` above (unchanged) still keeps the WHOLE wall visible
        // — any letterboxing from an aspect mismatch falls against the
        // Scaffold's own `ground` fill showing through, which is the only
        // acceptable non-image area.
        return gestureLayer;
      },
    );
  }
}
