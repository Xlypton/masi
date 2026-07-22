import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:masi/features/ar/domain/homography.dart';
import 'package:masi/features/ar/presentation/ar_overlay_painter.dart';
import 'package:masi/features/topo/domain/topo_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A minimal fake [Canvas] that records the drawing calls
/// [ArOverlayPainter] actually makes (`drawCircle`, `drawLine`, `drawPath`,
/// and — when [ArOverlayPainter.outline] is set — `save`/`transform`/
/// `saveLayer`/`drawImageRect`/`restore`) without needing a mocking package.
/// [callOrder] records the sequence of method names invoked so tests can
/// assert ordering (e.g. the outline's `transform` happens before its
/// `drawImageRect`, which happens before any route polylines).
class _RecordingCanvas implements Canvas {
  final List<Offset> circleCenters = [];
  final List<Paint> circlePaints = [];
  final List<({Offset p1, Offset p2})> lines = [];
  final List<Paint> linePaints = [];
  final List<Path> paths = [];
  final List<Paint> pathPaints = [];
  final List<Float64List> transforms = [];
  final List<({Rect? bounds, Paint paint})> saveLayers = [];
  final List<({ui.Image image, Rect src, Rect dst, Paint paint})> imageRects = [];
  int saveCount = 0;
  int restoreCount = 0;
  final List<String> callOrder = [];

  @override
  void drawCircle(Offset c, double radius, Paint paint) {
    callOrder.add('drawCircle');
    circleCenters.add(c);
    circlePaints.add(paint);
  }

  @override
  void drawLine(Offset p1, Offset p2, Paint paint) {
    callOrder.add('drawLine');
    lines.add((p1: p1, p2: p2));
    linePaints.add(paint);
  }

  @override
  void drawPath(Path path, Paint paint) {
    callOrder.add('drawPath');
    paths.add(path);
    pathPaints.add(paint);
  }

  @override
  void save() {
    callOrder.add('save');
    saveCount++;
  }

  @override
  void restore() {
    callOrder.add('restore');
    restoreCount++;
  }

  @override
  void transform(Float64List matrix4) {
    callOrder.add('transform');
    transforms.add(matrix4);
  }

  @override
  void saveLayer(Rect? bounds, Paint paint) {
    callOrder.add('saveLayer');
    saveLayers.add((bounds: bounds, paint: paint));
  }

  @override
  void drawImageRect(ui.Image image, Rect src, Rect dst, Paint paint) {
    callOrder.add('drawImageRect');
    imageRects.add((image: image, src: src, dst: dst, paint: paint));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Decodes a tiny 2x2 RGBA image, for tests that need a real (non-null)
/// `ui.Image` to pass as [ArOverlayPainter.outline].
Future<ui.Image> _createTinyImage() {
  final completer = Completer<ui.Image>();
  final pixels = Uint8List.fromList(<int>[
    255, 0, 0, 255, //
    0, 255, 0, 255, //
    0, 0, 255, 255, //
    255, 255, 0, 255, //
  ]);
  ui.decodeImageFromPixels(
    pixels,
    2,
    2,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  return completer.future;
}

void main() {
  const refSize = Size(400, 300);
  const palette = [Color(0xFF2E7D32), Color(0xFF1565C0), Color(0xFF6A1B9A)];

  ArOverlayPainter buildPainter({
    List<TopoRoute> routes = const [],
    Size refSize = refSize,
    Homography? homography,
    List<Color> palette = palette,
    double confidence = 1.0,
    Color Function(TopoRoute)? routeColorResolver,
  }) {
    return ArOverlayPainter(
      routes: routes,
      refSize: refSize,
      homography: homography ?? Homography.identity(),
      palette: palette,
      confidence: confidence,
      routeColorResolver: routeColorResolver,
    );
  }

  group('A1: identity homography + refSize == canvas size', () {
    test(
      'warped screen points equal percent*refSize (same scene positions '
      'TopoPainter would use)',
      () {
        final route = TopoRoute(
          id: 1,
          number: 1,
          colorIndex: 0,
          points: const [
            Offset(0.1, 0.1),
            Offset(0.4, 0.5),
            Offset(0.6, 0.3),
            Offset(0.9, 0.8),
          ],
        );
        final homography = Homography.identity();

        // Directly assert on warpOriginalPercent, the exact mapping the
        // painter uses per-point.
        for (final p in route.points) {
          final warped = homography.warpOriginalPercent(p, refSize);
          expect(warped, Offset(p.dx * refSize.width, p.dy * refSize.height));
        }

        final painter = buildPainter(routes: [route], homography: homography);
        final canvas = _RecordingCanvas();
        painter.paint(canvas, refSize);

        expect(canvas.paths, hasLength(1));
        final metrics = canvas.paths.single.computeMetrics().toList();
        final start = metrics.first.getTangentForOffset(0)?.position;
        expect(start, isNotNull);
        // Path starts exactly at the first warped (== refSize-scaled
        // percent) point.
        expect((start! - const Offset(40, 30)).distance, lessThan(0.01));
      },
    );

    test('a 2-point route draws a straight line at the scaled percents', () {
      final route = TopoRoute(
        id: 1,
        number: 1,
        points: const [Offset(0.0, 0.0), Offset(1.0, 1.0)],
      );
      final painter = buildPainter(routes: [route]);
      final canvas = _RecordingCanvas();

      painter.paint(canvas, refSize);

      expect(canvas.lines, hasLength(1));
      expect(canvas.lines.single.p1, Offset.zero);
      expect(canvas.lines.single.p2, const Offset(400, 300));
    });

    test('a 1-point route draws a dot at the scaled percent', () {
      final route = TopoRoute(
        id: 1,
        number: 1,
        points: const [Offset(0.5, 0.5)],
      );
      final painter = buildPainter(routes: [route]);
      final canvas = _RecordingCanvas();

      painter.paint(canvas, refSize);

      expect(canvas.circleCenters, hasLength(1));
      expect(canvas.circleCenters.single, const Offset(200, 150));
    });
  });

  group('A2: translation homography', () {
    test('every drawn point is shifted by (dx, dy) vs identity', () {
      const dx = 25.0;
      const dy = -13.0;
      final route = TopoRoute(
        id: 1,
        number: 1,
        points: const [Offset(0.0, 0.0), Offset(1.0, 1.0)],
      );

      final identityCanvas = _RecordingCanvas();
      buildPainter(routes: [route], homography: Homography.identity()).paint(identityCanvas, refSize);

      final translatedCanvas = _RecordingCanvas();
      buildPainter(routes: [route], homography: Homography.translation(dx, dy)).paint(translatedCanvas, refSize);

      expect(identityCanvas.lines, hasLength(1));
      expect(translatedCanvas.lines, hasLength(1));

      final shiftP1 = translatedCanvas.lines.single.p1 - identityCanvas.lines.single.p1;
      final shiftP2 = translatedCanvas.lines.single.p2 - identityCanvas.lines.single.p2;

      expect(shiftP1, const Offset(dx, dy));
      expect(shiftP2, const Offset(dx, dy));
    });

    test(
      'warpOriginalPercent directly: two warped points differ by exactly '
      'the translation',
      () {
        const dx = 7.0;
        const dy = 11.0;
        final identity = Homography.identity();
        final translated = Homography.translation(dx, dy);
        const p = Offset(0.3, 0.6);

        final a = identity.warpOriginalPercent(p, refSize);
        final b = translated.warpOriginalPercent(p, refSize);

        expect(b - a, const Offset(dx, dy));
      },
    );
  });

  group('A3: low-confidence paint treatment', () {
    test(
      'confidence 0.2 (< kLowConfidenceThreshold) produces a visibly '
      'different (lower-alpha) stroke than confidence 1.0',
      () {
        final route = TopoRoute(
          id: 1,
          number: 1,
          colorIndex: 0,
          points: const [Offset(0.0, 0.0), Offset(1.0, 1.0)],
        );

        final highConfidenceCanvas = _RecordingCanvas();
        buildPainter(routes: [route], confidence: 1.0).paint(highConfidenceCanvas, refSize);

        final lowConfidenceCanvas = _RecordingCanvas();
        buildPainter(routes: [route], confidence: 0.2).paint(lowConfidenceCanvas, refSize);

        expect(highConfidenceCanvas.linePaints, hasLength(1));
        expect(lowConfidenceCanvas.linePaints, hasLength(1));

        final highAlpha = highConfidenceCanvas.linePaints.single.color.a;
        final lowAlpha = lowConfidenceCanvas.linePaints.single.color.a;

        expect(lowAlpha, lessThan(highAlpha));
        expect(
          lowConfidenceCanvas.linePaints.single.color.toARGB32(),
          isNot(highConfidenceCanvas.linePaints.single.color.toARGB32()),
        );
        // Pinned to the documented threshold/alpha so a regression that
        // silently changes the treatment is caught.
        expect(0.2, lessThan(kLowConfidenceThreshold));
        expect(
          lowConfidenceCanvas.linePaints.single.color.toARGB32(),
          palette[0].withAlpha(kLowConfidenceAlpha).toARGB32(),
        );
      },
    );

    test(
      'confidence exactly at kLowConfidenceThreshold is NOT low-confidence '
      '(boundary is a strict <)',
      () {
        final route = TopoRoute(
          id: 1,
          number: 1,
          colorIndex: 0,
          points: const [Offset(0.0, 0.0), Offset(1.0, 1.0)],
        );

        final atThresholdCanvas = _RecordingCanvas();
        buildPainter(routes: [route], confidence: kLowConfidenceThreshold).paint(atThresholdCanvas, refSize);

        expect(
          atThresholdCanvas.linePaints.single.color.toARGB32(),
          palette[0].toARGB32(),
        );
      },
    );
  });

  group('outline (ghost reference image)', () {
    test('outline: null (default) draws no image; existing behavior unaffected', () {
      final route = TopoRoute(
        id: 1,
        number: 1,
        points: const [Offset(0.0, 0.0), Offset(1.0, 1.0)],
      );
      final painter = buildPainter(routes: [route]); // outline defaults to null.
      final canvas = _RecordingCanvas();

      painter.paint(canvas, refSize);

      expect(canvas.imageRects, isEmpty);
      expect(canvas.transforms, isEmpty);
      expect(canvas.saveLayers, isEmpty);
      // Existing polyline behavior is unaffected by the absent outline.
      expect(canvas.lines, hasLength(1));
      expect(canvas.lines.single.p1, Offset.zero);
      expect(canvas.lines.single.p2, const Offset(400, 300));
    });

    test(
      'outline: non-null draws the image transformed by homography, before '
      'route polylines',
      () async {
        final image = await _createTinyImage();
        final homography = Homography.translation(20, 10);
        final route = TopoRoute(
          id: 1,
          number: 1,
          points: const [Offset(0.0, 0.0), Offset(1.0, 1.0)],
        );

        final painter = ArOverlayPainter(
          routes: [route],
          refSize: refSize,
          homography: homography,
          palette: palette,
          outline: image,
        );
        final canvas = _RecordingCanvas();

        painter.paint(canvas, refSize);

        expect(canvas.imageRects, hasLength(1));
        final rec = canvas.imageRects.single;
        expect(rec.image, same(image));
        expect(rec.src, Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()));
        expect(rec.dst, Rect.fromLTWH(0, 0, refSize.width, refSize.height));
        // The hard binary edge image is scaled up into `dst`; without
        // high-quality filtering that upscale looks jagged/aliased on
        // device, so the outline paint must opt into bilinear filtering.
        expect(rec.paint.filterQuality, FilterQuality.high);
        expect(rec.paint.isAntiAlias, isTrue);

        expect(canvas.transforms, hasLength(1));
        final expected = homography.toMatrix4ColumnMajor();
        final actual = canvas.transforms.single;
        expect(actual.length, 16);
        for (var i = 0; i < 16; i++) {
          expect(actual[i], closeTo(expected[i], 1e-9));
        }

        // Ordering: transform -> saveLayer -> drawImageRect -> (restore,
        // restore) -> route polyline drawing, so the outline renders as a
        // ghost *behind* the routes.
        final transformIndex = canvas.callOrder.indexOf('transform');
        final imageIndex = canvas.callOrder.indexOf('drawImageRect');
        final lineIndex = canvas.callOrder.indexOf('drawLine');
        expect(transformIndex, lessThan(imageIndex));
        expect(imageIndex, lessThan(lineIndex));

        expect(canvas.saveCount, 1);
        expect(canvas.restoreCount, 2); // one for saveLayer, one for save/transform.
      },
    );
  });

  group('A5: shouldRepaint', () {
    test('returns false when everything is identical', () {
      final routes = [
        TopoRoute(id: 1, number: 1, points: const [Offset(0.1, 0.1), Offset(0.2, 0.2)]),
      ];
      final a = buildPainter(routes: routes);
      final b = buildPainter(routes: routes);

      expect(a.shouldRepaint(b), isFalse);
    });

    test('returns true when routes differ', () {
      final a = buildPainter(
        routes: [TopoRoute(id: 1, number: 1, points: const [Offset(0.1, 0.1), Offset(0.2, 0.2)])],
      );
      final b = buildPainter(routes: const []);

      expect(a.shouldRepaint(b), isTrue);
    });

    test('returns true when homography differs', () {
      final a = buildPainter(homography: Homography.identity());
      final b = buildPainter(homography: Homography.translation(1, 1));

      expect(a.shouldRepaint(b), isTrue);
    });

    test('returns true when confidence differs', () {
      final a = buildPainter(confidence: 1.0);
      final b = buildPainter(confidence: 0.2);

      expect(a.shouldRepaint(b), isTrue);
    });

    test('returns true when refSize differs', () {
      final a = buildPainter(refSize: const Size(400, 300));
      final b = buildPainter(refSize: const Size(800, 600));

      expect(a.shouldRepaint(b), isTrue);
    });

    test('returns true when palette differs', () {
      final a = buildPainter(palette: const [Colors.red, Colors.blue]);
      final b = buildPainter(palette: const [Colors.green, Colors.blue]);

      expect(a.shouldRepaint(b), isTrue);
    });

    test(
      'returns true when routeColorResolver differs (one null, one '
      'non-null); returns false when both share the identical resolver '
      'reference',
      () {
        Color resolver(TopoRoute route) => Colors.red;

        final withoutResolver = buildPainter();
        final withResolver = buildPainter(routeColorResolver: resolver);

        expect(withoutResolver.shouldRepaint(withResolver), isTrue);
        expect(withResolver.shouldRepaint(withoutResolver), isTrue);

        final sameResolverReference = buildPainter(routeColorResolver: resolver);
        expect(withResolver.shouldRepaint(sameResolverReference), isFalse);
      },
    );

    test(
      'returns true when outline differs (one null, one non-null); '
      'returns false when both share the identical outline reference',
      () async {
        final image = await _createTinyImage();

        final withoutOutline = buildPainter();
        final withOutline = ArOverlayPainter(
          routes: const [],
          refSize: refSize,
          homography: Homography.identity(),
          palette: palette,
          outline: image,
        );

        expect(withoutOutline.shouldRepaint(withOutline), isTrue);
        expect(withOutline.shouldRepaint(withoutOutline), isTrue);

        final sameOutlineReference = ArOverlayPainter(
          routes: const [],
          refSize: refSize,
          homography: Homography.identity(),
          palette: palette,
          outline: image,
        );
        expect(withOutline.shouldRepaint(sameOutlineReference), isFalse);
      },
    );
  });

  group('A6: defensive empty/invisible', () {
    test('an empty routes list draws nothing and does not crash', () {
      final painter = buildPainter(routes: const []);
      final canvas = _RecordingCanvas();

      expect(() => painter.paint(canvas, refSize), returnsNormally);

      expect(canvas.circleCenters, isEmpty);
      expect(canvas.lines, isEmpty);
      expect(canvas.paths, isEmpty);
    });

    test('an invisible route draws nothing and does not crash', () {
      final route = TopoRoute(
        id: 1,
        number: 1,
        visible: false,
        points: const [
          Offset(0.1, 0.1),
          Offset(0.4, 0.5),
          Offset(0.9, 0.8),
        ],
      );
      final painter = buildPainter(routes: [route]);
      final canvas = _RecordingCanvas();

      expect(() => painter.paint(canvas, refSize), returnsNormally);

      expect(canvas.circleCenters, isEmpty);
      expect(canvas.lines, isEmpty);
      expect(canvas.paths, isEmpty);
    });

    test('PictureRecorder smoke test against a real dart:ui Canvas', () {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      final painter = buildPainter(
        routes: [
          TopoRoute(
            id: 1,
            number: 1,
            colorIndex: 0,
            points: const [
              Offset(0.1, 0.1),
              Offset(0.4, 0.5),
              Offset(0.6, 0.3),
              Offset(0.9, 0.8),
            ],
          ),
        ],
        homography: Homography.translation(20, 10),
      );

      expect(() => painter.paint(canvas, refSize), returnsNormally);

      final picture = recorder.endRecording();
      expect(picture, isNotNull);
    });
  });

  group('empty palette defensive', () {
    test('painting a route with an empty palette does not throw', () {
      final route = TopoRoute(
        id: 1,
        number: 1,
        colorIndex: 0,
        points: const [Offset(0.1, 0.1), Offset(0.4, 0.5), Offset(0.9, 0.8)],
      );
      final painter = buildPainter(routes: [route], palette: const []);
      final canvas = _RecordingCanvas();

      expect(() => painter.paint(canvas, refSize), returnsNormally);
    });
  });

  group('A4: golden', () {
    testWidgets(
      'a route under a fixed non-identity homography renders a stable '
      'golden image',
      (tester) async {
        // Pin the device pixel ratio *and* physical size so the checked-in
        // golden PNG's dimensions (and pixel content) are deterministic
        // across machines, mirroring TopoPainter's golden test setup.
        tester.view.physicalSize = const Size(400, 300);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        // translation(20, 10) composed with a mild scale (1.1x), applied as
        // scale-then-translate (this * other == apply-other-first): scale
        // by 1.1 about the origin, then shift by (20, 10).
        final scale = Homography.fromRowMajor(const [
          1.1, 0, 0, //
          0, 1.1, 0, //
          0, 0, 1, //
        ]);
        final homography = Homography.translation(20, 10).multiply(scale);

        final route = TopoRoute(
          id: 1,
          number: 1,
          colorIndex: 0,
          points: const [
            Offset(0.1, 0.1),
            Offset(0.4, 0.5),
            Offset(0.6, 0.3),
            Offset(0.9, 0.8),
          ],
        );

        final painter = ArOverlayPainter(
          routes: [route],
          refSize: const Size(400, 300),
          homography: homography,
          palette: palette,
          confidence: 1.0,
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
          matchesGoldenFile('goldens/ar_overlay_painter_route.png'),
        );
      },
    );
  });
}
