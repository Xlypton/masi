import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// Web thumbnail generation — runs the decode/resize/encode on the browser's
/// offscreen canvas instead of pure-Dart `package:image`, since `compute()`
/// is a no-op on web and a large-photo decode/resize in pure Dart would
/// freeze the UI thread. Wasm-clean: built only on `dart:js_interop` +
/// `package:web` bindings — the legacy browser-interop libraries are
/// intentionally unused.
Future<Uint8List> generateThumbnail(
  Uint8List src, {
  int maxEdge = 512,
  int quality = 80,
}) async {
  final blob = web.Blob(
    <web.BlobPart>[src.toJS].toJS,
  );
  final bitmap = await web.window.createImageBitmap(blob).toDart;

  final width = bitmap.width;
  final height = bitmap.height;
  final longEdge = width >= height ? width : height;
  if (longEdge <= maxEdge) {
    bitmap.close();
    return src; // already small enough
  }

  final scale = maxEdge / longEdge;
  final targetWidth = (width * scale).round();
  final targetHeight = (height * scale).round();

  final canvas = web.OffscreenCanvas(targetWidth, targetHeight);
  final ctx = canvas.getContext('2d') as web.OffscreenCanvasRenderingContext2D;
  ctx.drawImage(bitmap, 0, 0, targetWidth, targetHeight);
  bitmap.close();

  final outBlob = await canvas
      .convertToBlob(
        web.ImageEncodeOptions(type: 'image/jpeg', quality: quality / 100),
      )
      .toDart;
  final buffer = await outBlob.arrayBuffer().toDart;
  return buffer.toDart.asUint8List();
}
