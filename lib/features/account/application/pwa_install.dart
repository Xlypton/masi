// Facade for the PWA-install seam. This is a WEB-ONLY feature (there is no
// native counterpart to a browser install prompt), so unlike the
// native/web/stub three-way splits elsewhere (e.g.
// `lib/features/topo/data/photo_files.dart`), this is a two-way split:
//  - native (iOS/Android/desktop) AND plain-Dart tests: the inert stub —
//    picked whenever `dart.library.js_interop` is unavailable.
//  - web: the real `window`/`navigator` + install-prompt implementation.
export 'pwa_install_stub.dart' if (dart.library.js_interop) 'pwa_install_web.dart';
