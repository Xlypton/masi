// Facade for the Web Push registration seam.
//
// WEB-ONLY, like the PWA-install seam it is modelled on (`pwa_install.dart`):
// there is no native counterpart here, because the native builds of this app
// have no push story at all. So this is a two-way split rather than the
// native/web/stub three-way one used for things like `photo_files.dart`:
//
//  - native (iOS/Android/desktop) AND plain-Dart tests: the inert stub, picked
//    whenever `dart.library.js_interop` is unavailable. It reports
//    `PushPermission.unsupported`, which every caller already has to handle.
//  - web: the real Notification/PushManager implementation.
export 'push_registration_stub.dart'
    if (dart.library.js_interop) 'push_registration_web.dart';
