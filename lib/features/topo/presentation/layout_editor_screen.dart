import 'dart:math' as math;

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

class _LayoutEditorScreenState extends ConsumerState<LayoutEditorScreen> {
  String? _selectedFaceId;
  bool _bannerDismissed = false;

  /// The stroke being drawn right now, in plane coordinates, or `null` when
  /// not in redraw mode.
  List<LayoutPoint>? _draftPoints;

  /// The face being dragged along the line, and the position it has reached.
  String? _draggingFaceId;
  double? _draggingT;

  bool get _redrawing => _draftPoints != null;

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
        if (layout.isProvisional && !_bannerDismissed) _banner(colors),
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
      final draft = _draftPoints == null ? null : Baseline(_draftPoints!);
      final fit = LayoutPlaneFit.forBaseline(
        draft ?? layout.baseline,
        size,
      );
      final preview = _previewLayout(layout);

      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (details) =>
            _handleTap(details.localPosition, preview, fit),
        onPanStart: (details) => _panStart(details.localPosition, preview, fit),
        onPanUpdate: (details) =>
            _panUpdate(details.localPosition, preview, fit),
        onPanEnd: (_) => _panEnd(),
        child: Container(
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
                    showHandles: !_redrawing,
                    draft: draft,
                  ),
                ),
              ),
              if (!_redrawing)
                for (final face in preview.faces)
                  _thumbnail(colors, preview, fit, face, photos),
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
  LayoutResult _previewLayout(LayoutResult layout) {
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
    LayoutResult layout,
    LayoutPlaneFit fit,
    FacePosition face,
    List<PhotoRef> photos,
  ) {
    final anchor = LayoutBaselinePainter.thumbnailAnchor(layout, fit, face.id);
    if (anchor == null) return const SizedBox.shrink();
    final photo = _photoFor(photos, face.id);
    final selected = face.id == _selectedFaceId;

    return Positioned(
      left: anchor.dx - 22,
      top: anchor.dy - 22,
      child: IgnorePointer(
        child: Container(
          key: Key('layout-face-${face.id}'),
          width: 44,
          height: 44,
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
              if (photo != null) PhotoImage(photo.localPath),
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
                    : PhotoImage(photo.localPath),
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

  Widget _actions(MasiColors colors, LayoutResult layout) => Row(
    children: [
      Expanded(
        child: FilledButton.tonal(
          key: const Key('layout-redraw'),
          onPressed: _redrawing ? _cancelRedraw : _startRedraw,
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

  void _handleTap(Offset at, LayoutResult layout, LayoutPlaneFit fit) {
    if (_redrawing) return;
    final hit = _faceNear(at, layout, fit);
    setState(() => _selectedFaceId = hit?.id);
  }

  void _panStart(Offset at, LayoutResult layout, LayoutPlaneFit fit) {
    if (_redrawing) {
      setState(() => _draftPoints = [fit.toPlane(at)]);
      return;
    }
    final hit = _faceNear(at, layout, fit);
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
  ) {
    FacePosition? best;
    var bestDistance = double.infinity;
    for (final face in layout.faces) {
      for (final candidate in [
        fit.toCanvas(layout.baseline.pointAt(face.t)),
        LayoutBaselinePainter.thumbnailAnchor(layout, fit, face.id),
      ]) {
        if (candidate == null) continue;
        final distance = (candidate - at).distance;
        if (distance < bestDistance) {
          bestDistance = distance;
          best = face;
        }
      }
    }
    // A generous radius, because the target is a 44px thumbnail on a phone
    // and the alternative to hitting it is dragging the wrong photo.
    return bestDistance <= 34 ? best : null;
  }

  void _startRedraw() => setState(() {
    _draftPoints = const [];
    _selectedFaceId = null;
  });

  void _cancelRedraw() => setState(() => _draftPoints = null);

  Future<void> _commitDraft() async {
    final points = _draftPoints;
    if (points == null || points.length < 2) {
      setState(() => _draftPoints = null);
      return;
    }

    // The closure gesture, and the only way this app has of being told
    // something is a boulder: if the stroke ends near where it began, it is a
    // ring. Proportional to the stroke's own size so it means the same thing
    // for a 4 m block and an 80 m sector.
    final drawn = Baseline(points);
    final closes =
        points.length >= 3 &&
        points.first.distanceTo(points.last) <= drawn.extent * 0.12;

    // Simplified before storing: a finger produces hundreds of points, and
    // every one of them would ride the sync engine's full-row re-push on
    // every future edit to any other column of this wall.
    final simplified = Baseline(
      points,
      closed: closes,
    ).simplified(math.max(drawn.extent * 0.01, 1e-6));

    setState(() => _draftPoints = null);
    await ref
        .read(libraryCrudRepositoryProvider)
        .setWallBaseline(widget.wallId, simplified.encode());
  }

  Future<void> _accept(LayoutResult layout) => ref
      .read(libraryCrudRepositoryProvider)
      .setWallBaseline(widget.wallId, layout.baseline.encode());
}
