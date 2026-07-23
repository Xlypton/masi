import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:masi/core/coordinates/coordinate_transformer.dart';
import 'package:masi/features/ar/domain/rock_box.dart';
import 'package:masi/features/topo/presentation/rock_mask_painter.dart';

/// A minimal fake [Canvas] recording the ONE call [RockBoxPainter] makes --
/// `drawPath` -- without needing a mocking package (mirrors
/// `ar_overlay_painter_test.dart`'s `_RecordingCanvas`).
class _RecordingCanvas implements Canvas {
  final List<Path> paths = [];
  final List<Paint> paints = [];

  @override
  void drawPath(Path path, Paint paint) {
    paths.add(path);
    paints.add(paint);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  const imageSize = Size(400, 300);
  const box = Rect.fromLTRB(0.2, 0.3, 0.8, 0.7);

  test(
    'draws a closed path through the box\'s 4 corners converted to scene '
    'space (fill + stroke), no image drawing at all',
    () {
      final painter = RockBoxPainter(box: box, imageSize: imageSize);
      final canvas = _RecordingCanvas();

      painter.paint(canvas, imageSize);

      // Fill + stroke -> exactly 2 drawPath calls.
      expect(canvas.paths, hasLength(2));

      // Both paths trace the same 4 corners, each converted from the
      // normalized box into scene pixels the same way a route point would
      // be (CoordinateTransformer.percentToScene) -- no homography, since
      // this painter shares the InteractiveViewer transform directly.
      final expectedCorners = [
        for (final p in rockBoxCornersNorm(box))
          CoordinateTransformer.percentToScene(p, imageSize),
      ];
      for (final path in canvas.paths) {
        final metrics = path.computeMetrics().toList();
        expect(metrics, isNotEmpty);
        final start = metrics.first.getTangentForOffset(0)?.position;
        expect(start, isNotNull);
        expect((start! - expectedCorners[0]).distance, lessThan(0.01));
      }

      // One paint is a fill, the other a stroke -- both in the same
      // highlight tint family (non-opaque, translucent alpha), and the
      // stroke's alpha must be higher (more opaque) than the fill's,
      // matching the "tinted stroke + faint fill" contract.
      final fillPaint = canvas.paints.firstWhere(
        (p) => p.style == PaintingStyle.fill,
      );
      final strokePaint = canvas.paints.firstWhere(
        (p) => p.style == PaintingStyle.stroke,
      );
      expect(fillPaint.color.a, greaterThan(0));
      expect(strokePaint.color.a, greaterThan(fillPaint.color.a));
      expect(strokePaint.strokeWidth, greaterThan(0));
      // Same tint family (RGB) for both.
      expect(
        fillPaint.color.toARGB32() & 0x00FFFFFF,
        strokePaint.color.toARGB32() & 0x00FFFFFF,
      );
    },
  );

  test('PictureRecorder smoke test against a real dart:ui Canvas', () {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final painter = RockBoxPainter(box: box, imageSize: imageSize);

    expect(() => painter.paint(canvas, imageSize), returnsNormally);

    final picture = recorder.endRecording();
    expect(picture, isNotNull);
  });

  group('shouldRepaint', () {
    test('false when the box and imageSize are identical', () {
      final a = RockBoxPainter(box: box, imageSize: imageSize);
      final b = RockBoxPainter(box: box, imageSize: imageSize);

      expect(a.shouldRepaint(b), isFalse);
    });

    test('true when the box differs', () {
      final a = RockBoxPainter(box: box, imageSize: imageSize);
      final b = RockBoxPainter(
        box: const Rect.fromLTRB(0.1, 0.1, 0.9, 0.9),
        imageSize: imageSize,
      );

      expect(a.shouldRepaint(b), isTrue);
    });

    test('true when imageSize differs', () {
      final a = RockBoxPainter(box: box, imageSize: imageSize);
      final b = RockBoxPainter(box: box, imageSize: const Size(800, 600));

      expect(a.shouldRepaint(b), isTrue);
    });
  });

  testWidgets('renders inside a CustomPaint without throwing', (tester) async {
    // No image decode involved -- a box painter draws pure vector paths, so
    // (unlike the old mask painter) this needs no tester.runAsync/real
    // engine decode to avoid hanging under fake-async.
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: RepaintBoundary(
          child: SizedBox(
            width: imageSize.width,
            height: imageSize.height,
            child: CustomPaint(
              size: imageSize,
              painter: RockBoxPainter(box: box, imageSize: imageSize),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(CustomPaint), findsWidgets);
  });
}
