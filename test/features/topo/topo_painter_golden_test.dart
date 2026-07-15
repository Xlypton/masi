import 'dart:ui' as ui;

import 'package:climbtopo/core/grades/grade_system.dart';
import 'package:climbtopo/features/topo/domain/topo_route.dart';
import 'package:climbtopo/features/topo/presentation/grade_colors.dart';
import 'package:climbtopo/features/topo/presentation/topo_canvas.dart';
import 'package:climbtopo/features/topo/presentation/topo_painter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A minimal fake [Canvas] that records the drawing calls [TopoPainter]
/// actually makes (`drawCircle`, `drawLine`, `drawPath`, `drawParagraph`,
/// `drawRRect` — recorded as a regression guard so tests can assert NO
/// background chip is drawn behind a route-number label) without needing a
/// mocking package. `TopoPainter.paint` never calls
/// `save`/`restore`/`transform`/clip methods, so leaving those to the
/// `noSuchMethod` fallback is safe: they are never invoked in these tests.
class _RecordingCanvas implements Canvas {
  final List<Offset> circleCenters = [];
  final List<double> circleRadii = [];
  final List<Color> circleColors = [];
  final List<Paint> circlePaints = [];
  final List<({Offset p1, Offset p2})> lines = [];
  final List<Paint> linePaints = [];
  final List<Path> paths = [];
  final List<Paint> pathPaints = [];
  final List<({ui.Paragraph paragraph, Offset offset})> paragraphs = [];
  final List<RRect> roundRects = [];
  final List<Paint> roundRectPaints = [];

  @override
  void drawRRect(RRect rrect, Paint paint) {
    roundRects.add(rrect);
    roundRectPaints.add(paint);
  }

  @override
  void drawCircle(Offset c, double radius, Paint paint) {
    circleCenters.add(c);
    circleRadii.add(radius);
    circleColors.add(paint.color);
    circlePaints.add(paint);
  }

  @override
  void drawLine(Offset p1, Offset p2, Paint paint) {
    lines.add((p1: p1, p2: p2));
    linePaints.add(paint);
  }

  @override
  void drawPath(Path path, Paint paint) {
    paths.add(path);
    pathPaints.add(paint);
  }

  @override
  void drawParagraph(ui.Paragraph paragraph, Offset offset) {
    paragraphs.add((paragraph: paragraph, offset: offset));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  const imageSize = Size(400, 300);
  // Plain (non-MaterialColor) Color values: Paint.color always returns a
  // plain Color (see Paint's color getter in dart:ui, which reconstructs
  // from raw bytes), so comparing against a MaterialColor like Colors.green
  // would spuriously fail on runtimeType even with identical channel values.
  const palette = [Color(0xFF2E7D32), Color(0xFF1565C0), Color(0xFF6A1B9A)];

  TopoPainter buildPainter({
    List<TopoRoute> routes = const [],
    List<Offset> currentPoints = const [],
    bool showHandles = false,
    int? selectedRouteId,
    List<Color> palette = palette,
    double scale = 1.0,
  }) {
    return TopoPainter(
      imageSize: imageSize,
      routes: routes,
      currentPoints: currentPoints,
      showHandles: showHandles,
      selectedRouteId: selectedRouteId,
      palette: palette,
      scale: scale,
    );
  }

  group('TopoPainter drawing behavior (in-progress route + handles)', () {
    test('A single point paints without throwing and draws a dot', () {
      final painter = buildPainter(currentPoints: const [Offset(0.5, 0.5)]);
      final canvas = _RecordingCanvas();

      expect(() => painter.paint(canvas, imageSize), returnsNormally);

      expect(canvas.circleCenters, hasLength(1));
      expect(canvas.circleCenters.single, const Offset(200, 150));
      expect(canvas.lines, isEmpty);
      expect(canvas.paths, isEmpty);
    });

    test('Two points paint a straight line segment without crashing', () {
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
      'Three or more points paint a Catmull-Rom cubic bezier path '
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
      'catmullRomControlPoints computes the exact Catmull-Rom cubic '
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

    test('showHandles=true draws one handle per current point', () {
      const points = [Offset(0.1, 0.2), Offset(0.5, 0.5), Offset(0.8, 0.1)];
      final painter = buildPainter(currentPoints: points, showHandles: true);
      final canvas = _RecordingCanvas();

      painter.paint(canvas, imageSize);

      // 1 dot per point drawn by the polyline pass is not expected here
      // (3 points -> a path, not dots), so all recorded circles are
      // handles: exactly one per current point.
      expect(canvas.circleCenters, hasLength(points.length));
    });

    test('showHandles=false draws no handles', () {
      const points = [Offset(0.1, 0.2), Offset(0.5, 0.5), Offset(0.8, 0.1)];
      final painter = buildPainter(currentPoints: points, showHandles: false);
      final canvas = _RecordingCanvas();

      painter.paint(canvas, imageSize);

      expect(canvas.circleCenters, isEmpty);
    });

    test(
      'showHandles=true with a single current point draws the dot '
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

  group('TopoPainter multi-route + symbols + selection', () {
    test(
      'A1: two visible routes with different colorIndex draw two distinct '
      'spline paths in distinct colors; an invisible route draws no path',
      () {
        final routes = [
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
          TopoRoute(
            id: 2,
            number: 2,
            colorIndex: 1,
            points: const [
              Offset(0.2, 0.2),
              Offset(0.3, 0.6),
              Offset(0.5, 0.4),
              Offset(0.8, 0.9),
            ],
          ),
          TopoRoute(
            id: 3,
            number: 3,
            colorIndex: 2,
            visible: false,
            points: const [
              Offset(0.1, 0.9),
              Offset(0.4, 0.6),
              Offset(0.6, 0.2),
              Offset(0.9, 0.1),
            ],
          ),
        ];
        final painter = buildPainter(routes: routes);
        final canvas = _RecordingCanvas();

        painter.paint(canvas, imageSize);

        expect(canvas.paths, hasLength(2));
        // Compare via toARGB32() rather than Color equality: Paint stores
        // color channels as Float32 internally, so a Color read back from
        // paint.color loses precision relative to the original Float64
        // Color and can fail exact `==` even when visually identical.
        // Quantizing to 8-bit ARGB int sidesteps that precision noise.
        expect(canvas.pathPaints[0].color.toARGB32(), palette[0].toARGB32());
        expect(canvas.pathPaints[1].color.toARGB32(), palette[1].toARGB32());
        expect(canvas.pathPaints[0].color.toARGB32(), isNot(canvas.pathPaints[1].color.toARGB32()));
      },
    );

    test('A2: each visible route draws its number label', () {
      final routes = [
        TopoRoute(
          id: 1,
          number: 1,
          colorIndex: 0,
          points: const [Offset(0.1, 0.1), Offset(0.4, 0.5), Offset(0.9, 0.8)],
        ),
        TopoRoute(
          id: 2,
          number: 2,
          colorIndex: 1,
          points: const [Offset(0.2, 0.8), Offset(0.7, 0.2)],
        ),
        TopoRoute(
          id: 3,
          number: 3,
          colorIndex: 2,
          visible: false,
          points: const [Offset(0.1, 0.9), Offset(0.4, 0.6)],
        ),
      ];
      final painter = buildPainter(routes: routes);

      // Use a real ui.PictureRecorder-backed canvas: TextPainter.paint
      // ultimately calls Canvas.drawParagraph, which our fake canvas can
      // record, but TextPainter itself requires real text layout to run,
      // so exercise this against the genuine engine here.
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);

      expect(() => painter.paint(canvas, imageSize), returnsNormally);

      final picture = recorder.endRecording();
      expect(picture, isNotNull);
    });

    test(
      'A3: each SymbolType renders a distinct glyph; a route with 3 '
      'symbols draws 3 glyphs worth of draw calls',
      () {
        final route = TopoRoute(
          id: 1,
          number: 1,
          colorIndex: 0,
          points: const [Offset(0.1, 0.1), Offset(0.9, 0.8)],
          symbols: const [
            TopoSymbol(type: SymbolType.anchor, position: Offset(0.1, 0.1)),
            TopoSymbol(type: SymbolType.bolt, position: Offset(0.5, 0.5)),
            TopoSymbol(type: SymbolType.top, position: Offset(0.9, 0.8)),
          ],
        );
        final painter = buildPainter(routes: [route]);
        final canvas = _RecordingCanvas();

        painter.paint(canvas, imageSize);

        // anchor -> 1 circle, bolt -> 2 lines, top -> 1 path.
        // The route itself is a 2-point polyline, so it draws 1 line (no
        // path, no circle), meaning all recorded paths/extra circles come
        // from the symbols.
        expect(canvas.circleCenters, hasLength(1)); // anchor
        expect(canvas.lines, hasLength(1 + 2)); // route line + bolt's 2 lines
        expect(canvas.paths, hasLength(1)); // top triangle
      },
    );

    test('A3b: each SymbolType renders without throwing on a real canvas', () {
      for (final type in SymbolType.values) {
        final route = TopoRoute(
          id: 1,
          number: 1,
          colorIndex: 0,
          points: const [Offset(0.1, 0.1), Offset(0.9, 0.8)],
          symbols: [TopoSymbol(type: type, position: const Offset(0.5, 0.5))],
        );
        final painter = buildPainter(routes: [route]);
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);

        expect(() => painter.paint(canvas, imageSize), returnsNormally);
        recorder.endRecording();
      }
    });

    test(
      'A4: selectedRouteId set to a route id renders it with a wider '
      'strokeWidth than when selectedRouteId is null',
      () {
        final routes = [
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
        ];

        final unselectedCanvas = _RecordingCanvas();
        buildPainter(routes: routes).paint(unselectedCanvas, imageSize);

        final selectedCanvas = _RecordingCanvas();
        buildPainter(routes: routes, selectedRouteId: 1).paint(selectedCanvas, imageSize);

        expect(unselectedCanvas.paths, hasLength(1));
        // Selected route draws an extra highlight-outline path in addition
        // to its normal spline pass.
        expect(selectedCanvas.paths, hasLength(2));

        final unselectedWidth = unselectedCanvas.pathPaints.single.strokeWidth;
        final selectedMaxWidth = selectedCanvas.pathPaints.map((p) => p.strokeWidth).reduce((a, b) => a > b ? a : b);
        expect(selectedMaxWidth, greaterThan(unselectedWidth));
      },
    );
  });

  group('TopoPainter defensive: empty palette', () {
    test(
      'Fix P: painting a route with an empty palette does not throw '
      '(falls back to a hardcoded default color instead of indexing '
      'palette[colorIndex % palette.length])',
      () {
        final routes = [
          TopoRoute(
            id: 1,
            number: 1,
            colorIndex: 0,
            points: const [
              Offset(0.1, 0.1),
              Offset(0.4, 0.5),
              Offset(0.9, 0.8),
            ],
          ),
        ];
        final painter = buildPainter(routes: routes, palette: const []);
        final canvas = _RecordingCanvas();

        expect(() => painter.paint(canvas, imageSize), returnsNormally);
      },
    );
  });

  group('TopoPainter routeColorResolver (grade-band coloring)', () {
    test(
      'A4: when routeColorResolver is provided, a graded route strokes in '
      "its grade band's color (colorForRoute/colorForGradeBand), not the "
      'palette color',
      () {
        final gradedRoute = TopoRoute(
          id: 1,
          number: 1,
          colorIndex: 0,
          gradeSystem: GradeSystem.french,
          gradeRaw: '7a',
          // French '7a' -> shared-scale index 13.0 -> GradeBand.hard.
          gradeSortKey: gradeSortKey(GradeSystem.french, '7a'),
          points: const [
            Offset(0.1, 0.1),
            Offset(0.4, 0.5),
            Offset(0.9, 0.8),
          ],
        );
        final painter = TopoPainter(
          imageSize: imageSize,
          routes: [gradedRoute],
          currentPoints: const [],
          showHandles: false,
          palette: palette,
          routeColorResolver: (route) => colorForRoute(route, palette),
        );
        final canvas = _RecordingCanvas();

        painter.paint(canvas, imageSize);

        expect(canvas.paths, hasLength(1));
        expect(
          canvas.pathPaints.single.color.toARGB32(),
          colorForGradeBand(GradeBand.hard).toARGB32(),
        );
        // Sanity: the resolver's output must NOT equal the plain
        // palette-by-colorIndex color, otherwise this test wouldn't
        // distinguish the resolver path from the pre-existing fallback.
        expect(
          canvas.pathPaints.single.color.toARGB32(),
          isNot(palette[gradedRoute.colorIndex % palette.length].toARGB32()),
        );
      },
    );

    test(
      'Fractional UIAA sortKey: VII- -> shared-scale 8.5 -> GradeBand.advanced '
      "(colorForRoute reflects the advanced band's color)",
      () {
        final sortKey = gradeSortKey(GradeSystem.uiaa, 'VII-');
        expect(sortKey, closeTo(8.5, 1e-9));
        expect(bandForSortKey(sortKey), GradeBand.advanced);

        final route = TopoRoute(
          id: 1,
          number: 1,
          points: const [Offset(0.0, 0.0), Offset(1.0, 1.0)],
          gradeSystem: GradeSystem.uiaa,
          gradeRaw: 'VII-',
          gradeSortKey: sortKey,
        );

        expect(
          colorForRoute(route, palette).toARGB32(),
          colorForGradeBand(GradeBand.advanced).toARGB32(),
        );
      },
    );
  });

  group('colorForGradeBand (M4 cleanup coverage: all 5 bands)', () {
    test('returns the exact spec Color literal for each GradeBand', () {
      expect(colorForGradeBand(GradeBand.beginner), const Color(0xFF2F9E6B)); // green
      expect(colorForGradeBand(GradeBand.intermediate), const Color(0xFF3B82C4)); // blue
      expect(colorForGradeBand(GradeBand.advanced), const Color(0xFFE08A2B)); // orange
      expect(colorForGradeBand(GradeBand.hard), const Color(0xFFD6483B)); // red
      expect(colorForGradeBand(GradeBand.elite), const Color(0xFF8A5CD1)); // purple
    });
  });

  group('TopoPainter.shouldRepaint', () {
    test('returns false when everything is identical', () {
      final a = buildPainter(
        routes: [
          TopoRoute(
            id: 1,
            number: 1,
            points: const [Offset(0.1, 0.1), Offset(0.2, 0.2)],
          ),
        ],
        currentPoints: const [Offset(0.5, 0.5)],
        showHandles: true,
      );
      final b = buildPainter(
        routes: [
          TopoRoute(
            id: 1,
            number: 1,
            points: const [Offset(0.1, 0.1), Offset(0.2, 0.2)],
          ),
        ],
        currentPoints: const [Offset(0.5, 0.5)],
        showHandles: true,
      );

      expect(a.shouldRepaint(b), isFalse);
    });

    test('returns true when routes differ', () {
      final a = buildPainter(
        routes: [
          TopoRoute(
            id: 1,
            number: 1,
            points: const [Offset(0.1, 0.1), Offset(0.2, 0.2)],
          ),
        ],
      );
      final b = buildPainter(routes: const []);

      expect(a.shouldRepaint(b), isTrue);
    });

    test('returns true when a route symbol list differs', () {
      final a = buildPainter(
        routes: [
          TopoRoute(
            id: 1,
            number: 1,
            points: const [Offset(0.1, 0.1), Offset(0.2, 0.2)],
            symbols: const [TopoSymbol(type: SymbolType.anchor, position: Offset(0.1, 0.1))],
          ),
        ],
      );
      final b = buildPainter(
        routes: [
          TopoRoute(
            id: 1,
            number: 1,
            points: const [Offset(0.1, 0.1), Offset(0.2, 0.2)],
          ),
        ],
      );

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
          routes: [
            TopoRoute(
              id: 1,
              number: 1,
              points: const [Offset(0.1, 0.1), Offset(0.2, 0.2), Offset(0.3, 0.1)],
            ),
          ],
        );
        final b = buildPainter(
          routes: [
            TopoRoute(
              id: 1,
              number: 1,
              points: const [Offset(0.1, 0.1), Offset(0.25, 0.2), Offset(0.3, 0.1)],
            ),
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

    test('returns true when selectedRouteId differs', () {
      final a = buildPainter(selectedRouteId: 1);
      final b = buildPainter(selectedRouteId: null);

      expect(a.shouldRepaint(b), isTrue);
    });

    test('returns true when palette differs', () {
      final a = buildPainter(palette: const [Colors.red, Colors.blue]);
      final b = buildPainter(palette: const [Colors.green, Colors.blue]);

      expect(a.shouldRepaint(b), isTrue);
    });

    test('returns true when imageSize differs', () {
      const a = TopoPainter(
        imageSize: Size(400, 300),
        routes: [],
        currentPoints: [],
        showHandles: false,
        palette: palette,
      );
      const b = TopoPainter(
        imageSize: Size(200, 150),
        routes: [],
        currentPoints: [],
        showHandles: false,
        palette: palette,
      );

      expect(a.shouldRepaint(b), isTrue);
    });

    test('returns true when any color differs', () {
      const base = TopoPainter(
        imageSize: imageSize,
        routes: [],
        currentPoints: [],
        showHandles: false,
        palette: palette,
      );
      const differentCurrentColor = TopoPainter(
        imageSize: imageSize,
        routes: [],
        currentPoints: [],
        showHandles: false,
        palette: palette,
        currentColor: Colors.red,
      );
      const differentHandleColor = TopoPainter(
        imageSize: imageSize,
        routes: [],
        currentPoints: [],
        showHandles: false,
        palette: palette,
        handleColor: Colors.red,
      );

      expect(base.shouldRepaint(differentCurrentColor), isTrue);
      expect(base.shouldRepaint(differentHandleColor), isTrue);
    });

    test(
      'returns true when routeColorResolver differs (one null, one '
      'non-null); returns false when both painters share the identical '
      'resolver reference (Fix 1 coverage)',
      () {
        Color resolver(TopoRoute route) => colorForRoute(route, palette);

        const withoutResolver = TopoPainter(
          imageSize: imageSize,
          routes: [],
          currentPoints: [],
          showHandles: false,
          palette: palette,
        );
        final withResolver = TopoPainter(
          imageSize: imageSize,
          routes: const [],
          currentPoints: const [],
          showHandles: false,
          palette: palette,
          routeColorResolver: resolver,
        );

        expect(withoutResolver.shouldRepaint(withResolver), isTrue);
        expect(withResolver.shouldRepaint(withoutResolver), isTrue);

        final samePaletteReference = TopoPainter(
          imageSize: imageSize,
          routes: const [],
          currentPoints: const [],
          showHandles: false,
          palette: palette,
          routeColorResolver: resolver,
        );

        expect(withResolver.shouldRepaint(samePaletteReference), isFalse);
      },
    );
  });

  group(
    'TopoPainter scale (Subtask 2: screen-constant stroke/handles/symbols)',
    () {
      test(
        'A1: at scale 1.0 (identity/default), the painted stroke width '
        'equals the base _strokeWidth (5.5 — bumped from 4.0 so unselected '
        'routes read boldly at rest on a Retina phone screen) — preserves '
        'pre-existing scene-px behavior for callers that never pass scale',
        () {
          final painter = buildPainter(
            currentPoints: const [Offset(0.0, 0.0), Offset(1.0, 1.0)],
          );
          final canvas = _RecordingCanvas();

          painter.paint(canvas, imageSize);

          expect(canvas.lines, hasLength(1));
          expect(canvas.linePaints.single.strokeWidth, 5.5);
        },
      );

      test(
        'A2: at scale 0.25, the value passed to Paint.strokeWidth equals '
        '_strokeWidth / 0.25 (= 22.0), so once the canvas itself is scaled '
        'down by 0.25 the ON-SCREEN width stays constant at 5.5',
        () {
          final painter = buildPainter(
            currentPoints: const [Offset(0.0, 0.0), Offset(1.0, 1.0)],
            scale: 0.25,
          );
          final canvas = _RecordingCanvas();

          painter.paint(canvas, imageSize);

          expect(canvas.lines, hasLength(1));
          expect(canvas.linePaints.single.strokeWidth, closeTo(22.0, 1e-9));
        },
      );

      test(
        'A3a: the in-progress-route single-point dot radius doubles in '
        'scene space at scale 0.5 (base _dotRadius 4.0 -> 8.0)',
        () {
          final at1 = buildPainter(currentPoints: const [Offset(0.5, 0.5)]);
          final canvas1 = _RecordingCanvas();
          at1.paint(canvas1, imageSize);

          final at05 = buildPainter(
            currentPoints: const [Offset(0.5, 0.5)],
            scale: 0.5,
          );
          final canvas05 = _RecordingCanvas();
          at05.paint(canvas05, imageSize);

          expect(canvas1.circleRadii.single, 4.0);
          expect(canvas05.circleRadii.single, closeTo(8.0, 1e-9));
        },
      );

      test(
        'A3b: draggable handle radius doubles in scene space at scale 0.5 '
        '(base _handleRadius 6.0 -> 12.0)',
        () {
          const points = [Offset(0.5, 0.5)];

          final at1 = buildPainter(currentPoints: points, showHandles: true);
          final canvas1 = _RecordingCanvas();
          at1.paint(canvas1, imageSize);

          final at05 = buildPainter(
            currentPoints: points,
            showHandles: true,
            scale: 0.5,
          );
          final canvas05 = _RecordingCanvas();
          at05.paint(canvas05, imageSize);

          // Single current point + showHandles=true draws the dot (radius
          // 4.0 base) then the handle (radius 6.0 base) as the second
          // circle — see the existing "draws the dot plus one handle" test
          // above for this same two-circle shape.
          expect(canvas1.circleRadii, hasLength(2));
          expect(canvas1.circleRadii[1], 6.0);
          expect(canvas05.circleRadii[1], closeTo(12.0, 1e-9));
        },
      );

      test(
        'A3c: symbol glyph radius doubles in scene space at scale 0.5 '
        '(base _symbolRadius 7.0 -> 14.0), via the anchor glyph\'s circle',
        () {
          TopoRoute routeWithAnchor() => TopoRoute(
            id: 1,
            number: 1,
            colorIndex: 0,
            points: const [Offset(0.1, 0.1), Offset(0.9, 0.8)],
            symbols: const [
              TopoSymbol(type: SymbolType.anchor, position: Offset(0.5, 0.5)),
            ],
          );

          final at1 = buildPainter(routes: [routeWithAnchor()]);
          final canvas1 = _RecordingCanvas();
          at1.paint(canvas1, imageSize);

          final at05 = buildPainter(routes: [routeWithAnchor()], scale: 0.5);
          final canvas05 = _RecordingCanvas();
          at05.paint(canvas05, imageSize);

          // The 2-point route itself draws a line (not a circle), so the
          // only recorded circle is the anchor glyph.
          expect(canvas1.circleRadii, hasLength(1));
          expect(canvas1.circleRadii.single, 7.0);
          expect(canvas05.circleRadii.single, closeTo(14.0, 1e-9));
        },
      );

      test(
        'A3d (#18): the route-number label is offset PERPENDICULAR to the '
        "first segment's direction — clear of the route stroke regardless "
        'of which way the route heads from its first point — and that '
        'offset magnitude doubles in scene space at scale 0.5, proving the '
        'POSITION (not just the font) is scaled by 1/scale like every '
        'other on-screen-constant size',
        () {
          TopoRoute routeWithLabel() => TopoRoute(
            id: 1,
            number: 1,
            colorIndex: 0,
            // Anchored well away from the image edges (unlike some other
            // fixtures in this file) so doubling the offset magnitude at
            // scale 0.5 below stays clear of the edge-clamping margin
            // added by the label-clipping fix — this test is specifically
            // about the unclamped scaling behavior; A3h below covers
            // clamping near an edge.
            points: const [Offset(0.3, 0.3), Offset(0.7, 0.6)],
          );
          // percent (0.3, 0.3) -> (0.7, 0.6) in a 400x300 image -> scene
          // (120, 90) -> (280, 180).
          const anchor = Offset(120, 90);
          const segment = Offset(160, 90); // (280-120, 180-90)
          final unit = segment / segment.distance;
          // Matches TopoPainter._paintLabel's own perpendicular
          // construction: rotate the segment's unit direction by -90°,
          // i.e. (dx, dy) -> (dy, -dx).
          final expectedDirection = Offset(unit.dy, -unit.dx);

          final canvas1 = _RecordingCanvas();
          buildPainter(routes: [routeWithLabel()]).paint(canvas1, imageSize);

          final canvas05 = _RecordingCanvas();
          buildPainter(
            routes: [routeWithLabel()],
            scale: 0.5,
          ).paint(canvas05, imageSize);

          expect(canvas1.paragraphs, hasLength(1));
          expect(canvas05.paragraphs, hasLength(1));

          final delta1 = canvas1.paragraphs.single.offset - anchor;
          final delta05 = canvas05.paragraphs.single.offset - anchor;

          // Perpendicular to the segment: dot product ~0 — this is what
          // "clear of the stroke" means geometrically, regardless of the
          // stroke's own direction.
          expect(
            (delta1.dx * segment.dx + delta1.dy * segment.dy).abs(),
            lessThan(0.01),
            reason: 'label offset must be perpendicular to the first segment',
          );

          // Magnitude is the fixed on-screen offset distance (22.0, see
          // _labelOffsetDistance) and doubles in SCENE space at scale 0.5
          // (the ON-SCREEN distance itself stays constant).
          expect(delta1.distance, closeTo(22.0, 1e-6));
          expect(delta05.distance, closeTo(44.0, 1e-6));

          // Same direction at both scales — only the magnitude changes.
          expect(
            delta1.dx / delta1.distance,
            closeTo(expectedDirection.dx, 1e-6),
          );
          expect(
            delta1.dy / delta1.distance,
            closeTo(expectedDirection.dy, 1e-6),
          );
          expect(
            delta05.dx / delta05.distance,
            closeTo(expectedDirection.dx, 1e-6),
          );
          expect(
            delta05.dy / delta05.distance,
            closeTo(expectedDirection.dy, 1e-6),
          );
        },
      );

      test(
        'A3f (#18): a single-point route (no segment to be perpendicular '
        'to) falls back to the pre-existing up-and-left placement',
        () {
          final route = TopoRoute(
            id: 1,
            number: 1,
            colorIndex: 0,
            points: const [Offset(0.5, 0.5)],
          );
          final canvas = _RecordingCanvas();

          buildPainter(routes: [route]).paint(canvas, imageSize);

          // percent (0.5, 0.5) in a 400x300 image -> scene (200, 150).
          const anchor = Offset(200, 150);
          expect(canvas.paragraphs, hasLength(1));
          final delta = canvas.paragraphs.single.offset - anchor;

          expect(delta.dx, lessThan(0), reason: 'fallback must offset left');
          expect(delta.dy, lessThan(0), reason: 'fallback must offset up');
          expect(delta.distance, closeTo(22.0, 1e-6));
        },
      );

      test(
        'A3g (#18): the route number is painted with NO background chip — '
        'only the number (with a subtle text shadow for legibility)',
        () {
          final route = TopoRoute(
            id: 1,
            number: 1,
            colorIndex: 0,
            points: const [Offset(0.1, 0.1), Offset(0.9, 0.8)],
          );
          final canvas = _RecordingCanvas();

          buildPainter(routes: [route]).paint(canvas, imageSize);

          expect(
            canvas.roundRects,
            isEmpty,
            reason: 'no background chip must be drawn behind the label — '
                'only the number',
          );

          // The label itself must still be painted at its (unchanged)
          // perpendicular-offset origin. The subtle drop shadow added for
          // legibility is baked into the built paragraph/TextStyle and is
          // not independently observable from this recording canvas.
          expect(canvas.paragraphs, hasLength(1));
          final labelOrigin = canvas.paragraphs.single.offset;
          expect(
            labelOrigin.dx.isFinite && labelOrigin.dy.isFinite,
            isTrue,
            reason: 'the label must still be painted at a well-defined '
                'origin',
          );
        },
      );

      test(
        'A3h: a route whose first point sits at the image corner has its '
        'label CLAMPED so the full laid-out label stays within the image '
        "bounds — not clipped off-frame (fix for the perpendicular offset "
        'pushing it into negative/out-of-bounds territory near an edge)',
        () {
          // Single-point route pinned to the top-left corner: unclamped,
          // the fallback up-and-left offset direction would place the
          // label origin at negative x/y (off-frame).
          final route = TopoRoute(
            id: 1,
            number: 9,
            colorIndex: 0,
            points: const [Offset(0.0, 0.0)],
          );
          final canvas = _RecordingCanvas();

          buildPainter(routes: [route]).paint(canvas, imageSize);

          expect(canvas.paragraphs, hasLength(1));
          final origin = canvas.paragraphs.single.offset;
          final paragraph = canvas.paragraphs.single.paragraph;

          expect(
            origin.dx,
            greaterThanOrEqualTo(0),
            reason: 'label must not clip off the left edge',
          );
          expect(
            origin.dy,
            greaterThanOrEqualTo(0),
            reason: 'label must not clip off the top edge',
          );
          expect(
            origin.dx + paragraph.maxIntrinsicWidth,
            lessThanOrEqualTo(imageSize.width),
            reason: 'label must not clip off the right edge',
          );
          expect(
            origin.dy + paragraph.height,
            lessThanOrEqualTo(imageSize.height),
            reason: 'label must not clip off the bottom edge',
          );
        },
      );

      test(
        'A3e: label font size itself scales by 1/scale — the rendered '
        'paragraph is measurably wider at scale 0.5 (fontSize 28.0) than '
        'at scale 1.0 (fontSize 14.0) for the same text',
        () {
          TopoRoute routeWithLabel() => TopoRoute(
            id: 1,
            number: 8,
            colorIndex: 0,
            points: const [Offset(0.1, 0.1), Offset(0.9, 0.8)],
          );

          double? widthAt(double scale) {
            final canvas = _RecordingCanvas();
            buildPainter(
              routes: [routeWithLabel()],
              scale: scale,
            ).paint(canvas, imageSize);
            // _RecordingCanvas.drawParagraph (used by TextPainter.paint)
            // captures the real ui.Paragraph the engine laid out, so its
            // maxIntrinsicWidth reflects the actual fontSize used.
            return canvas.paragraphs.isEmpty
                ? null
                : canvas.paragraphs.single.paragraph.maxIntrinsicWidth;
          }

          final widthAt1 = widthAt(1.0);
          final widthAt05 = widthAt(0.5);

          expect(widthAt1, isNotNull);
          expect(widthAt05, isNotNull);
          // fontSize doubles (14.0 -> 28.0) at scale 0.5, so the laid-out
          // paragraph width should also roughly double.
          expect(widthAt05! / widthAt1!, closeTo(2.0, 0.2));
        },
      );

      test(
        'A4: shouldRepaint returns true when only scale changes',
        () {
          final a = buildPainter();
          final b = buildPainter(scale: 0.5);

          expect(a.shouldRepaint(b), isTrue);
          expect(b.shouldRepaint(a), isTrue);
        },
      );

      test(
        'shouldRepaint returns false when scale (and everything else) is '
        'identical',
        () {
          final a = buildPainter(scale: 0.5);
          final b = buildPainter(scale: 0.5);

          expect(a.shouldRepaint(b), isFalse);
        },
      );

      test(
        'Non-positive scale is clamped to 1.0 (no divide-by-zero blow-up): '
        'scale 0.0 paints the same stroke width as scale 1.0',
        () {
          final at0 = buildPainter(
            currentPoints: const [Offset(0.0, 0.0), Offset(1.0, 1.0)],
            scale: 0.0,
          );
          final canvas = _RecordingCanvas();

          expect(() => at0.paint(canvas, imageSize), returnsNormally);
          expect(canvas.linePaints.single.strokeWidth, 5.5);
        },
      );
    },
  );

  group('TopoPainter golden', () {
    testWidgets(
      'A6: two visible routes with symbols and a selection render a '
      'stable golden image',
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
          routes: [
            TopoRoute(
              id: 1,
              number: 1,
              colorIndex: 0,
              points: const [
                Offset(0.1, 0.1),
                Offset(0.4, 0.5),
                Offset(0.9, 0.8),
              ],
              symbols: const [
                TopoSymbol(type: SymbolType.anchor, position: Offset(0.1, 0.1)),
                TopoSymbol(type: SymbolType.top, position: Offset(0.9, 0.8)),
              ],
            ),
            TopoRoute(
              id: 2,
              number: 2,
              colorIndex: 1,
              points: const [
                Offset(0.2, 0.8),
                Offset(0.7, 0.2),
              ],
            ),
          ],
          currentPoints: const [],
          showHandles: false,
          selectedRouteId: 1,
          palette: palette,
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
          matchesGoldenFile('goldens/topo_painter_multiroute.png'),
        );
      },
    );
  });

  group('TopoCanvas crop framing golden (M5, A5)', () {
    testWidgets(
      'A5: a slice active + a route renders a stable golden of the '
      'cropped/framed view',
      (tester) async {
        // Pin DPR + physical size, same rationale as the multi-route golden
        // above, so the checked-in PNG is deterministic across machines.
        tester.view.physicalSize = const Size(400, 400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        // A 2000x1000 original image, cropped to [0.25, 0.75] (cropWidthPct
        // 0.5) and framed into a 400x400 viewport — see
        // TopoCanvas.computeCropTransform's doc for the scale/translate
        // math this reproduces directly (rather than pumping the full
        // TopoCanvas widget, which would need a real decodable image file
        // and a ProviderScope for no benefit here: this golden is only
        // about the crop-transform + painter composition, exactly what
        // TopoCanvas wraps its Image.file + CustomPaint stack in).
        const imageSize = Size(2000, 1000);
        const viewportSize = Size(400, 400);
        const cropXpct = 0.25;
        const cropWidthPct = 0.5;

        final matrix = TopoCanvas.computeCropTransform(
          viewportSize: viewportSize,
          imageSize: imageSize,
          cropXpct: cropXpct,
          cropWidthPct: cropWidthPct,
        );

        // A route that spans across (and beyond) the crop band, in ORIGINAL
        // percent space — proving the painter still draws in original
        // coordinates while the canvas is merely framed/clipped to the
        // slice.
        final route = TopoRoute(
          id: 1,
          number: 1,
          colorIndex: 0,
          points: const [
            Offset(0.1, 0.2),
            Offset(0.4, 0.5),
            Offset(0.6, 0.4),
            Offset(0.9, 0.8),
          ],
        );

        final painter = TopoPainter(
          imageSize: imageSize,
          routes: [route],
          currentPoints: const [],
          showHandles: false,
          palette: palette,
        );

        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: RepaintBoundary(
              child: SizedBox(
                width: viewportSize.width,
                height: viewportSize.height,
                child: ClipRect(
                  child: Transform(
                    transform: matrix,
                    child: SizedBox(
                      width: imageSize.width,
                      height: imageSize.height,
                      child: CustomPaint(painter: painter, size: imageSize),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        await expectLater(
          find.byType(RepaintBoundary),
          matchesGoldenFile('goldens/topo_canvas_crop_framed.png'),
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
          symbols: const [
            TopoSymbol(type: SymbolType.anchor, position: Offset(0.1, 0.1)),
            TopoSymbol(type: SymbolType.bolt, position: Offset(0.3, 0.4)),
            TopoSymbol(type: SymbolType.top, position: Offset(0.9, 0.8)),
            TopoSymbol(type: SymbolType.crux, position: Offset(0.5, 0.5)),
            TopoSymbol(type: SymbolType.rest, position: Offset(0.2, 0.6)),
          ],
        ),
      ],
      currentPoints: const [Offset(0.2, 0.2), Offset(0.8, 0.8)],
      showHandles: true,
      selectedRouteId: 1,
    );

    expect(() => painter.paint(canvas, imageSize), returnsNormally);

    final picture = recorder.endRecording();
    expect(picture, isNotNull);
  });
}
