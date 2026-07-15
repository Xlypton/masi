import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import 'package:climbtopo/features/ar/application/outline_extractor.dart';

/// Builds a 40x40 synthetic image that is solid black on the left half
/// (x < 20) and solid white on the right half (x >= 20) — a single, clean
/// vertical edge at x == 20.
img.Image _halfBlackHalfWhite() {
  final image = img.Image(width: 40, height: 40, numChannels: 3);
  for (var y = 0; y < image.height; y++) {
    for (var x = 0; x < image.width; x++) {
      if (x < 20) {
        image.setPixelRgb(x, y, 0, 0, 0);
      } else {
        image.setPixelRgb(x, y, 255, 255, 255);
      }
    }
  }
  return image;
}

/// Builds a 60x20 synthetic image that is a gentle grayscale gradient over
/// x in [0, 40) (a weak, texture-like slope) followed by solid white over
/// x in [40, 60) — one strong, hard edge at x == 40 sitting alongside a soft
/// gradient. Useful for proving a threshold can distinguish "real edge" from
/// "faint texture" the way real photo noise needs to be suppressed.
img.Image _gradientWithHardEdge() {
  final image = img.Image(width: 60, height: 20, numChannels: 3);
  for (var y = 0; y < image.height; y++) {
    for (var x = 0; x < image.width; x++) {
      if (x < 40) {
        final v = (x * 255 / 80).round();
        image.setPixelRgb(x, y, v, v, v);
      } else {
        image.setPixelRgb(x, y, 255, 255, 255);
      }
    }
  }
  return image;
}

int _countOpaque(img.Image out) {
  var count = 0;
  for (final p in out) {
    if (p.a.toInt() == 255) count++;
  }
  return count;
}

void main() {
  group('outlineFromImage', () {
    test('is fully transparent over flat regions and fully opaque at the '
        'edge', () {
      final src = _halfBlackHalfWhite();
      final out = outlineFromImage(src, maxDim: 40);

      expect(out.width, src.width);
      expect(out.height, src.height);

      // Flat regions must be genuinely transparent — no color wash.
      expect(
        out.getPixel(5, 20).a.toInt(),
        0,
        reason: 'flat black region should be exactly transparent',
      );
      expect(
        out.getPixel(35, 20).a.toInt(),
        0,
        reason: 'flat white region should be exactly transparent',
      );

      // Sample several rows near the boundary column; every one should be a
      // fully opaque line pixel (hard threshold, no partial alphas).
      for (final y in [5, 15, 20, 25, 35]) {
        expect(
          out.getPixel(20, y).a.toInt(),
          255,
          reason: 'pixel at x=20,y=$y should be a fully opaque edge pixel',
        );
      }
    });

    test('opaque edge pixels default to black', () {
      final src = _halfBlackHalfWhite();
      final out = outlineFromImage(src, maxDim: 40);

      final edgePixel = out.getPixel(20, 20);
      expect(edgePixel.a.toInt(), 255);
      expect(edgePixel.r.toInt(), 0);
      expect(edgePixel.g.toInt(), 0);
      expect(edgePixel.b.toInt(), 0);
    });

    test('opaque edge pixels use the requested line color', () {
      final src = _halfBlackHalfWhite();
      const lineR = 200;
      const lineG = 100;
      const lineB = 50;
      final out = outlineFromImage(
        src,
        maxDim: 40,
        lineR: lineR,
        lineG: lineG,
        lineB: lineB,
      );

      final edgePixel = out.getPixel(20, 20);
      expect(edgePixel.a.toInt(), 255);
      expect(edgePixel.r.toInt(), lineR);
      expect(edgePixel.g.toInt(), lineG);
      expect(edgePixel.b.toInt(), lineB);
    });

    test('does not mutate the source image', () {
      final src = _halfBlackHalfWhite();
      final beforeTopLeft = src.getPixel(0, 0);
      final beforeTopLeftRgb = (
        beforeTopLeft.r.toInt(),
        beforeTopLeft.g.toInt(),
        beforeTopLeft.b.toInt(),
      );

      outlineFromImage(src, maxDim: 40);

      final afterTopLeft = src.getPixel(0, 0);
      expect(afterTopLeft.r.toInt(), beforeTopLeftRgb.$1);
      expect(afterTopLeft.g.toInt(), beforeTopLeftRgb.$2);
      expect(afterTopLeft.b.toInt(), beforeTopLeftRgb.$3);
    });

    test(
      'a higher threshold produces fewer opaque pixels than a lower '
      'threshold on the same source',
      () {
        final src = _gradientWithHardEdge();
        final low = outlineFromImage(src, maxDim: 60, threshold: 15);
        final mid = outlineFromImage(src, maxDim: 60, threshold: 50);

        final lowCount = _countOpaque(low);
        final midCount = _countOpaque(mid);

        expect(
          midCount,
          lessThan(lowCount),
          reason:
              'raising the threshold should drop weak/noisy edges, '
              'leaving fewer opaque pixels',
        );

        // The low threshold picks up the soft gradient as "edges" (noise)...
        expect(
          low.getPixel(5, 10).a.toInt(),
          255,
          reason: 'low threshold should treat the soft gradient as an edge',
        );
        // ...but the mid threshold suppresses that same noisy gradient area.
        expect(
          mid.getPixel(5, 10).a.toInt(),
          0,
          reason: 'mid threshold should suppress the soft gradient noise',
        );
        // Both thresholds keep the one genuine, hard edge.
        expect(
          low.getPixel(40, 10).a.toInt(),
          255,
          reason: 'the hard edge should survive the low threshold',
        );
        expect(
          mid.getPixel(40, 10).a.toInt(),
          255,
          reason: 'the hard edge should survive the mid threshold too',
        );
      },
    );
  });

  group('extractOutline', () {
    // These tests run in plain `test()` blocks (not `testWidgets()`), so they
    // execute in a real (non-fake-async) zone — required both for `compute`
    // (spawns a genuine background isolate) and for `ui.decodeImageFromPixels`
    // (its completion callback never fires under a fake-async widget-test
    // clock; see this project's `flutter test` guidance on never driving a
    // real image-codec decode inside `testWidgets`).
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('outline_extractor_test');
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    test(
      'decodes a real file off the main isolate via compute() and returns a '
      'ui.Image sized like outlineFromImage would produce',
      () async {
        final src = _halfBlackHalfWhite();
        final file = File(p.join(tempDir.path, 'src.png'));
        file.writeAsBytesSync(img.encodePng(src));

        final image = await extractOutline(file.path, maxDim: 40);

        expect(image, isNotNull);
        expect(image!.width, src.width);
        expect(image.height, src.height);
      },
    );

    test(
      'downscales per maxDim exactly like outlineFromImage does',
      () async {
        final src = _halfBlackHalfWhite(); // 40x40
        final file = File(p.join(tempDir.path, 'src.png'));
        file.writeAsBytesSync(img.encodePng(src));

        final image = await extractOutline(file.path, maxDim: 20);

        expect(image, isNotNull);
        expect(image!.width, 20);
        expect(image.height, 20);
      },
    );

    test('returns null for a path that does not exist, no throw', () async {
      final image = await extractOutline(
        p.join(tempDir.path, 'does_not_exist.png'),
      );

      expect(image, isNull);
    });

    test(
      'returns null for a file that is not a decodable image, no throw',
      () async {
        final file = File(p.join(tempDir.path, 'garbage.png'));
        file.writeAsBytesSync(<int>[1, 2, 3, 4, 5]);

        final image = await extractOutline(file.path);

        expect(image, isNull);
      },
    );
  });
}
