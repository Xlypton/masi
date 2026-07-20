import 'dart:ui';

import 'package:image_picker/image_picker.dart';

/// Fallback used when neither `dart:io` nor `dart:js_interop` is available.
Future<Size> decodeImageSize(XFile xfile) => throw UnsupportedError(
  'No image-dimension decoding backend available on this platform.',
);
