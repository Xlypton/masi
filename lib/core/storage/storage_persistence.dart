// Facade for the browser's storage-persistence API:
// `navigator.storage.persist()` / `persisted()` / `estimate()`.
//
// This is a WEB-ONLY capability — nothing outside a browser can silently
// evict this app's local data — so, exactly like
// `lib/features/account/application/pwa_install.dart`,
// `lib/app/web_lifecycle.dart` and `lib/app/is_safari.dart`, this is a
// TWO-way split rather than the three-way stub/native/web split used where a
// real native backend exists (e.g. `lib/core/platform/ar_support.dart`):
//  - native (iOS/Android/desktop) AND plain-Dart `flutter test`: the inert
//    stub, picked whenever `dart.library.js_interop` is unavailable. Every
//    entry point answers "not applicable" and touches nothing, so native
//    behaviour is completely unchanged by this seam's existence. There is
//    deliberately no `*_native.dart` file: it would be a byte-copy of the
//    stub.
//  - web: real `navigator.storage` reads via `package:web` +
//    `dart:js_interop` ONLY — never `dart:html` — so this stays
//    dart2wasm-clean (wasm is the default web build here) and introduces no
//    file-system library that `tool/build_web.sh`'s grep gate would flag.
//
// Value types live in `storage_persistence_types.dart` so both backends can
// import them without importing this facade (which would be a cycle).
export 'storage_persistence_stub.dart'
    if (dart.library.js_interop) 'storage_persistence_web.dart';
