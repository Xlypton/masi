import 'dart:typed_data';

/// Fallback used when neither dart:io nor dart:js_interop is available.
Future<Uint8List> generateThumbnail(
  Uint8List src, {
  int maxEdge = 512,
  int quality = 80,
}) =>
    throw UnsupportedError(
      'No thumbnail generation backend available on this platform.',
    );
