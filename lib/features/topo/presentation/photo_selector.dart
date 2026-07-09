import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:climbtopo/features/topo/application/active_view_controller.dart';
import 'package:climbtopo/features/topo/data/photo_repository.dart';

/// Horizontal strip of selectable "views" onto the current wall's photo:
/// an "Original" chip plus one chip per persisted slice (ordered by
/// `cropXpct`, as returned by [PhotoRepository.loadSlices]).
///
/// Tapping a chip switches [activeViewProvider] via
/// [ActiveViewController.showOriginal]/[ActiveViewController.showSlice],
/// which [TopoCanvas] reads to decide whether/how to frame the viewport to
/// a crop band. The active chip is highlighted via [ChoiceChip.selected].
class PhotoSelector extends ConsumerWidget {
  const PhotoSelector({
    super.key,
    required this.originalPhotoId,
    required this.slices,
  });

  /// The id of the wall's "original" (unsliced) photo — what tapping the
  /// "Original" chip switches [activeViewProvider] to.
  final String originalPhotoId;

  /// The wall's persisted slices, ordered by `cropXpct` ascending.
  final List<PhotoRef> slices;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activeView = ref.watch(activeViewProvider);
    // Nothing loaded yet (null) reads the same as Original: no crop band is
    // active either way.
    final isOriginalActive = activeView == null || activeView.isOriginal;

    return SizedBox(
      key: const Key('photo-selector'),
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: ChoiceChip(
              key: const Key('photo-sel-original'),
              label: const Text('Original'),
              selected: isOriginalActive,
              onSelected: (_) => ref
                  .read(activeViewProvider.notifier)
                  .showOriginal(originalPhotoId),
            ),
          ),
          for (var i = 0; i < slices.length; i++)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: ChoiceChip(
                key: Key('photo-sel-slice-$i'),
                label: Text('Slice ${i + 1}'),
                selected:
                    !isOriginalActive && activeView.photoId == slices[i].id,
                onSelected: (_) => ref
                    .read(activeViewProvider.notifier)
                    .showSlice(slices[i]),
              ),
            ),
        ],
      ),
    );
  }
}
