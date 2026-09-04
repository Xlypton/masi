// `PointCloudView` (`lib/features/scan/presentation/point_cloud_view.dart`) —
// the hand-rolled 3D viewer.
//
// Two things this file is careful about:
//
//  * It never loads or decodes an image. The widget draws points, not
//    textures, and per CLAUDE.md a real image-codec decode hangs under
//    fake-async — so there is nothing here to hang on, and nothing should be
//    added that would change that.
//  * It asserts on the camera through the `@visibleForTesting` accessors on
//    `PointCloudViewState` rather than on painted pixels. Gestures are what
//    can regress; the exact arrangement of dots is not something an assertion
//    can usefully pin.

import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:masi/app/theme.dart';
import 'package:masi/features/scan/domain/point_cloud.dart';
import 'package:masi/features/scan/presentation/point_cloud_view.dart';

/// A small synthetic cloud: a 2x2x2 cube of coloured corners plus a centre
/// point, which is enough to exercise every branch of the painter (several
/// distinct palette entries, points in more than one depth band) while staying
/// readable in a failure message.
PointCloud _cube() {
  final positions = <double>[];
  final colors = <int>[];
  var i = 0;
  for (final x in const [-1.0, 1.0]) {
    for (final y in const [-1.0, 1.0]) {
      for (final z in const [-1.0, 1.0]) {
        positions.addAll([x, y, z]);
        colors.addAll([(i * 31) % 256, (i * 57) % 256, (i * 91) % 256]);
        i++;
      }
    }
  }
  positions.addAll([0, 0, 0]);
  colors.addAll([128, 128, 128]);
  return PointCloud.fromXyzRgb(
    Float32List.fromList(positions),
    Uint8List.fromList(colors),
  )!;
}

/// A cloud where every point is the same colour — one palette entry — so the
/// painter's degenerate-palette path gets walked too.
PointCloud _monochrome() => PointCloud.fromXyzRgb(
  Float32List.fromList([0, 0, 0, 1, 1, 1, -1, 2, 0.5]),
  Uint8List.fromList([90, 90, 90, 90, 90, 90, 90, 90, 90]),
)!;

Widget _host(Widget child) => MaterialApp(
  theme: MasiTheme.light,
  home: Scaffold(
    body: Center(
      child: SizedBox(width: 400, height: 600, child: child),
    ),
  ),
);

PointCloudViewState _stateOf(WidgetTester tester) =>
    tester.state<PointCloudViewState>(find.byType(PointCloudView));

Finder get _surface => find.byKey(const Key('point-cloud-view'));

void main() {
  group('rendering', () {
    testWidgets('renders a cloud without throwing', (tester) async {
      await tester.pumpWidget(_host(PointCloudView(cloud: _cube())));
      await tester.pump();

      expect(_surface, findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('renders a single-colour cloud without throwing', (
      tester,
    ) async {
      await tester.pumpWidget(_host(PointCloudView(cloud: _monochrome())));
      await tester.pump();

      expect(tester.takeException(), isNull);
    });

    testWidgets('renders a one-point cloud without throwing', (tester) async {
      final cloud = PointCloud.fromXyzRgb(
        Float32List.fromList([3, 4, 5]),
        Uint8List.fromList([1, 2, 3]),
      )!;

      await tester.pumpWidget(_host(PointCloudView(cloud: cloud)));
      await tester.pump();

      expect(tester.takeException(), isNull);
      // A zero-radius cloud must still get a usable, finite camera rather
      // than a division by zero.
      expect(_stateOf(tester).fitDistance, greaterThan(0));
      expect(_stateOf(tester).fitDistance.isFinite, isTrue);
    });

    testWidgets('survives a zero-sized viewport', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: MasiTheme.light,
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 0,
                height: 0,
                child: PointCloudView(cloud: _cube()),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
    });
  });

  group('framing', () {
    testWidgets('opens framed on the model, not on a void', (tester) async {
      final cloud = _cube();
      await tester.pumpWidget(_host(PointCloudView(cloud: cloud)));

      final state = _stateOf(tester);

      // The camera must start outside the model and close enough that the
      // bounding sphere fills a useful fraction of the field of view.
      expect(state.camera.distance, state.fitDistance);
      expect(state.camera.distance, greaterThan(cloud.boundingRadius));
      expect(state.camera.distance, lessThan(cloud.boundingRadius * 6));
      expect(state.camera.pan, Offset.zero);
    });

    testWidgets('re-frames when the cloud is replaced', (tester) async {
      await tester.pumpWidget(_host(PointCloudView(cloud: _cube())));
      final small = _stateOf(tester).fitDistance;

      final big = PointCloud.fromXyzRgb(
        Float32List.fromList([-500, -500, -500, 500, 500, 500]),
        Uint8List.fromList([1, 2, 3, 4, 5, 6]),
      )!;
      await tester.pumpWidget(_host(PointCloudView(cloud: big)));

      expect(_stateOf(tester).fitDistance, greaterThan(small * 10));
      expect(_stateOf(tester).camera.distance, _stateOf(tester).fitDistance);
    });
  });

  group('gestures', () {
    testWidgets('a one-finger horizontal drag orbits in yaw', (tester) async {
      await tester.pumpWidget(_host(PointCloudView(cloud: _cube())));
      final before = _stateOf(tester).camera;

      await tester.drag(_surface, const Offset(120, 0));
      await tester.pump();

      final after = _stateOf(tester).camera;
      expect(after.yaw, isNot(before.yaw));
      expect(after.pitch, before.pitch);
      expect(after.distance, before.distance, reason: 'orbit must not zoom');
    });

    testWidgets('a one-finger vertical drag orbits in pitch', (tester) async {
      await tester.pumpWidget(_host(PointCloudView(cloud: _cube())));
      final before = _stateOf(tester).camera;

      await tester.drag(_surface, const Offset(0, 60));
      await tester.pump();

      final after = _stateOf(tester).camera;
      expect(after.pitch, greaterThan(before.pitch));
      expect(after.yaw, before.yaw);
    });

    testWidgets('pitch is clamped so the view cannot flip', (tester) async {
      await tester.pumpWidget(_host(PointCloudView(cloud: _cube())));

      await tester.drag(_surface, const Offset(0, 4000));
      await tester.pump();
      expect(_stateOf(tester).camera.pitch, PointCloudCamera.maxPitch);
      expect(PointCloudCamera.maxPitch, lessThan(1.5708));

      await tester.drag(_surface, const Offset(0, -8000));
      await tester.pump();
      expect(_stateOf(tester).camera.pitch, -PointCloudCamera.maxPitch);
    });

    testWidgets('the mouse wheel zooms', (tester) async {
      await tester.pumpWidget(_host(PointCloudView(cloud: _cube())));
      final start = _stateOf(tester).camera.distance;

      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      final centre = tester.getCenter(_surface);
      await tester.sendEventToBinding(pointer.hover(centre));
      await tester.pump();

      await tester.sendEventToBinding(pointer.scroll(const Offset(0, 200)));
      await tester.pump();
      final out = _stateOf(tester).camera.distance;
      expect(out, greaterThan(start), reason: 'scrolling down zooms out');

      await tester.sendEventToBinding(pointer.scroll(const Offset(0, -400)));
      await tester.pump();
      expect(_stateOf(tester).camera.distance, lessThan(out));
    });

    testWidgets('wheel zoom is clamped at both ends', (tester) async {
      await tester.pumpWidget(_host(PointCloudView(cloud: _cube())));
      final state = _stateOf(tester);
      final fit = state.fitDistance;

      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(pointer.hover(tester.getCenter(_surface)));
      for (var i = 0; i < 40; i++) {
        await tester.sendEventToBinding(pointer.scroll(const Offset(0, 500)));
        await tester.pump();
      }
      expect(state.camera.distance, lessThanOrEqualTo(fit * 20 + 1e-9));

      for (var i = 0; i < 80; i++) {
        await tester.sendEventToBinding(pointer.scroll(const Offset(0, -500)));
        await tester.pump();
      }
      expect(state.camera.distance, greaterThanOrEqualTo(fit * 0.05 - 1e-9));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a two-finger pinch zooms in and pans', (tester) async {
      await tester.pumpWidget(_host(PointCloudView(cloud: _cube())));
      final before = _stateOf(tester).camera;

      final centre = tester.getCenter(_surface);
      final first = await tester.startGesture(centre - const Offset(40, 0));
      final second = await tester.startGesture(centre + const Offset(40, 0));
      // Spread the fingers (zoom in) and slide the whole gesture right (pan).
      await tester.pump();
      await first.moveBy(const Offset(-20, 0));
      await second.moveBy(const Offset(100, 0));
      await tester.pump();

      final after = _stateOf(tester).camera;
      expect(after.distance, lessThan(before.distance));
      expect(after.pan.dx, isNot(0.0));
      // A pinch is not an orbit.
      expect(after.yaw, before.yaw);
      expect(after.pitch, before.pitch);

      await first.up();
      await second.up();
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });

  group('scale note — the honesty rule', () {
    testWidgets('shows NO measurement when metresPerUnit is null', (
      tester,
    ) async {
      await tester.pumpWidget(_host(PointCloudView(cloud: _cube())));

      expect(find.byKey(const Key('point-cloud-scale-note')), findsNothing);
      // Nothing anywhere on the surface may read as a measurement: an
      // SfM reconstruction is only defined up to scale.
      expect(find.textContaining('m'), findsNothing);
    });

    testWidgets('shows a measurement when metresPerUnit is supplied', (
      tester,
    ) async {
      // The cube spans 2 units; at 3 m per unit that is 6 m across.
      await tester.pumpWidget(
        _host(PointCloudView(cloud: _cube(), metresPerUnit: 3)),
      );

      final note = find.byKey(const Key('point-cloud-scale-note'));
      expect(note, findsOneWidget);
      expect(tester.widget<Text>(note).data, '6.0 m across');
    });

    testWidgets('rounds a large span to whole metres', (tester) async {
      await tester.pumpWidget(
        _host(PointCloudView(cloud: _cube(), metresPerUnit: 21.4)),
      );

      expect(
        tester
            .widget<Text>(find.byKey(const Key('point-cloud-scale-note')))
            .data,
        '43 m across',
      );
    });

    testWidgets('a nonsensical scale is treated as no scale', (tester) async {
      for (final bad in const [0.0, -2.0, double.nan, double.infinity]) {
        await tester.pumpWidget(
          _host(PointCloudView(cloud: _cube(), metresPerUnit: bad)),
        );
        await tester.pump();

        expect(
          find.byKey(const Key('point-cloud-scale-note')),
          findsNothing,
          reason: 'metresPerUnit $bad should show nothing',
        );
      }
    });
  });
}
