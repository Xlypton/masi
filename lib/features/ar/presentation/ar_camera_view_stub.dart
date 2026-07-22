// Default (non-web) backend for the AR live-camera surface widget.
//
// Used on native platforms (iOS/Android) and by `flutter test` (VM) — on
// iOS, `ArScreen` never actually calls this: it constructs a native
// `UiKitView` directly instead (see `ar_screen.dart` / `ar_support.dart`).
// This stub exists purely so the module compiles on every platform and is
// renderable in widget tests without pulling in any web-only libraries
// (no `dart:js_interop`, no `dart:io`).
//
// The `Key('ar-web-camera')` is load-bearing: it's the same key the real
// web widget (`ar_camera_view_web.dart`) uses for its `HtmlElementView`, so
// tests that locate the camera surface by key work identically against
// either backend.
import 'package:flutter/widgets.dart';

Widget buildArCameraView({
  VoidCallback? onReady,
  void Function(String message)? onError,
}) {
  return const ColoredBox(
    color: Color(0xFF000000),
    child: SizedBox.expand(key: Key('ar-web-camera')),
  );
}
