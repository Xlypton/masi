import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Native (iOS/Android/desktop) thumbnail generation — pure Dart via
/// `package:image`, operating entirely on bytes (no `dart:io`).
///
/// This is a synchronous CPU-bound transform; the CALLER is responsible for
/// running it off the UI thread (e.g. via `compute()`) — this function does
/// not do that itself.
Future<Uint8List> generateThumbnail(
  Uint8List src, {
  int maxEdge = 512,
  int quality = 80,
}) async {
  // Any decode/encode failure (undecodable, truncated, or a format sniffer
  // that reads past a short buffer and throws) falls back to the original
  // bytes — a thumbnail is derivable/disposable, never worth failing over.
  try {
    final decoded = img.decodeImage(src);
    if (decoded == null) return src; // undecodable → original bytes unchanged

    final longEdge =
        decoded.width >= decoded.height ? decoded.width : decoded.height;
    if (longEdge <= maxEdge) return src; // already small enough

    final resized = decoded.width >= decoded.height
        ? img.copyResize(decoded, width: maxEdge)
        : img.copyResize(decoded, height: maxEdge);

    return Uint8List.fromList(img.encodeJpg(resized, quality: quality));
  } catch (_) {
    return src;
  }
}
