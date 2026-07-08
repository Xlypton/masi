import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import 'package:climbtopo/core/db/database_provider.dart';
import 'package:climbtopo/features/topo/application/draw_controller.dart';
import 'package:climbtopo/features/topo/presentation/route_legend.dart';
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
    } catch (e, st) {
      debugPrint('Failed to load wall/routes for $path: $e\n$st');
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
              onPressed: drawNotifier.commitRoute,
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

/// The canvas area shown once [imageSize] is resolved: the symbol palette
/// bar (gated to [DrawMode.draw] — see Fix 2), the interactive [TopoCanvas],
/// and the [RouteLegend].
///
/// Extracted as a standalone public widget (rather than inlined into
/// [_TopoCanvasScreenState._buildCanvasArea]) so it can be pumped directly
/// in widget tests with an injected [imageSize] and [drawState] — the same
/// approach [TopoCanvas] itself uses (see its class doc) — without needing
/// a real, decodable image file on disk or waiting on the async image
/// decode that only [TopoCanvasScreen] drives.
class TopoCanvasBody extends StatelessWidget {
  const TopoCanvasBody({
    super.key,
    required this.imagePath,
    required this.imageSize,
    required this.drawState,
    required this.transformationController,
  });

  final String imagePath;
  final Size imageSize;
  final DrawState drawState;
  final TransformationController transformationController;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Only shown in draw mode: in view mode a canvas tap means "select
        // a route", not "place a symbol", so showing (and letting the user
        // activate) the symbol bar there would be misleading. Not clearing
        // `activeSymbol` on mode switch is deliberate — see fix notes —
        // so a quick peek at view mode and back to draw mode preserves the
        // user's chosen symbol.
        if (drawState.mode == DrawMode.draw) const SymbolPaletteBar(),
        Expanded(
          child: TopoCanvas(
            imagePath: imagePath,
            imageSize: imageSize,
            transformationController: transformationController,
          ),
        ),
        const RouteLegend(),
      ],
    );
  }
}
