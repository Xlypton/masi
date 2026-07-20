// Facade for photo-file persistence (originals + thumbnails).
//
// Conditional export picks the right backend for the running platform,
// exactly like `lib/core/db/connection/`:
//  - native (iOS/Android/desktop): copies files into the app documents
//    directory via `dart:io`.
//  - web: stores bytes in IndexedDB via `PhotoByteStore` (no filesystem).
//  - anything else: stub that throws `UnsupportedError`.
export 'photo_path_resolution.dart';
export 'photo_files_stub.dart'
    if (dart.library.io) 'photo_files_native.dart'
    if (dart.library.js_interop) 'photo_files_web.dart';
