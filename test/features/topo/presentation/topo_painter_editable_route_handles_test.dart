import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:masi/features/topo/domain/topo_route.dart';
import 'package:masi/features/topo/presentation/topo_painter.dart';

/// A minimal fake [Canvas] that records only the drawing calls these tests
/// care about (`drawCircle`, `drawLine`, `drawPath`), mirroring the
/// `_RecordingCanvas` technique already used in
/// `test/features/topo/topo_painter_golden_test.dart` -- a plain
/// `noSuchMethod` fallback stands in for every unrecorded Canvas method
/// (`save`/`restore`/`drawParagraph`/etc.), which is safe because
/// `TopoPainter.paint` never calls them for the fixtures below (no
/// `symbolPictures`, so no save/saveLayer/drawPicture path is exercised).
class _RecordingCanvas implements Canvas {
  final List<Offset> circleCenters = [];
  final List<double> circleRadii = [];
  final List<Paint> circlePaints = [];
  final List<({Offset p1, Offset p2})> lines = [];
  final List<Path> paths = [];

  @override
  void drawCircle(Offset c, double radius, Paint paint) {
    circleCenters.add(c);
    circleRadii.add(radius);
    circlePaints.add(paint);
  }

  @override
  void drawLine(Offset p1, Offset p2, Paint paint) {
    lines.add((p1: p1, p2: p2));
  }

  @override
  void drawPath(Path path, Paint paint) {
    paths.add(path);
  }

  // TopoPainter._paintLabel always paints a route-number label for every
  // visible route (regardless of handles/selection), via
  // TextPainter.paint -> Canvas.drawParagraph -- must be handled explicitly
  // (not left to noSuchMethod below) or every fixture with a visible route
  // throws, matching topo_painter_golden_test.dart's _RecordingCanvas.
  @override
  void drawParagraph(ui.Paragraph paragraph, Offset offset) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  const imageSize = Size(400, 300);
  const palette = [Color(0xFF2E7D32), Color(0xFF1565C0), Color(0xFF6A1B9A)];

  /// Converts a percent-space point into scene/pixel coordinates using the
  /// same `percent * imageSize` transform `TopoPainter` applies internally --
  /// matches `topo_painter_golden_test.dart`'s `scenePt` helper.
  Offset scenePt(Offset percent) =>
      Offset(percent.dx * imageSize.width, percent.dy * imageSize.height);

  // A committed route with 3 points, so its own line renders via drawPath
  // (a Catmull-Rom spline) rather than drawCircle/drawLine -- every recorded
  // circle in these tests is therefore unambiguously a drag handle, never
  // the route's own dot/line geometry (matching the disambiguation technique
  // already used throughout topo_painter_golden_test.dart).
  TopoRoute committedRoute({int id = 1}) => TopoRoute(
    id: id,
    number: id,
    colorIndex: 0,
    points: const [
      Offset(0.1, 0.2),
      Offset(0.5, 0.5),
      Offset(0.8, 0.1),
    ],
  );

  TopoPainter buildPainter({
    required List<TopoRoute> routes,
    int? editableRouteId,
    int? selectedRouteId,
  }) {
    return TopoPainter(
      imageSize: imageSize,
      routes: routes,
      currentPoints: const [],
      showHandles: false,
      selectedRouteId: selectedRouteId,
      palette: palette,
      editableRouteId: editableRouteId,
    );
  }

  group('TopoPainter.editableRouteId (route-editing plan step 2)', () {
    test(
      'editableRouteId == null: a committed route paints no handles',
      () {
        final painter = buildPainter(routes: [committedRoute()]);
        final canvas = _RecordingCanvas();

        painter.paint(canvas, imageSize);

        expect(canvas.paths, hasLength(1)); // the route's own spline only.
        expect(canvas.circleCenters, isEmpty);
      },
    );

    test(
      'editableRouteId set to a committed route\'s id: handles are painted '
      'at exactly that route\'s scene points, with the SAME geometry '
      '(radius, color, fill style) the draft draws under showHandles for '
      'an identical set of points -- proving reuse of one handle code path '
      'rather than a second, subtly-different style',
      () {
        final route = committedRoute();

        final editableCanvas = _RecordingCanvas();
        buildPainter(routes: [route], editableRouteId: 1).paint(editableCanvas, imageSize);

        // Same points, drawn via the pre-existing draft/showHandles path
        // instead, as the parity reference.
        final draftCanvas = _RecordingCanvas();
        TopoPainter(
          imageSize: imageSize,
          routes: const [],
          currentPoints: route.points,
          showHandles: true,
          palette: palette,
        ).paint(draftCanvas, imageSize);

        expect(editableCanvas.circleCenters, hasLength(route.points.length));
        expect(editableCanvas.circleCenters, route.points.map(scenePt).toList());
        expect(editableCanvas.circleCenters, draftCanvas.circleCenters);
        expect(editableCanvas.circleRadii, draftCanvas.circleRadii);
        for (var i = 0; i < editableCanvas.circlePaints.length; i++) {
          expect(editableCanvas.circlePaints[i].color, draftCanvas.circlePaints[i].color);
          expect(editableCanvas.circlePaints[i].style, PaintingStyle.fill);
        }
      },
    );

    test(
      'a route present but NOT matching editableRouteId paints no handles '
      '-- only the requested route\'s id gets handles',
      () {
        final target = committedRoute(id: 1);
        const other = TopoRoute(
          id: 2,
          number: 2,
          colorIndex: 1,
          points: [Offset(0.2, 0.8), Offset(0.7, 0.2)],
        );
        final painter = buildPainter(routes: [target, other], editableRouteId: 1);
        final canvas = _RecordingCanvas();

        painter.paint(canvas, imageSize);

        expect(canvas.circleCenters, hasLength(target.points.length));
        expect(canvas.circleCenters, target.points.map(scenePt).toList());
      },
    );

    test(
      'an invisible route matching editableRouteId paints no handles -- '
      'a route must be present AND visible',
      () {
        const route = TopoRoute(
          id: 1,
          number: 1,
          colorIndex: 0,
          visible: false,
          points: [
            Offset(0.1, 0.2),
            Offset(0.5, 0.5),
            Offset(0.8, 0.1),
          ],
        );
        final painter = buildPainter(routes: [route], editableRouteId: 1);
        final canvas = _RecordingCanvas();

        painter.paint(canvas, imageSize);

        expect(canvas.paths, isEmpty); // invisible: no spline either.
        expect(canvas.circleCenters, isEmpty);
      },
    );

    test(
      'editableRouteId with no matching route id present paints no handles',
      () {
        final painter = buildPainter(routes: [committedRoute(id: 1)], editableRouteId: 99);
        final canvas = _RecordingCanvas();

        painter.paint(canvas, imageSize);

        expect(canvas.circleCenters, isEmpty);
      },
    );

    test(
      'editableRouteId is independent of selectedRouteId: a route can be '
      'editable without being selected (its symbols would still stay '
      'hidden under feature #43, but its handles paint regardless)',
      () {
        final route = committedRoute();
        final painter = buildPainter(
          routes: [route],
          editableRouteId: 1,
          selectedRouteId: null,
        );
        final canvas = _RecordingCanvas();

        painter.paint(canvas, imageSize);

        expect(canvas.circleCenters, hasLength(route.points.length));
      },
    );

    test(
      'shouldRepaint returns true when only editableRouteId differs',
      () {
        final a = buildPainter(routes: [committedRoute()], editableRouteId: 1);
        final b = buildPainter(routes: [committedRoute()], editableRouteId: null);

        expect(a.shouldRepaint(b), isTrue);
        expect(b.shouldRepaint(a), isTrue);
      },
    );

    test(
      'shouldRepaint returns false when editableRouteId (and everything '
      'else) is identical',
      () {
        final a = buildPainter(routes: [committedRoute()], editableRouteId: 1);
        final b = buildPainter(routes: [committedRoute()], editableRouteId: 1);

        expect(a.shouldRepaint(b), isFalse);
      },
    );
  });
}
