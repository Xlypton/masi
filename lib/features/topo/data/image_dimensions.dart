// Facade for decoding a picked image's pixel dimensions.
//
// Conditional export picks the right backend for the running platform,
// exactly like `lib/core/db/connection/`:
//  - native (iOS/Android/desktop): `dart:ui`'s `instantiateImageCodec` on
//    bytes read from the `XFile`.
//  - web: the browser's `createImageBitmap`, mirroring `image_ops_web.dart`.
//  - anything else: stub that throws `UnsupportedError`.
export 'image_dimensions_stub.dart'
    if (dart.library.io) 'image_dimensions_native.dart'
    if (dart.library.js_interop) 'image_dimensions_web.dart';
