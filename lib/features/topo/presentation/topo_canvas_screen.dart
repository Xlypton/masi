import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

/// Holds the path of the currently selected image, or null if none.
class SelectedImageNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  void select(String path) => state = path;
  void clear() => state = null;
}

final selectedImageProvider =
    NotifierProvider<SelectedImageNotifier, String?>(SelectedImageNotifier.new);

class TopoCanvasScreen extends ConsumerWidget {
  const TopoCanvasScreen({super.key});

  Future<void> _pickImage(WidgetRef ref) async {
    final picker = ImagePicker();
    final xfile = await picker.pickImage(source: ImageSource.gallery);
    if (xfile != null) {
      ref.read(selectedImageProvider.notifier).select(xfile.path);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final imagePath = ref.watch(selectedImageProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('ClimbTopo'),
        centerTitle: false,
      ),
      body: imagePath == null
          ? _buildEmptyState(context)
          : _buildCanvas(imagePath),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _pickImage(ref),
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

  Widget _buildCanvas(String imagePath) {
    return InteractiveViewer(
      minScale: 0.5,
      maxScale: 5.0,
      boundaryMargin: const EdgeInsets.all(double.infinity),
      child: Image.file(
        File(imagePath),
        fit: BoxFit.contain,
      ),
    );
  }
}
