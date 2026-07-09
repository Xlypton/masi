import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import 'package:climbtopo/core/db/database_provider.dart';
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

class TopoCanvasScreen extends ConsumerStatefulWidget {
  const TopoCanvasScreen({super.key});

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
      ref.read(selectedImageProvider.notifier).select(xfile.path);
    }
  }

  /// Ensures a default Area/Sector/Wall/Photo hierarchy exists for the image
  /// at [path] (creating one on first sight of that path, reusing it on
  /// subsequent sights — see [LibraryRepository.ensureDefaultForImage]),
  /// then loads that wall's persisted routes into [drawControllerProvider]
  /// via [DrawController.loadForWall].
  ///
  /// This is what resets/repopulates the draw state for a newly-picked or
  /// newly-resolved photo: [DrawController.loadForWall] itself clears
  /// in-progress drawing state (current points, redo stack, selection) and
  /// replaces [DrawState.routes] with whatever is persisted for this photo's
  /// wall (empty for a photo never seen before), and marks the controller as
  /// persistence-backed so subsequent edits write through. This replaces the
  /// earlier, cruder `ref.invalidate(drawControllerProvider)` reset, which
  /// only cleared in-memory state and never loaded persisted routes.
  ///
  /// Called only once [width]/[height] are known (i.e. from the
  /// [ImageStreamListener] success callback in [_resolveImageSize]), since
  /// [LibraryRepository.ensureDefaultForImage] needs the image's natural
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
  Future<void> _loadWallForImage(String path, int width, int height) async {
    try {
      final ids = await ref
          .read(libraryRepositoryProvider)
          .ensureDefaultForImage(path, width, height);
      if (!mounted) return;
      // Latest-path guard: if the user has already moved on to a different
      // photo since this call started (e.g. this is a stale/out-of-order
      // resolution for a photo the user swiped past), bail out instead of
      // calling loadForWall — otherwise this stale load could clobber the
      // CURRENT photo's in-memory state with the wrong wall's routes.
      if (ref.read(selectedImageProvider) != path) return;
      await ref
          .read(drawControllerProvider.notifier)
          .loadForWall(ids.wallId, ids.photoId);
      if (!mounted || ref.read(selectedImageProvider) != path) return;
      await _loadSlicesForOriginal(ids.photoId);
    } catch (e, st) {
      debugPrint('Failed to load wall/routes for $path: $e\n$st');
    }
  }

  /// Loads [originalPhotoId]'s persisted slices into [_slices] (shown by
  /// [PhotoSelector]) and defaults [activeViewProvider] to viewing the
  /// original (uncropped) photo.
  ///
  /// Called once after [_loadWallForImage]'s `loadForWall` resolves (so the
  /// selector/canvas default to Original the moment a wall's photo/routes
  /// are known), and again after a slice-tool commit
  /// ([_handleSliceCommit]) so newly-created slices show up immediately
  /// without requiring the user to re-pick the photo.
  ///
  /// Guarded the same way as [_loadWallForImage]'s own latest-path check:
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
        _loadWallForImage(path, width, height);
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
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.photo_size_select_actual_outlined,
            size: 72,
            color: Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(height: 16),
          Text(
            'Pick a photo to start',
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
