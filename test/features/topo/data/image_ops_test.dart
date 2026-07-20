import 'dart:typed_data';

import 'package:climbtopo/features/topo/data/image_ops/image_ops.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

/// These tests run on the Dart VM, so they exercise the NATIVE
/// implementation (`image_ops_native.dart`) via the conditional-export
/// facade in `image_ops.dart`.
void main() {
  Uint8List encodeSolidJpg(int width, int height) {
    final image = img.Image(width: width, height: height);
    img.fill(image, color: img.ColorRgb8(120, 60, 200));
    return Uint8List.fromList(img.encodeJpg(image, quality: 90));
  }

  Uint8List encodeSolidPng(int width, int height) {
    final image = img.Image(width: width, height: height);
    img.fill(image, color: img.ColorRgb8(10, 200, 40));
    return Uint8List.fromList(img.encodePng(image));
  }

  group('generateThumbnail (native)', () {
    test('downscales a large landscape image to a 512px long edge', () async {
      final src = encodeSolidJpg(1024, 768);

      final result = await generateThumbnail(src);

      final decoded = img.decodeImage(result);
      expect(decoded, isNotNull);
      final longEdge =
          decoded!.width >= decoded.height ? decoded.width : decoded.height;
      expect(longEdge, 512);
      // Aspect ratio preserved within ±1px of the source 1024x768 (4:3).
      final expectedHeight = (decoded.width * 768 / 1024).round();
      expect((decoded.height - expectedHeight).abs(), lessThanOrEqualTo(1));

      // Output must decode as a valid JPEG (re-encoding it should succeed
      // and decodeImage must recognize it without needing a format hint).
      expect(() => img.encodeJpg(decoded), returnsNormally);
    });

    test('downscales a large portrait image preserving aspect', () async {
      final src = encodeSolidJpg(768, 1024);

      final result = await generateThumbnail(src);

      final decoded = img.decodeImage(result);
      expect(decoded, isNotNull);
      final longEdge =
          decoded!.width >= decoded.height ? decoded.width : decoded.height;
      expect(longEdge, 512);
      final expectedWidth = (decoded.height * 768 / 1024).round();
      expect((decoded.width - expectedWidth).abs(), lessThanOrEqualTo(1));
    });

    test('accepts a PNG source and still emits a decodable thumbnail',
        () async {
      final src = encodeSolidPng(1200, 900);

      final result = await generateThumbnail(src);

      final decoded = img.decodeImage(result);
      expect(decoded, isNotNull);
      final longEdge =
          decoded!.width >= decoded.height ? decoded.width : decoded.height;
      expect(longEdge, 512);
    });

    test('returns the input unchanged when already at/under maxEdge',
        () async {
      final src = encodeSolidJpg(100, 100);

      final result = await generateThumbnail(src);

      expect(result, same(src));
    });

    test('returns the input unchanged when given undecodable garbage bytes',
        () async {
      // 8 bytes: img.decodeImage returns null → the `decoded == null` fallback.
      final src = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);

      final result = await generateThumbnail(src);

      expect(result, same(src));
    });

    test('returns the input unchanged when decode THROWS (short buffer)',
        () async {
      // 5 bytes trip the image package's PSD sniffer into reading past the
      // buffer end and throwing a RangeError — exercises the try/catch
      // fallback (a truncated restore-download payload is the real trigger).
      final src = Uint8List.fromList([1, 2, 3, 4, 5]);

      final result = await generateThumbnail(src);

      expect(result, same(src));
    });

    test('respects a custom maxEdge', () async {
      final src = encodeSolidJpg(1024, 768);

      final result = await generateThumbnail(src, maxEdge: 256);

      final decoded = img.decodeImage(result);
      expect(decoded, isNotNull);
      final longEdge =
          decoded!.width >= decoded.height ? decoded.width : decoded.height;
      expect(longEdge, 256);
    });
  });
}
