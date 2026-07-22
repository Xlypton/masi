// Under `flutter test` (VM), `ar_camera_view.dart`'s conditional export
// resolves to `ar_camera_view_stub.dart` (no `dart:js_interop` on the VM),
// so this exercises the stub backend — the web backend
// (`ar_camera_view_web.dart`) can only compile/run under `flutter build
// web`/web-server test runners, not here.
import 'package:masi/features/ar/presentation/ar_camera_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('buildArCameraView renders a camera-surface placeholder keyed '
      'ar-web-camera', (tester) async {
    await tester.pumpWidget(MaterialApp(home: buildArCameraView()));

    expect(find.byKey(const Key('ar-web-camera')), findsOneWidget);
  });
}
