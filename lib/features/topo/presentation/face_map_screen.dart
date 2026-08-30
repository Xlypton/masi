import 'package:flutter/material.dart' hide Baseline;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:masi/app/theme.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/features/library/application/library_providers.dart';
import 'package:masi/features/topo/application/face_layout_providers.dart';
import 'package:masi/features/topo/data/photo_repository.dart';
import 'package:masi/features/topo/presentation/face_lane.dart';
import 'package:masi/features/topo/presentation/photo_image.dart';
import 'package:masi/shared/presentation/masi_icon.dart';

/// The plan view, full screen: this rock from above, with every photo of it
/// standing where it was taken from.
///
/// A screen rather than a lane inside the reading dock, which is where this
/// lived and what made the bottom half of the canvas unusable on a phone. It
/// was mounted permanently at 153pt — too small to recognise a face from, too
/// big to keep on screen — for a glance most readers take once, to orient
/// themselves, and then not again. Given the whole screen the cameras can be
/// real thumbnails at a size where the picture alone says which side it is,
/// which no dot on a 184px card ever managed.
///
/// Read-only. Every correction to the plan is a drag, and dragging happens in
/// the layout editor behind `Edit` — see `LayoutEditorScreen`.
///
/// Pops with the id of the photo the reader chose (or `null` if they backed
/// out), so the canvas underneath switches to it. That is the whole contract:
/// this screen never writes.
class FaceMapScreen extends ConsumerStatefulWidget {
  const FaceMapScreen({
    required this.wallId,
    this.initialPhotoId,
    this.readOnly = false,
    super.key,
  });

  final String wallId;

  /// The photo the reader is looking at. Selected on open, so the map opens
  /// oriented on where they already are rather than on the first face.
  final String? initialPhotoId;

  /// Hides the way into the layout editor. A community reader can look at
  /// somebody else's rock but not reshape it.
  final bool readOnly;

  @override
  ConsumerState<FaceMapScreen> createState() => _FaceMapScreenState();
}

class _FaceMapScreenState extends ConsumerState<FaceMapScreen> {
  String? _selectedId;

  @override
  void initState() {
    super.initState();
    _selectedId = widget.initialPhotoId;
  }

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    final photos =
        ref.watch(wallOriginalsProvider(widget.wallId)).value ??
        const <PhotoRef>[];
    final layout = ref.watch(wallLayoutProvider(widget.wallId)).value;
    final counts =
        ref.watch(wallRouteCountsProvider(widget.wallId)).value ??
        const <String, int>{};
    final wallName = ref.watch(wallNameProvider(widget.wallId)).value;

    // Whatever the reader picked, narrowed to a photo that still exists: a
    // face can be deleted from the canvas while this screen is open.
    PhotoRef? selected;
    for (final photo in photos) {
      if (photo.id == _selectedId) selected = photo;
    }
    selected ??= photos.isEmpty ? null : photos.first;

    return Scaffold(
      backgroundColor: colors.ground,
      body: SafeArea(
        child: Column(
          children: [
            _header(context, colors, wallName, photos.length),
            Expanded(
              child: layout == null || layout.baseline.isDegenerate
                  ? _noPlan(colors)
                  : Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: MasiSpacing.sm,
                      ),
                      child: FaceMapPlan(
                        layout: layout,
                        photos: photos,
                        activePhotoId: selected?.id,
                        routeCounts: counts,
                        onSelect: (photo) =>
                            setState(() => _selectedId = photo.id),
                        colors: colors,
                      ),
                    ),
            ),
            if (selected case final photo?)
              _currentBar(context, colors, photo, photos, counts),
          ],
        ),
      ),
    );
  }

  Widget _header(
    BuildContext context,
    MasiColors colors,
    String? wallName,
    int photoCount,
  ) => Padding(
    padding: const EdgeInsets.fromLTRB(
      MasiSpacing.sm,
      MasiSpacing.sm,
      MasiSpacing.md,
      MasiSpacing.sm,
    ),
    child: Row(
      children: [
        IconButton(
          key: const Key('face-map-close'),
          tooltip: 'Back to the photo',
          icon: MasiIcon('close', color: colors.accent),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                (wallName == null || wallName.isEmpty) ? 'Topo' : wallName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              Text(
                photoCount == 1
                    ? '1 photo of this rock'
                    : '$photoCount photos around this rock',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: colors.ink2),
              ),
            ],
          ),
        ),
        if (!widget.readOnly)
          TextButton.icon(
            key: const Key('face-map-edit'),
            onPressed: () =>
                context.push('/walls/${widget.wallId}/layout'),
            icon: MasiIcon('edit', size: 16, color: colors.accent),
            label: const Text('Edit'),
          ),
      ],
    ),
  );

  Widget _noPlan(MasiColors colors) => Center(
    child: Padding(
      padding: const EdgeInsets.all(MasiSpacing.xl),
      child: Text(
        // Not an error: a rock nobody has traced yet genuinely has no plan,
        // and the honest answer is to say so and point at the one screen that
        // can make one.
        'No plan for this rock yet.\nTrace its shape in the layout editor and '
        'every photo will find its place on it.',
        key: const Key('face-map-empty'),
        textAlign: TextAlign.center,
        style: TextStyle(color: colors.ink2, height: 1.5),
      ),
    ),
  );

  Widget _currentBar(
    BuildContext context,
    MasiColors colors,
    PhotoRef photo,
    List<PhotoRef> photos,
    Map<String, int> counts,
  ) {
    final index = photos.indexWhere((p) => p.id == photo.id);
    final count = counts[photo.id] ?? 0;
    final dpr = MediaQuery.devicePixelRatioOf(context);

    return Container(
      key: const Key('face-map-current'),
      margin: const EdgeInsets.fromLTRB(
        MasiSpacing.md,
        0,
        MasiSpacing.md,
        MasiSpacing.md,
      ),
      padding: const EdgeInsets.all(MasiSpacing.md),
      decoration: BoxDecoration(
        color: colors.chrome,
        borderRadius: BorderRadius.circular(MasiRadii.large),
        border: Border.all(color: colors.separator),
      ),
      child: Row(
        children: [
          Container(
            width: 74,
            height: 56,
            decoration: BoxDecoration(
              color: colors.surface2,
              borderRadius: BorderRadius.circular(MasiRadii.control),
              border: Border.all(color: colors.accent, width: 2),
            ),
            clipBehavior: Clip.antiAlias,
            child: PhotoImage(
              photo.localPath,
              fit: BoxFit.cover,
              cacheWidth: (74 * dpr).round(),
            ),
          ),
          const SizedBox(width: MasiSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Photo ${index + 1}',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 2),
                Text(
                  count == 1
                      ? '1 route · ${index + 1} of ${photos.length}'
                      : '$count routes · ${index + 1} of ${photos.length}',
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: colors.ink2),
                ),
              ],
            ),
          ),
          FilledButton(
            key: const Key('face-map-open'),
            // Pops the id rather than switching the canvas from here: this
            // screen owns no state on the wall, so handing back the choice is
            // the whole of its side of the contract.
            onPressed: () => Navigator.of(context).pop(photo.id),
            child: const Text('Open'),
          ),
        ],
      ),
    );
  }
}
