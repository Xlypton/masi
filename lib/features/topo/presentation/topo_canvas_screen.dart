import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import 'package:climbtopo/core/db/database_provider.dart';
import 'package:climbtopo/features/library/application/library_providers.dart';
import 'package:climbtopo/features/topo/application/active_view_controller.dart';
import 'package:climbtopo/features/topo/application/draw_controller.dart';
import 'package:climbtopo/features/topo/application/slice_controller.dart';
import 'package:climbtopo/features/topo/data/photo_repository.dart';
import 'package:climbtopo/features/topo/domain/topo_route.dart';
import 'package:climbtopo/features/topo/presentation/photo_selector.dart';
import 'package:climbtopo/features/topo/presentation/route_legend.dart';
import 'package:climbtopo/features/topo/presentation/route_metadata_sheet.dart';
import 'package:climbtopo/features/topo/presentation/slice_tool.dart';
import 'package:climbtopo/features/topo/presentation/symbol_palette_bar.dart';
import 'package:climbtopo/features/topo/presentation/topo_canvas.dart';

/// Holds the path of the currently selected image, or null if none.
class SelectedImageNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  void select(String path) => state = path;
  void clear() => state = null;
}

final selectedImageProvider = NotifierProvider<SelectedImageNotifier, String?>(
  SelectedImageNotifier.new,
);

/// Loads [wallId]'s persisted "original" photo (if any) via
/// [photoRepository], and, when found, loads its routes into
/// [drawController]'s state via [DrawController.loadForWall].
///
/// Extracted as a standalone, non-UI function taking its dependencies
/// directly (rather than a [WidgetRef], and rather than being inlined into
/// [_TopoCanvasScreenState]) precisely so the "restore a wall's persisted
/// photo/routes on open" contract is testable directly against a
/// [ProviderContainer]'s `photoRepositoryProvider` /
/// `drawControllerProvider.notifier` — no widget pump, no [WidgetRef] (which
/// is `sealed` in riverpod 3 and so cannot be faked in tests), and no real
/// image decode required (see
/// `test/features/topo/application/topo_canvas_wall_binding_test.dart`).
///
/// UNCONDITIONAL reset (cross-wall leak fix): [drawController.beginPhotoSwitch]
/// is called — and [onReset], if given, is invoked — synchronously, BEFORE
/// the async [photoRepository.loadOriginal] call even starts, and regardless
/// of whether a photo is ultimately found. Previously the only reset was
/// [beforeLoadForWall] below, which only ever ran when a photo WAS found;
/// entering a wall with no photo yet left [drawControllerProvider] (and,
/// via [onReset], `selectedImageProvider`/`activeViewProvider`) holding
/// whatever the PREVIOUSLY-viewed wall had left there — both are app-lifetime
/// globals, not per-wall state. Concretely, without this: navigating from a
/// wall A that has a photo+routes to a wall B that has none would show B's
/// screen with A's photo and routes still on screen, AND leave
/// `state.activeWallId == A`, so drawing+committing on B would silently
/// persist to wall A. Resetting first — synchronously, before the `await`
/// below — closes that: `activeWallId` becomes null immediately (so a stray
/// commit mid-load can't reach ANY wall's persisted routes — see
/// [DrawController.beginPhotoSwitch]'s doc), and the screen falls back to its
/// own empty state rather than the previous wall's image, for exactly as
/// long as wall B genuinely has nothing to show.
///
/// [beforeLoadForWall], if given, is invoked synchronously with the found
/// photo right before [DrawController.loadForWall] is called. This exists so
/// [_TopoCanvasScreenState] can select the photo's path (showing the image)
/// at exactly the right moment: [SelectedImageNotifier.select] synchronously
/// triggers this screen's `ref.listen` callback in `build`
/// ([DrawController.beginPhotoSwitch] + clearing the active view/transform),
/// which must run BEFORE `loadForWall` populates fresh wall/route state, or
/// that synchronous clear would immediately wipe out what was just loaded.
/// (For the has-photo path, this means [DrawController.beginPhotoSwitch] is
/// invoked twice — once unconditionally above, once via that listener when
/// [beforeLoadForWall] selects the path — which is harmless: the second call
/// finds state already clear, then `loadForWall` proceeds exactly as before.)
Future<PhotoRef?> loadWallOriginalPhoto(
  PhotoRepository photoRepository,
  DrawController drawController,
  String wallId, {
  void Function(PhotoRef photo)? beforeLoadForWall,
  void Function()? onReset,
}) async {
  drawController.beginPhotoSwitch();
  onReset?.call();

  final photo = await photoRepository.loadOriginal(wallId);
  if (photo == null) return null;
  beforeLoadForWall?.call(photo);
  await drawController.loadForWall(wallId, photo.id);
  return photo;
}

class TopoCanvasScreen extends ConsumerStatefulWidget {
  const TopoCanvasScreen({super.key, required this.wallId});

  /// The wall this canvas is bound to (from the `/walls/:wallId` route).
  /// Routes/photos loaded and attached by this screen are always scoped to
  /// this wall — see [loadWallOriginalPhoto] and [_attachPhotoAndLoad].
  final String wallId;

  @override
  ConsumerState<TopoCanvasScreen> createState() => _TopoCanvasScreenState();
}

class _TopoCanvasScreenState extends ConsumerState<TopoCanvasScreen> {
  final TransformationController _transformationController =
      TransformationController();

  /// The decoded natural size of the currently selected image, resolved
  /// asynchronously by [_resolveImageSize]. Null while unknown/loading.
  Size? _imageSize;

  /// The image path [_imageSize] was (or is being) resolved for, so that a
  /// newly-selected image triggers exactly one re-resolve.
  String? _resolvedForPath;

  /// Set when the current image failed to decode (e.g. a corrupt or
  /// unreadable file), so [_buildCanvasArea] can show a recoverable error
  /// state instead of leaving [CircularProgressIndicator] spinning forever
  /// (see [_resolveImageSize]'s `onError`).
  bool _imageLoadError = false;

  /// Whether the screen is in slice-creation mode (dragging/tapping vertical
  /// cuts over the image, see [SliceTool]) rather than its normal draw/view
  /// modes. Local, UI-only state — not part of [DrawState] — since it's a
  /// tool choice for this screen, not persisted drawing data. Mutually
  /// exclusive with the draw/view gesture paths: see [_buildCanvasArea] and
  /// [SliceTool]'s class doc for how the overlay's opaque gesture detector
  /// keeps taps from reaching [TopoCanvas] underneath while this is true.
  bool _sliceMode = false;

  /// The current wall's persisted slices (ordered by cropXpct ascending),
  /// loaded via [_loadSlicesForOriginal] once the wall/original photo is
  /// known. Shown as [PhotoSelector] chips above the canvas whenever
  /// non-empty. Reset to empty in [_resolveImageSize] the moment a new image
  /// is selected, alongside `_imageSize`, so the canvas area (hidden behind
  /// a loading spinner while `_imageSize` is null — see [_buildCanvasArea])
  /// never shows a stale photo's slice chips while a new one is loading.
  List<PhotoRef> _slices = const [];

  ImageStream? _imageStream;
  ImageStreamListener? _imageStreamListener;

  /// The wallId [_loadInitialPhotoForWall] has already run (or is running)
  /// for, so a rebuild never re-triggers the initial load for the same wall.
  /// [TopoCanvasScreen.wallId] is effectively fixed for the lifetime of a
  /// given route/widget instance (a new wallId means a new route, hence a
  /// new widget), so this is set once in [initState] and never changes.
  String? _loadedWallId;

  /// The image path most recently handed to [ImagePicker] via [_pickImage],
  /// awaiting its natural size before it can be attached to
  /// [TopoCanvasScreen.wallId] via [_attachPhotoAndLoad]. Null the rest of
  /// the time — including while restoring an already-attached photo via
  /// [_loadInitialPhotoForWall], which never needs to attach anything — so
  /// [_resolveImageSize]'s decode-success callback only calls
  /// [_attachPhotoAndLoad] for a freshly-PICKED photo, never for one being
  /// restored from persistence.
  String? _pendingAttachPath;

  @override
  void initState() {
    super.initState();
    // Deferred via Future.microtask (Riverpod's own documented fix for this
    // exact situation — see the "Tried to modify a provider while the
    // widget tree was building" error it raises otherwise): loadWallOriginalPhoto
    // now calls DrawController.beginPhotoSwitch synchronously, as its very
    // first step (see that function's unconditional-reset doc), and
    // Notifier.state= synchronously notifies listeners — which Riverpod
    // disallows while ANY widget in the tree (not just this one) is still
    // building, initState included. A microtask runs only after the current
    // synchronous call stack — which, for a widget mounting, covers the
    // ENTIRE build phase for the whole tree — unwinds, so by the time this
    // fires the tree is guaranteed done building and the reset is safe.
    //
    // This means this widget's own FIRST build can still observe the
    // previous wall's leftover `selectedImageProvider`/`drawControllerProvider`
    // state for that one frame (the reset lands a microtask later, on the
    // rebuild it triggers) — but that's an imperceptible, one-microtask-turn
    // window, not "however long the DB query in loadOriginal takes" (the
    // PREVIOUS window, when the only reset was `beforeLoadForWall`, which
    // never ran at all for a photo-less wall). No user input is possible in
    // that window, so it does not reopen the wrong-wall-commit bug this fix
    // closes.
    Future.microtask(() => _loadInitialPhotoForWall(widget.wallId));
  }

  /// Defensive re-entry point for [widget.wallId] changing on an EXISTING
  /// [_TopoCanvasScreenState] (rather than the normal case: a new wallId
  /// getting its own fresh widget/state via `context.push`'s unique keys —
  /// see [TopoCanvasScreen]'s class doc). Not currently reachable through
  /// this app's navigation, but if that ever changes (e.g. a switch to
  /// `context.go` re-using this route), skipping this would leave
  /// [_loadedWallId] pointing at the OLD wall forever, so
  /// [_loadInitialPhotoForWall] would silently no-op for the new one and the
  /// screen would keep showing the previous wall's photo/routes — exactly
  /// the cross-wall leak [loadWallOriginalPhoto]'s unconditional reset
  /// otherwise closes. Resetting [_loadedWallId] here lets that guard fire
  /// again for the new wallId.
  @override
  void didUpdateWidget(TopoCanvasScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.wallId != oldWidget.wallId) {
      _loadedWallId = null;
      // Deferred the same way as initState's call — see its doc for why a
      // direct, synchronous call here would hit Riverpod's "modify a
      // provider while the widget tree was building" guard (didUpdateWidget
      // is itself a build-lifecycle callback).
      Future.microtask(() => _loadInitialPhotoForWall(widget.wallId));
    }
  }

  @override
  void dispose() {
    final stream = _imageStream;
    final listener = _imageStreamListener;
    if (stream != null && listener != null) {
      stream.removeListener(listener);
    }
    _transformationController.dispose();
    super.dispose();
  }

  /// Invokes [DrawController.commitRoute] and, if it actually committed a
  /// new route (it no-ops when there are fewer than 2 current points — see
  /// that method's doc), opens [RouteMetadataSheet] for that route so its
  /// name/grade/style/description can be filled in right away.
  ///
  /// The new route is the last entry in [DrawState.routes]: `commitRoute`
  /// always appends, never inserts, so "highest number" and "last in the
  /// list" agree.
  Future<void> _handleCommitRoute() async {
    final notifier = ref.read(drawControllerProvider.notifier);
    final countBefore = ref.read(drawControllerProvider).routes.length;
    await notifier.commitRoute();
    if (!mounted) return;

    final routes = ref.read(drawControllerProvider).routes;
    if (routes.length <= countBefore) return;

    await _openMetadataSheet(routes.last);
  }

  /// Flips [_sliceMode]. Turning slice mode OFF (whether via this toggle or
  /// after a successful [_handleSliceCommit]) also clears any pending cuts,
  /// so re-entering slice mode later never starts from stale cuts left over
  /// from a previous, abandoned session.
  ///
  /// Turning slice mode ON (Fix 2) additionally forces [activeViewProvider]
  /// back to Original when there's a known original photo id. [SliceTool]
  /// computes each cut's fraction as `dx / viewportWidth`, which is only a
  /// valid ORIGINAL-image fraction when the canvas is showing the full
  /// original at its fit transform. If a slice (a zoomed/cropped band) were
  /// left active while slicing, that same dx/width fraction would be a
  /// fraction of the BAND, not the original — corrupting the crop rects
  /// [SliceController.commit] persists. Forcing Original here (which also
  /// makes [TopoCanvas] reframe to the full-image fit — see
  /// [_TopoCanvasState._reframeIfNeeded]) guarantees SliceTool's math is
  /// always against the true original width. [PhotoSelector] is also hidden
  /// for the duration of slice mode (see [TopoCanvasBody.build]) so the user
  /// can't switch to a slice mid-slicing and reintroduce the same problem.
  void _toggleSliceMode() {
    ref.read(sliceControllerProvider.notifier).clear();
    final enteringSliceMode = !_sliceMode;
    if (enteringSliceMode) {
      final originalPhotoId = ref.read(drawControllerProvider).activePhotoId;
      if (originalPhotoId != null) {
        ref.read(activeViewProvider.notifier).showOriginal(originalPhotoId);
      }
    }
    setState(() => _sliceMode = enteringSliceMode);
  }

  /// Commits the pending cuts in [sliceControllerProvider] as a fresh set of
  /// slices for the currently loaded wall/original photo, via
  /// [SliceController.commit] (see that method's doc for why the actual
  /// persistence call lives there rather than here: it keeps the
  /// replaceSlices/slicesFromCuts wiring unit-testable without a real image
  /// decode).
  ///
  /// No-ops with a hint snackbar if there are no pending cuts (requiring
  /// >=1 cut to commit — see [SliceController.commit]'s empty-no-op
  /// contract), and no-ops silently if no wall/original photo is loaded yet
  /// ([DrawState.activeWallId]/[activePhotoId] null) or the image's natural
  /// size hasn't resolved yet ([_imageSize] null) — there is nothing to
  /// persist against in either case.
  Future<void> _handleSliceCommit() async {
    final cuts = ref.read(sliceControllerProvider);
    if (cuts.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Add at least one cut before committing.'),
        ),
      );
      return;
    }

    final drawState = ref.read(drawControllerProvider);
    final wallId = drawState.activeWallId;
    final photoId = drawState.activePhotoId;
    final imageSize = _imageSize;
    final path = ref.read(selectedImageProvider);
    if (wallId == null || photoId == null || imageSize == null || path == null) {
      return;
    }

    final committed = await ref.read(sliceControllerProvider.notifier).commit(
      ref.read(photoRepositoryProvider),
      wallId: wallId,
      originalPhotoId: photoId,
      originalWidth: imageSize.width.round(),
      originalHeight: imageSize.height.round(),
      originalLocalPath: path,
    );
    if (!mounted || !committed) return;

    setState(() => _sliceMode = false);
    await _loadSlicesForOriginal(photoId);
  }

  /// Opens [RouteMetadataSheet] as a modal bottom sheet for [route],
  /// pre-filling its fields from [route]'s current metadata.
  Future<void> _openMetadataSheet(TopoRoute route) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => RouteMetadataSheet(routeId: route.id, initial: route),
    );
  }

  Future<void> _pickImage() async {
    final picker = ImagePicker();
    final xfile = await picker.pickImage(source: ImageSource.gallery);
    if (xfile != null) {
      _pendingAttachPath = xfile.path;
      ref.read(selectedImageProvider.notifier).select(xfile.path);
    }
  }

  /// Restores [wallId]'s already-attached original photo (if any) so the
  /// canvas shows it and its persisted routes immediately on open, without
  /// requiring the user to re-pick a photo they attached on a previous
  /// visit. If the wall has no original photo yet, leaves the empty-state UI
  /// in place — but see [loadWallOriginalPhoto]'s unconditional-reset doc:
  /// this is now a genuinely CLEAN empty state (previous wall's photo/routes
  /// cleared), not a leftover one.
  ///
  /// Guarded by [_loadedWallId] so this runs at most once per wall — called
  /// from [initState] (Flutter itself only invokes that once per widget
  /// instance) and from [didUpdateWidget] on a wallId change (which first
  /// resets [_loadedWallId] so the guard re-arms), but the guard also
  /// protects against any incidental re-entry.
  ///
  /// The actual repository read + [DrawController.loadForWall] call, AND the
  /// unconditional pre-load reset, are delegated to [loadWallOriginalPhoto]
  /// (see that function's doc for why it's a standalone, directly-testable
  /// function); this method's own job is purely the screen-side bookkeeping:
  /// clearing `selectedImageProvider`/[activeViewProvider] up front (via the
  /// `onReset` hook) so a photo-less wall never shows the previous wall's
  /// image, selecting the found photo's path (via [loadWallOriginalPhoto]'s
  /// `beforeLoadForWall` hook, at the correct point in the sequence — see
  /// that function's doc) so [TopoCanvas] shows the restored image, and
  /// loading its slices for [PhotoSelector].
  Future<void> _loadInitialPhotoForWall(String wallId) async {
    if (_loadedWallId == wallId) return;
    _loadedWallId = wallId;
    try {
      final photo = await loadWallOriginalPhoto(
        ref.read(photoRepositoryProvider),
        ref.read(drawControllerProvider.notifier),
        wallId,
        onReset: () {
          ref.read(selectedImageProvider.notifier).clear();
          ref.read(activeViewProvider.notifier).clear();
        },
        beforeLoadForWall: (p) =>
            ref.read(selectedImageProvider.notifier).select(p.localPath),
      );
      if (!mounted || widget.wallId != wallId || photo == null) return;
      await _loadSlicesForOriginal(photo.id);
    } catch (e, st) {
      debugPrint('Failed to load initial photo for wall $wallId: $e\n$st');
    }
  }

  /// Attaches the freshly-picked image at [path] (now that its natural
  /// [width]/[height] are known) to [TopoCanvasScreen.wallId] via
  /// [LibraryCrudRepository.attachPhotoToWall], then loads that new photo's
  /// (empty) routes into [drawControllerProvider] via
  /// [DrawController.loadForWall].
  ///
  /// This is what resets/repopulates the draw state for a newly-picked
  /// photo: [DrawController.loadForWall] itself clears in-progress drawing
  /// state (current points, redo stack, selection) and replaces
  /// [DrawState.routes] with whatever is persisted for this photo's wall
  /// (empty, since attaching just created the photo), and marks the
  /// controller as persistence-backed so subsequent edits write through.
  ///
  /// Called only once [width]/[height] are known (i.e. from the
  /// [ImageStreamListener] success callback in [_resolveImageSize]), since
  /// [LibraryCrudRepository.attachPhotoToWall] needs the image's natural
  /// size to create its Photo row. Since that decode is async, there is
  /// necessarily a window between the photo becoming selected and this
  /// method's [DrawController.loadForWall] call resolving; the `ref.listen`
  /// in [build] calls [DrawController.beginPhotoSwitch] synchronously the
  /// moment the path changes so [DrawState] never shows the previous
  /// photo's routes/wall during that window (see that method's doc for why
  /// this also prevents a mid-window commit from persisting to the wrong
  /// wall). The latest-path guard below additionally drops this call
  /// entirely if the user has since moved on to yet another photo, so an
  /// out-of-order resolution can't clobber a newer photo's state.
  Future<void> _attachPhotoAndLoad(String path, int width, int height) async {
    try {
      final photoId = await ref
          .read(libraryCrudRepositoryProvider)
          .attachPhotoToWall(widget.wallId, path, width, height);
      if (!mounted) return;
      // Latest-path guard: if the user has already moved on to a different
      // photo since this call started (e.g. this is a stale/out-of-order
      // resolution for a photo the user swiped past), bail out instead of
      // calling loadForWall — otherwise this stale load could clobber the
      // CURRENT photo's in-memory state with the wrong wall's routes.
      if (ref.read(selectedImageProvider) != path) return;
      await ref
          .read(drawControllerProvider.notifier)
          .loadForWall(widget.wallId, photoId);
      if (!mounted || ref.read(selectedImageProvider) != path) return;
      await _loadSlicesForOriginal(photoId);
    } catch (e, st) {
      debugPrint('Failed to attach/load photo for $path: $e\n$st');
    }
  }

  /// Loads [originalPhotoId]'s persisted slices into [_slices] (shown by
  /// [PhotoSelector]) and defaults [activeViewProvider] to viewing the
  /// original (uncropped) photo.
  ///
  /// Called once after [_attachPhotoAndLoad]'s or [_loadInitialPhotoForWall]'s
  /// `loadForWall` resolves (so the selector/canvas default to Original the
  /// moment a wall's photo/routes are known), and again after a slice-tool
  /// commit ([_handleSliceCommit]) so newly-created slices show up
  /// immediately without requiring the user to re-pick the photo.
  ///
  /// Guarded the same way as [_attachPhotoAndLoad]'s own latest-path check:
  /// [DrawState.activePhotoId] must still match [originalPhotoId] when this
  /// resolves, so a stale/out-of-order call (e.g. the user picked a
  /// different photo while this was in flight) can't clobber the current
  /// photo's slice list.
  Future<void> _loadSlicesForOriginal(String originalPhotoId) async {
    try {
      final slices = await ref
          .read(photoRepositoryProvider)
          .loadSlices(originalPhotoId);
      if (!mounted) return;
      if (ref.read(drawControllerProvider).activePhotoId != originalPhotoId) {
        return;
      }
      setState(() => _slices = slices);
      ref.read(activeViewProvider.notifier).showOriginal(originalPhotoId);
    } catch (e, st) {
      debugPrint('Failed to load slices for $originalPhotoId: $e\n$st');
    }
  }

  /// Decodes the image at [path] purely to learn its natural size, which
  /// [TopoCanvas] needs for percent<->scene coordinate conversion and for
  /// sizing its [CustomPaint]. Guarded by [_resolvedForPath] so repeated
  /// widget rebuilds while the same image is selected don't re-trigger a
  /// decode.
  void _resolveImageSize(String path) {
    if (_resolvedForPath == path) return;
    _resolvedForPath = path;
    if (mounted) {
      setState(() {
        _imageSize = null;
        _imageLoadError = false;
        _slices = const [];
      });
    }

    final previousStream = _imageStream;
    final previousListener = _imageStreamListener;
    if (previousStream != null && previousListener != null) {
      previousStream.removeListener(previousListener);
    }

    final stream = FileImage(File(path)).resolve(const ImageConfiguration());
    final listener = ImageStreamListener(
      (info, _) {
        if (!mounted) return;
        final width = info.image.width;
        final height = info.image.height;
        setState(() {
          _imageSize = Size(width.toDouble(), height.toDouble());
        });
        // Only a freshly-PICKED photo (see _pickImage) needs attaching —
        // restoring an already-attached photo via _loadInitialPhotoForWall
        // never sets _pendingAttachPath, so this is a no-op for that path.
        if (_pendingAttachPath == path) {
          _pendingAttachPath = null;
          _attachPhotoAndLoad(path, width, height);
        }
      },
      onError: (error, stackTrace) {
        // Rather than leaving _imageSize null forever (which previously
        // left the screen showing a permanent loading spinner for an
        // unreadable/corrupt image), surface a recoverable error state so
        // the user can pick a different photo.
        if (!mounted) return;
        setState(() {
          _imageSize = null;
          _imageLoadError = true;
        });
      },
    );
    _imageStream = stream;
    _imageStreamListener = listener;
    stream.addListener(listener);
  }

  @override
  Widget build(BuildContext context) {
    // Fires synchronously, as part of the same state-change notification
    // triggered by SelectedImageNotifier.select, whenever the selected
    // image path changes to a new non-null value (including the very
    // first pick). This is what closes the M3 race: DrawController state
    // is cleared (activeWallId -> null, routes -> empty, ...) the MOMENT
    // the new photo is selected, well before the async
    // ensureDefaultForImage -> loadForWall chain kicked off from
    // _resolveImageSize's decode callback below even starts, let alone
    // resolves. See DrawController.beginPhotoSwitch for why nulling
    // activeWallId is what actually prevents a mid-switch commit from
    // persisting against the previous photo's wall.
    ref.listen<String?>(selectedImageProvider, (previous, next) {
      if (next != null && next != previous) {
        ref.read(drawControllerProvider.notifier).beginPhotoSwitch();
        // Fix 1 (M5 hardening): also reset the active view and the shared
        // transformationController synchronously, right alongside
        // beginPhotoSwitch above. Without this, a fresh TopoCanvas for the
        // new photo could see this SAME (screen-owned, never-recreated)
        // TransformationController still holding the PREVIOUS photo's
        // non-identity fit/crop matrix; since the new photo's activeView
        // hasn't loaded yet either (still whatever the old photo left it
        // at — commonly "Original", i.e. no crop), TopoCanvas's own
        // pre-seeded-controller escape hatch (see
        // _TopoCanvasState._reframeIfNeeded) would read that stale
        // non-identity matrix as "a caller intentionally pre-seeded this"
        // and leave it alone forever, permanently showing the new photo
        // through the old one's transform. Resetting both to a known
        // "nothing framed yet" state here means the next reframe always
        // computes a fresh, correct fit for whatever photo/crop actually
        // ends up active.
        ref.read(activeViewProvider.notifier).clear();
        _transformationController.value = Matrix4.identity();
      }
    });

    final imagePath = ref.watch(selectedImageProvider);
    final drawState = ref.watch(drawControllerProvider);
    final drawNotifier = ref.read(drawControllerProvider.notifier);

    if (imagePath != null && imagePath != _resolvedForPath) {
      // Deferred to after this frame: triggering the decode (and its
      // setState) synchronously during build is not allowed.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _resolveImageSize(imagePath);
      });
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('ClimbTopo'),
        centerTitle: false,
        actions: [
          // Only meaningful once the wall has a photo AND at least one
          // committed, VISIBLE route: with nothing to align (or every route
          // hidden), AR would show an empty feed.
          if (drawState.activePhotoId != null &&
              drawState.routes.any((r) => r.visible))
            IconButton(
              key: const Key('topo-ar-button'),
              icon: const Icon(Icons.view_in_ar_outlined),
              tooltip: 'View in AR',
              onPressed: () => context.push('/walls/${widget.wallId}/ar'),
            ),
          if (drawState.selectedRouteId != null)
            IconButton(
              key: const Key('topo-edit-metadata-button'),
              icon: const Icon(Icons.edit_note),
              tooltip: 'Edit route metadata',
              onPressed: () {
                final selected = drawState.routes.firstWhere(
                  (r) => r.id == drawState.selectedRouteId,
                );
                _openMetadataSheet(selected);
              },
            ),
          if (_sliceMode) ...[
            IconButton(
              key: const Key('topo-slice-clear'),
              icon: const Icon(Icons.clear),
              tooltip: 'Clear pending cuts',
              onPressed: () =>
                  ref.read(sliceControllerProvider.notifier).clear(),
            ),
            IconButton(
              key: const Key('topo-slice-commit'),
              icon: const Icon(Icons.check),
              tooltip: 'Commit slices',
              onPressed: _handleSliceCommit,
            ),
          ],
          IconButton(
            key: const Key('topo-slice-mode-button'),
            icon: Icon(
              _sliceMode ? Icons.content_cut : Icons.content_cut_outlined,
            ),
            tooltip: _sliceMode
                ? 'Exit slice mode'
                : 'Slice this photo into strips',
            onPressed: _toggleSliceMode,
          ),
          IconButton(
            key: const Key('topo-mode-toggle'),
            icon: Icon(
              drawState.mode == DrawMode.draw
                  ? Icons.edit
                  : Icons.pan_tool_alt_outlined,
            ),
            tooltip: drawState.mode == DrawMode.draw
                ? 'Switch to view mode'
                : 'Switch to draw mode',
            onPressed: drawNotifier.toggleMode,
          ),
        ],
      ),
      body: imagePath == null
          ? _buildEmptyState(context)
          : _buildCanvasArea(imagePath, drawState),
      bottomNavigationBar: BottomAppBar(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            IconButton(
              key: const Key('topo-undo-button'),
              icon: const Icon(Icons.undo),
              tooltip: 'Undo',
              onPressed: drawNotifier.undo,
            ),
            IconButton(
              key: const Key('topo-redo-button'),
              icon: const Icon(Icons.redo),
              tooltip: 'Redo',
              onPressed: drawNotifier.redo,
            ),
            IconButton(
              key: const Key('topo-clear-button'),
              icon: const Icon(Icons.clear),
              tooltip: 'Discard current route',
              onPressed: drawNotifier.clearCurrent,
            ),
            IconButton(
              key: const Key('topo-commit-button'),
              icon: const Icon(Icons.check),
              tooltip: 'Commit route',
              onPressed: _handleCommitRoute,
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _pickImage,
        tooltip: 'Pick a photo',
        child: const Icon(Icons.add_photo_alternate_outlined),
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    return Center(
      child: Column(
        key: const Key('topo-empty-state'),
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.photo_size_select_actual_outlined,
            size: 72,
            color: Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(height: 16),
          Text(
            'No photo yet — pick one to start',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: Theme.of(context).colorScheme.outline,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCanvasArea(String imagePath, DrawState drawState) {
    if (_imageLoadError) {
      return _buildImageErrorState(context);
    }
    final imageSize = _imageSize;
    if (imageSize == null) {
      return const Center(
        key: Key('topo-image-loading'),
        child: CircularProgressIndicator(),
      );
    }
    return TopoCanvasBody(
      imagePath: imagePath,
      imageSize: imageSize,
      drawState: drawState,
      transformationController: _transformationController,
      sliceMode: _sliceMode,
      originalPhotoId: drawState.activePhotoId,
      slices: _slices,
    );
  }

  Widget _buildImageErrorState(BuildContext context) {
    return Center(
      child: Column(
        key: const Key('topo-image-error-state'),
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.broken_image_outlined,
            size: 72,
            color: Theme.of(context).colorScheme.error,
          ),
          const SizedBox(height: 16),
          Text(
            "Couldn't load this photo",
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: Theme.of(context).colorScheme.error,
            ),
          ),
          const SizedBox(height: 16),
          OutlinedButton(
            key: const Key('topo-image-error-pick-another'),
            onPressed: _pickImage,
            child: const Text('Choose another photo'),
          ),
        ],
      ),
    );
  }
}

/// The canvas area shown once [imageSize] is resolved: the [PhotoSelector]
/// (when the wall has slices), the symbol palette bar (gated to
/// [DrawMode.draw] — see Fix 2), the interactive [TopoCanvas] framed to
/// whichever view is active, and the [RouteLegend].
///
/// Extracted as a standalone public widget (rather than inlined into
/// [_TopoCanvasScreenState._buildCanvasArea]) so it can be pumped directly
/// in widget tests with an injected [imageSize] and [drawState] — the same
/// approach [TopoCanvas] itself uses (see its class doc) — without needing
/// a real, decodable image file on disk or waiting on the async image
/// decode that only [TopoCanvasScreen] drives.
class TopoCanvasBody extends ConsumerWidget {
  const TopoCanvasBody({
    super.key,
    required this.imagePath,
    required this.imageSize,
    required this.drawState,
    required this.transformationController,
    this.sliceMode = false,
    this.originalPhotoId,
    this.slices = const [],
  });

  final String imagePath;
  final Size imageSize;
  final DrawState drawState;
  final TransformationController transformationController;

  /// Whether the slice-creation tool overlay ([SliceTool]) is showing over
  /// the canvas. Defaults to `false` so existing call sites (and the
  /// pre-M5 widget tests that construct this widget without mentioning
  /// slicing at all) are unaffected. Exposed as a plain parameter — mirroring
  /// [drawState] — rather than this widget owning the flag itself, so it can
  /// be driven directly in widget tests (see the "TopoCanvasBody: slice mode
  /// overlay" test group) without needing [TopoCanvasScreen]'s real,
  /// async image-decode gate.
  final bool sliceMode;

  /// The id of the wall's "original" (unsliced) photo, or null if unknown
  /// yet (e.g. [TopoCanvasScreen]'s wall/routes load hasn't resolved). Fed
  /// to [PhotoSelector] (and used as the "Original" chip's target); the
  /// selector is only shown when both this is non-null AND [slices] is
  /// non-empty.
  final String? originalPhotoId;

  /// The wall's persisted slices (ordered by cropXpct ascending). Defaults
  /// to empty so existing call sites/tests that never mention slicing are
  /// unaffected — with no slices, [PhotoSelector] is never shown and
  /// [TopoCanvas] is never framed to a crop.
  final List<PhotoRef> slices;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activeView = ref.watch(activeViewProvider);
    // No crop when nothing is loaded yet (null) or the active view is
    // explicitly Original — either way TopoCanvas gets nulls and falls back
    // to its normal fit-to-viewport framing.
    final cropXpct = (activeView != null && !activeView.isOriginal)
        ? activeView.cropXpct
        : null;
    final cropWidthPct = (activeView != null && !activeView.isOriginal)
        ? activeView.cropWidthPct
        : null;

    return Column(
      children: [
        // Hidden during slice mode (Fix 2): the screen forces activeView
        // back to Original the moment slice mode is entered (see
        // TopoCanvasScreen._toggleSliceMode's doc for why SliceTool's
        // dx/viewportWidth cut math requires that), so letting the user
        // switch to a slice mid-slicing via this selector would silently
        // reintroduce the same corrupted-crop-rect bug.
        if (originalPhotoId != null && slices.isNotEmpty && !sliceMode)
          PhotoSelector(originalPhotoId: originalPhotoId!, slices: slices),
        // Only shown in draw mode (and never during slice mode, which is
        // mutually exclusive with drawing): in view mode a canvas tap means
        // "select a route", not "place a symbol", so showing (and letting
        // the user activate) the symbol bar there would be misleading. Not
        // clearing `activeSymbol` on mode switch is deliberate — see fix
        // notes — so a quick peek at view mode and back to draw mode
        // preserves the user's chosen symbol.
        if (drawState.mode == DrawMode.draw && !sliceMode)
          const SymbolPaletteBar(),
        Expanded(
          child: Stack(
            children: [
              TopoCanvas(
                imagePath: imagePath,
                imageSize: imageSize,
                transformationController: transformationController,
                activeCropXpct: cropXpct,
                activeCropWidthPct: cropWidthPct,
              ),
              if (sliceMode)
                Positioned.fill(
                  // SliceTool is sized to the actual rendered viewport (via
                  // LayoutBuilder) rather than the image's natural
                  // `imageSize`, and its opaque gesture detector sits on top
                  // of TopoCanvas — see SliceTool's class doc for why that's
                  // what keeps slice-mode taps from ever reaching
                  // TopoCanvas's own draw/view gesture handling underneath.
                  child: LayoutBuilder(
                    builder: (context, constraints) => SliceTool(
                      size: Size(constraints.maxWidth, constraints.maxHeight),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const RouteLegend(),
      ],
    );
  }
}
