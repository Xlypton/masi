import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:masi/app/theme.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/features/topo/data/photo_files.dart';
import 'package:masi/features/topo/data/photo_repository.dart';
import 'package:masi/features/topo/presentation/photo_image.dart';
import 'package:masi/features/topo/presentation/photo_loading_fill.dart';
import 'package:masi/shared/presentation/masi_icon.dart';
import 'package:masi/shared/presentation/masi_loading_gate.dart';
import 'package:masi/shared/presentation/masi_loading_indicator.dart';
import 'package:masi/shared/presentation/masi_skeleton.dart';

/// Horizontal strip of a wall's `original` photos — the "multiple photos
/// per topo" axis, watching [wallOriginalsProvider] directly (so it stays
/// live as photos are attached/reordered/deleted, with no manual refresh
/// needed). [PhotoStrip] switches between DIFFERENT photos entirely, each
/// with its own independent set of route overlays (see `RouteRepository`'s
/// class doc) — see `TopoCanvasScreen.build`'s call site for where it sits
/// in the top glass-chrome band.
///
/// Renders nothing ([SizedBox.shrink]) while the wall has zero live
/// originals — a single-photo wall is free to keep showing a one-item
/// strip (harmless) or a caller can gate it away entirely at zero cost, but
/// this widget itself never insists on being visible below that.
///
/// **Loading is not emptiness.** This used to collapse
/// `AsyncValue<List<PhotoRef>>` with
/// `maybeWhen(data: (l) => l, orElse: () => const [])`, which rendered the
/// still-loading state as an EMPTY LIST — i.e. it claimed "this wall has no
/// photos" before that was known, and the band then popped into existence once
/// the rows landed. A first load with no value yet now shows a shaped skeleton
/// strip instead (`photo-strip-loading`, three placeholder tiles at the real
/// 52 px tile geometry), behind [MasiLoadingGate]'s reveal delay so a fast
/// Drift read still paints no loading state at all. The empty case below is
/// therefore reachable only when the wall really has no photos.
///
/// **The separator is part of this band.** The hairline [Divider] that used to
/// live in `TopoCanvasScreen`'s own chrome column moved in here so it appears
/// and disappears with whatever this widget decides to show (tiles, skeleton or
/// nothing) — a divider floating over the photo above an invisible strip is
/// exactly the kind of state the split ownership produced.
class PhotoStrip extends ConsumerStatefulWidget {
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
  ///
  /// Returns a [Future] so this widget knows when the write it kicked off has
  /// finished, and can show a busy cue on the affected tile in the meantime —
  /// see [_PhotoStripState._runManageAction]. Before that this was a plain
  /// `void` callback, so the whole window between the confirm tap and the
  /// eventual SnackBar had no UI at all.
  final Future<void> Function(PhotoRef photo)? onSetCover;

  /// Long-press menu's "Delete photo" action (after the menu's own confirm
  /// dialog). Null (or [readOnly]) suppresses the long-press menu's delete
  /// entry. Returns a [Future] for the same reason as [onSetCover].
  final Future<void> Function(PhotoRef photo)? onDelete;

  @override
  ConsumerState<PhotoStrip> createState() => _PhotoStripState();
}

class _PhotoStripState extends ConsumerState<PhotoStrip> {
  /// The photo a manage action ([PhotoStrip.onSetCover]/[PhotoStrip.onDelete])
  /// is currently running for, or `null` when nothing is in flight.
  ///
  /// The manage sheet pops itself before the write starts (deliberately — the
  /// sheet is a menu, not a progress dialog), which used to leave the write
  /// running with no UI anywhere: the strip looked idle for the whole cascade
  /// (photo row + its routes + the redirect to another photo) and then a
  /// SnackBar appeared out of nowhere. The tile the action is about is the
  /// honest place for that cue, so it gets a gated busy overlay.
  String? _busyPhotoId;

  /// Runs [action] for [photo] with [_busyPhotoId] held for its duration.
  Future<void> _runManageAction(
    PhotoRef photo,
    Future<void> Function(PhotoRef photo) action,
  ) async {
    setState(() => _busyPhotoId = photo.id);
    try {
      await action(photo);
    } finally {
      // The strip is very often gone by now (deleting the last photo unmounts
      // this whole band), which is exactly why this is guarded.
      if (mounted) setState(() => _busyPhotoId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    final photosAsync = ref.watch(wallOriginalsProvider(widget.wallId));
    // Read the value's facts rather than pattern-matching: a REFRESH carries
    // both `isLoading` and the previous list, and that list must keep showing.
    final photos = photosAsync.hasValue
        ? photosAsync.requireValue
        : const <PhotoRef>[];
    final firstLoad = photosAsync.isLoading && !photosAsync.hasValue;

    return MasiLoadingGate(
      isLoading: firstLoad,
      builder: (context, showLoading) {
        if (photos.isEmpty) {
          // Not "no photos" until the load says so — and nothing at all until
          // the gate's reveal delay has passed, so a fast read never flashes.
          if (!showLoading) return const SizedBox.shrink();
          return _band(colors, const _PhotoStripSkeleton());
        }
        // Real rows win immediately, even mid-hold: a skeleton must never sit
        // on top of content that has already arrived.
        return _band(colors, _buildStrip(colors, photos));
      },
    );
  }

  /// The strip band: its own hairline separator plus [child]. See the class
  /// doc for why the separator lives here rather than in the screen.
  Widget _band(MasiColors colors, Widget child) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Divider(height: MasiSpacing.sm, thickness: 1, color: colors.separator),
        child,
      ],
    );
  }

  Widget _buildStrip(MasiColors colors, List<PhotoRef> photos) {
    final showAdd = !widget.readOnly && widget.onAdd != null;
    final onSetCover = widget.onSetCover;
    final onDelete = widget.onDelete;

    return SizedBox(
      key: const Key('photo-strip'),
      height: _kStripHeight,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        children: [
          for (final photo in photos)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: _PhotoStripItem(
                photo: photo,
                active: photo.id == widget.activePhotoId,
                readOnly: widget.readOnly,
                busy: photo.id == _busyPhotoId,
                onTap: () => widget.onSelect(photo),
                onSetCover: onSetCover == null
                    ? null
                    : (p) => _runManageAction(p, onSetCover),
                onDelete: onDelete == null
                    ? null
                    : (p) => _runManageAction(p, onDelete),
              ),
            ),
          if (showAdd)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: _AddPhotoTile(onTap: widget.onAdd!, colors: colors),
            ),
        ],
      ),
    );
  }
}

/// Height of the strip band's tile row — the 52 px tile plus its 4 px vertical
/// padding, top and bottom.
const double _kStripHeight = 60;

/// First-load placeholder for the strip: the same row geometry as the real
/// thing (52 px tiles at [MasiRadii.control], 4 px gutters) with shimmering
/// boxes where the thumbnails will be, so the band does not resize when the
/// rows land.
///
/// Three tiles regardless of how many photos turn out to exist: the count is
/// exactly what is not yet known, and three reads as "some photos" without
/// promising a number.
class _PhotoStripSkeleton extends StatelessWidget {
  const _PhotoStripSkeleton();

  @override
  Widget build(BuildContext context) {
    return Semantics(
      key: const Key('photo-strip-loading'),
      container: true,
      label: 'Loading photos',
      child: IgnorePointer(
        child: SizedBox(
          height: _kStripHeight,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            child: Row(
              children: List<Widget>.generate(
                3,
                (_) => const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 4),
                  child: MasiSkeleton.box(
                    width: _PhotoStripItem._size,
                    height: _PhotoStripItem._size,
                    radius: MasiRadii.control,
                  ),
                ),
              ),
            ),
          ),
        ),
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
    this.busy = false,
    this.onSetCover,
    this.onDelete,
  });

  final PhotoRef photo;
  final bool active;
  final bool readOnly;

  /// A manage action for this photo is in flight — see
  /// [_PhotoStripState._busyPhotoId].
  final bool busy;

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
                  // #56's distinct "still resolving" slot. Without it a
                  // thumbnail whose bytes are still being read from
                  // disk/IndexedDB — or fetched on demand for a public photo
                  // this device does not have yet (see
                  // `missing_photo_byte_resolver.dart`) — looked EXACTLY like
                  // a broken one: same grey box, same 'image' glyph. The
                  // shimmer says "coming"; the glyph now only ever means
                  // "gone".
                  loadingPlaceholder: () => const PhotoLoadingFill(),
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
            // The manage-action busy cue. Driven by `isLoading` + a hidden
            // child rather than a conditional mount, so it honours the
            // minimum-visible hold as well as the reveal delay: a fast write
            // shows nothing, a slow one does not strobe.
            Positioned.fill(
              child: IgnorePointer(
                child: MasiLoadingGate(
                  isLoading: busy,
                  builder: (context, showLoading) {
                    if (!showLoading) return const SizedBox.shrink();
                    return DecoratedBox(
                      key: Key('photo-strip-item-busy-${photo.id}'),
                      decoration: BoxDecoration(
                        color: colors.ground.withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(
                          MasiRadii.control - 2,
                        ),
                      ),
                      child: Center(
                        child: MasiLoadingIndicator.inline(
                          // The gate above already applied both delays; the
                          // indicator must not re-apply them.
                          revealDelay: Duration.zero,
                          minVisible: Duration.zero,
                          semanticLabel: 'Updating photo',
                        ),
                      ),
                    );
                  },
                ),
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
///
/// Both entries pop this sheet BEFORE running their action, unchanged: the
/// sheet is a menu, and holding it open over a write would make its own
/// dismissal feel broken. What the action does show is the busy cue on the
/// tile it is about — see [_PhotoStripState._busyPhotoId], which is what
/// [onSetCover]/[onDelete] are wired through here.
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
