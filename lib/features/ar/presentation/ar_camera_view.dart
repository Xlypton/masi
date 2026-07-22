// Facade for the AR live-camera surface widget.
//
// Conditional export picks the right backend for the running platform,
// mirroring `lib/features/topo/data/photo_files.dart`'s pattern — except
// this module only ever needs two branches (no native/`dart:io` backend):
// native platforms (iOS/Android) never render this widget at all (`ArScreen`
// uses a native `UiKitView` there instead, see `ar_screen.dart` /
// `ar_support.dart`), but the stub must still exist so this file — and
// anything importing it — compiles and is test-renderable on the VM.
//  - web (`dart:js_interop` available): a real `getUserMedia()`-backed
//    `HtmlElementView` surface (`ar_camera_view_web.dart`).
//  - everything else (VM: native + `flutter test`): an inert placeholder
//    (`ar_camera_view_stub.dart`).
export 'ar_camera_view_stub.dart'
    if (dart.library.js_interop) 'ar_camera_view_web.dart';
