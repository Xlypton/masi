import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:climbtopo/app/theme.dart';
import 'package:climbtopo/core/db/database_provider.dart';
import 'package:climbtopo/features/topo/data/photo_files.dart';
import 'package:climbtopo/features/topo/data/photo_repository.dart';
import 'package:climbtopo/features/topo/presentation/photo_image.dart';
import 'package:climbtopo/shared/presentation/masi_icon.dart';

/// Horizontal strip of a wall's `original` photos — the "multiple photos
/// per topo" axis, watching [wallOriginalsProvider] directly (so it stays
/// live as photos are attached/reordered/deleted, with no manual refresh
/// needed).
///
/// This is a SEPARATE axis from [PhotoSelector] (`photo_selector.dart`),
/// which switches between the Original/slice VIEWS of a single photo —
/// [PhotoStrip] switches between DIFFERENT photos entirely, each with its
/// own independent set of route overlays (see `RouteRepository`'s class
/// doc). The two are meant to compose, stacked in the same top glass-chrome
/// band, not to replace one another — see `TopoCanvasScreen.build`'s call
/// site.
///
/// Renders nothing ([SizedBox.shrink]) while the wall has zero live
/// originals — a single-photo wall is free to keep showing a one-item
/// strip (harmless) or a caller can gate it away entirely at zero cost, but
/// this widget itself never insists on being visible below that.
class PhotoStrip extends ConsumerWidget {
  const PhotoStrip({
    super.key,
    required this.wallId,
    required this.activePhotoId,
    required this.onSelect,
    this.readOnly = false,
    this.onAdd,
    this.onSetCover,
    this.onDelete,
  });

  /// The wall whose live originals back this strip.
  final String wallId;

  /// The id of the photo currently shown on the canvas — highlighted with
  /// an accent ring. `null` (nothing loaded yet) highlights nothing.
  final String? activePhotoId;

  /// Invoked with the tapped photo's [PhotoRef] — the caller is responsible
  /// for actually switching the canvas over to it (selecting its path and
  /// loading its routes; see `TopoCanvasScreen._switchToPhoto`).
  final void Function(PhotoRef photo) onSelect;

  /// See [TopoCanvasScreen.readOnly]. When `true`, the trailing '+' add
  /// tile and the long-press manage menu (set cover / delete) are both
  /// suppressed — a read-only viewer can still switch between a shared
  /// topo's photos via [onSelect], but every mutating affordance disappears
  /// (mirroring every other editing control on this screen).
  final bool readOnly;

  /// Tapped via the trailing '+' tile. Null (or [readOnly]) hides that
  /// tile entirely — there is nothing to attach a new photo TO in that
  /// case.
  final VoidCallback? onAdd;

  /// Long-press menu's "Set as cover" action for a given photo. Null (or
  /// [readOnly]) suppresses the long-press menu's cover entry.
  final void Function(PhotoRef photo)? onSetCover;

  /// Long-press menu's "Delete photo" action (after the menu's own confirm
  /// dialog). Null (or [readOnly]) suppresses the long-press menu's delete
  /// entry.
  final void Function(PhotoRef photo)? onDelete;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final photosAsync = ref.watch(wallOriginalsProvider(wallId));
    final photos = photosAsync.maybeWhen(
      data: (list) => list,
      orElse: () => const <PhotoRef>[],
    );
    if (photos.isEmpty) return const SizedBox.shrink();

    final colors = MasiColors.of(context);
    final showAdd = !readOnly && onAdd != null;

    return SizedBox(
      key: const Key('photo-strip'),
      height: 60,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        children: [
          for (final photo in photos)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: _PhotoStripItem(
                photo: photo,
                active: photo.id == activePhotoId,
                readOnly: readOnly,
                onTap: () => onSelect(photo),
                onSetCover: onSetCover,
                onDelete: onDelete,
              ),
            ),
          if (showAdd)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: _AddPhotoTile(onTap: onAdd!, colors: colors),
            ),
        ],
      ),
    );
  }
}

/// A single 52x52 thumbnail in [PhotoStrip]: a [PhotoImage] of
/// [PhotoRef.localPath]'s THUMBNAIL variant (via [thumbKeyFor] — a 52px
/// strip tile has no business decoding/holding the full-resolution
/// original), an accent ring when [active], a small star badge
/// when [PhotoRef.isPrimary] (the wall's cover photo), and — unless
/// [readOnly] — a long-press manage menu (set cover / delete).
class _PhotoStripItem extends StatelessWidget {
  const _PhotoStripItem({
    required this.photo,
    required this.active,
    required this.readOnly,
    required this.onTap,
    this.onSetCover,
    this.onDelete,
  });

  final PhotoRef photo;
  final bool active;
  final bool readOnly;
  final VoidCallback onTap;
  final void Function(PhotoRef photo)? onSetCover;
  final void Function(PhotoRef photo)? onDelete;

  static const double _size = 52;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    return GestureDetector(
      key: Key('photo-strip-item-${photo.id}'),
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onLongPress: readOnly
          ? null
          : () => _showManageSheet(context, photo, colors, onSetCover, onDelete),
      child: Container(
        width: _size,
        height: _size,
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(MasiRadii.control),
          border: Border.all(
            color: active ? colors.accent : Colors.transparent,
            width: 2,
          ),
        ),
        child: Stack(
          children: [
            Positioned.fill(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(MasiRadii.control - 2),
                child: PhotoImage(
                  thumbKeyFor(photo.localPath),
                  fit: BoxFit.cover,
                  placeholder: () => Container(
                    color: colors.surface2,
                    child: Center(
                      child: MasiIcon('image', size: 20, color: colors.ink3),
                    ),
                  ),
                ),
              ),
            ),
            if (photo.isPrimary)
              Positioned(
                top: 1,
                right: 1,
                child: Container(
                  padding: const EdgeInsets.all(2),
                  decoration: BoxDecoration(
                    color: colors.ground.withValues(alpha: 0.9),
                    shape: BoxShape.circle,
                  ),
                  child: MasiIcon('star_fill', size: 12, color: colors.accent),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The trailing '+' tile in [PhotoStrip] (`photo-strip-add`) — tapping it
/// runs the caller's existing pick-image flow (see
/// `TopoCanvasScreen._pickImage`), attaching a brand new original rather
/// than replacing any existing one.
class _AddPhotoTile extends StatelessWidget {
  const _AddPhotoTile({required this.onTap, required this.colors});

  final VoidCallback onTap;
  final MasiColors colors;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key: const Key('photo-strip-add'),
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        width: _PhotoStripItem._size,
        height: _PhotoStripItem._size,
        decoration: BoxDecoration(
          color: colors.surface2,
          borderRadius: BorderRadius.circular(MasiRadii.control),
          border: Border.all(color: colors.separator),
        ),
        child: Center(
          child: MasiIcon('add', size: 22, color: colors.accent),
        ),
      ),
    );
  }
}

/// The long-press manage menu for a strip thumbnail (U4): "Set as cover"
/// (hidden for the already-primary photo — nothing to promote) and "Delete
/// photo" (behind its own confirm [AlertDialog], since it's destructive and
/// cascades that photo's routes — see
/// `PhotoRepository.deleteOriginalPhoto`'s doc).
Future<void> _showManageSheet(
  BuildContext context,
  PhotoRef photo,
  MasiColors colors,
  void Function(PhotoRef photo)? onSetCover,
  void Function(PhotoRef photo)? onDelete,
) async {
  await showModalBottomSheet<void>(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!photo.isPrimary && onSetCover != null)
            ListTile(
              key: Key('photo-manage-setcover-${photo.id}'),
              leading: MasiIcon('star_fill', color: colors.accent),
              title: const Text('Set as cover'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                onSetCover(photo);
              },
            ),
          if (onDelete != null)
            ListTile(
              key: Key('photo-manage-delete-${photo.id}'),
              leading: MasiIcon('delete', color: colors.gradeHard),
              title: const Text('Delete photo'),
              onTap: () async {
                Navigator.of(sheetContext).pop();
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (dialogContext) => AlertDialog(
                    key: const Key('photo-manage-delete-dialog'),
                    title: const Text('Delete this photo?'),
                    content: const Text(
                      "This removes the photo and every route drawn on "
                      'it. This cannot be undone.',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () =>
                            Navigator.of(dialogContext).pop(false),
                        child: const Text('Cancel'),
                      ),
                      TextButton(
                        key: const Key('photo-manage-delete-confirm'),
                        onPressed: () => Navigator.of(dialogContext).pop(true),
                        child: const Text('Delete'),
                      ),
                    ],
                  ),
                );
                if (confirmed == true) onDelete(photo);
              },
            ),
        ],
      ),
    ),
  );
}
