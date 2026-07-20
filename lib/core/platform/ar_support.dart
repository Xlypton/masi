// Facade for AR-platform-support checks. Conditional export picks the right
// backend for the running platform, exactly like `lib/core/db/connection/`
// and `lib/features/topo/data/image_ops/`:
//  - native (iOS/Android/desktop): real `dart:io`-backed checks —
//    `Platform.isIOS` for [isArSupported], `File(...).existsSync()` for
//    [photoFileExistsSync].
//  - web: both always return `false` — AR (camera/ARKit) never runs on web,
//    and there is no `dart:io` `File` there either. Wasm-clean: this branch
//    has zero `dart:io` dependency.
//  - anything else: stub, same inert `false` behavior as web.
//
// AR is iOS-only in this app — see the (now-replaced) `_isArPlatformSupported`
// this factors out of `lib/features/ar/presentation/ar_screen.dart`, which
// was `!kIsWeb && Platform.isIOS`. Android has no native AR implementation
// wired up (no `climbtopo/ar` platform-view handler on that side), so
// matching that exactly means: supported iff native AND iOS.
export 'ar_support_stub.dart'
    if (dart.library.io) 'ar_support_native.dart'
    if (dart.library.js_interop) 'ar_support_web.dart';
