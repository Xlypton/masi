import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:masi/features/topo/presentation/rock_mask_painter.dart';

/// A minimal fake [Canvas] recording the ONE call [RockMaskPainter] makes —
/// `drawImageRect` — without needing a mocking package (mirrors
/// `ar_overlay_painter_test.dart`'s `_RecordingCanvas`).
class _RecordingCanvas implements Canvas {
  final List<({ui.Image image, Rect src, Rect dst, Paint paint})> imageRects =
      [];

  @override
  void drawImageRect(ui.Image image, Rect src, Rect dst, Paint paint) {
    imageRects.add((image: image, src: src, dst: dst, paint: paint));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Decodes a tiny fake RGBA "mask" image (like the real
/// `decodeRockMaskAlpha` output) from raw pixels, so the painter test needs
/// no device, no PNG, and no real segmentation. [width]/[height] let a test
/// pick non-square dims to exercise the independent-x/y stretch.
Future<ui.Image> _createFakeMask({int width = 2, int height = 2}) {
  final completer = Completer<ui.Image>();
  final pixels = Uint8List(width * height * 4);
  for (var i = 0; i < width * height; i++) {
    final o = i * 4;
    pixels[o] = 0x00; // R
    pixels[o + 1] = 0xE5; // G
    pixels[o + 2] = 0xFF; // B
    pixels[o + 3] = 0xFF; // A (fully "rock")
  }
  ui.decodeImageFromPixels(
    pixels,
    width,
    height,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  return completer.future;
}

void main() {
  const imageSize = Size(400, 300);

  test('draws the mask stretched from its full rect onto the image rect', () async {
    final mask = await _createFakeMask(width: 4, height: 2);
    final painter = RockMaskPainter(mask: mask, imageSize: imageSize);
    final canvas = _RecordingCanvas();

    painter.paint(canvas, imageSize);

    // Exactly one drawImageRect, drawing OUR mask.
    expect(canvas.imageRects, hasLength(1));
    final rec = canvas.imageRects.single;
    expect(rec.image, same(mask));
    // src = full mask rect (downsampled mask dims), dst = full photo rect —
    // the independent-x/y stretch (4x2 mask onto 400x300) self-corrects the
    // aspect mismatch.
    expect(rec.src, Rect.fromLTWH(0, 0, 4, 2));
    expect(rec.dst, Rect.fromLTWH(0, 0, imageSize.width, imageSize.height));
    // Tinted via a srcIn ColorFilter so the mask is recolored to a
    // translucent wash rather than painting its own baked RGB opaquely.
    expect(rec.paint.colorFilter, isNotNull);
  });

  test('PictureRecorder smoke test against a real dart:ui Canvas', () async {
    final mask = await _createFakeMask();
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final painter = RockMaskPainter(mask: mask, imageSize: imageSize);

    expect(() => painter.paint(canvas, imageSize), returnsNormally);

    final picture = recorder.endRecording();
    expect(picture, isNotNull);
  });

  group('shouldRepaint', () {
    test('false when the mask image and imageSize are identical', () async {
      final mask = await _createFakeMask();
      final a = RockMaskPainter(mask: mask, imageSize: imageSize);
      final b = RockMaskPainter(mask: mask, imageSize: imageSize);

      expect(a.shouldRepaint(b), isFalse);
    });

    test('true when the mask image differs', () async {
      final maskA = await _createFakeMask();
      final maskB = await _createFakeMask();
      final a = RockMaskPainter(mask: maskA, imageSize: imageSize);
      final b = RockMaskPainter(mask: maskB, imageSize: imageSize);

      expect(a.shouldRepaint(b), isTrue);
    });

    test('true when imageSize differs', () async {
      final mask = await _createFakeMask();
      final a = RockMaskPainter(mask: mask, imageSize: imageSize);
      final b = RockMaskPainter(mask: mask, imageSize: const Size(800, 600));

      expect(a.shouldRepaint(b), isTrue);
    });
  });

  testWidgets('renders inside a CustomPaint without throwing', (tester) async {
    // Decode via runAsync: `decodeImageFromPixels` is real (non-fake-async)
    // engine work that never completes under testWidgets' fake clock —
    // mirrors `ar_screen_test.dart`'s ui.Image-decoding testWidgets tests.
    final mask = (await tester.runAsync(
      () => _createFakeMask(width: 4, height: 3),
    ))!;
    addTearDown(mask.dispose);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: RepaintBoundary(
          child: SizedBox(
            width: imageSize.width,
            height: imageSize.height,
            child: CustomPaint(
              size: imageSize,
              painter: RockMaskPainter(mask: mask, imageSize: imageSize),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(CustomPaint), findsWidgets);
  });
}
