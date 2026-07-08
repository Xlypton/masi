import 'dart:ui' as ui;

import 'package:climbtopo/features/topo/presentation/topo_painter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A minimal fake [Canvas] that records the drawing calls [TopoPainter]
/// actually makes (`drawCircle`, `drawLine`, `drawPath`) without needing a
/// mocking package. `TopoPainter.paint` never calls `save`/`restore`/
/// `transform`/clip methods, so leaving those to the `noSuchMethod`
/// fallback is safe: they are never invoked in these tests.
class _RecordingCanvas implements Canvas {
  final List<Offset> circleCenters = [];
  final List<double> circleRadii = [];
  final List<Color> circleColors = [];
  final List<({Offset p1, Offset p2})> lines = [];
  final List<Path> paths = [];

  @override
  void drawCircle(Offset c, double radius, Paint paint) {
    circleCenters.add(c);
    circleRadii.add(radius);
    circleColors.add(paint.color);
  }

  @override
  void drawLine(Offset p1, Offset p2, Paint paint) {
    lines.add((p1: p1, p2: p2));
  }

  @override
  void drawPath(Path path, Paint paint) {
    paths.add(path);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  const imageSize = Size(400, 300);

  TopoPainter buildPainter({
    List<List<Offset>> routes = const [],
    List<Offset> currentPoints = const [],
    bool showHandles = false,
  }) {
    return TopoPainter(
      imageSize: imageSize,
      routes: routes,
      currentPoints: currentPoints,
      showHandles: showHandles,
    );
  }

  group('TopoPainter drawing behavior', () {
    test('A1: a single point paints without throwing and draws a dot', () {
      final painter = buildPainter(currentPoints: const [Offset(0.5, 0.5)]);
      final canvas = _RecordingCanvas();

      expect(() => painter.paint(canvas, imageSize), returnsNormally);

      expect(canvas.circleCenters, hasLength(1));
      expect(canvas.circleCenters.single, const Offset(200, 150));
      expect(canvas.lines, isEmpty);
      expect(canvas.paths, isEmpty);
    });

    test('A2: two points paint a straight line segment without crashing', () {
      final painter = buildPainter(
        currentPoints: const [Offset(0.0, 0.0), Offset(1.0, 1.0)],
      );
      final canvas = _RecordingCanvas();

      expect(() => painter.paint(canvas, imageSize), returnsNormally);

      expect(canvas.lines, hasLength(1));
      expect(canvas.lines.single.p1, Offset.zero);
      expect(canvas.lines.single.p2, const Offset(400, 300));
      expect(canvas.circleCenters, isEmpty);
      expect(canvas.paths, isEmpty);
    });

    test(
      'A3: three or more points paint a Catmull-Rom cubic bezier path '
      'without crashing',
      () {
        final painter = buildPainter(
          currentPoints: const [
            Offset(0.1, 0.1),
            Offset(0.4, 0.5),
            Offset(0.6, 0.3),
            Offset(0.9, 0.8),
          ],
        );
        final canvas = _RecordingCanvas();

        expect(() => painter.paint(canvas, imageSize), returnsNormally);

        expect(canvas.paths, hasLength(1));
        expect(canvas.lines, isEmpty);
        expect(canvas.circleCenters, isEmpty);

        // The path should start exactly at the first scene point.
        final metrics = canvas.paths.single.computeMetrics().toList();
        expect(metrics, isNotEmpty);
        final start = metrics.first.getTangentForOffset(0)?.position;
        expect(start, isNotNull);
        expect((start! - const Offset(40, 30)).distance, lessThan(0.01));
      },
    );

    test(
      'A3b: catmullRomControlPoints computes the exact Catmull-Rom cubic '
      'Bezier control points (would catch a /6 -> /3 or p0/p3 swap '
      'regression)',
      () {
        const p0 = Offset(0, 0);
        const p1 = Offset(10, 0);
        const p2 = Offset(10, 10);
        const p3 = Offset(0, 10);

        final (cp1, cp2) = TopoPainter.catmullRomControlPoints(p0, p1, p2, p3);

        // cp1 = p1 + (p2 - p0) / 6 = (10, 0) + (10, 10) / 6
        //     = (11.666..., 1.666...)
        expect(cp1.dx, closeTo(11.6666667, 1e-6));
        expect(cp1.dy, closeTo(1.6666667, 1e-6));

        // cp2 = p2 - (p3 - p1) / 6 = (10, 10) - (-10, 10) / 6
        //     = (11.666..., 8.333...)
        expect(cp2.dx, closeTo(11.6666667, 1e-6));
        expect(cp2.dy, closeTo(8.3333333, 1e-6));
      },
    );

    test('A4: showHandles=true draws one handle per current point', () {
      const points = [Offset(0.1, 0.2), Offset(0.5, 0.5), Offset(0.8, 0.1)];
      final painter = buildPainter(currentPoints: points, showHandles: true);
      final canvas = _RecordingCanvas();

      painter.paint(canvas, imageSize);

      // 1 dot per point drawn by the polyline pass is not expected here
      // (3 points -> a path, not dots), so all recorded circles are
      // handles: exactly one per current point.
      expect(canvas.circleCenters, hasLength(points.length));
    });

    test('A4: showHandles=false draws no handles', () {
      const points = [Offset(0.1, 0.2), Offset(0.5, 0.5), Offset(0.8, 0.1)];
      final painter = buildPainter(currentPoints: points, showHandles: false);
      final canvas = _RecordingCanvas();

      painter.paint(canvas, imageSize);

      expect(canvas.circleCenters, isEmpty);
    });

    test(
      'A4: showHandles=true with a single current point draws the dot '
      'plus one handle (two circles)',
      () {
        final painter = buildPainter(
          currentPoints: const [Offset(0.5, 0.5)],
          showHandles: true,
        );
        final canvas = _RecordingCanvas();

        painter.paint(canvas, imageSize);

        // 1 circle from the single-point dot render + 1 handle circle.
        expect(canvas.circleCenters, hasLength(2));
      },
    );
  });

  group('TopoPainter.shouldRepaint', () {
    test('returns false when everything is identical', () {
      final a = buildPainter(
        routes: const [
          [Offset(0.1, 0.1), Offset(0.2, 0.2)],
        ],
        currentPoints: const [Offset(0.5, 0.5)],
        showHandles: true,
      );
      final b = buildPainter(
        routes: const [
          [Offset(0.1, 0.1), Offset(0.2, 0.2)],
        ],
        currentPoints: const [Offset(0.5, 0.5)],
        showHandles: true,
      );

      expect(a.shouldRepaint(b), isFalse);
    });

    test('returns true when routes differ', () {
      final a = buildPainter(
        routes: const [
          [Offset(0.1, 0.1), Offset(0.2, 0.2)],
        ],
      );
      final b = buildPainter(routes: const []);

      expect(a.shouldRepaint(b), isTrue);
    });

    test('returns true when currentPoints differ', () {
      final a = buildPainter(currentPoints: const [Offset(0.5, 0.5)]);
      final b = buildPainter(currentPoints: const [Offset(0.6, 0.5)]);

      expect(a.shouldRepaint(b), isTrue);
    });

    test(
      'returns true when a point moves within a completed route (same '
      'route count, same point count, one coordinate changed)',
      () {
        final a = buildPainter(
          routes: const [
            [Offset(0.1, 0.1), Offset(0.2, 0.2), Offset(0.3, 0.1)],
          ],
        );
        final b = buildPainter(
          routes: const [
            [Offset(0.1, 0.1), Offset(0.25, 0.2), Offset(0.3, 0.1)],
          ],
        );

        expect(a.shouldRepaint(b), isTrue);
      },
    );

    test('returns true when showHandles differs', () {
      final a = buildPainter(showHandles: true);
      final b = buildPainter(showHandles: false);

      expect(a.shouldRepaint(b), isTrue);
    });

    test('returns true when imageSize differs', () {
      const a = TopoPainter(
        imageSize: Size(400, 300),
        routes: [],
        currentPoints: [],
        showHandles: false,
      );
      const b = TopoPainter(
        imageSize: Size(200, 150),
        routes: [],
        currentPoints: [],
        showHandles: false,
      );

      expect(a.shouldRepaint(b), isTrue);
    });

    test('returns true when any color differs', () {
      const base = TopoPainter(
        imageSize: imageSize,
        routes: [],
        currentPoints: [],
        showHandles: false,
      );
      const differentRouteColor = TopoPainter(
        imageSize: imageSize,
        routes: [],
        currentPoints: [],
        showHandles: false,
        routeColor: Colors.red,
      );
      const differentCurrentColor = TopoPainter(
        imageSize: imageSize,
        routes: [],
        currentPoints: [],
        showHandles: false,
        currentColor: Colors.red,
      );
      const differentHandleColor = TopoPainter(
        imageSize: imageSize,
        routes: [],
        currentPoints: [],
        showHandles: false,
        handleColor: Colors.red,
      );

      expect(base.shouldRepaint(differentRouteColor), isTrue);
      expect(base.shouldRepaint(differentCurrentColor), isTrue);
      expect(base.shouldRepaint(differentHandleColor), isTrue);
    });
  });

  group('TopoPainter golden', () {
    testWidgets(
      'A5: one completed route renders a stable golden image',
      (tester) async {
        // Pin the device pixel ratio *and* physical size so the checked-in
        // golden PNG's dimensions (and pixel content) are deterministic
        // across machines. The test window gives the RepaintBoundary tight
        // layout constraints equal to physicalSize / devicePixelRatio, so
        // pinning devicePixelRatio alone is not enough: without also
        // pinning physicalSize, the resulting logical window size (and
        // thus the captured image size) still varies with whatever
        // physicalSize the host happens to report.
        tester.view.physicalSize = const Size(400, 300);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final painter = TopoPainter(
          imageSize: const Size(400, 300),
          routes: const [
            [
              Offset(0.1, 0.1),
              Offset(0.4, 0.5),
              Offset(0.6, 0.3),
              Offset(0.9, 0.8),
            ],
          ],
          currentPoints: const [],
          showHandles: false,
        );

        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: RepaintBoundary(
              child: SizedBox(
                width: 400,
                height: 300,
                child: CustomPaint(painter: painter, size: const Size(400, 300)),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        await expectLater(
          find.byType(RepaintBoundary),
          matchesGoldenFile('goldens/topo_painter_route.png'),
        );
      },
    );
  });

  test('PictureRecorder smoke test: painting a full scene completes', () {
    // Belt-and-suspenders check using a real ui.PictureRecorder-backed
    // Canvas (in addition to the _RecordingCanvas-based tests above) to
    // confirm the painter also works against the genuine dart:ui Canvas
    // implementation, not just our fake.
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final painter = buildPainter(
      routes: const [
        [
          Offset(0.1, 0.1),
          Offset(0.4, 0.5),
          Offset(0.6, 0.3),
          Offset(0.9, 0.8),
        ],
      ],
      currentPoints: const [Offset(0.2, 0.2), Offset(0.8, 0.8)],
      showHandles: true,
    );

    expect(() => painter.paint(canvas, imageSize), returnsNormally);

    final picture = recorder.endRecording();
    expect(picture, isNotNull);
  });
}
