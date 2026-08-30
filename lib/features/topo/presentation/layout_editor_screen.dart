import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart' hide Baseline;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:masi/app/theme.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/features/library/application/library_providers.dart';
import 'package:masi/features/topo/application/face_layout_providers.dart';
import 'package:masi/features/topo/data/photo_repository.dart';
import 'package:masi/features/topo/domain/face_layout/baseline.dart';
import 'package:masi/features/topo/domain/face_layout/baseline_synthesis.dart';
import 'package:masi/features/topo/domain/face_layout/layout_resolver.dart';
import 'package:masi/features/topo/presentation/layout_baseline_painter.dart';
import 'package:masi/features/topo/presentation/layout_plane_fit.dart';
import 'package:masi/features/topo/presentation/thumbnail_arrangement.dart';
import 'package:masi/features/topo/presentation/photo_image.dart';
import 'package:masi/shared/presentation/masi_icon.dart';

/// The layout editor: one line, and the wall's photos riding it.
///
/// Every correction here is a drag on the picture. There is no form, no
/// coordinate field, and — deliberately — no control anywhere that asks
/// whether this rock is a boulder or a wall: closing the stroke onto itself
/// is the only thing that makes it a ring, exactly as closing any polygon is.
/// Asking the question in words would mean asking every contributor to hold a
/// model in their head, and the whole design goal is that they hold none.
class LayoutEditorScreen extends ConsumerStatefulWidget {
  const LayoutEditorScreen({required this.wallId, super.key});

  final String wallId;

  @override
  ConsumerState<LayoutEditorScreen> createState() => _LayoutEditorScreenState();
}

/// A pan recognizer that will not hand the pointer to the scrolling list
/// above it once it has decided the touch belongs to the canvas.
///
/// The editor's canvas lives inside a `ListView`, and a `ListView` claims any
/// drag with a vertical component. So tracing a rock — which is a drag with a
/// vertical component almost by definition — scrolled the page instead of
/// drawing, and dragging a photo up the line scrolled it too. Only a
/// dead-level horizontal drag ever reached the canvas, which is why this
/// looked like "redraw does nothing" rather than like a gesture conflict.
///
/// [shouldClaim] keeps the theft narrow: the canvas takes the pointer only
/// while redrawing, or when the touch lands on a handle or a face. A touch
/// on empty canvas still scrolls the page, so the screen does not become a
/// trap on a small phone.
class _CanvasPanRecognizer extends PanGestureRecognizer {
  _CanvasPanRecognizer({required this.shouldClaim});

  final bool Function(Offset globalPosition) shouldClaim;
  bool _claiming = false;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    _claiming = shouldClaim(event.position);
    super.addAllowedPointer(event);
  }

  @override
  void rejectGesture(int pointer) {
    if (_claiming) {
      acceptGesture(pointer);
      return;
    }
    super.rejectGesture(pointer);
  }
}

class _LayoutEditorScreenState extends ConsumerState<LayoutEditorScreen> {
  String? _selectedFaceId;
  bool _bannerDismissed = false;

  /// The stroke being drawn right now, in plane coordinates, or `null` when
  /// not in redraw mode.
  List<LayoutPoint>? _draftPoints;

  /// The mapping a redraw is being recorded through, pinned when the stroke
  /// starts and held until it is committed.
  ///
  /// Deriving the fit from the draft — which is what this screen used to do —
  /// rescales the plane on every pointer move as the draft's bounds grow, so
  /// a straight drag records as a curve that accelerates away from its start,
  /// and the finished stroke is a shape nobody drew. Pinning it is the whole
  /// fix.
  LayoutPlaneFit? _redrawFit;

  /// The canvas's last laid-out size, so [_startRedraw] can pin a fit before
  /// the next build. Written during build and never read to decide layout, so
  /// it cannot drive a rebuild of its own.
  Size? _canvasSize;

  /// The canvas box, so a global pointer position can be turned into a
  /// position on the plan.
  final GlobalKey _canvasBoxKey = GlobalKey();

  /// The face being dragged along the line, and the position it has reached.
  String? _draggingFaceId;
  double? _draggingT;

  /// The baseline vertex being dragged, and the whole stroke as edited so far.
  ///
  /// Reshaping by handle is the design's primary correction — 'diamond
  /// handles reshape it' — and its absence is what left redrawing the entire
  /// line as the only way to fix one that was slightly wrong.
  int? _draggingHandle;
  List<LayoutPoint>? _handlePoints;

  /// Whether the stroke being reshaped is a ring. Reshaping never changes
  /// that — only redrawing does — so it is carried across the drag rather
  /// than re-derived from the moved points.
  bool _handleClosed = false;

  bool get _redrawing => _draftPoints != null;

  /// What the canvas's width stands for when drawing a line from scratch.
  /// A crag-sized default: big enough that a boulder is not a dot, small
  /// enough that a wall does not run off the edge.
  static const double _blankSpanMetres = 40;

  /// How close, IN PIXELS, a stroke's end must come to its start to be a ring.
  /// Pixels rather than a fraction of the stroke's own size: proportional
  /// thresholds grow with a messy stroke, which is how a wall drawn as a
  /// 135 m scribble got a 16 m closure radius and became a boulder.
  static const double _closeGapPx = 28;

  /// Douglas-Peucker tolerance, in pixels of the canvas it was drawn on.
  static const double _simplifyPx = 3;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    final layoutAsync = ref.watch(wallLayoutProvider(widget.wallId));
    final photos = ref.watch(wallOriginalsProvider(widget.wallId)).value ??
        const <PhotoRef>[];

    return Scaffold(
      backgroundColor: colors.ground,
      appBar: AppBar(
        title: const Text('Layout'),
        actions: [
          TextButton(
            key: const Key('layout-done'),
            onPressed: () => Navigator.of(context).maybePop(),
            child: const Text('Done'),
          ),
        ],
      ),
      body: layoutAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text('Could not read this topo’s layout.\n$error'),
          ),
        ),
        data: (layout) => _body(context, colors, layout, photos),
      ),
    );
  }

  Widget _body(
    BuildContext context,
    MasiColors colors,
    LayoutResult layout,
    List<PhotoRef> photos,
  ) {
    if (photos.isEmpty) {
      return Center(
        child: Text(
          'Add a photo and this topo gets a layout.',
          style: TextStyle(color: colors.ink2),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      children: [
        if (_redrawing)
          _redrawHint(colors)
        else if (layout.isProvisional && !_bannerDismissed)
          _banner(colors),
        const SizedBox(height: 12),
        _canvas(colors, layout, photos),
        const SizedBox(height: 10),
        Text(
          _caption(layout, photos),
          key: const Key('layout-caption'),
          style: TextStyle(
            fontFeatures: const [FontFeature.tabularFigures()],
            fontSize: 11,
            height: 1.5,
            letterSpacing: 0.5,
            color: colors.ink2,
          ),
        ),
        const SizedBox(height: 18),
        _captureOrderRail(colors, layout, photos),
        const SizedBox(height: 18),
        if (_selectedFaceId != null)
          _selectedCard(colors, layout, photos, _selectedFaceId!),
        const SizedBox(height: 18),
        _actions(colors, layout),
      ],
    );
  }

  /// What to actually DO, while doing it.
  ///
  /// Redrawing used to start with no instruction anywhere on screen: the
  /// button said 'Redraw line', the canvas cleared, and the contributor was
  /// left to guess that this surface wants a finger dragged across it and
  /// that ending where you started is what makes a boulder. Both facts are
  /// unguessable and neither was written down.
  Widget _redrawHint(MasiColors colors) => Container(
    key: const Key('layout-redraw-hint'),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    decoration: BoxDecoration(
      color: colors.amethyst100,
      borderRadius: BorderRadius.circular(MasiRadii.card),
      border: Border.all(color: colors.accent.withValues(alpha: 0.35)),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MasiIcon('edit', size: 18, color: colors.accent),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            (_draftPoints?.isEmpty ?? true)
                ? 'Drag across the box to trace the rock, the way you walked '
                      'it. Finish where you started and it becomes a boulder '
                      'you can walk around.'
                : 'Lift your finger to keep this line. Cancel leaves the old '
                      'one alone.',
            style: TextStyle(fontSize: 13, height: 1.4, color: colors.ink2),
          ),
        ),
      ],
    ),
  );

  Widget _banner(MasiColors colors) => Container(
    key: const Key('layout-confidence-banner'),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    decoration: BoxDecoration(
      color: colors.amethyst100,
      borderRadius: BorderRadius.circular(MasiRadii.card),
      border: Border.all(color: colors.accent.withValues(alpha: 0.22)),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MasiIcon('compass', size: 18, color: colors.accent),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            'We assembled this line from your photos. '
            'Drag anything that looks wrong.',
            style: TextStyle(fontSize: 13, height: 1.4, color: colors.ink2),
          ),
        ),
        // Dismissible and never blocking: a guessed layout is still a usable
        // topo, so this must never stand between a contributor and the rest
        // of the screen.
        GestureDetector(
          key: const Key('layout-banner-dismiss'),
          onTap: () => setState(() => _bannerDismissed = true),
          child: MasiIcon('close', size: 16, color: colors.ink3),
        ),
      ],
    ),
  );

  Widget _canvas(
    MasiColors colors,
    LayoutResult layout,
    List<PhotoRef> photos,
  ) => LayoutBuilder(
    builder: (context, constraints) {
      final size = Size(constraints.maxWidth, 240);
      _canvasSize = size;
      final draft = _draftPoints == null ? null : Baseline(_draftPoints!);
      // Never fitted to the draft: see _redrawFit. While redrawing, the
      // pinned fit is the one the stroke is being recorded through, so what
      // is painted and what is stored agree.
      final fit = _redrawFit ??
          LayoutPlaneFit.forBaseline(layout.baseline, size);
      final preview = _previewLayout(layout, photos);
      // Resolved ONCE per build and shared by the painter (leaders) and the
      // widgets (the boxes themselves) — two independent placements of the
      // same thumbnail is exactly how a leader ends up pointing at nothing.
      final slots = arrangeThumbnails(
        anchors: LayoutBaselinePainter.anchorsFor(preview, fit),
        canvas: size,
        stem: LayoutBaselinePainter.stemLength,
      );

      Offset toLocal(Offset global) {
        final box =
            _canvasBoxKey.currentContext?.findRenderObject() as RenderBox?;
        return box == null ? global : box.globalToLocal(global);
      }

      return RawGestureDetector(
        behavior: HitTestBehavior.opaque,
        gestures: <Type, GestureRecognizerFactory>{
          TapGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
                TapGestureRecognizer.new,
                (instance) {
                  instance.onTapUp = (TapUpDetails details) =>
                      _handleTap(
                        toLocal(details.globalPosition),
                        preview,
                        fit,
                        slots,
                      );
                },
              ),
          _CanvasPanRecognizer:
              GestureRecognizerFactoryWithHandlers<_CanvasPanRecognizer>(
                () => _CanvasPanRecognizer(
                  shouldClaim: (global) {
                    if (_redrawing) return true;
                    final at = toLocal(global);
                    return _handleNear(at, preview, fit) != null ||
                        _faceNear(at, preview, fit, slots) != null;
                  },
                ),
                (instance) {
                  // Report the position the finger actually landed on, not
                  // the one ~18px later where the drag cleared touch slop.
                  // Without this the stroke silently loses its first
                  // centimetres, which matters most for the one comparison
                  // that decides ring-or-wall: did it end where it began.
                  instance.dragStartBehavior = DragStartBehavior.down;
                  instance.onStart = (DragStartDetails details) =>
                      _panStart(
                        toLocal(details.globalPosition),
                        preview,
                        fit,
                        slots,
                      );
                  instance.onUpdate = (DragUpdateDetails details) =>
                      _panUpdate(toLocal(details.globalPosition), preview, fit);
                  instance.onEnd = (DragEndDetails details) => _panEnd();
                },
              ),
        },
        child: Container(
          key: _canvasBoxKey,
          height: size.height,
          decoration: BoxDecoration(
            color: colors.surface2,
            borderRadius: BorderRadius.circular(MasiRadii.card),
            border: Border.all(color: colors.separator),
          ),
          child: Stack(
            children: [
              Positioned.fill(
                child: CustomPaint(
                  key: const Key('layout-canvas'),
                  painter: LayoutBaselinePainter(
                    layout: preview,
                    fit: fit,
                    stroke: colors.amethyst400,
                    provisionalStroke: colors.amethyst300,
                    dotColor: colors.accent,
                    pinnedColor: colors.accent,
                    handleColor: colors.amethyst400,
                    selectedFaceId: _selectedFaceId,
                    slots: slots,
                    showHandles: !_redrawing,
                    draft: draft,
                  ),
                ),
              ),
              if (!_redrawing)
                for (final face in preview.faces)
                  _thumbnail(colors, face, photos, slots),
            ],
          ),
        ),
      );
    },
  );

  /// The layout as it should look RIGHT NOW, including a drag in progress.
  ///
  /// A drag has to preview without being saved: writing on every pointer move
  /// would put one sync-dirty row per frame through the push engine, and
  /// dropping the finger somewhere the contributor did not mean would be
  /// unrecoverable. So the pin is applied locally for the duration and
  /// committed once, on release.
  LayoutResult _previewLayout(LayoutResult layout, List<PhotoRef> photos) {
    // A handle drag reshapes the LINE, so the faces have to be re-resolved
    // against it rather than carried over: they ride the stroke, and a stroke
    // that moved without them would show every photo hanging off it.
    final edited = _handlePoints;
    if (edited != null && edited.length >= 2) {
      return resolveLayout(
        faces: faceInputsFrom(photos),
        baseline: Baseline(edited, closed: layout.baseline.closed),
        origin: BaselineOrigin.authored,
      );
    }
    final draggingId = _draggingFaceId;
    final draggingT = _draggingT;
    if (draggingId == null || draggingT == null) return layout;
    return LayoutResult(
      baseline: layout.baseline,
      origin: layout.origin,
      orientation: layout.orientation,
      thumbnailNormalSign: layout.thumbnailNormalSign,
      faces: [
        for (final face in layout.faces)
          if (face.id == draggingId)
            FacePosition(
              id: face.id,
              captureOrder: face.captureOrder,
              t: draggingT,
              placement: FacePlacement.pinned,
            )
          else
            face,
      ],
    );
  }

  Widget _thumbnail(
    MasiColors colors,
    FacePosition face,
    List<PhotoRef> photos,
    List<ThumbnailSlot> slots,
  ) {
    ThumbnailSlot? slot;
    for (final candidate in slots) {
      if (candidate.id == face.id) slot = candidate;
    }
    if (slot == null) return const SizedBox.shrink();
    final photo = _photoFor(photos, face.id);
    final selected = face.id == _selectedFaceId;

    return Positioned(
      // Landscape, and half again as large as the 44px square this used to
      // be. A square crop of a landscape photo of a crag throws away the
      // sides — which is precisely the part that tells one face from the
      // next — and at 44px what survived was unreadable.
      left: slot.topLeft.dx,
      top: slot.topLeft.dy,
      child: IgnorePointer(
        child: Container(
          key: Key('layout-face-${face.id}'),
          width: slot.size.width,
          height: slot.size.height,
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: BorderRadius.circular(MasiRadii.control),
            border: Border.all(
              color: selected ? colors.accent : colors.separator,
              width: selected ? 2 : 1,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // The thumbnail, not the original: this draws EVERY face of the
              // wall at once, so the originals would be N full-resolution
              // decodes in one frame. See [PhotoThumbnail].
              if (photo != null) PhotoThumbnail(photo.localPath),
              if (face.isPinned)
                Align(
                  alignment: Alignment.topRight,
                  child: Container(
                    key: Key('layout-face-pinned-${face.id}'),
                    margin: const EdgeInsets.all(2),
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: colors.accent,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _captureOrderRail(
    MasiColors colors,
    LayoutResult layout,
    List<PhotoRef> photos,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        'CAPTURE ORDER',
        style: TextStyle(
          fontSize: 12,
          letterSpacing: 0.4,
          fontWeight: FontWeight.w500,
          color: colors.ink2,
        ),
      ),
      const SizedBox(height: 8),
      SizedBox(
        height: 52,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: layout.faces.length,
          separatorBuilder: (_, _) => const SizedBox(width: 6),
          itemBuilder: (context, index) {
            final face = layout.faces[index];
            final photo = _photoFor(photos, face.id);
            return GestureDetector(
              key: Key('layout-order-${face.id}'),
              onTap: () => setState(() => _selectedFaceId = face.id),
              child: Container(
                width: 52,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(MasiRadii.control),
                  border: Border.all(
                    color: face.id == _selectedFaceId
                        ? colors.accent
                        : colors.separator,
                    width: face.id == _selectedFaceId ? 2 : 1,
                  ),
                ),
                clipBehavior: Clip.antiAlias,
                child: photo == null
                    ? const SizedBox.shrink()
                    : PhotoThumbnail(photo.localPath),
              ),
            );
          },
        ),
      ),
      const SizedBox(height: 6),
      Text(
        'The line never reshuffles this order — only your drag does.',
        style: TextStyle(fontSize: 13, height: 1.35, color: colors.ink2),
      ),
    ],
  );

  Widget _selectedCard(
    MasiColors colors,
    LayoutResult layout,
    List<PhotoRef> photos,
    String faceId,
  ) {
    final face = layout.positionOf(faceId);
    if (face == null) return const SizedBox.shrink();
    final photo = _photoFor(photos, faceId);

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(MasiRadii.card),
        border: Border.all(color: colors.separator),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 52,
            height: 52,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(MasiRadii.control),
              child: photo == null
                  ? const SizedBox.shrink()
                  : PhotoImage(photo.localPath),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Photo ${face.captureOrder + 1}',
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _placementLabel(face.placement),
                  key: const Key('layout-selected-placement'),
                  style: TextStyle(fontSize: 13, color: colors.ink2),
                ),
              ],
            ),
          ),
          if (face.isPinned)
            TextButton(
              key: const Key('layout-unpin'),
              onPressed: () => ref
                  .read(photoRepositoryProvider)
                  .setFacePin(faceId, null),
              child: const Text('Unpin'),
            ),
        ],
      ),
    );
  }

  Widget _actions(MasiColors colors, LayoutResult layout) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _actionRow(colors, layout),
      // The way back. A stored line that came out wrong used to be
      // unrecoverable without drawing an acceptable one first — and the
      // reason to reach for this is usually that drawing went badly.
      if (!layout.isProvisional && !_redrawing)
        TextButton(
          key: const Key('layout-reset'),
          onPressed: () => ref
              .read(libraryCrudRepositoryProvider)
              .setWallBaseline(widget.wallId, null),
          child: const Text('Use the automatic line instead'),
        ),
    ],
  );

  Widget _actionRow(MasiColors colors, LayoutResult layout) => Row(
    children: [
      Expanded(
        child: FilledButton.tonal(
          key: const Key('layout-redraw'),
          onPressed: _redrawing ? _cancelRedraw : () => _startRedraw(layout),
          child: Text(_redrawing ? 'Cancel' : 'Redraw line'),
        ),
      ),
      const SizedBox(width: 10),
      Expanded(
        child: FilledButton(
          key: const Key('layout-accept'),
          // Accepting a guess is a real edit: it promotes the synthesised
          // line to an authored one, which stops it being re-synthesised (and
          // silently changing) the next time a photo is added.
          onPressed: _redrawing || !layout.isProvisional
              ? null
              : () => _accept(layout),
          child: const Text('Accept'),
        ),
      ),
    ],
  );

  String _caption(LayoutResult layout, List<PhotoRef> photos) {
    final located = photos.where((p) => p.captureLatitude != null).length;
    final source = switch (layout.origin) {
      BaselineOrigin.authored => 'Your line',
      BaselineOrigin.gpsTrack => 'From $located GPS points',
      BaselineOrigin.bearingRing => 'From your photos’ headings',
      BaselineOrigin.bearingStrip => 'From your photos’ headings',
      BaselineOrigin.captureOrderStrip => 'In the order you shot them',
    };
    return layout.isProvisional
        ? '$source · dashed = a guess'
        : '$source · solid = accepted';
  }

  String _placementLabel(FacePlacement placement) => switch (placement) {
    FacePlacement.pinned => 'You placed this one',
    FacePlacement.gpsProjected => 'Placed from its GPS',
    FacePlacement.bearingRefined => 'Placed from its heading',
    FacePlacement.captureOrder => 'Placed in capture order',
  };

  PhotoRef? _photoFor(List<PhotoRef> photos, String id) {
    for (final photo in photos) {
      if (photo.id == id) return photo;
    }
    return null;
  }

  void _handleTap(
    Offset at,
    LayoutResult layout,
    LayoutPlaneFit fit,
    List<ThumbnailSlot> slots,
  ) {
    if (_redrawing) return;
    final hit = _faceNear(at, layout, fit, slots);
    setState(() => _selectedFaceId = hit?.id);
  }

  void _panStart(
    Offset at,
    LayoutResult layout,
    LayoutPlaneFit fit,
    List<ThumbnailSlot> slots,
  ) {
    if (_redrawing) {
      setState(() => _draftPoints = [fit.toPlane(at)]);
      return;
    }
    // Handles win over faces: a handle sits ON the line and a thumbnail sits
    // off it, so where they compete the finger is far likelier to be aiming
    // at the line it is touching.
    final handle = _handleNear(at, layout, fit);
    if (handle != null) {
      setState(() {
        _selectedFaceId = null;
        _draggingHandle = handle;
        _handleClosed = layout.baseline.closed;
        _handlePoints = [...layout.baseline.points];
      });
      return;
    }
    final hit = _faceNear(at, layout, fit, slots);
    if (hit == null) return;
    setState(() {
      _selectedFaceId = hit.id;
      _draggingFaceId = hit.id;
      _draggingT = hit.t;
    });
  }

  void _panUpdate(Offset at, LayoutResult layout, LayoutPlaneFit fit) {
    if (_redrawing) {
      setState(() => _draftPoints = [...?_draftPoints, fit.toPlane(at)]);
      return;
    }
    final handle = _draggingHandle;
    final points = _handlePoints;
    if (handle != null && points != null && handle < points.length) {
      setState(() {
        _handlePoints = [...points]..[handle] = fit.toPlane(at);
      });
      return;
    }
    if (_draggingFaceId == null) return;
    // Snapped onto the line rather than following the finger freely: a face
    // is a position ALONG the rock, and a thumbnail sitting off the stroke
    // would be claiming a second dimension the model does not have.
    setState(() => _draggingT = layout.baseline.project(fit.toPlane(at)).t);
  }

  Future<void> _panEnd() async {
    if (_redrawing) {
      await _commitDraft();
      return;
    }
    final reshaped = _handlePoints;
    if (_draggingHandle != null) {
      setState(() {
        _draggingHandle = null;
        _handlePoints = null;
      });
      if (reshaped != null && reshaped.length >= 2) {
        await _storeBaseline(Baseline(reshaped, closed: _handleClosed));
      }
      return;
    }
    final faceId = _draggingFaceId;
    final t = _draggingT;
    setState(() {
      _draggingFaceId = null;
      _draggingT = null;
    });
    if (faceId == null || t == null) return;
    await ref.read(photoRepositoryProvider).setFacePin(faceId, t);
  }

  FacePosition? _faceNear(
    Offset at,
    LayoutResult layout,
    LayoutPlaneFit fit,
    List<ThumbnailSlot> slots,
  ) {
    // A thumbnail that the arrangement pass moved is grabbed where it IS,
    // not where its normal would have put it — so the box under the finger is
    // always the one that responds. The rect is tested directly rather than by
    // distance-to-centre: a 64x48 box has corners a plain radius misses.
    for (final slot in slots) {
      if (slot.rect.inflate(6).contains(at)) {
        final face = layout.positionOf(slot.id);
        if (face != null) return face;
      }
    }
    FacePosition? best;
    var bestDistance = double.infinity;
    for (final face in layout.faces) {
      final distance =
          (fit.toCanvas(layout.baseline.pointAt(face.t)) - at).distance;
      if (distance < bestDistance) {
        bestDistance = distance;
        best = face;
      }
    }
    // A generous radius, because the target is a dot on a phone and the
    // alternative to hitting it is dragging the wrong photo.
    return bestDistance <= 34 ? best : null;
  }

  /// The baseline vertex under the finger, if any.
  int? _handleNear(Offset at, LayoutResult layout, LayoutPlaneFit fit) {
    final points = layout.baseline.points;
    if (points.length < 2) return null;
    int? best;
    var bestDistance = double.infinity;
    for (var i = 0; i < points.length; i++) {
      final distance = (fit.toCanvas(points[i]) - at).distance;
      if (distance < bestDistance) {
        bestDistance = distance;
        best = i;
      }
    }
    // Tighter than the face radius: handles can sit close together on a
    // detailed stroke, and grabbing the wrong one silently deforms the rock.
    return bestDistance <= 22 ? best : null;
  }

  Future<void> _storeBaseline(Baseline baseline) => ref
      .read(libraryCrudRepositoryProvider)
      .setWallBaseline(widget.wallId, baseline.encode());

  void _startRedraw(LayoutResult layout) => setState(() {
    _draftPoints = const [];
    _selectedFaceId = null;
    // Pinned BEFORE the first point, so the whole stroke is recorded through
    // one mapping. Falls back to a fixed crag-sized span when there is no
    // line to inherit a scale from.
    final size = _canvasSize ?? const Size(360, 240);
    _redrawFit = layout.baseline.isDegenerate
        ? LayoutPlaneFit.forSpan(size, _blankSpanMetres)
        : LayoutPlaneFit.forBaseline(layout.baseline, size);
  });

  void _cancelRedraw() => setState(() {
    _draftPoints = null;
    _redrawFit = null;
  });

  Future<void> _commitDraft() async {
    final points = _draftPoints;
    if (points == null || points.length < 2) {
      setState(() => _draftPoints = null);
      return;
    }

    // The closure gesture, and the only way this app has of being told
    // something is a boulder: if the stroke ends near where it began, it is a
    // ring. Measured in PIXELS of the canvas it was drawn on — see
    // _closeGapPx for why a proportional threshold was the wrong instrument.
    final fit = _redrawFit;
    final closes = fit != null &&
        points.length >= 3 &&
        (fit.toCanvas(points.first) - fit.toCanvas(points.last)).distance <=
            _closeGapPx;

    // Simplified before storing: a finger produces hundreds of points, and
    // every one of them would ride the sync engine's full-row re-push on
    // every future edit to any other column of this wall. The tolerance is a
    // few pixels of the stroke as drawn, so it removes what the eye cannot
    // see and nothing else, whatever the rock's real size.
    final tolerance = fit == null || fit.scale <= 0
        ? 1e-6
        : math.max(_simplifyPx / fit.scale, 1e-6);
    final simplified = Baseline(points, closed: closes).simplified(tolerance);

    setState(() {
      _draftPoints = null;
      _redrawFit = null;
    });
    await _storeBaseline(simplified);
  }

  Future<void> _accept(LayoutResult layout) => ref
      .read(libraryCrudRepositoryProvider)
      .setWallBaseline(widget.wallId, layout.baseline.encode());
}
