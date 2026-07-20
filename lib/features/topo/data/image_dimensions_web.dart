import 'dart:js_interop';
import 'dart:ui';

import 'package:image_picker/image_picker.dart';
import 'package:web/web.dart' as web;

/// Web pixel-dimension decode via the browser's offscreen `createImageBitmap`
/// — mirrors `image_ops_web.dart`'s Blob-construction idiom, wasm-clean
/// (built only on `dart:js_interop` + `package:web`).
Future<Size> decodeImageSize(XFile xfile) async {
  final bytes = await xfile.readAsBytes();
  final blob = web.Blob(<web.BlobPart>[bytes.toJS].toJS);
  final bitmap = await web.window.createImageBitmap(blob).toDart;
  final size = Size(bitmap.width.toDouble(), bitmap.height.toDouble());
  bitmap.close();
  return size;
}
