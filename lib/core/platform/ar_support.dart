// Facade for AR-platform-support checks. Conditional export picks the right
// backend for the running platform, exactly like `lib/core/db/connection/`
// and `lib/features/topo/data/image_ops/`. Two capabilities:
//  - [isArSupported]: is the AR screen reachable at all?
//  - [arSupportsAutoTracking]: is there native ARKit-style continuous
//    tracking (auto-placement)? When false, AR runs in manual-align-only
//    mode (live camera + hand-aligned overlay, no auto lock-on).
//
// Backends:
//  - native (iOS/Android/desktop): real `dart:io`-backed checks —
//    `Platform.isIOS` for BOTH capabilities; `File(...).existsSync()` for
//    [photoFileExistsSync]. So native AR = iOS only, with auto-tracking.
//  - web: [isArSupported] is `true` (a `getUserMedia` camera surface backs
//    manual AR — see `ar_camera_view_web.dart`), but [arSupportsAutoTracking]
//    is `false` (no WebXR/ARKit in the browser — iPhone Safari has no working
//    immersive-ar). [photoFileExistsSync] stays `false` (no `dart:io` File).
//    Wasm-clean: zero `dart:io` dependency in this branch.
//  - anything else: stub, inert `false` for every capability.
//
// Android native still has no AR implementation wired up (no `masi/ar`
// platform-view handler on that side), so native support remains iff iOS.
export 'ar_support_stub.dart'
    if (dart.library.io) 'ar_support_native.dart'
    if (dart.library.js_interop) 'ar_support_web.dart';
