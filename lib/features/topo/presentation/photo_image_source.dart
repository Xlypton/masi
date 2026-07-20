// Facade for `photo_image.dart`'s platform-specific rendering/decode.
//
// Conditional export picks the right backend for the running platform,
// exactly like `lib/core/db/connection/` and
// `lib/features/topo/data/image_ops/`:
//  - native (iOS/Android/desktop): `Image.file`/`FileImage` (`dart:io`).
//  - web: IndexedDB bytes -> Blob object URL -> `Image.network`/
//    `NetworkImage` (`dart:js_interop` + `package:web`, via the LRU
//    `PhotoImageCache`).
//  - anything else: stub that throws `UnsupportedError`.
export 'photo_image_source_stub.dart'
    if (dart.library.io) 'photo_image_source_native.dart'
    if (dart.library.js_interop) 'photo_image_source_web.dart';
