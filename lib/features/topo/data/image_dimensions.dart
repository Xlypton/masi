// Facade for decoding a picked image's pixel dimensions.
//
// Conditional export picks the right backend for the running platform,
// exactly like `lib/core/db/connection/`:
//  - native (iOS/Android/desktop): `dart:ui`'s `instantiateImageCodec` on
//    bytes read from the `XFile`.
//  - web: a bounded, zero-allocation header scan (`image_header_size.dart`),
//    with the browser's `createImageBitmap` kept only as the fallback for
//    containers that scan can't parse (HEIC). It does NOT decode the photo to
//    read two integers any more, and it does not call `package:image` either —
//    see `image_dimensions_web.dart` for the measurements behind both.
//  - anything else: stub that throws `UnsupportedError`.
//
// Both real backends return the EXIF-ORIENTED size, i.e. the dimensions of the
// image as it will actually be painted, not necessarily as it is stored.
export 'image_dimensions_stub.dart'
    if (dart.library.io) 'image_dimensions_native.dart'
    if (dart.library.js_interop) 'image_dimensions_web.dart';
