import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import 'package:climbtopo/features/topo/application/draw_controller.dart';
import 'package:climbtopo/features/topo/presentation/topo_canvas.dart';

/// Holds the path of the currently selected image, or null if none.
class SelectedImageNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  void select(String path) => state = path;
  void clear() => state = null;
}

final selectedImageProvider =
    NotifierProvider<SelectedImageNotifier, String?>(SelectedImageNotifier.new);

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

  /// Whenever [selectedImageProvider] changes from one photo to a
  /// *different* photo, resets [drawControllerProvider] so routes/points
  /// drawn on the previous photo don't carry over onto the new one.
  ///
  /// This is wired via [ref.listen] in [build] (invoked from there as
  /// `_onSelectedImageChanged`) rather than inlined into [_pickImage]
  /// itself: [_pickImage] can't be driven from a widget test without
  /// mocking the `image_picker` platform channel, whereas
  /// [selectedImageProvider] is a plain, already-public provider. Listening
  /// on the provider instead means the reset fires no matter how the
  /// selected path changes (today, only [_pickImage] changes it) and — more
  /// importantly for testing Fix 2 — lets a widget test simulate "picking a
  /// photo" by calling `selectedImageProvider.notifier.select(path)`
  /// directly and asserting the draw controller was invalidated, without
  /// needing a real/mocked image picker.
  void _onSelectedImageChanged(String? previous, String? next) {
    if (previous == null || next == null || previous == next) return;
    ref.invalidate(drawControllerProvider);
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
        setState(() {
          _imageSize = Size(
            info.image.width.toDouble(),
            info.image.height.toDouble(),
          );
        });
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
    ref.listen<String?>(selectedImageProvider, _onSelectedImageChanged);
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
          : _buildCanvasArea(imagePath),
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

  Widget _buildCanvasArea(String imagePath) {
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
    return TopoCanvas(
      imagePath: imagePath,
      imageSize: imageSize,
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
