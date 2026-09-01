import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'package:masi/core/coordinates/coordinate_transformer.dart';
import 'package:masi/core/db/database_provider.dart'
    show photoFilesProvider, nowMsProvider;
import 'package:masi/features/topo/application/draw_controller.dart';
import 'package:masi/features/topo/application/draw_hint_providers.dart';
import 'package:masi/features/topo/application/wall_route_edit_permission.dart';
import 'package:masi/features/topo/data/photo_path_resolution.dart'
    show thumbKeyFor;
import 'package:masi/features/topo/domain/route_hit_test.dart';
import 'package:masi/features/topo/domain/topo_route.dart';
import 'package:masi/features/topo/presentation/grade_colors.dart';
import 'package:masi/features/topo/presentation/photo_image.dart';
import 'package:masi/features/topo/presentation/photo_loading_fill.dart';
import 'package:masi/features/topo/presentation/route_palette.dart';
import 'package:masi/features/topo/presentation/topo_painter.dart';
import 'package:masi/shared/presentation/masi_toast.dart';

/// Maps each [SymbolType] that has a dedicated masi brand glyph to its SVG
/// asset name suffix (`assets/icons/masi/masi_<name>.svg`) — the SAME
/// assets `MasiIcon`/the draw-mode `SymbolPaletteBar` render, so the
/// on-photo marker matches the palette glyph exactly. [SymbolType
/// .disabledHold] has no entry: it keeps [TopoPainter]'s hand-drawn
/// prohibition-sign geometry (no brand glyph exists for it) — see
/// [TopoPainter]'s "Symbol glyph mapping" doc.
const Map<SymbolType, String> _symbolGlyphAssetNames = {
  SymbolType.anchor: 'anchor',
  SymbolType.bolt: 'bolt',
  SymbolType.top: 'finish_flag',
  SymbolType.crux: 'crux',
};

/// Preloads [_symbolGlyphAssetNames]'s glyphs as [ui.Picture]s ONCE (called
/// from [_TopoCanvasState.initState], never from [TopoPainter.paint] —
/// which runs every frame) via `flutter_svg`'s exported `vg`
/// (`vector_graphics`) picture-decoding API — the same underlying decode
/// `MasiIcon`'s `SvgPicture.asset` uses. Each glyph's [PictureInfo.picture]
/// is recorded in the SVG's 24x24 viewBox space; [TopoPainter] scales it to
/// match the existing marker's on-screen size at paint time.
Future<Map<SymbolType, ui.Picture>> _loadSymbolPictures() async {
  final pictures = <SymbolType, ui.Picture>{};
  try {
    for (final entry in _symbolGlyphAssetNames.entries) {
      final info = await vg.loadPicture(
        SvgAssetLoader('assets/icons/masi/masi_${entry.value}.svg'),
        null,
      );
      pictures[entry.key] = info.picture;
    }
  } catch (_) {
    // A later glyph failed to decode: dispose every picture already
    // decoded in this call so far (real engine resources) before the
    // error propagates — otherwise they'd be orphaned, since nothing
    // downstream (initState's .catchError only sees the error object)
    // can reach them to dispose them itself.
    for (final picture in pictures.values) {
      picture.dispose();
    }
    rethrow;
  }
  return pictures;
}

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
    required this.wallId,
    required this.imagePath,
    required this.imageSize,
    required this.transformationController,
  });

  /// FIX #6: family key for [drawControllerProvider] — see that provider's
  /// doc. Always the same wallId as the owning [TopoCanvasScreen].
  final String wallId;

  /// Filesystem path of the selected topo photo.
  final String imagePath;

  /// The natural (decoded) size of the image at [imagePath]. Needed to
  /// convert between percent-space route coordinates (see [DrawState]) and
  /// scene/pixel coordinates.
  final Size imageSize;

  /// Shared with the owning screen so pan/zoom state (and coordinate
  /// mapping via [TransformationController.toScene]) persists across
  /// draw/view mode switches.
  final TransformationController transformationController;

  /// Pure computation of the scale at which [imageSize] fits entirely
  /// within a viewport of [viewportSize] (CONTAIN-fit: `min` of the two
  /// axis scales, letterboxed on whichever axis has slack) — the "see the
  /// whole wall" scale.
  ///
  /// Exposed as a static, side-effect-free method so its math can be
  /// asserted directly and deterministically in tests, independent of any
  /// widget/layout timing.
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
  /// [computeFitScale]) so its math can be asserted directly and
  /// deterministically in tests.
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
  /// [computeFitScale]/[computeFillScale]) for direct, deterministic
  /// testing.
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
  /// entire photo letterboxed, and so is [computeFitTransform] (the
  /// pre-existing COVER/fill transform, kept alongside this rather than
  /// replaced — see that method's doc).
  ///
  /// Exposed as a static, side-effect-free method (mirroring
  /// [computeFitTransform]) for direct, deterministic testing.
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
  /// open-framing transform: [_TopoCanvasState._fitMatrix] applies this in
  /// place of the older [computeContainTransform] (contain/letterboxed/
  /// centered) so the photo reads as filling the screen width on open
  /// instead of floating centered with gray bands on the sides — but,
  /// unlike the transform's previous (top-anchored-always) revision, a
  /// short/landscape photo's leftover vertical slack is now split evenly
  /// above and below rather than dumped entirely below the image.
  /// [computeContainTransform] is RETAINED — not deleted — as the CONTAIN
  /// reference [_TopoCanvasState._scaleRangeFor] uses for
  /// [InteractiveViewer]'s `minScale`: the user can always pinch OUT past
  /// this fill-width default to see the whole photo letterboxed.
  ///
  /// Exposed as a static, side-effect-free method (mirroring
  /// [computeContainTransform]) for direct, deterministic testing.
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
  /// The masi brand glyphs (see [_symbolGlyphAssetNames]) preloaded ONCE via
  /// [_loadSymbolPictures] in [initState] — never re-loaded on rebuild, and
  /// never loaded inside [TopoPainter.paint] (which runs every frame) —
  /// then handed to [TopoPainter] via its `symbolPictures` constructor
  /// param. Starts empty so the very first frame(s), before the async SVG
  /// decode completes, fall back to [TopoPainter]'s pre-existing hand-drawn
  /// geometry (see that class's doc) rather than blocking on the load; once
  /// loaded, [setState] swaps in the full map and triggers exactly one
  /// repaint.
  Map<SymbolType, ui.Picture> _symbolPictures = const {};

  @override
  void initState() {
    super.initState();
    _loadSymbolPictures()
        .then((pictures) {
          if (!mounted) {
            // Disposed before the load finished: dispose the just-decoded
            // pictures instead of leaking them (see [ui.Picture.dispose]'s
            // "caller's responsibility" contract) rather than assigning them
            // to a field on a widget that's gone.
            for (final picture in pictures.values) {
              picture.dispose();
            }
            return;
          }
          setState(() => _symbolPictures = pictures);
        })
        .catchError((Object error, StackTrace stackTrace) {
          // A glyph SVG failing to load/decode (missing asset, corrupt
          // file, etc.) must not surface as an unhandled async error (which
          // crashes a debug build / fails a test) nor leave this widget
          // wedged waiting on a Future that will never resolve
          // successfully. Swallowing it here simply leaves `_symbolPictures`
          // at whatever it already was (empty on the very first load
          // attempt), so every symbol keeps rendering via TopoPainter's
          // pre-existing hand-drawn fallback geometry (see that class's
          // doc) instead of ever throwing or hanging.
        });
    _maybeProbeDecodedSize();
  }

  @override
  void didUpdateWidget(TopoCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.imagePath != oldWidget.imagePath) {
      _maybeProbeDecodedSize();
    }
    if (widget.wallId != oldWidget.wallId) {
      // A different wall means a different [DrawController] instance, which
      // has never been told anything by this widget. Forgetting what we told
      // the PREVIOUS one is what keeps [_syncProposalOnlyGeometryEdits]'s
      // no-op check from swallowing the first push to the new one.
      _pushedProposalOnlyGeometryEdits = null;
    }
  }

  /// The last value this widget pushed to
  /// [DrawController.setProposalOnlyGeometryEdits], or null if it has pushed
  /// nothing to the CURRENT wall's controller yet.
  ///
  /// Exists purely to make [_syncProposalOnlyGeometryEdits] idempotent: it is
  /// called from every build, and this canvas rebuilds on every draw-state
  /// change (i.e. on every frame of a drag).
  bool? _pushedProposalOnlyGeometryEdits;

  /// Tells this wall's [DrawController] whether committed-route geometry
  /// edits here are the owner's own writes or a non-owner's proposal
  /// (`ROUTE_EDITING_PLAN.md` §3.2).
  ///
  /// The gestures themselves are identical either way — a non-owner drags a
  /// point and watches it move exactly as the owner does — and
  /// [DrawController.endRouteGeometryEdit] is the single place the two paths
  /// diverge, into a database write or an in-memory edit awaiting submission.
  /// This canvas' only job is to answer the question, which is why the answer
  /// is pushed as state rather than checked at each of the gesture sites.
  ///
  /// Deferred to after the frame because it is called FROM [build], and
  /// mutating another provider mid-build is exactly what Riverpod's
  /// `debugCanModifyProviders` guard exists to catch ("Tried to modify a
  /// provider while the widget tree was building"). It is driven from build
  /// rather than a `ref.listen` because a listener only fires on a CHANGE,
  /// and a [DrawController] can outlive this widget — both providers are
  /// family+autoDispose and the owning screen holds them alive across a photo
  /// switch — so the flag has to be asserted on mount, never assumed to still
  /// sit at its default.
  void _syncProposalOnlyGeometryEdits({required bool proposalOnly}) {
    if (_pushedProposalOnlyGeometryEdits == proposalOnly) return;
    _pushedProposalOnlyGeometryEdits = proposalOnly;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref
          .read(drawControllerProvider(widget.wallId).notifier)
          .setProposalOnlyGeometryEdits(proposalOnly);
    });
  }

  @override
  void dispose() {
    for (final picture in _symbolPictures.values) {
      picture.dispose();
    }
    super.dispose();
  }

  /// Starts a best-effort probe for [widget.imagePath]'s REAL decoded size —
  /// see [_decodedImageSize]'s doc for why. No-ops if a probe for this exact
  /// path has already been started (or already resolved) — [_decodeProbePath]
  /// tracks that. Called once from [initState] (the very first photo) and
  /// again from [didUpdateWidget] whenever [widget.imagePath] actually
  /// changes (a photo switch); never re-run for the SAME path on an
  /// unrelated rebuild.
  ///
  /// Uses [PhotoImageProvider] — the same cross-platform (native `FileImage`
  /// / web cached-blob-URL) dimension resolver [PhotoImage] itself decodes
  /// through, so this shares that decode/cache rather than doubling it (see
  /// `photo_image_source_native.dart`/`_web.dart`'s own dimension-probe
  /// docs) — purely to LEARN the real size, never to gate rendering on it:
  /// the `onError` branch deliberately does nothing (no error field, no
  /// state at all) so a probe failure changes zero observable behavior,
  /// unlike the pre-F-A2 architecture this deliberately does not repeat (see
  /// [_decodedImageSize]'s doc).
  void _maybeProbeDecodedSize() {
    final path = widget.imagePath;
    if (_decodeProbePath == path) return;
    _decodeProbePath = path;
    // A stale correction from whatever photo was previously active must
    // never leak onto this new one while its own probe is in flight.
    if (_decodedImageSize != null) {
      setState(() => _decodedImageSize = null);
    }

    final photoFiles = ref.read(photoFilesProvider);
    final stream = PhotoImageProvider(
      path,
      photoFiles: photoFiles,
    ).resolve(const ImageConfiguration());
    late ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, synchronousCall) {
        stream.removeListener(listener);
        // Stale-result guard: this widget may have moved on to a DIFFERENT
        // photo (or unmounted) while this decode was in flight.
        if (!mounted || _decodeProbePath != path) return;
        final real = Size(
          info.image.width.toDouble(),
          info.image.height.toDouble(),
        );
        if (real.width <= 0 || real.height <= 0 || real == widget.imageSize) {
          // Degenerate, or already agrees with the persisted size — nothing
          // to correct (the overwhelmingly common case).
          return;
        }
        setState(() => _decodedImageSize = real);
      },
      onError: (error, stackTrace) {
        stream.removeListener(listener);
        // Best-effort only — see this method's doc. Deliberately swallowed:
        // no field is set, so [_effectiveImageSize] keeps falling back to
        // [widget.imageSize] exactly as if this probe never ran.
      },
    );
    stream.addListener(listener);
  }

  /// Index into `DrawState.currentPoints` currently being dragged, or null
  /// if the user isn't mid-drag on an existing handle.
  int? _draggingIndex;

  /// The COMMITTED route whose geometry the current drag is editing, or null
  /// when the drag (if any) is on the draft line instead — see
  /// `ROUTE_EDITING_PLAN.md`.
  ///
  /// Held alongside exactly one of [_draggingRoutePointIndex] /
  /// [_draggingRouteSymbolIndex]; all three are cleared together. Kept as a
  /// route ID rather than an index into `DrawState.routes` for the same reason
  /// the controller's own operations are: a delete arriving mid-drag shifts
  /// every later index, and a drag that silently retargeted itself onto a
  /// different route would be very hard to explain afterwards.
  int? _draggingRouteId;

  /// Index into the dragged committed route's `points`, or null when the drag
  /// is on one of its symbols instead (or when there is no such drag).
  int? _draggingRoutePointIndex;

  /// Index into the dragged committed route's `symbols`, or null when the drag
  /// is on one of its points instead (or when there is no such drag).
  int? _draggingRouteSymbolIndex;

  /// Whether the current interaction started as a possible tap-to-add and was
  /// cancelled because the finger MOVED — i.e. the climber dragged across the
  /// photo, which in draw mode does nothing whatsoever.
  ///
  /// Cleared at the start of every interaction and by the second-finger abort,
  /// so a pinch-zoom (which also clears the pending tap) is never mistaken for
  /// someone trying and failing to draw. Consumed on pointer-up/cancel by
  /// [_maybeHintTapToDraw].
  bool _tapCancelledByDrag = false;

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
  /// Reframing (fit-to-viewport) is meant to run once PER distinct image —
  /// see [_framedImageSize] — never stomping the user's subsequent manual
  /// pan/zoom for that same image.
  bool _hasFramed = false;

  /// The `widget.imageSize` this widget was last framed for (Fix 1
  /// hardening) — so a genuinely NEW image still forces a fresh reframe
  /// rather than being treated as "unchanged". Without this,
  /// [TopoCanvasScreen] handing this same, long-lived [_TopoCanvasState] a
  /// new photo would silently keep showing the PREVIOUS photo's fit
  /// transform forever.
  ///
  /// NOT sufficient on its own to identify the content, though — see
  /// [_framedImagePath], which is the other half of that identity.
  Size? _framedImageSize;

  /// The `widget.imagePath` this widget was last framed for — the OTHER half
  /// of "is this the same content?", alongside [_framedImageSize].
  ///
  /// Size alone is not an identity: [TopoCanvasScreen] pins ONE
  /// [_TopoCanvasState] (via its `_canvasKey` GlobalKey) and ONE
  /// [TransformationController] across every photo it ever shows, and resets
  /// that controller to [Matrix4.identity] on each photo switch (see its
  /// `selectedImageProvider` listener). So switching to a DIFFERENT photo
  /// that happens to have the SAME pixel dimensions — two shots from the same
  /// camera in the same orientation, two equal slices of one photo, a wall
  /// whose photos were all imported at one resolution — used to take
  /// [_reframeIfNeeded]'s "truly unchanged" early return: no reframe ran, and
  /// the controller stayed at that freshly-written identity, which with
  /// `constrained: false` plus the natural-size (oversized) child paints the
  /// photo's TOP-LEFT CORNER AT 1:1, permanently. Keying content identity on
  /// the path too means a photo switch is ALWAYS a content reframe, whatever
  /// the dimensions.
  ///
  /// This matches the owning screen's own notion of identity exactly: it is
  /// a change of the selected image PATH that makes it call
  /// `beginPhotoSwitch` and reset the shared controller.
  String? _framedImagePath;

  /// The real, decoded natural size of [widget.imagePath]'s bytes, once
  /// learned via [_maybeProbeDecodedSize] — or `null` if it hasn't resolved
  /// yet (or ever failed to). [widget.imageSize] is a *persisted* value
  /// (the wall's [PhotoRef.width]/[PhotoRef.height], recorded once at import
  /// time — see [TopoCanvasScreen]'s doc) that this widget's caller can
  /// never re-verify against what actually decodes for THIS render: an
  /// EXIF-orientation disagreement between the import-time prober and the
  /// display-time decoder, or a public photo whose locally-available bytes
  /// are a substituted variant, can leave it describing a different aspect
  /// ratio than what [PhotoImage] actually paints.
  ///
  /// [PhotoImage] itself already tolerates that mismatch harmlessly — it
  /// paints via `BoxFit.contain`, so a wrong aspect ratio just letterboxes
  /// inside the `SizedBox(imageSize)` box. The real bug is everything
  /// ELSE sharing that same box: the route overlay ([TopoPainter]) and
  /// every hit test ([_hitTestHandle]/[_beginInteraction]/
  /// [_updateInteraction]/[_endInteraction]/[_endViewTap]) treat the WHOLE
  /// box as the image, so a letterboxed photo leaves them permanently
  /// offset from what's actually on screen.
  ///
  /// [_effectiveImageSize] is the single fix for this: once this field is
  /// non-null, EVERY use of "the image size" in this state — the paint
  /// box, the `CustomPaint` overlays, every coordinate conversion, and the
  /// fit/zoom-range math — switches to it, so the box always has the exact
  /// aspect ratio of what's actually decoded and `BoxFit.contain` never has
  /// anything left to letterbox. That is deliberately the ONLY change: no
  /// second, letterbox-offset transform is introduced anywhere, so paint
  /// and hit-test keep sharing exactly one mapping (this size, plus
  /// [widget.transformationController]) — see this class's `Transform`/
  /// `toScene` doc for why that single-sourcing matters.
  ///
  /// A failed/absent probe (no bytes yet, a genuinely missing photo) leaves
  /// this `null` forever for that photo, which is safe BY CONSTRUCTION:
  /// [_effectiveImageSize] then falls back to [widget.imageSize], exactly
  /// today's behavior. This is deliberately NOT the pre-F-A2 architecture
  /// (see `topo_canvas_missing_bytes_test.dart`) that latched a permanent
  /// error state on decode failure and blanked the whole canvas — a failed
  /// probe here changes NOTHING observable; only a SUCCESSFUL decode with a
  /// genuinely different size ever changes what's rendered.
  Size? _decodedImageSize;

  /// The `widget.imagePath` [_maybeProbeDecodedSize] has already started (or
  /// finished) a probe for, so a rebuild for the SAME photo never starts a
  /// second redundant probe. Reset (and [_decodedImageSize] cleared) the
  /// moment [widget.imagePath] changes, so a stale correction from the
  /// PREVIOUS photo can never leak onto a new one that happens to reuse this
  /// same long-lived [_TopoCanvasState] (mirrors [_framedImagePath]'s own
  /// per-photo scoping, for the same reason).
  String? _decodeProbePath;

  /// The image size every paint/overlay/hit-test/fit computation in this
  /// state actually uses — [_decodedImageSize] once a probe has SUCCESSFULLY
  /// resolved a real, positive-area size for the current photo, otherwise
  /// [widget.imageSize] (today's behavior). See [_decodedImageSize]'s doc for
  /// the full rationale; every call site below that used to read
  /// `widget.imageSize` directly now reads this instead, so there is exactly
  /// ONE size in play at any given time — never two competing derivations.
  Size get _effectiveImageSize => _decodedImageSize ?? widget.imageSize;

  /// The `viewportSize` this widget was last framed for (reframe-on-resize
  /// fix). A [LayoutBuilder] viewport can be transient/degenerate on its
  /// first pass (e.g. ~110x70, before a surrounding `Scaffold`'s `AppBar`/
  /// `BottomAppBar` settle to their final extents) — without tracking this,
  /// [_hasFramed] flipping true against that bogus size meant the resulting
  /// tiny fit scale stuck forever, rendering the wall photo as a tiny
  /// top-left thumbnail. Tracked alongside [_framedImageSize] so a later,
  /// settled viewport (differing by more than [_viewportChangeEpsilonPx] on
  /// either axis) forces a fresh reframe even when the image hasn't
  /// changed.
  Size? _framedViewportSize;

  /// The [Matrix4] this widget last wrote into
  /// [TopoCanvas.transformationController] via [_reframeIfNeeded]'s own
  /// auto-frame (fit-to-viewport), or null if it has never auto-framed.
  ///
  /// Used to distinguish "the viewport changed but the controller's value
  /// is still exactly what WE last set" (safe to replace with a fresh fit
  /// for the new viewport) from "the user has since manually panned/zoomed"
  /// (must NOT be stomped by a resize) — see the viewport-changed branch of
  /// [_reframeIfNeeded]. An image change always reframes unconditionally
  /// regardless of this, matching the pre-existing (M5) behavior.
  ///
  /// Written SYNCHRONOUSLY the moment a reframe is decided (still during
  /// `build`), one full frame BEFORE it's actually written into
  /// [TopoCanvas.transformationController] (see [_autoFrameWritePending] for
  /// why that gap matters, and why comparing the controller's live value
  /// against this field alone is not enough to tell "our own write hasn't
  /// landed yet" apart from "the user panned").
  Matrix4? _lastAutoFrameMatrix;

  /// True from the instant [_reframeIfNeeded] decides on a fresh
  /// [_lastAutoFrameMatrix] until the post-frame callback that actually
  /// writes it into [TopoCanvas.transformationController] runs — i.e. exactly
  /// the one-frame gap described on [_lastAutoFrameMatrix]'s doc.
  ///
  /// This is what fixes the "stale auto-fit sticks forever" bug: if
  /// [LayoutBuilder] runs a SECOND pass with a newer viewport size before
  /// that post-frame write lands, the controller's live value still holds
  /// the OLDER matrix — indistinguishable, by value alone, from a genuine
  /// user pan away from [_lastAutoFrameMatrix]. Without this flag,
  /// [_reframeIfNeeded]'s `stillAutoFramed` check reads that as "the user
  /// touched it" and bails, permanently committing the fit for the STALE
  /// viewport while the real one has already moved on. With it,
  /// `stillAutoFramed` also accepts "there is a pending write of OUR OWN
  /// that just hasn't landed yet" as still-auto-framed, so the second pass's
  /// fresh fit proceeds and simply supersedes the first — see
  /// [_reframeIfNeeded]'s post-frame callback for how a superseded (stale)
  /// callback then detects that and skips writing its now-outdated matrix,
  /// rather than clobbering the newer one that landed (or is about to).
  ///
  /// Cleared back to `false` the instant the write for the CURRENT
  /// [_lastAutoFrameMatrix] actually lands. A genuine user pan/zoom, in
  /// contrast, only ever happens once this flag is already `false` (nothing
  /// of ours is still in flight to confuse it with), so that detection is
  /// untouched by this fix — see [_reframeIfNeeded]'s `stillAutoFramed` doc.
  bool _autoFrameWritePending = false;

  /// True once [_reframeIfNeeded]'s auto-fit transform for the CURRENT image
  /// has actually been written into [widget.transformationController] — which
  /// happens one frame LATE, in a post-frame callback, because the controller
  /// cannot be mutated during the build that reads the viewport size. Until
  /// then the controller is at identity (or a freshly-reset identity on image
  /// switch); with `constrained: false` + the oversized natural-size child,
  /// identity paints the photo's top-left corner at 1:1 scale — the "zoomed
  /// into the top-left" flash of bug #78, seen only when a warm-cache decode
  /// is ready on that very first frame (hence intermittent, and web-prone).
  /// [build] gates the photo/overlay layer's opacity on this so that pre-fit
  /// identity frame is never painted; it flips true (via setState) the instant
  /// the fit lands, and for a pre-seeded controller it is set true immediately
  /// (nothing to hide).
  bool _autoFrameApplied = false;

  /// The pointer id that started the current view-mode down/up interaction
  /// (see [_beginViewTap]/[_endViewTap]), or null when none is in progress.
  int? _viewTapPointer;

  /// The viewport-local position at which [_viewTapPointer] went down, used
  /// by [_endViewTap] to measure total movement and decide tap vs. drag.
  Offset? _viewTapDownPosition;

  double get _currentScale =>
      widget.transformationController.value.getMaxScaleOnAxis();

  /// Whether [widget.imageSize] is a size this canvas can actually fit
  /// against — i.e. strictly positive on both axes.
  ///
  /// A degenerate (zero/negative) image size is NOT a small image, it is an
  /// ABSENT one: [TopoCanvas.computeFillWidthTransform] falls back to scale
  /// 1.0 for it, so framing against it COMMITS a scale-1-at-the-origin
  /// transform — precisely the "zoomed into the top-left corner, not fitted"
  /// symptom. [_reframeIfNeeded] therefore refuses to frame at all while this
  /// is false (mirroring its existing [_minFrameableViewportDimensionPx]
  /// guard on the viewport), and [build] holds the photo/overlay layer at
  /// opacity 0 for as long as it stays false — the canvas never paints
  /// content transformed against a size it does not have. The moment a real
  /// size arrives, that is the first REAL content frame and gets a proper
  /// fit.
  bool get _hasFrameableImageSize =>
      _effectiveImageSize.width > 0 && _effectiveImageSize.height > 0;

  /// Computes the scale at which [widget.imageSize] fits entirely within a
  /// viewport of [viewportSize] (letterboxed on whichever axis has slack).
  /// Delegates to [TopoCanvas.computeFitScale] (the pure, directly-testable
  /// form of this same math).
  double _fitScale(Size viewportSize) => TopoCanvas.computeFitScale(
    imageSize: _effectiveImageSize,
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
  /// The DEFAULT framing's applied scale
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
      imageSize: _effectiveImageSize,
      viewportSize: viewportSize,
    ).getMaxScaleOnAxis();
    if (fillWidthScale > maxScale) {
      maxScale = fillWidthScale;
    }

    return (minScale, maxScale);
  }

  /// Builds the DEFAULT fit-to-viewport matrix: [widget.imageSize] scaled
  /// by WIDTH ALONE to span [viewportSize]'s full width, then vertically
  /// centered within any leftover slack (fill-width — not
  /// CONTAIN/letterboxed on both axes). Delegates to
  /// [TopoCanvas.computeFillWidthTransform] (the pure, directly-testable
  /// form of this same math) — see that method's doc for why the default
  /// open-framing is fill-width/vertically-centered rather than the
  /// CONTAIN/centered-on-both-axes behavior
  /// ([TopoCanvas.computeContainTransform], still used elsewhere as the
  /// zoom-out reference — see [_scaleRangeFor]) or the older COVER/fill
  /// behavior ([TopoCanvas.computeFitTransform]).
  Matrix4 _fitMatrix(Size viewportSize) => TopoCanvas.computeFillWidthTransform(
    imageSize: _effectiveImageSize,
    viewportSize: viewportSize,
  );

  /// Frames [widget.transformationController] to the whole image
  /// fit-to-viewport (via [_fitMatrix]).
  ///
  /// Re-applies whenever the image, OR the viewport size itself, has
  /// changed materially (by more than [_viewportChangeEpsilonPx] on either
  /// axis) since the last application (tracked via [_framedImageSize]/
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
  /// pan/zoom) has touched it since. An image change, in contrast, always
  /// reframes unconditionally (matching pre-existing M5 behavior): that's a
  /// deliberate, always-applied override.
  ///
  /// As a special case, on the very first frame, a pre-seeded/non-identity
  /// [widget.transformationController] (as some callers/tests supply) is
  /// left exactly as given rather than being overwritten with the fit
  /// transform — this preserves pre-M5 behavior. That escape hatch does not
  /// apply once this widget has already framed at least once.
  ///
  /// Because [CoordinateTransformer.sceneToPercent]/`toScene` work off the
  /// controller's *live* matrix (see `TopoCanvas` doc comment / call sites
  /// in [_beginInteraction] etc.), initializing the controller to a pure
  /// scale+translate here does not change what "scene space" means — scene
  /// space is always `widget.imageSize`-sized pixels, `toScene` just now
  /// inverts a matrix that starts pre-zoomed/pre-centered instead of at
  /// identity. Percent math (`sceneToPercent`/`percentToScene`) is
  /// unaffected either way since it never reads the transform directly.
  void _reframeIfNeeded(Size viewportSize) {
    if (viewportSize.width < _minFrameableViewportDimensionPx ||
        viewportSize.height < _minFrameableViewportDimensionPx) {
      // Transient/degenerate viewport: skip framing entirely rather than
      // committing to whatever tiny scale it would imply. `_hasFramed` is
      // deliberately left untouched so the next (hopefully real) viewport
      // is treated as the genuine first frame.
      return;
    }

    if (!_hasFrameableImageSize) {
      // No usable image dimensions (zero/absent — see
      // [_hasFrameableImageSize]): framing against them would commit a
      // scale-1-at-the-origin transform, which is the top-left-at-1:1 bug
      // itself. Skip entirely, touching NO framing bookkeeping, so whatever
      // fit is already applied for real content stays applied and the next
      // valid size is framed on its own merits. `build` keeps the photo
      // layer hidden meanwhile.
      return;
    }

    // Content identity is the PHOTO, not merely its dimensions — see
    // [_framedImagePath] for why size alone let a same-dimensions photo
    // switch slip through the "truly unchanged" early return below and
    // strand the new photo at identity.
    final sameImage =
        _framedImageSize == _effectiveImageSize &&
        _framedImagePath == widget.imagePath;
    final viewportChanged =
        _framedViewportSize == null ||
        (_framedViewportSize!.width - viewportSize.width).abs() >
            _viewportChangeEpsilonPx ||
        (_framedViewportSize!.height - viewportSize.height).abs() >
            _viewportChangeEpsilonPx;

    // Whether this reframe is for NEW content — the first frame ever, or a
    // switched-to image — as opposed to a same-image viewport change. Only
    // content reframes hide the photo until the auto-fit lands (see
    // [_autoFrameApplied]); a viewport-only reframe must NOT hide it, or the
    // photo would flicker on every resize (e.g. the community detail header
    // collapsing as it scrolls).
    final isContentReframe = !_hasFramed || !sameImage;

    // Somebody OUTSIDE this widget wrote identity to the shared controller
    // since our last auto-frame — and [TopoCanvasScreen] does exactly that,
    // unconditionally, from its `selectedImageProvider` listener.
    //
    // Both branches below reason only about OUR OWN inputs (content, viewport)
    // and about a USER pan; neither can see a third party stomping the
    // controller. When that write lands without any accompanying content or
    // viewport change, the "truly unchanged" early return fires, nothing
    // reframes, and — because `_autoFrameApplied` is already true from the
    // previous frame — the photo stays VISIBLE at identity, which with
    // `constrained: false` plus the oversized child paints its top-left corner
    // at 1:1 and never recovers. That is bug #78 arriving by a different road
    // than the ones the guards above were built for.
    //
    // Identity is safe to treat as "not ours": every fit this method computes
    // for a real (positive-sized) image is a scale+translate that is only
    // identity in the degenerate case, and `_hasFrameableImageSize` has already
    // excluded that above. `_autoFrameWritePending` is excluded because during
    // that window identity is legitimately still on the controller — it is our
    // own not-yet-applied write, not a foreign one.
    final externallyReset =
        _lastAutoFrameMatrix != null &&
        !_autoFrameWritePending &&
        _lastAutoFrameMatrix != Matrix4.identity() &&
        widget.transformationController.value == Matrix4.identity();

    if (_hasFramed && sameImage && !viewportChanged && !externallyReset) {
      return; // Truly unchanged: never stomp a manual pan/zoom.
    }

    if (_hasFramed && sameImage && viewportChanged) {
      // Only the viewport moved (the reframe-on-resize fix): re-fit to the
      // NEW viewport unless the user has manually panned/zoomed since the
      // last auto-frame, detected by the controller's live value having
      // drifted away from the matrix WE last wrote. A stale auto-frame
      // must never block a later, larger viewport's fit; a genuine user
      // adjustment must never be stomped by a resize.
      //
      // `_autoFrameWritePending` is the other half of that detection (see
      // its own doc): the controller's live value can ALSO differ from
      // `_lastAutoFrameMatrix` for a reason that is NOT a user pan — our
      // own previous reframe's post-frame write for that matrix simply
      // hasn't run yet (this same [LayoutBuilder] got a second pass, with
      // a newer viewport, before that one frame elapsed). Treating that as
      // "still auto-framed" lets THIS pass's fresh fit proceed and
      // supersede the still-pending one, rather than mistaking our own
      // lag for a manual pan and permanently committing the stale
      // viewport's fit — the "auto-fit sticks after a fast resize" bug.
      // `externallyReset` is the third way the live value can legitimately
      // differ from `_lastAutoFrameMatrix` without a user having panned: the
      // owning screen reset the shared controller to identity. Without it here,
      // a resize arriving after such a reset is read as "the user has taken
      // over" and returns — stranding the photo at identity for exactly the
      // same reason the branch above had to account for.
      final stillAutoFramed =
          _lastAutoFrameMatrix != null &&
          (widget.transformationController.value == _lastAutoFrameMatrix ||
              _autoFrameWritePending ||
              externallyReset);
      if (!stillAutoFramed) return;
    } else if (!_hasFramed &&
        widget.transformationController.value != Matrix4.identity()) {
      // First frame ever, and a test/caller pre-seeded a non-identity
      // controller: leave it exactly as given.
      _hasFramed = true;
      _framedImageSize = _effectiveImageSize;
      _framedImagePath = widget.imagePath;
      _framedViewportSize = viewportSize;
      _lastAutoFrameMatrix = null;
      _autoFrameWritePending = false;
      // Pre-seeded controller already holds a valid transform — nothing to
      // hide, so reveal immediately.
      _autoFrameApplied = true;
      return;
    }

    _hasFramed = true;
    _framedImageSize = _effectiveImageSize;
    _framedImagePath = widget.imagePath;
    _framedViewportSize = viewportSize;

    final matrix = _fitMatrix(viewportSize);

    _lastAutoFrameMatrix = matrix;
    // A write for THIS matrix is now in flight — see
    // `_autoFrameWritePending`'s doc. Stays true across however many further
    // reframes supersede this one before the callback below actually runs;
    // only the callback that matches the CURRENT `_lastAutoFrameMatrix` ever
    // clears it.
    _autoFrameWritePending = true;

    if (isContentReframe) {
      // Hide the photo for the single pre-fit frame: until the callback below
      // writes `matrix`, the controller is at identity (or a just-reset
      // identity on image switch), which — with `constrained: false` + the
      // oversized child — paints the photo's top-left corner at 1:1 (bug #78).
      // Revealed again the moment the fit is applied.
      _autoFrameApplied = false;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_lastAutoFrameMatrix != matrix) {
        // Superseded: a LATER reframe (decided before this callback got its
        // turn) has already replaced `_lastAutoFrameMatrix` with a fresher
        // matrix for a fresher viewport, and scheduled its OWN callback to
        // write that one. Writing this stale `matrix` now would clobber
        // that newer, still-pending write (or a write that already landed)
        // with an outdated fit — skip it entirely and let the superseding
        // reframe's own callback be the one that actually lands.
        return;
      }
      widget.transformationController.value = matrix;
      _autoFrameWritePending = false;
      if (!_autoFrameApplied) {
        setState(() => _autoFrameApplied = true);
      }
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
        _effectiveImageSize,
      );
      final distance = (scenePoint - sceneTap).distance;
      if (distance <= thresholdScenePx && distance < nearestDistance) {
        nearestIndex = i;
        nearestDistance = distance;
      }
    }
    return nearestIndex;
  }

  /// The [SymbolType] marker of [route] under [sceneTap], if any — the
  /// marker-side twin of [_hitTestHandle], with the same zoom-adjusted radius
  /// and the same nearest-wins rule.
  ///
  /// Separate from [_hitTestHandle] only because a symbol's position lives on
  /// [TopoSymbol.position] rather than being an [Offset] in a flat list; the
  /// geometry is deliberately identical, so a marker and a point are equally
  /// easy to grab.
  int? _hitTestRouteSymbol(Offset sceneTap, TopoRoute route) {
    final scale = _currentScale;
    final thresholdScenePx = _handleHitRadiusPx / (scale == 0 ? 1 : scale);
    int? nearestIndex;
    var nearestDistance = double.infinity;
    for (var i = 0; i < route.symbols.length; i++) {
      final scenePoint = CoordinateTransformer.percentToScene(
        route.symbols[i].position,
        _effectiveImageSize,
      );
      final distance = (scenePoint - sceneTap).distance;
      if (distance <= thresholdScenePx && distance < nearestDistance) {
        nearestIndex = i;
        nearestDistance = distance;
      }
    }
    return nearestIndex;
  }

  /// The committed route currently selected, or null if none is (or the
  /// selection points at a route that no longer exists).
  ///
  /// Selection is what makes a committed route editable at all: its markers
  /// render only while it is selected (feature #43) and so do its point
  /// handles, so an unselected route has nothing on screen to grab. That is
  /// also the feature's entry point — see [_beginInteraction].
  TopoRoute? _selectedCommittedRoute(DrawState drawState) {
    final selectedId = drawState.selectedRouteId;
    if (selectedId == null) return null;
    for (final route in drawState.routes) {
      if (route.id == selectedId) return route;
    }
    return null;
  }

  /// Removes whatever [scene] lands on in [route] — a marker first, then a
  /// point — and closes the resulting one-tap edit gesture.
  ///
  /// Markers are tested before points because a marker is the smaller target
  /// and sits ON the line: testing points first would make a marker placed
  /// near a point unreachable, since the point would always win.
  void _eraseAt(Offset scene, TopoRoute route) {
    final notifier = ref.read(drawControllerProvider(widget.wallId).notifier);

    final symbolIndex = _hitTestRouteSymbol(scene, route);
    if (symbolIndex != null) {
      unawaited(HapticFeedback.selectionClick());
      notifier.removeRouteSymbol(route.id, symbolIndex);
      unawaited(notifier.endRouteGeometryEdit(route.id));
      return;
    }

    final pointIndex = _hitTestHandle(scene, route.points);
    if (pointIndex == null) return;

    if (route.points.length <= 2) {
      // [DrawController.removeRoutePoint] refuses below two points, because a
      // one-point route draws no line at all while still holding a number and
      // a legend row. Refusing SILENTLY is the part worth avoiding: the
      // climber taps a handle with the eraser, watches nothing happen, and has
      // no way to tell a floor from a broken tool.
      ScaffoldMessenger.of(context).showMasiToast(
        'A route needs at least two points. Delete the route '
              'instead to remove it.',
        kind: MasiToastKind.warning,
      );
      return;
    }

    unawaited(HapticFeedback.selectionClick());
    notifier.removeRoutePoint(route.id, pointIndex);
    unawaited(notifier.endRouteGeometryEdit(route.id));
  }

  /// Clears the committed-route drag fields and closes the controller-side
  /// edit gesture, persisting everything the drag did as ONE change and ONE
  /// undo entry (`ROUTE_EDITING_PLAN.md` §3.1).
  ///
  /// Called from every exit path a drag has — pointer-up, pointer-cancel, and
  /// the second-finger abort — because the moves are already applied and
  /// already on screen by the time any of them run. Leaving one of those paths
  /// out would not undo the drag; it would leave it visible and unsaved, which
  /// is the failure mode this whole layer exists to avoid.
  void _endRouteGeometryDrag() {
    final routeId = _draggingRouteId;
    _draggingRouteId = null;
    _draggingRoutePointIndex = null;
    _draggingRouteSymbolIndex = null;
    if (routeId == null) return;
    unawaited(
      ref
          .read(drawControllerProvider(widget.wallId).notifier)
          .endRouteGeometryEdit(routeId),
    );
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
      // A second finger means a pinch/pan, not a failed attempt to draw. The
      // pending tap is cancelled either way, so without this the zoom gesture
      // would be answered with "dragging does not draw".
      _tapCancelledByDrag = false;
      // The committed-route drag is settled rather than merely dropped: its
      // moves are already applied and on screen, so abandoning the fields
      // without closing the gesture would leave that edit unpersisted and
      // absent from the undo stack. See [_endRouteGeometryDrag].
      _endRouteGeometryDrag();
      return;
    }
    _activePointer = pointerId;
    _tapCancelledByDrag = false;
    final scene = widget.transformationController.toScene(
      viewportLocalPosition,
    );
    final drawState = ref.read(drawControllerProvider(widget.wallId));
    final selectedRoute = _selectedCommittedRoute(drawState);

    // PRIORITY 1 — the eraser. An explicitly-chosen tool is the most explicit
    // intent available, so it outranks everything below it. It is also
    // mutually exclusive with symbol placement by construction:
    // [DrawController.setEraserActive] CLEARS `activeSymbol`, so the branch
    // just below cannot also be live.
    if (drawState.activeTool == DrawTool.eraser) {
      _draggingIndex = null;
      _pendingTapDownPosition = null;
      if (selectedRoute != null) _eraseAt(scene, selectedRoute);
      return;
    }

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
        _effectiveImageSize,
      );
      final outcome = await ref
          .read(drawControllerProvider(widget.wallId).notifier)
          .placeSymbol(percent);
      // This method is now async (awaiting placeSymbol above), so `mounted`
      // must be re-checked before touching `context` below — the widget may
      // have been unmounted while that await was in flight.
      if (!mounted) return;
      if (outcome == SymbolPlacementOutcome.noRouteAvailable) {
        ScaffoldMessenger.of(context).showMasiToast(
          'Draw a route first to place symbols',
          kind: MasiToastKind.info,
        );
      }
      return;
    }

    // PRIORITY 3 — a handle of the DRAFT line. An active draw always beats
    // editing a committed route: the line being drawn right now is the thing
    // the climber is looking at, and its handles are the ones under their
    // finger.
    final hitIndex = _hitTestHandle(scene, drawState.currentPoints);
    if (hitIndex != null) {
      _draggingIndex = hitIndex;
      _pendingTapDownPosition = null;
      unawaited(HapticFeedback.selectionClick());
      return;
    }

    // PRIORITIES 4 and 5 — the selected committed route's own geometry. This
    // is the feature's entry point: there is no menu item and no separate
    // edit mode, because selecting a route in draw mode already makes its
    // handles and markers appear, and grabbing one is the affordance.
    //
    // Markers before points, for the reason given on [_eraseAt]: a marker is
    // the smaller target and sits on the line, so testing points first would
    // make any marker near a point impossible to grab.
    //
    // Deliberately NOT gated on who owns the wall. Editing someone else's line
    // is allowed here and produces a proposal instead of a write — the canvas
    // says which of those two it is by pushing ownership into the controller
    // (see [build]'s [canEditWallRoutesProvider] listener), and
    // [DrawController.endRouteGeometryEdit] is where the two paths diverge.
    // Putting the fork there rather than in this hit-test funnel is what lets
    // a non-owner drag a point, see it move, and then decide to submit it.
    if (selectedRoute != null) {
      final symbolIndex = _hitTestRouteSymbol(scene, selectedRoute);
      if (symbolIndex != null) {
        _draggingIndex = null;
        _pendingTapDownPosition = null;
        _draggingRouteId = selectedRoute.id;
        _draggingRouteSymbolIndex = symbolIndex;
        _draggingRoutePointIndex = null;
        unawaited(HapticFeedback.selectionClick());
        return;
      }

      final routePointIndex = _hitTestHandle(scene, selectedRoute.points);
      if (routePointIndex != null) {
        _draggingIndex = null;
        _pendingTapDownPosition = null;
        _draggingRouteId = selectedRoute.id;
        _draggingRoutePointIndex = routePointIndex;
        _draggingRouteSymbolIndex = null;
        unawaited(HapticFeedback.selectionClick());
        return;
      }
    }

    // PRIORITY 6 — no handle hit: this MIGHT be a tap-to-add, but don't commit it yet —
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
        _effectiveImageSize,
      );
      ref
          .read(drawControllerProvider(widget.wallId).notifier)
          .movePoint(draggingIndex, percent);
      return;
    }

    // A committed route's point or marker. Every frame mutates in-memory
    // state and NOTHING else — no database write, no undo entry — which is
    // the whole reason [DrawController.endRouteGeometryEdit] exists as a
    // separate boundary. See its doc: a two-second drag is roughly 120 of
    // these.
    final draggingRouteId = _draggingRouteId;
    if (draggingRouteId != null) {
      final scene = widget.transformationController.toScene(
        viewportLocalPosition,
      );
      final percent = CoordinateTransformer.sceneToPercent(
        scene,
        _effectiveImageSize,
      );
      final notifier = ref.read(
        drawControllerProvider(widget.wallId).notifier,
      );
      final symbolIndex = _draggingRouteSymbolIndex;
      if (symbolIndex != null) {
        notifier.moveRouteSymbol(draggingRouteId, symbolIndex, percent);
      } else {
        final pointIndex = _draggingRoutePointIndex;
        if (pointIndex != null) {
          notifier.moveRoutePoint(draggingRouteId, pointIndex, percent);
        }
      }
      return;
    }

    final downPosition = _pendingTapDownPosition;
    if (downPosition == null) return;
    final movement = (viewportLocalPosition - downPosition).distance;
    if (movement > _tapMovementSlopPx) {
      _pendingTapDownPosition = null;
      // Remember WHY the tap was cancelled. This is the gesture that does
      // nothing at all — draw mode disables panning, so a single-finger drag
      // across the photo neither draws nor moves the view — and it is the
      // instinctive way to try to draw a line. The hint fires on pointer-up
      // rather than here: mid-drag the finger is still on the photo, and
      // popping a message under it while it moves reads as an error.
      _tapCancelledByDrag = true;
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
    final wasEditingRoute = _draggingRouteId != null;
    // Persists the whole drag as one change and one undo entry.
    _endRouteGeometryDrag();

    if (wasEditingRoute) return;
    if (draggingIndex != null) return; // Handle drag: already applied.
    if (pendingTapDownPosition == null) {
      // Cancelled: moved past the slop, or aborted by a 2nd finger. Only the
      // first of those is someone trying to draw by dragging.
      _maybeHintTapToDraw();
      return;
    }

    final scene = widget.transformationController.toScene(
      viewportLocalPosition,
    );
    final percent = CoordinateTransformer.sceneToPercent(
      scene,
      _effectiveImageSize,
    );
    unawaited(HapticFeedback.selectionClick());
    ref.read(drawControllerProvider(widget.wallId).notifier).addPoint(percent);
    // A point landed, so whatever the hint was saying has been answered.
    ref.read(drawHintProvider.notifier).dismiss();
  }

  /// Shows the "tap, don't drag" hint if the interaction that just ended was a
  /// drag across empty canvas that added nothing.
  ///
  /// The guard is [_tapCancelledByDrag] rather than "the pending tap is gone",
  /// because a second finger clears the pending tap too and a pinch must not
  /// be answered with drawing advice.
  void _maybeHintTapToDraw() {
    if (!_tapCancelledByDrag) return;
    _tapCancelledByDrag = false;
    ref
        .read(drawHintProvider.notifier)
        .reportFruitlessDrag(ref.read(nowMsProvider)());
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
    // A pointer-cancel after a fruitless drag is the same confusion as a
    // pointer-up after one — the finger left the glass either way, and nothing
    // was drawn.
    _maybeHintTapToDraw();
    // A cancelled committed-route drag is still SETTLED rather than dropped.
    // Unlike a pending tap-to-add — which has changed nothing yet, and so has
    // nothing to save — the drag's moves have already been applied and the
    // climber has already watched the line follow their finger. Discarding
    // them here would silently unsave an edit that is visibly on screen; the
    // honest close is to keep it, as one change and one undo entry they can
    // reverse deliberately.
    _endRouteGeometryDrag();
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
    final scale = _currentScale;
    final thresholdScenePx = _handleHitRadiusPx / (scale == 0 ? 1 : scale);

    final drawState = ref.read(drawControllerProvider(widget.wallId));
    // Hit-test in true scene-pixel space rather than [CoordinateTransformer]'s
    // normalized "percent" space: percent.dx is a fraction of `imageSize
    // .width` while percent.dy is a fraction of `imageSize.height`
    // independently, so on a non-square photo one percent-unit is a
    // different physical distance on each axis. Comparing a single scalar
    // threshold against a percent-space distance would make the hit
    // tolerance anisotropic (tighter on the shorter axis). Converting both
    // the tap and every route point to real scene pixels first makes the
    // distance calculation isotropic, so `thresholdScenePx` applies
    // symmetrically on both axes.
    final scenePointRoutes = [
      for (final route in drawState.routes)
        route.copyWith(
          points: [
            for (final p in route.points)
              CoordinateTransformer.percentToScene(p, _effectiveImageSize),
          ],
        ),
    ];
    final hitId = hitTestRoute(scene, scenePointRoutes, thresholdScenePx);
    ref.read(drawControllerProvider(widget.wallId).notifier).selectRoute(hitId);
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
    final drawState = ref.watch(drawControllerProvider(widget.wallId));
    final isDrawMode = drawState.mode == DrawMode.draw;
    // Whether this wall's committed routes are ours to WRITE, or only ours to
    // propose changes to (`ROUTE_EDITING_PLAN.md` §3.2) — pushed into the
    // controller by [_syncProposalOnlyGeometryEdits] below.
    //
    // ## An unresolved answer pushes NOTHING, deliberately
    //
    // Ownership is a database read, so it is `AsyncLoading` for the first
    // frame(s). Staying silent leaves the controller at its own default
    // (`proposalOnlyGeometryEdits: false` — writes persist), so "don't know
    // yet" fails OPEN, towards owner. That direction is chosen, not
    // incidental: at worst a not-yet-classified foreign wall persists one
    // gesture locally, a write that RLS refuses to push and the next sync pull
    // overwrites; the other direction would silently reroute an owner's first
    // edit on their OWN topo into a proposal to themselves, which is a
    // data-loss shape. Same keep-by-default posture as `PublicPhotoPruner`:
    // act only on what is positively proven foreign. Pushing an explicit
    // `false` while unknown would be worse than pushing nothing, since
    // [DrawController.setProposalOnlyGeometryEdits] discards pending
    // baselines on the way down — a flap through `false` would throw away
    // edits a returning non-owner had not submitted yet.
    //
    // `hasValue`/`requireValue`, NOT `asData?.value`, for the reason
    // `account_screen.dart` records: in Riverpod v3 a REFRESHING provider is
    // an `AsyncLoading` that still carries its previous value, and reading
    // through `asData` would throw a settled answer away on every re-emission
    // — here, silently reverting a foreign wall to "ours to write" mid-edit.
    final mayEdit = ref.watch(canEditWallRoutesProvider(widget.wallId));
    if (mayEdit.hasValue) {
      _syncProposalOnlyGeometryEdits(proposalOnly: !mayEdit.requireValue);
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final viewportSize = Size(constraints.maxWidth, constraints.maxHeight);
        _reframeIfNeeded(viewportSize);
        final (minScale, maxScale) = _scaleRangeFor(viewportSize);

        final Widget interactiveViewer = InteractiveViewer(
          key: const Key('topo-interactive-viewer'),
          transformationController: widget.transformationController,
          // `constrained: false` is required because the child below is
          // deliberately OVERSIZED relative to the viewport (a full-res
          // photo, often much larger than the screen) and this widget drives
          // its scale/position entirely itself via `_fitMatrix` written into
          // `transformationController`.
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
          // below lays out at its TRUE natural size, and `_fitMatrix`'s
          // scale+translate is the only scaling ever applied.
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
            width: _effectiveImageSize.width,
            height: _effectiveImageSize.height,
            child: Stack(
              children: [
                // PROGRESSIVE LOAD, layer 1 of 2: the 512px thumbnail this
                // photo already has, painted underneath the original.
                //
                // The original is the largest decode in the app by a wide
                // margin — the user's own library has 7-9 MB originals whose
                // thumbnails are 52-65 KB — and on web every one of those
                // megabytes is an IndexedDB read, a blob URL and a
                // full-resolution decode before a single pixel appears. That
                // is the whole of the reported slowness ("images still load
                // very slowly", 2026-08-11), and it is worse the better the
                // photo, which is why some topos felt fine and others did not.
                //
                // The thumbnail costs ~1% of that, is written at import time
                // for every photo (see `PhotoFiles.importPhoto`), and is
                // usually already decoded — it is what the row the climber
                // just tapped was showing. So it paints essentially at once
                // and the original replaces it, in place, the moment it is
                // ready: the standard progressive-image swap.
                //
                // Geometry is identical by construction and the swap cannot
                // jump: the thumbnail is a proportional downscale of the same
                // photo, laid out in the same box under the same
                // `BoxFit.contain`. It is blurry until the original lands,
                // which is the entire trade being made.
                //
                // `thumbKeyFor` takes the RESOLVED original path and returns
                // the relative `thumbs/<id>.jpg` storage key; `PhotoImage`
                // re-resolves that through `PhotoFiles.resolvePhotoPathSync`
                // (a docs-dir join on native, a passthrough on web), exactly
                // as `LibraryCrudRepository._resolveThumbnail` does for the
                // list rows. A photo with no thumbnail (one imported before
                // that tier, or whose best-effort write failed) resolves to
                // nothing and falls through to the skeleton below, which is
                // precisely the behaviour this call site had before.
                PhotoImage(
                  thumbKeyFor(widget.imagePath),
                  key: const Key('topo-canvas-photo-thumb'),
                  fit: BoxFit.contain,
                  width: _effectiveImageSize.width,
                  height: _effectiveImageSize.height,
                  placeholder: () => const SizedBox.shrink(),
                  // The skeleton lives HERE now rather than on the original
                  // below — this is the layer that arrives first, so it is
                  // the honest place to say "coming". Square corners and the
                  // photo's exact box: this photo is full-bleed (see build's
                  // doc), so a rounded or differently sized placeholder would
                  // move the moment the real frame arrived.
                  loadingPlaceholder: () => PhotoLoadingFill(
                    width: _effectiveImageSize.width,
                    height: _effectiveImageSize.height,
                  ),
                ),
                // PROGRESSIVE LOAD, layer 2 of 2: the real, full-resolution
                // photo, painted over the thumbnail and covering it entirely
                // once it has a frame.
                PhotoImage(
                  widget.imagePath,
                  // Keyed so a test can name THIS layer rather than
                  // `find.byType(PhotoImage)`, which now matches two.
                  key: const Key('topo-canvas-photo'),
                  fit: BoxFit.contain,
                  width: _effectiveImageSize.width,
                  height: _effectiveImageSize.height,
                  // DELIBERATELY no `cacheWidth`/`cacheHeight`, even though
                  // this is far and away the largest decode in the app. Two
                  // reasons, in order:
                  //
                  //  1. Full resolution is the POINT here. This canvas
                  //     pinch-zooms well past 1:1 so a line can be placed on
                  //     an individual hold; decoding it at viewport size
                  //     would make the zoom show nothing but the decoder's
                  //     own blur.
                  //  2. A sized decode would not even replace the full one.
                  //     `cacheWidth` wraps the provider in a `ResizeImage`,
                  //     which is a DIFFERENT `imageCache` key — and this
                  //     screen already resolves the UNSIZED image through
                  //     `PhotoImageProvider` for its dimension probe (see
                  //     `_maybeProbeDecodedSize`). So the hint would decode
                  //     this photo a second time and retain both bitmaps:
                  //     strictly more memory, which is the opposite of why
                  //     anyone would add it. See [PhotoImage]'s doc for what
                  //     these hints do and don't buy, per platform.
                  //
                  // Bounding what the app RETAINS across screens is a
                  // separate lever (the global `imageCache` budget), not this
                  // one.
                  // Swallow decode errors (e.g. a path that doesn't resolve
                  // to a real file, as widget tests use) instead of letting
                  // them propagate as an unhandled exception — see class
                  // doc for why tests can pump this widget without a real
                  // image file.
                  placeholder: () => const SizedBox.shrink(),
                  // TRANSPARENT while the original resolves — the thumbnail
                  // underneath is what the climber looks at for that window,
                  // and a skeleton here would paint straight over it and
                  // undo the whole point.
                  //
                  // The "never blank" property #56 added this slot for is not
                  // lost, it is improved: the case it was written against —
                  // the image cache evicting this bitmap, or a photo-switch
                  // back, blanking a canvas the climber was already looking
                  // at with the route overlay floating over the backdrop —
                  // now falls back to the thumbnail rather than to a
                  // skeleton, and only to the skeleton if the thumbnail is
                  // missing too (see the layer below's own
                  // `loadingPlaceholder`).
                  loadingPlaceholder: () => const SizedBox.shrink(),
                ),
                // Wrapped in a ListenableBuilder on the transformation
                // controller (bug fix: "lines are super thin until you tap
                // one") — `_currentScale` reads the controller's LIVE value,
                // but that value changes out-of-band from this widget's own
                // `build()`: the fit/fill reframe (`_reframeIfNeeded` above)
                // writes the real, non-identity scale into the controller
                // from a POST-FRAME callback, well after this `build()` has
                // already run and already captured a stale `scale == 1.0`.
                // Without listening, that stale scale stuck in the painter
                // until SOME UNRELATED rebuild (e.g. a Riverpod state change
                // from tapping/selecting a route) happened to re-run
                // `build()` and sample the now-correct scale — which is
                // exactly the reported symptom (thin at open, normal after a
                // tap). This ListenableBuilder re-reads `_currentScale` and
                // rebuilds `TopoPainter` on every controller tick, fixing
                // both the first-paint reframe and keeping the on-screen
                // line width constant during live pinch-zoom.
                ListenableBuilder(
                  listenable: widget.transformationController,
                  // RepaintBoundary (web-perf fix): this painter repaints on
                  // every transform-controller tick (live pinch-zoom/pan —
                  // see this `ListenableBuilder`'s own doc) as well as every
                  // `DrawState` change while drawing. Isolating it into its
                  // own layer means those frequent repaints don't force the
                  // `PhotoImage` layer sharing this `Stack`
                  // to re-composite alongside it. Doesn't change
                  // `TopoPainter` or its `shouldRepaint` — purely a
                  // layer-boundary hint.
                  builder: (context, _) => RepaintBoundary(
                    child: CustomPaint(
                      size: _effectiveImageSize,
                      painter: TopoPainter(
                        imageSize: _effectiveImageSize,
                        routes: drawState.routes,
                        currentPoints: drawState.currentPoints,
                        currentSymbols: drawState.currentSymbols,
                        showHandles:
                            isDrawMode && drawState.activeSymbol == null,
                        selectedRouteId: drawState.selectedRouteId,
                        // The selected committed route's own points get
                        // handles too, in draw mode, which is the entire
                        // affordance for editing it — there is no menu item
                        // and no separate edit mode (`ROUTE_EDITING_PLAN.md`
                        // §4.4). Selection is the gate rather than a
                        // decoration: a committed route's markers already
                        // render only while it is selected (feature #43), so
                        // handles appearing on the same condition means
                        // everything grabbable appears and disappears
                        // together.
                        //
                        // Deliberately NOT gated on `activeSymbol == null` the
                        // way `showHandles` above is. That gate exists so the
                        // draft's handles stop competing with symbol
                        // PLACEMENT taps; here the opposite is wanted, because
                        // the eraser's whole job is to hit these handles and
                        // it would be unusable if selecting it hid them.
                        editableRouteId: isDrawMode
                            ? drawState.selectedRouteId
                            : null,
                        palette: kRoutePalette,
                        // Live view-transform scale so TopoPainter can divide
                        // its scene-space sizes by it and render at a constant
                        // ON-SCREEN size instead of shrinking to a sub-pixel
                        // hairline at small fit scales (see TopoPainter.scale).
                        scale: _currentScale,
                        // Wires grade-band coloring into the canvas itself
                        // (not just the legend, see route_legend.dart): a
                        // stable top-level function reference — not a closure
                        // allocated fresh per build — so
                        // TopoPainter.shouldRepaint's reference comparison of
                        // routeColorResolver stays stable across rebuilds (see
                        // topoRouteColor's doc).
                        routeColorResolver: topoRouteColor,
                        // The masi brand glyphs preloaded once in initState
                        // (see [_symbolPictures]'s doc) — empty on the very
                        // first frame(s), so TopoPainter falls back to its
                        // hand-drawn geometry until the async SVG decode
                        // completes.
                        symbolPictures: _symbolPictures,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );

        // Gate the photo/overlay layer's opacity on [_autoFrameApplied] so the
        // single pre-fit identity frame — which paints the photo's top-left
        // corner at 1:1 — is never shown (bug #78). Opacity keeps the subtree
        // laid out and decoding (so the image is ready the instant the fit
        // lands and this flips to 1.0) and, unlike IgnorePointer/Offstage,
        // does NOT block InteractiveViewer's gestures.
        //
        // [_hasFrameableImageSize] is the second half of the same invariant:
        // with no usable image dimensions there is no fit to apply at all
        // (see that getter, and [_reframeIfNeeded]'s matching skip), so the
        // layer stays hidden rather than painting the scale-1-at-the-origin
        // fallback. Together: this canvas NEVER paints content through a
        // transform that is not a real fit for the size it actually has.
        final viewer = Opacity(
          opacity: (_autoFrameApplied && _hasFrameableImageSize) ? 1.0 : 0.0,
          child: interactiveViewer,
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
