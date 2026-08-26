// Facade for reading the offline shell's state: `navigator.serviceWorker`'s
// registration/controller plus the `masi-shell-<version>` cache name that
// `web/sw.js` opens.
//
// A service worker is a WEB-ONLY capability, so — exactly like
// `lib/core/storage/storage_persistence.dart`, `lib/app/page_reload.dart` and
// `lib/app/is_safari.dart` — this is a TWO-way split rather than the three-way
// stub/native/web split used where a real native backend exists:
//  - native (iOS/Android/desktop) AND plain-Dart `flutter test`: the inert
//    stub, picked whenever `dart.library.js_interop` is unavailable. It
//    answers [ShellInfo.notApplicable] and touches nothing, so native
//    behaviour is completely unchanged by this seam's existence. There is
//    deliberately no `*_native.dart` file: it would be a byte-copy of the
//    stub.
//  - web: real `navigator.serviceWorker` / `caches` reads via `package:web` +
//    `dart:js_interop` ONLY — never `dart:html` — so this stays dart2wasm-clean
//    (wasm is the default web build here) and introduces nothing
//    `tool/build_web.sh`'s grep gate would flag.
//
// READ-ONLY BY CONSTRUCTION. This seam never registers, unregisters, updates
// or skip-waits a worker, and never deletes a cache. It is a diagnostic, and a
// diagnostic that changes what it measures is worse than no diagnostic — the
// same line `page_reload.dart` draws when it refuses to do cache eviction.
//
// Value types live in `shell_info_types.dart` so both backends can import them
// without importing this facade (which would be a cycle).
export 'shell_info_stub.dart'
    if (dart.library.js_interop) 'shell_info_web.dart';
