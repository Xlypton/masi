import 'dart:ui';

import 'package:image_picker/image_picker.dart';

/// Native (iOS/Android/desktop) pixel-dimension decode — reads [xfile]'s
/// bytes and decodes just enough to report width/height, via `dart:ui`'s
/// `instantiateImageCodec` (the same technique
/// `topos_screen.dart`'s `_handleNewTopo` already uses for its own dimension
/// decode). No `dart:io` needed: bytes come in through `xfile.readAsBytes()`.
Future<Size> decodeImageSize(XFile xfile) async {
  final bytes = await xfile.readAsBytes();
  final codec = await instantiateImageCodec(bytes);
  try {
    final frame = await codec.getNextFrame();
    final size = Size(
      frame.image.width.toDouble(),
      frame.image.height.toDouble(),
    );
    frame.image.dispose();
    return size;
  } finally {
    codec.dispose();
  }
}
