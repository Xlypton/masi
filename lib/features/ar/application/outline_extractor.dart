// Facade for AR ghost-outline extraction (see `ArScreen._load`'s use of
// `extractOutline`). Conditional export picks the right backend for the
// running platform, exactly like `lib/core/db/connection/` and
// `lib/features/topo/data/image_ops/`:
//  - native (iOS/Android/desktop): real `dart:io` file read + `package:image`
//    decode/edge-detection + a `compute()` isolate hop.
//  - web: an inert no-op (`null`) — AR (camera/ARKit) never runs on web, so
//    there's nothing to extract an alignment ghost-outline for, and this
//    keeps `dart:io` out of the web bundle entirely.
//  - anything else: stub, same inert no-op as web.
//
// All three variants also export `outlineFromImage` (the pure, platform-
// agnostic pixel-processing core from `outline_shape.dart`) unchanged, so
// existing direct callers of that function keep working regardless of which
// backend got picked.
export 'outline_extractor_stub.dart'
    if (dart.library.io) 'outline_extractor_native.dart'
    if (dart.library.js_interop) 'outline_extractor_web.dart';
