import 'dart:ui';

import 'package:image_picker/image_picker.dart';

/// Native (iOS/Android/desktop) pixel-dimension decode — reads [xfile]'s
/// bytes and decodes just enough to report width/height, via `dart:ui`'s
/// `instantiateImageCodec`. No `dart:io` needed: bytes come in through
/// `xfile.readAsBytes()`.
///
/// This one really does decode a frame, unlike the web backend's header scan.
/// That is deliberate and stays: `instantiateImageCodec` runs the decode off
/// the UI thread in the engine, applies EXIF orientation itself (so the size
/// reported here is the ORIENTED one, matching web), and hands the frame back
/// as a `dart:ui` image that `dispose()` frees outside the Dart heap — none of
/// which is true of the web path, which is why the two differ. Native is also
/// no longer the memory-constrained target (see the web-only focus in
/// CLAUDE.md), so the extra decode buys correctness cheaply here.
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
