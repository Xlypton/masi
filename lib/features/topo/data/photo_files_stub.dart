import 'dart:typed_data';

import 'package:image_picker/image_picker.dart';

import 'photo_path_resolution.dart';

/// Fallback used when neither `dart:io` nor `dart:js_interop` is available.
///
/// The constructor accepts (and ignores) both [docsDir] and [byteStore] —
/// loosely typed as `Object?` rather than the native/web constructors'
/// precise types — purely so that call sites written against either the
/// native (`docsDir:`) or web (`byteStore:`) constructor still type-check
/// under `flutter analyze`. Dart's static analyzer resolves a
/// conditional-export facade like `photo_files.dart` to its unconditional
/// (stub) branch for type-checking purposes regardless of target platform
/// (only the real compiler picks the platform-correct native/web branch at
/// build time) — so the stub's public API must be a permissive superset of
/// every real constructor's parameters, exactly like this project's other
/// conditional-export facades keep their variants signature-identical
/// (`lib/core/db/connection/`, `lib/features/topo/data/image_ops/`) to avoid
/// the same trap.
class PhotoFiles {
  PhotoFiles({Object? docsDir, Object? byteStore});

  Future<String> importPhoto(XFile xfile, String photoId) =>
      throw UnsupportedError(
        'No PhotoFiles backend available on this platform.',
      );

  Future<String> writePhotoBytes(
    String photoId,
    String ext,
    List<int> bytes,
  ) => throw UnsupportedError(
    'No PhotoFiles backend available on this platform.',
  );

  Future<Uint8List?> readPhotoBytes(String stored) => throw UnsupportedError(
    'No PhotoFiles backend available on this platform.',
  );

  Future<PhotoPathResolution> resolvePhotoPath(String stored) =>
      throw UnsupportedError(
        'No PhotoFiles backend available on this platform.',
      );

  PhotoPathResolution resolvePhotoPathSync(String stored) =>
      throw UnsupportedError(
        'No PhotoFiles backend available on this platform.',
      );

  Future<String> canonicalStoredPath(String maybePath) =>
      throw UnsupportedError(
        'No PhotoFiles backend available on this platform.',
      );

  Future<void> warmDocsPath() => throw UnsupportedError(
    'No PhotoFiles backend available on this platform.',
  );
}
