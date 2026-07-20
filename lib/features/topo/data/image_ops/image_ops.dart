// Facade for downscaled-JPEG thumbnail generation.
//
// Conditional export picks the right backend for the running platform,
// exactly like `lib/core/db/connection/`:
//  - native (iOS/Android/desktop): `package:image` (pure Dart, off the UI
//    thread via the CALLER's `compute()`).
//  - web: the browser's offscreen canvas via `dart:js_interop` +
//    `package:web` (wasm-clean; `compute()` is a no-op on web so we must
//    hand the decode/resize/encode off to native browser APIs instead).
//  - anything else: stub that throws `UnsupportedError`.
export 'image_ops_stub.dart'
    if (dart.library.io) 'image_ops_native.dart'
    if (dart.library.js_interop) 'image_ops_web.dart';
