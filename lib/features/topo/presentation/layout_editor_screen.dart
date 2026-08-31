import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart' hide Baseline;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:masi/app/theme.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/features/library/application/library_providers.dart';
import 'package:masi/features/topo/application/face_layout_providers.dart';
import 'package:masi/features/topo/data/photo_repository.dart';
import 'package:masi/features/topo/domain/face_layout/baseline.dart';
import 'package:masi/features/topo/domain/face_layout/baseline_set.dart';
import 'package:masi/features/topo/domain/face_layout/baseline_synthesis.dart';
import 'package:masi/features/topo/domain/face_layout/layout_resolver.dart';
import 'package:masi/features/topo/presentation/layout_baseline_painter.dart';
import 'package:masi/features/topo/presentation/layout_plane_fit.dart';
import 'package:masi/features/topo/presentation/thumbnail_arrangement.dart';
import 'package:masi/features/topo/presentation/photo_image.dart';
import 'package:masi/features/topo/presentation/photo_preview.dart';
import 'package:masi/shared/presentation/masi_icon.dart';

/// The layout editor: one line, and the wall's photos riding it.
///
/// Every correction here happens on the picture. There is no form, no
/// coordinate field, and — deliberately — no control anywhere that asks
/// whether this rock is a boulder or a wall: closing the stroke onto itself
/// is the only thing that makes it a ring, exactly as closing any polygon is.
/// Asking the question in words would mean asking every contributor to hold a
/// model in their head, and the whole design goal is that they hold none.
///
/// The line is TAPPED out, point by point, and points are then dragged — the
/// same two gestures that draw a route on a topo. That is not a style
/// preference: it is the only line-drawing anyone using this app has already
/// learned, and a second gesture for the same job reads as a broken screen
/// rather than as a different one. The freehand drag this replaced also had
/// no repair short of starting the rock again.
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
/// drag with a vertical component. So dragging a photo up the line, or a
/// point of the stroke, scrolled the page instead. Only a dead-level
/// horizontal drag ever reached the canvas, which is why this looked like
/// "dragging does nothing" rather than like a gesture conflict.
///
/// [shouldClaim] keeps the theft narrow: the canvas takes the pointer only
/// when the touch lands on something draggable — a draft point, a handle, or
/// a face. A touch on empty canvas still scrolls the page, so the screen does
/// not become a trap on a small phone.
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

  /// The layout, mapping and thumbnail boxes the last build put on screen —
  /// i.e. what a finger landing right now would actually be touching.
  /// Written during build and read only by hit tests, never to decide layout.
  LayoutResult? _hitLayout;
  LayoutPlaneFit? _hitFit;
  List<ThumbnailSlot> _hitSlots = const <ThumbnailSlot>[];

  /// A global pointer position as a position on the plan.
  Offset _toLocal(Offset global) {
    final box = _canvasBoxKey.currentContext?.findRenderObject() as RenderBox?;
    return box == null ? global : box.globalToLocal(global);
  }

  /// The face being dragged along the line, and the position it has reached.
  String? _draggingFaceId;
  double? _draggingT;

  /// Whether the drag in progress has actually MOVED anything.
  ///
  /// A press that never moves still opens and closes a drag — a long-press
  /// on a face runs `_panStart` too, because the recognizer that guards this
  /// canvas takes the pointer back when the arena rejects it. Without this,
  /// merely holding a photo to look at it pinned it: a write, a sync-dirty
  /// row, and a face permanently reported as "you placed this one" by a
  /// gesture that placed nothing.
  bool _dragMoved = false;

  /// The draft point being dragged right now, while redrawing.
  ///
  /// A point placed by tap is a point you can move, exactly as a route's
  /// handles are — otherwise the only repair for one tap landing 10px off is
  /// to undo back to it.
  int? _draggingDraftIndex;

  /// The baseline vertex being dragged, and the whole stroke as edited so far.
  ///
  /// Reshaping by handle is the design's primary correction — 'diamond
  /// handles reshape it' — and its absence is what left redrawing the entire
  /// line as the only way to fix one that was slightly wrong.
  int? _draggingHandle;

  /// Which rock the dragged vertex belongs to.
  int? _draggingHandleStroke;

  List<LayoutPoint>? _handlePoints;

  /// Which rock the face being dragged has reached. A drag can carry a photo
  /// from one boulder to another — that is how a wall's photos get sorted
  /// between its rocks, and with no GPS it is the only way.
  int? _draggingFaceStroke;

  /// The rock the contributor has picked out by tapping it, if any. Only
  /// meaningful with more than one; it is what "remove this rock" removes.
  int? _selectedStroke;

  /// Whether the stroke being drawn ADDS a rock or replaces the drawing.
  ///
  /// The same draft machinery serves both, and the difference is one line at
  /// commit time — but it is the whole difference between "this crag bay has
  /// a second boulder" and "that was wrong, here it is again".
  bool _draftAppends = false;

  /// Which rock the stroke being drawn REPLACES, if it replaces one.
  ///
  /// Redrawing used to be all-or-nothing: the button wiped every rock on the
  /// wall and started again, so a crag bay whose second boulder came out
  /// wrong cost you the first one as well. A rock you can point at is a rock
  /// you can redraw on its own.
  int? _draftReplaces;

  /// Whether the stroke being reshaped is a ring. Reshaping never changes
  /// that — only redrawing does — so it is carried across the drag rather
  /// than re-derived from the moved points.
  bool _handleClosed = false;

  bool get _redrawing => _draftPoints != null;

  /// What the canvas's width stands for when drawing a line from scratch.
  /// A crag-sized default: big enough that a boulder is not a dot, small
  /// enough that a wall does not run off the edge.
  static const double _blankSpanMetres = 40;

  /// The tile every face is drawn at — the default `arrangeThumbnails` has
  /// always used, named here because the fit's padding is derived from it.
  static const Size _thumbnailSize = Size(64, 48);

  /// How close, IN PIXELS, a stroke's end must come to its start to be a ring.
  /// Pixels rather than a fraction of the stroke's own size: proportional
  /// thresholds grow with a messy stroke, which is how a wall drawn as a
  /// 135 m scribble got a 16 m closure radius and became a boulder.
  static const double _closeGapPx = 28;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    final layoutAsync = ref.watch(wallLayoutProvider(widget.wallId));
    final photos =
        ref.watch(wallOriginalsProvider(widget.wallId)).value ??
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
        // Everything below the plan is about faces, and there are no faces
        // while a line is being drawn — the stroke does not exist yet for
        // them to ride. Hiding it is what lets the canvas take the screen at
        // the moment the screen is entirely about the canvas.
        if (!_redrawing) ...[
          // One chip per rock, so picking one out is a button rather than a
          // secret. Tapping the line does it too — but nothing on a drawing
          // says a drawing is touchable, and a repair nobody can find is a
          // repair the app does not have.
          if (layout.strokes.length > 1) ...[
            _rockChips(colors, layout),
            const SizedBox(height: 10),
          ],
          // The picked-out rock's own card, directly under the picture it
          // refers to — every other control on this screen is about faces,
          // and a rock action buried among them was never going to be read
          // as being about the line.
          if (_pickedStroke(layout) case final picked?
              when _selectedFaceId == null) ...[
            _rockCard(colors, layout, photos, picked),
            const SizedBox(height: 12),
          ],
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
          const SizedBox(height: 6),
          Text(
            _rockHint(layout),
            key: const Key('layout-rock-count'),
            style: TextStyle(fontSize: 13, height: 1.35, color: colors.ink2),
          ),
          const SizedBox(height: 18),
          _captureOrderRail(colors, layout, photos),
          const SizedBox(height: 18),
          if (_selectedFaceId != null)
            _selectedCard(colors, layout, photos, _selectedFaceId!),
          const SizedBox(height: 18),
        ],
        _actions(colors, layout),
      ],
    );
  }

  /// How tall the plan gets on THIS screen.
  ///
  /// It used to be 240px on every device, which is a third of a phone and a
  /// tenth of a tablet: the rock was drawn in a letterbox with the rest of
  /// the screen empty below it, and the thumbnails had nowhere to spread
  /// into. A share of the real screen instead, floored so a small phone in
  /// landscape still gets something drawable and capped so a desktop window
  /// does not make one boulder two metres tall.
  ///
  /// [redrawing] is a parameter rather than a read of [_redrawing] because
  /// [_startRedraw] has to know the height it is ABOUT to have: it pins the
  /// plane fit from that size, and a fit pinned against the wrong canvas puts
  /// every point the finger places somewhere else.
  double _canvasHeightFor({required bool redrawing}) {
    final screen = MediaQuery.sizeOf(context).height;
    return redrawing
        ? (screen * 0.62).clamp(280.0, 640.0)
        : (screen * 0.44).clamp(240.0, 520.0);
  }

  /// What to actually DO, while doing it.
  ///
  /// Redrawing used to start with no instruction anywhere on screen: the
  /// button said 'Redraw line', the canvas cleared, and the contributor was
  /// left to guess both what the surface wanted and that ending where you
  /// started is what makes a boulder. The gesture is now the one routes use,
  /// so only the second fact is unguessable — and it is still the one thing
  /// this app can never ask in words.
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
            // ONE message for the whole stroke, not one per stage. A hint
            // that rewrites itself as points are placed changes its own
            // height, and everything below it — the canvas included — jumps
            // by a line while a finger is working in it. Points already
            // placed then sit somewhere else than where they were tapped.
            'Tap around the rock to place points, the way you walked it. Tap '
            'the first point again to close it into a boulder.',
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
      final size = Size(
        constraints.maxWidth,
        _canvasHeightFor(redrawing: _redrawing),
      );
      _canvasSize = size;
      final draft = _draftPoints == null ? null : Baseline(_draftPoints!);
      // Never fitted to the draft: see _redrawFit. While redrawing, the
      // pinned fit is the one the stroke is being recorded through, so what
      // is painted and what is stored agree.
      final insets = LayoutBaselinePainter.planInsets(
        layout: layout,
        thumbnail: _thumbnailSize,
        stem: LayoutBaselinePainter.stemLength,
      );
      final fit =
          _redrawFit ??
          LayoutPlaneFit.forBaseline(
            layout.baseline,
            size,
            padLeft: insets.left,
            padTop: insets.top,
            padRight: insets.right,
            padBottom: insets.bottom,
          );
      final preview = _previewLayout(layout, photos);
      // Resolved ONCE per build and shared by the painter (leaders) and the
      // widgets (the boxes themselves) — two independent placements of the
      // same thumbnail is exactly how a leader ends up pointing at nothing.
      final slots = arrangeThumbnails(
        anchors: LayoutBaselinePainter.anchorsFor(preview, fit),
        canvas: size,
        thumbnail: _thumbnailSize,
        stem: LayoutBaselinePainter.stemLength,
      );
      // What the finger can hit, as of THIS build — see the recognizer's
      // constructor below for why it cannot read these from a closure.
      _hitLayout = preview;
      _hitFit = fit;
      _hitSlots = slots;

      return RawGestureDetector(
        behavior: HitTestBehavior.opaque,
        gestures: <Type, GestureRecognizerFactory>{
          TapGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
                TapGestureRecognizer.new,
                (instance) {
                  instance.onTapUp = (TapUpDetails details) => _handleTap(
                    _toLocal(details.globalPosition),
                    preview,
                    fit,
                    slots,
                  );
                },
              ),
          // The faces on the canvas are drawn INSIDE an `IgnorePointer` —
          // every touch on this surface is resolved here, against the
          // arrangement, rather than by the boxes themselves. So the
          // long-press has to live here too.
          LongPressGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
                LongPressGestureRecognizer.new,
                (instance) {
                  instance.onLongPressStart = (LongPressStartDetails details) =>
                      _previewFaceAt(
                        _toLocal(details.globalPosition),
                        preview,
                        fit,
                        slots,
                        photos,
                      );
                },
              ),
          _CanvasPanRecognizer:
              GestureRecognizerFactoryWithHandlers<_CanvasPanRecognizer>(
                // Constructed ONCE for the life of this state — unlike the
                // handlers below, which the factory re-assigns on every
                // build. So this callback must not close over anything from
                // the build that happened to create it: the `fit` from the
                // first frame is the one the STORED line was drawn through,
                // and testing a finger against it while a redraw is in
                // progress asks about a mapping nobody is drawing in — which
                // is why a tapped point could not be grabbed at all. It reads
                // the fields below instead, which every build refreshes.
                () => _CanvasPanRecognizer(
                  shouldClaim: (global) {
                    final at = _toLocal(global);
                    if (_redrawing) return _draftPointNear(at) != null;
                    final hitLayout = _hitLayout;
                    final hitFit = _hitFit;
                    if (hitLayout == null || hitFit == null) return false;
                    return _handleNear(at, hitLayout, hitFit) != null ||
                        _faceNear(at, hitLayout, hitFit, _hitSlots) != null;
                  },
                ),
                (instance) {
                  // Report the position the finger actually landed on, not
                  // the one ~18px later where the drag cleared touch slop.
                  // Without this the stroke silently loses its first
                  // centimetres, which matters most for the one comparison
                  // that decides ring-or-wall: did it end where it began.
                  instance.dragStartBehavior = DragStartBehavior.down;
                  instance.onStart = (DragStartDetails details) => _panStart(
                    _toLocal(details.globalPosition),
                    preview,
                    fit,
                    slots,
                  );
                  instance.onUpdate = (DragUpdateDetails details) => _panUpdate(
                    _toLocal(details.globalPosition),
                    preview,
                    fit,
                  );
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
                    handleRingColor: colors.surface,
                    selectedFaceId: _selectedFaceId,
                    slots: slots,
                    // Handles on the DRAFT as well: the points you have
                    // placed are the points you can drag, and a stroke drawn
                    // by tapping has to show where its taps landed.
                    showHandles: true,
                    draft: draft,
                    selectedStroke: preview.strokes.length > 1
                        ? _selectedStroke
                        : null,
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
    // A handle drag reshapes ONE rock, so that rock's faces have to be
    // re-resolved against it rather than carried over: they ride the stroke,
    // and a stroke that moved without them would show every photo hanging
    // off it.
    final edited = _handlePoints;
    final editedStroke = _draggingHandleStroke;
    if (edited != null && editedStroke != null && edited.length >= 2) {
      final strokes = [...layout.strokes];
      if (editedStroke < strokes.length) {
        strokes[editedStroke] = Baseline(edited, closed: _handleClosed);
        return resolveLayoutSet(
          faces: faceInputsFrom(photos),
          strokes: BaselineSet(strokes),
          origin: BaselineOrigin.authored,
        );
      }
    }
    final draggingId = _draggingFaceId;
    final draggingT = _draggingT;
    if (draggingId == null || draggingT == null) return layout;
    final draggingStroke = _draggingFaceStroke ?? 0;
    return LayoutResult(
      baseline: layout.baseline,
      strokes: layout.strokes,
      normalSigns: layout.normalSigns,
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
              stroke: draggingStroke,
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
          ),
          // The frame paints ON TOP of the photo. Underneath it, the clipped
          // child covers its inner half and the rounded corners come out
          // bitten off — the selected face's highlight is where it shows.
          foregroundDecoration: BoxDecoration(
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
              onLongPress: photo == null
                  ? null
                  : () => showPhotoPreview(
                      context,
                      storedPath: photo.localPath,
                      title: 'Photo ${face.captureOrder + 1}',
                      subtitle: _placementLabel(face.placement),
                    ),
              child: Container(
                width: 52,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(MasiRadii.control),
                ),
                // Over the photo, not under it — see `_thumbnail`.
                foregroundDecoration: BoxDecoration(
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
                  : PhotoThumbnail(photo.localPath),
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
              onPressed: () =>
                  ref.read(photoRepositoryProvider).setFacePin(faceId, null),
              child: const Text('Unpin'),
            ),
        ],
      ),
    );
  }

  /// What the line under the picture says about picking a rock out.
  ///
  /// It used to appear only on a wall that already had two rocks, so on the
  /// ordinary one-rock wall nothing on screen ever said the line itself was
  /// touchable — and every repair to it (reshape, redraw, remove) is reached
  /// by touching it. 'I can draw a new line but I can't edit or delete the
  /// old one' is precisely what a screen that keeps that secret produces.
  String _rockHint(LayoutResult layout) {
    final count = layout.strokes.length;
    final selected = _pickedStroke(layout);
    if (selected != null) {
      return count > 1 ? 'Rock ${selected + 1} picked out.' : 'Picked out.';
    }
    return count > 1
        ? '$count rocks. Tap one to pick it out; drag a photo across to '
              'move it between them.'
        : 'Tap the line to pick it out, then reshape, redraw or remove it.';
  }

  /// The rock that is picked out, if it still exists.
  ///
  /// The index outlives the rock: resetting to the automatic line, or
  /// removing a rock, leaves the selection naming a stroke that is no longer
  /// there. Unclamped, the card then acts on it — and a redraw whose target
  /// index is out of range falls through to the branch that replaces the
  /// WHOLE drawing, which is the one outcome nobody asked for.
  int? _pickedStroke(LayoutResult layout) {
    final index = _selectedStroke;
    if (index == null || index < 0 || index >= layout.strokes.length) {
      return null;
    }
    return index;
  }

  /// One chip per rock on this wall.
  Widget _rockChips(MasiColors colors, LayoutResult layout) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      for (var i = 0; i < layout.strokes.length; i++)
        GestureDetector(
          key: Key('layout-rock-chip-$i'),
          onTap: () => setState(() {
            _selectedFaceId = null;
            _selectedStroke = _selectedStroke == i ? null : i;
          }),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: _selectedStroke == i ? colors.amethyst100 : colors.surface,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: _selectedStroke == i ? colors.accent : colors.separator,
                width: _selectedStroke == i ? 2 : 1,
              ),
            ),
            child: Text(
              'Rock ${i + 1}',
              style: TextStyle(
                fontSize: 13,
                fontWeight: _selectedStroke == i
                    ? FontWeight.w600
                    : FontWeight.w400,
                color: _selectedStroke == i ? colors.accent : colors.ink,
              ),
            ),
          ),
        ),
    ],
  );

  /// The picked-out rock, and the three things that can be done to it.
  ///
  /// All three existed before this card and none of them was findable. The
  /// handles were there but nothing said the line was yours to grab; redraw
  /// wiped every rock on the wall, so on a two-boulder crag it was not the
  /// repair anybody wanted; and remove was a text button at the bottom of a
  /// scrolling page, shown only on a wall that already had two rocks and only
  /// after a tap nothing had suggested.
  Widget _rockCard(
    MasiColors colors,
    LayoutResult layout,
    List<PhotoRef> photos,
    int index,
  ) {
    final stroke = layout.strokes[index];
    final riding = layout.faces.where((face) => face.stroke == index).length;
    final many = layout.strokes.length > 1;

    return Container(
      key: const Key('layout-rock-card'),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(MasiRadii.card),
        border: Border.all(color: colors.accent.withValues(alpha: 0.45)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      many ? 'Rock ${index + 1}' : 'This rock',
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      // The shape in the words the gesture uses: a stroke is
                      // a boulder because it closed, and this is the only
                      // place that fact is ever written down.
                      '${stroke.points.length} points · '
                      '${stroke.closed ? 'closed' : 'open'} · '
                      '$riding ${riding == 1 ? 'photo' : 'photos'}',
                      key: const Key('layout-rock-shape'),
                      style: TextStyle(fontSize: 13, color: colors.ink2),
                    ),
                  ],
                ),
              ),
              GestureDetector(
                key: const Key('layout-rock-deselect'),
                onTap: () => setState(() => _selectedStroke = null),
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: MasiIcon('close', size: 16, color: colors.ink3),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Drag its dots to reshape it.',
            style: TextStyle(fontSize: 13, height: 1.35, color: colors.ink2),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: FilledButton.tonal(
                  key: const Key('layout-redraw-rock'),
                  onPressed: () => _startRedrawRock(layout, index),
                  child: const Text('Redraw'),
                ),
              ),
              // Nothing to remove while the line is still the app's own
              // guess: storing no drawing is the state it is already in, so
              // the button would report having done something it did not.
              if (!layout.isProvisional) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: TextButton(
                    key: const Key('layout-remove-rock'),
                    onPressed: () => _removeStroke(layout, photos, index),
                    child: const Text('Remove'),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _actions(MasiColors colors, LayoutResult layout) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _actionRow(colors, layout),
      if (!_redrawing) ...[
        const SizedBox(height: 10),
        // A crag bay is often not one rock. Without this the contributor
        // either draws one line around two boulders — claiming the gap
        // between them is climbable — or leaves the guess alone.
        FilledButton.tonal(
          key: const Key('layout-add-rock'),
          onPressed: () => _startAddRock(layout),
          child: const Text('Add another rock'),
        ),
      ],
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

  Widget _actionRow(MasiColors colors, LayoutResult layout) {
    if (_redrawing) {
      final placed = _draftPoints?.length ?? 0;
      // Undo, Cancel, Finish — the three things a half-drawn line needs, and
      // the reason lifting a finger no longer decides anything.
      return Row(
        children: [
          Expanded(
            child: FilledButton.tonal(
              key: const Key('layout-redraw-undo'),
              onPressed: placed == 0 ? null : _undoDraftPoint,
              child: const Text('Undo'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: FilledButton.tonal(
              key: const Key('layout-redraw'),
              onPressed: _cancelRedraw,
              child: const Text('Cancel'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: FilledButton(
              key: const Key('layout-redraw-done'),
              // Two points is a line; one is a dot nobody can navigate by.
              onPressed: placed < 2 ? null : () => _commitDraft(closed: false),
              child: const Text('Finish'),
            ),
          ),
        ],
      );
    }

    return Row(
      children: [
        Expanded(
          child: FilledButton.tonal(
            key: const Key('layout-redraw'),
            onPressed: () => _startRedraw(layout),
            // Named for what it costs. With one rock this is the only way
            // back; with several it throws all of them away, and the repair
            // somebody actually wants there is the one rock's own Redraw.
            child: Text(
              layout.strokes.length > 1 ? 'Redraw all' : 'Redraw line',
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: FilledButton(
            key: const Key('layout-accept'),
            // Accepting a guess is a real edit: it promotes the synthesised
            // line to an authored one, which stops it being re-synthesised
            // (and silently changing) the next time a photo is added.
            onPressed: layout.isProvisional ? () => _accept(layout) : null,
            child: const Text('Accept'),
          ),
        ),
      ],
    );
  }

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

  /// Long-press a face on the plan and it opens full size.
  ///
  /// A 64x48 tile says which SIDE of the rock this is; it cannot say which
  /// slab. Checking that used to mean leaving the editor for the face and
  /// coming back, which loses the arrangement being read.
  void _previewFaceAt(
    Offset at,
    LayoutResult layout,
    LayoutPlaneFit fit,
    List<ThumbnailSlot> slots,
    List<PhotoRef> photos,
  ) {
    if (_redrawing) return;
    final face = _faceNear(at, layout, fit, slots);
    if (face == null) return;
    final photo = _photoFor(photos, face.id);
    if (photo == null) return;
    showPhotoPreview(
      context,
      storedPath: photo.localPath,
      title: 'Photo ${face.captureOrder + 1}',
      subtitle: _placementLabel(face.placement),
    );
  }

  void _handleTap(
    Offset at,
    LayoutResult layout,
    LayoutPlaneFit fit,
    List<ThumbnailSlot> slots,
  ) {
    if (_redrawing) {
      _tapDraft(at, fit);
      return;
    }
    final hit = _faceNear(at, layout, fit, slots);
    if (hit != null) {
      setState(() {
        _selectedFaceId = hit.id;
        _selectedStroke = hit.stroke;
      });
      return;
    }
    // Not a photo: the rock itself, if the finger is on one. That is what
    // gives "remove this rock" something to name, and on a wall with one
    // rock it changes nothing anybody can see.
    setState(() {
      _selectedFaceId = null;
      _selectedStroke = _strokeNear(at, layout, fit);
    });
  }

  /// One tap, one point — the same gesture that draws a route.
  ///
  /// This used to be a freehand drag, and a drag is the wrong instrument
  /// twice over. It is not what this app taught anyone: every line a climber
  /// has already drawn here — every route on every topo — is a series of
  /// TAPS, and a screen that silently wants a different gesture for the same
  /// job reads as broken rather than as different. And a dragged stroke
  /// cannot be corrected: a finger that wobbles at the third corner has no
  /// recourse but to start the rock again, where a tapped one has undo and a
  /// draggable point per tap.
  ///
  /// Tapping the first point again closes the ring, which is still the only
  /// way this app is ever told something is a boulder.
  void _tapDraft(Offset at, LayoutPlaneFit fit) {
    final points = _draftPoints ?? const <LayoutPoint>[];
    if (points.length >= 3 &&
        (fit.toCanvas(points.first) - at).distance <= _closeGapPx) {
      _commitDraft(closed: true);
      return;
    }
    setState(() => _draftPoints = [...points, fit.toPlane(at)]);
  }

  /// Removes the last point placed. Undo, in the one place a contributor
  /// looks for it after a tap lands wrong.
  void _undoDraftPoint() {
    final points = _draftPoints;
    if (points == null || points.isEmpty) return;
    setState(() {
      _draftPoints = points.sublist(0, points.length - 1);
      _draggingDraftIndex = null;
    });
  }

  /// The draft point under the finger, if any. Same radius as a baseline
  /// handle, for the same reason: close-together points on a detailed stroke.
  int? _draftPointNear(Offset at) {
    final points = _draftPoints;
    final fit = _redrawFit;
    if (points == null || points.isEmpty || fit == null) return null;
    int? best;
    var bestDistance = double.infinity;
    for (var i = 0; i < points.length; i++) {
      final distance = (fit.toCanvas(points[i]) - at).distance;
      if (distance < bestDistance) {
        bestDistance = distance;
        best = i;
      }
    }
    return bestDistance <= 22 ? best : null;
  }

  void _panStart(
    Offset at,
    LayoutResult layout,
    LayoutPlaneFit fit,
    List<ThumbnailSlot> slots,
  ) {
    if (_redrawing) {
      // Only ever a point being moved. A drag on empty canvas is left to the
      // page, exactly as it is in route drawing, so the editor never becomes
      // a scroll trap on a phone.
      final index = _draftPointNear(at);
      if (index == null) return;
      setState(() {
        _draggingDraftIndex = index;
        _dragMoved = false;
      });
      return;
    }
    // Handles win over faces: a handle sits ON the line and a thumbnail sits
    // off it, so where they compete the finger is far likelier to be aiming
    // at the line it is touching.
    final handle = _handleNear(at, layout, fit);
    if (handle != null) {
      final stroke = layout.strokes[handle.stroke];
      setState(() {
        _selectedFaceId = null;
        _selectedStroke = handle.stroke;
        _draggingHandle = handle.index;
        _draggingHandleStroke = handle.stroke;
        _handleClosed = stroke.closed;
        _handlePoints = [...stroke.points];
        _dragMoved = false;
      });
      return;
    }
    final hit = _faceNear(at, layout, fit, slots);
    if (hit == null) return;
    setState(() {
      _selectedFaceId = hit.id;
      _draggingFaceId = hit.id;
      _draggingT = hit.t;
      _draggingFaceStroke = hit.stroke;
      _dragMoved = false;
    });
  }

  void _panUpdate(Offset at, LayoutResult layout, LayoutPlaneFit fit) {
    if (_redrawing) {
      final index = _draggingDraftIndex;
      final points = _draftPoints;
      if (index == null || points == null || index >= points.length) return;
      setState(() {
        _draftPoints = [...points]..[index] = fit.toPlane(at);
        _dragMoved = true;
      });
      return;
    }
    final handle = _draggingHandle;
    final points = _handlePoints;
    if (handle != null && points != null && handle < points.length) {
      setState(() {
        _handlePoints = [...points]..[handle] = fit.toPlane(at);
        _dragMoved = true;
      });
      return;
    }
    if (_draggingFaceId == null) return;
    // Snapped onto the line rather than following the finger freely: a face
    // is a position ALONG the rock, and a thumbnail sitting off the stroke
    // would be claiming a second dimension the model does not have.
    //
    // Onto the NEAREST rock, not a fixed one: carrying a photo across to the
    // other boulder is the same gesture as sliding it along this one, and
    // with no GPS it is the only way to say which rock a photo is of.
    final plane = fit.toPlane(at);
    var bestStroke = _draggingFaceStroke ?? 0;
    var bestT = _draggingT ?? 0;
    var bestDistance = double.infinity;
    for (var i = 0; i < layout.strokes.length; i++) {
      final projection = layout.strokes[i].project(plane);
      if (projection.distance < bestDistance) {
        bestDistance = projection.distance;
        bestStroke = i;
        bestT = projection.t;
      }
    }
    setState(() {
      _draggingFaceStroke = bestStroke;
      _draggingT = bestT;
      _dragMoved = true;
    });
  }

  Future<void> _panEnd() async {
    if (_redrawing) {
      // Nothing to store: a stroke is finished by the button or by closing
      // the ring, never by lifting a finger. Lifting used to commit, which
      // meant a drag that was meant to fix one point ended the whole line.
      setState(() => _draggingDraftIndex = null);
      return;
    }
    final moved = _dragMoved;
    final reshaped = _handlePoints;
    final reshapedStroke = _draggingHandleStroke;
    final layout = _hitLayout;
    if (_draggingHandle != null) {
      setState(() {
        _draggingHandle = null;
        _draggingHandleStroke = null;
        _handlePoints = null;
      });
      if (moved &&
          reshaped != null &&
          reshapedStroke != null &&
          layout != null &&
          reshaped.length >= 2) {
        final strokes = [...layout.strokes];
        if (reshapedStroke < strokes.length) {
          strokes[reshapedStroke] = Baseline(reshaped, closed: _handleClosed);
          await _storeBaseline(BaselineSet(strokes));
        }
      }
      return;
    }
    final faceId = _draggingFaceId;
    final t = _draggingT;
    final faceStroke = _draggingFaceStroke ?? 0;
    setState(() {
      _draggingFaceId = null;
      _draggingT = null;
      _draggingFaceStroke = null;
    });
    // A press that never moved is a look, not a placement — see [_dragMoved].
    if (!moved || faceId == null || t == null) return;
    // On a one-rock wall the pin is written exactly as it always was — see
    // [BaselineSet.pack] for why that matters.
    final count = layout?.strokes.length ?? 1;
    await ref
        .read(photoRepositoryProvider)
        .setFacePin(faceId, count > 1 ? BaselineSet.pack(faceStroke, t) : t);
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
      // The face's OWN rock, not the first one. Asking `baseline` where a
      // face on the second boulder sits answers with a point on the first,
      // and a phantom dot 34px wide there swallows every tap meant for the
      // rock actually under the finger — which is most of why the second
      // rock could not be picked out, reshaped or removed at all.
      final distance =
          (fit.toCanvas(layout.strokeFor(face).pointAt(face.t)) - at).distance;
      if (distance < bestDistance) {
        bestDistance = distance;
        best = face;
      }
    }
    // A generous radius, because the target is a dot on a phone and the
    // alternative to hitting it is dragging the wrong photo.
    return bestDistance <= 34 ? best : null;
  }

  /// The baseline vertex under the finger, on any of the rocks.
  ({int stroke, int index})? _handleNear(
    Offset at,
    LayoutResult layout,
    LayoutPlaneFit fit,
  ) {
    ({int stroke, int index})? best;
    var bestDistance = double.infinity;
    for (var s = 0; s < layout.strokes.length; s++) {
      final points = layout.strokes[s].points;
      if (points.length < 2) continue;
      for (var i = 0; i < points.length; i++) {
        final distance = (fit.toCanvas(points[i]) - at).distance;
        if (distance < bestDistance) {
          bestDistance = distance;
          best = (stroke: s, index: i);
        }
      }
    }
    // Tighter than the face radius: handles can sit close together on a
    // detailed stroke, and grabbing the wrong one silently deforms the rock.
    return bestDistance <= 22 ? best : null;
  }

  /// The rock the finger is on, if any — a tap on the line itself rather
  /// than on one of its handles or photos. Selecting one is what gives
  /// "remove this rock" something to name.
  int? _strokeNear(Offset at, LayoutResult layout, LayoutPlaneFit fit) {
    int? best;
    var bestDistance = double.infinity;
    for (var s = 0; s < layout.strokes.length; s++) {
      final stroke = layout.strokes[s];
      if (stroke.isDegenerate) continue;
      final projection = stroke.project(fit.toPlane(at));
      final distance =
          (fit.toCanvas(stroke.pointAt(projection.t)) - at).distance;
      if (distance < bestDistance) {
        bestDistance = distance;
        best = s;
      }
    }
    return bestDistance <= 26 ? best : null;
  }

  /// Writes the whole drawing — every rock — back to the wall.
  ///
  /// An empty set stores NULL rather than an empty string, which is the same
  /// state as never having drawn: the engine re-synthesises a guess. Removing
  /// your only rock therefore hands you the automatic line back rather than a
  /// blank editor with nothing to grab.
  Future<void> _storeBaseline(BaselineSet strokes) => ref
      .read(libraryCrudRepositoryProvider)
      .setWallBaseline(
        widget.wallId,
        strokes.isEmpty ? null : strokes.encode(),
      );

  /// Starts a stroke that REPLACES the drawing.
  void _startRedraw(LayoutResult layout) => _startDraft(layout, appends: false);

  /// Starts a stroke that ADDS a rock to it.
  ///
  /// The crag bay with two boulders in it is the case this exists for: the
  /// alternative was one line drawn around both, which claims the gap between
  /// them is climbable rock.
  void _startAddRock(LayoutResult layout) => _startDraft(layout, appends: true);

  /// Starts a stroke that replaces ONE rock and leaves the others standing.
  void _startRedrawRock(LayoutResult layout, int index) =>
      _startDraft(layout, appends: false, replaces: index);

  void _startDraft(
    LayoutResult layout, {
    required bool appends,
    int? replaces,
  }) => setState(() {
    _draftPoints = const [];
    _draftAppends = appends;
    _draftReplaces = replaces;
    _selectedFaceId = null;
    _selectedStroke = null;
    // Pinned BEFORE the first point, so the whole stroke is recorded through
    // one mapping. Falls back to a fixed crag-sized span when there is no
    // line to inherit a scale from.
    //
    // Against the size the canvas is about to HAVE, not the one it has:
    // redrawing grows it (see [_canvasHeightFor]), and pinning against the
    // smaller box would leave every tap half the growth off the point the
    // finger touched.
    final size = Size(
      _canvasSize?.width ?? 360,
      _canvasHeightFor(redrawing: true),
    );
    final insets = LayoutBaselinePainter.planInsets(
      layout: layout,
      thumbnail: _thumbnailSize,
      stem: LayoutBaselinePainter.stemLength,
    );
    // Pinned against EVERY rock, not just the first: a second boulder has to
    // be drawn in the same coordinates as the one already there, or it lands
    // somewhere else entirely the moment it is committed.
    final existing = layout.strokes.isEmpty
        ? [layout.baseline]
        : layout.strokes;
    _redrawFit = existing.every((stroke) => stroke.isDegenerate)
        ? LayoutPlaneFit.forSpan(size, _blankSpanMetres)
        // The same padding the canvas is drawn with, or the outgoing line
        // would jump to a different scale the moment redrawing starts.
        : LayoutPlaneFit.forStrokes(
            existing,
            size,
            padLeft: insets.left,
            padTop: insets.top,
            padRight: insets.right,
            padBottom: insets.bottom,
          );
  });

  void _cancelRedraw() => setState(() {
    _draftPoints = null;
    _redrawFit = null;
    _draggingDraftIndex = null;
    _draftAppends = false;
    _draftReplaces = null;
  });

  /// Stores the tapped stroke. [closed] is the ring gesture's whole effect on
  /// the data — it is what makes this rock a boulder you can walk around.
  ///
  /// Nothing is simplified on the way in any more. Douglas-Peucker was there
  /// because a dragged finger produced hundreds of points and every one of
  /// them would ride the sync engine's full-row re-push forever. A tapped
  /// stroke has as many points as the contributor chose to place, and every
  /// one of them is a decision — dropping the ones that happen to sit near a
  /// line between their neighbours would quietly edit the shape someone drew.
  Future<void> _commitDraft({required bool closed}) async {
    final points = _draftPoints;
    if (points == null || points.length < 2) {
      setState(() {
        _draftPoints = null;
        _redrawFit = null;
        _draggingDraftIndex = null;
        _draftAppends = false;
        _draftReplaces = null;
      });
      return;
    }

    final existing = _hitLayout?.strokes ?? const <Baseline>[];
    final appends = _draftAppends;
    final replaces = _draftReplaces;
    setState(() {
      _draftPoints = null;
      _redrawFit = null;
      _draggingDraftIndex = null;
      _draftAppends = false;
      _draftReplaces = null;
    });
    final drawn = Baseline(points, closed: closed && points.length >= 3);
    // Three outcomes from one draft: it takes one rock's place, it joins the
    // rocks already there, or it is the whole drawing. Only the last wipes
    // anything, and it is the only one reached from a button that says so.
    final List<Baseline> strokes;
    if (replaces != null && replaces >= 0 && replaces < existing.length) {
      strokes = [...existing]..[replaces] = drawn;
    } else if (appends) {
      strokes = [...existing, drawn];
    } else {
      strokes = [drawn];
    }
    await _storeBaseline(BaselineSet(strokes));
  }

  /// Drops one rock from the drawing, and repairs every pin that named it.
  ///
  /// A pin carries its rock's INDEX (see [BaselineSet.pack]), so removing a
  /// rock silently re-points every pin above it at the wrong one. The photos
  /// of the removed rock lose their pin entirely — they have nowhere to be —
  /// and fall back to the placement the engine computes, which is the honest
  /// answer to "we no longer know where this was".
  Future<void> _removeStroke(
    LayoutResult layout,
    List<PhotoRef> photos,
    int index,
  ) async {
    final strokes = [...layout.strokes];
    if (index < 0 || index >= strokes.length) return;
    strokes.removeAt(index);
    setState(() => _selectedStroke = null);

    final photoRepository = ref.read(photoRepositoryProvider);
    final before = layout.strokes.length;
    for (final photo in photos) {
      final pin = photo.layoutPinnedT;
      if (pin == null) continue;
      final unpacked = BaselineSet.unpack(pin, before);
      if (unpacked.stroke == index) {
        await photoRepository.setFacePin(photo.id, null);
      } else if (unpacked.stroke > index) {
        final moved = unpacked.stroke - 1;
        await photoRepository.setFacePin(
          photo.id,
          strokes.length > 1 ? BaselineSet.pack(moved, unpacked.t) : unpacked.t,
        );
      } else if (strokes.length <= 1) {
        // Down to one rock, so pins go back to being a plain position.
        await photoRepository.setFacePin(photo.id, unpacked.t);
      }
    }

    await _storeBaseline(BaselineSet(strokes));
  }

  Future<void> _accept(LayoutResult layout) => _storeBaseline(
    BaselineSet(layout.strokes.isEmpty ? [layout.baseline] : layout.strokes),
  );
}
