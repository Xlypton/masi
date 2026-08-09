import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:masi/features/topo/data/image_header_size.dart';

/// `readImageHeader` is deliberately import-free pure Dart (only
/// `dart:typed_data`), so unlike the rest of the web photo pipeline it runs
/// unchanged on the VM and can be tested here rather than only under
/// `flutter test --platform chrome`.
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

  Uint8List encodeSolidGif(int width, int height) {
    final image = img.Image(width: width, height: height);
    img.fill(image, color: img.ColorRgb8(200, 200, 10));
    return Uint8List.fromList(img.encodeGif(image));
  }

  /// An APP1/EXIF segment carrying nothing but `Orientation` = [value].
  Uint8List exifApp1(int value, {bool littleEndian = true}) {
    final tiff = <int>[
      if (littleEndian) ...[0x49, 0x49, 0x2A, 0x00] else ...[0x4D, 0x4D, 0x00, 0x2A],
      // Offset to IFD0 = 8, relative to the TIFF header start.
      if (littleEndian) ...[0x08, 0x00, 0x00, 0x00] else ...[0x00, 0x00, 0x00, 0x08],
      // Entry count = 1.
      if (littleEndian) ...[0x01, 0x00] else ...[0x00, 0x01],
      // Tag 0x0112 (Orientation), type 3 (SHORT), count 1.
      if (littleEndian) ...[0x12, 0x01] else ...[0x01, 0x12],
      if (littleEndian) ...[0x03, 0x00] else ...[0x00, 0x03],
      if (littleEndian) ...[0x01, 0x00, 0x00, 0x00] else ...[0x00, 0x00, 0x00, 0x01],
      // Inline value, left-aligned in the 4-byte value field.
      if (littleEndian) ...[value, 0x00, 0x00, 0x00] else ...[0x00, value, 0x00, 0x00],
      // Next-IFD offset = 0.
      0x00, 0x00, 0x00, 0x00,
    ];
    final payload = <int>[0x45, 0x78, 0x69, 0x66, 0x00, 0x00, ...tiff];
    final len = payload.length + 2;
    return Uint8List.fromList(<int>[
      0xFF, 0xE1, (len >> 8) & 0xFF, len & 0xFF, ...payload,
    ]);
  }

  /// [jpeg] with an EXIF APP1 segment spliced in right after SOI, exactly where
  /// a camera writes it.
  Uint8List withExif(Uint8List jpeg, int orientation, {bool littleEndian = true}) =>
      Uint8List.fromList(<int>[
        jpeg[0], jpeg[1],
        ...exifApp1(orientation, littleEndian: littleEndian),
        ...jpeg.sublist(2),
      ]);

  /// A JPEG consisting of NOTHING but markers — no entropy-coded scan data at
  /// all — whose SOF claims [width] x [height]. If the scanner can size this,
  /// it provably never looks at a pixel.
  Uint8List headerOnlyJpeg(int width, int height, {int sofMarker = 0xC0}) =>
      Uint8List.fromList(<int>[
        0xFF, 0xD8, // SOI
        // APP0/JFIF, so there is at least one segment to jump over.
        0xFF, 0xE0, 0x00, 0x10,
        0x4A, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x00,
        0x00, 0x01, 0x00, 0x01, 0x00, 0x00,
        // SOFn: len 17, precision 8, height, width, 3 components.
        0xFF, sofMarker, 0x00, 0x11, 0x08,
        (height >> 8) & 0xFF, height & 0xFF,
        (width >> 8) & 0xFF, width & 0xFF,
        0x03,
        0x01, 0x22, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01,
        0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F, 0x00,
      ]);

  Uint8List riffWebp(List<int> chunk) {
    final body = <int>[0x57, 0x45, 0x42, 0x50, ...chunk];
    final size = body.length;
    return Uint8List.fromList(<int>[
      0x52, 0x49, 0x46, 0x46,
      size & 0xFF, (size >> 8) & 0xFF, (size >> 16) & 0xFF, (size >> 24) & 0xFF,
      ...body,
    ]);
  }

  group('readImageHeader — JPEG', () {
    test('reads a real encoder-produced landscape JPEG', () {
      final info = readImageHeader(encodeSolidJpg(1024, 768));

      expect(info, isNotNull);
      expect(info!.container, ImageContainer.jpeg);
      expect(info.width, 1024);
      expect(info.height, 768);
      expect(info.orientation, isNull);
      expect(info.swapsAxes, isFalse);
      expect(info.orientedWidth, 1024);
      expect(info.orientedHeight, 768);
      expect(info.longEdge, 1024);
      expect(info.shortEdge, 768);
    });

    test('reads a real encoder-produced portrait JPEG', () {
      final info = readImageHeader(encodeSolidJpg(300, 900));

      expect(info!.width, 300);
      expect(info.height, 900);
      expect(info.longEdge, 900);
      expect(info.shortEdge, 300);
    });

    test('sizes a header-only JPEG with no scan data — proof it reads no pixels',
        () {
      // 4032x3024 is the real 12 MP iPhone photo geometry that made
      // `startDecode` allocate 285,768 Int32List(64) blocks. Here the file is
      // ~50 bytes.
      final bytes = headerOnlyJpeg(4032, 3024);
      expect(bytes.length, lessThan(100));

      final info = readImageHeader(bytes);

      expect(info!.width, 4032);
      expect(info.height, 3024);
    });

    test('reads a progressive frame header (SOF2), not just baseline', () {
      final info = readImageHeader(headerOnlyJpeg(800, 600, sofMarker: 0xC2));

      expect(info!.width, 800);
      expect(info.height, 600);
    });

    test('does not mistake DHT/JPG/DAC in the 0xC0..0xCF range for a frame', () {
      for (final notAFrame in <int>[0xC4, 0xC8, 0xCC]) {
        final bytes = Uint8List.fromList(<int>[
          0xFF, 0xD8,
          // A segment using a non-SOF marker from the same numeric range,
          // whose payload would parse as 800x600 if it were misread.
          0xFF, notAFrame, 0x00, 0x11, 0x08,
          0x02, 0x58, 0x03, 0x20, 0x03,
          0x01, 0x22, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01,
          0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F, 0x00,
        ]);

        expect(readImageHeader(bytes), isNull, reason: 'marker 0x${notAFrame.toRadixString(16)}');
      }
    });

    test('returns null for a JPEG that reaches SOS with no frame header', () {
      final bytes = Uint8List.fromList(<int>[
        0xFF, 0xD8,
        0xFF, 0xE0, 0x00, 0x10,
        0x4A, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x00,
        0x00, 0x01, 0x00, 0x01, 0x00, 0x00,
        0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F, 0x00,
      ]);

      expect(readImageHeader(bytes), isNull);
    });

    test('returns null for a JPEG truncated inside its frame segment', () {
      final full = encodeSolidJpg(640, 480);
      // Cut before the SOF can possibly be complete but after SOI.
      expect(readImageHeader(Uint8List.sublistView(full, 0, 12)), isNull);
    });
  });

  group('readImageHeader — EXIF orientation', () {
    test('1..4 leave the stored axes alone', () {
      for (final o in <int>[1, 2, 3, 4]) {
        final info = readImageHeader(withExif(encodeSolidJpg(400, 200), o));

        expect(info!.orientation, o, reason: 'orientation $o');
        expect(info.swapsAxes, isFalse, reason: 'orientation $o');
        expect(info.orientedWidth, 400);
        expect(info.orientedHeight, 200);
      }
    });

    test('5..8 transpose the reported size', () {
      for (final o in <int>[5, 6, 7, 8]) {
        final info = readImageHeader(withExif(encodeSolidJpg(400, 200), o));

        expect(info!.orientation, o, reason: 'orientation $o');
        expect(info.swapsAxes, isTrue, reason: 'orientation $o');
        // Stored pair is untouched...
        expect(info.width, 400);
        expect(info.height, 200);
        // ...only the oriented view swaps.
        expect(info.orientedWidth, 200);
        expect(info.orientedHeight, 400);
        // Long/short edge stay orientation-invariant, which is what the
        // thumbnail path relies on.
        expect(info.longEdge, 400);
        expect(info.shortEdge, 200);
      }
    });

    test('reads a big-endian ("MM") EXIF block too', () {
      final info =
          readImageHeader(withExif(encodeSolidJpg(400, 200), 6, littleEndian: false));

      expect(info!.orientation, 6);
      expect(info.orientedWidth, 200);
      expect(info.orientedHeight, 400);
    });

    test('an out-of-range orientation value is reported as unknown, not applied',
        () {
      final info = readImageHeader(withExif(encodeSolidJpg(400, 200), 9));

      expect(info!.orientation, isNull);
      expect(info.swapsAxes, isFalse);
      expect(info.orientedWidth, 400);
    });

    test('a corrupt EXIF block never breaks the size read', () {
      final good = withExif(encodeSolidJpg(400, 200), 6);
      final broken = Uint8List.fromList(good);
      // Smash the TIFF byte-order mark inside APP1. Layout: SOI (0..1),
      // 0xFFE1 (2..3), length (4..5), "Exif\0\0" (6..11), TIFF header (12..).
      broken[12] = 0x00;
      broken[13] = 0x00;

      final info = readImageHeader(broken);

      expect(info, isNotNull);
      expect(info!.width, 400);
      expect(info.height, 200);
      expect(info.orientation, isNull);
    });
  });

  group('readImageHeader — PNG / GIF / WebP', () {
    test('reads PNG from the fixed IHDR offset', () {
      final info = readImageHeader(encodeSolidPng(1200, 900));

      expect(info!.container, ImageContainer.png);
      expect(info.width, 1200);
      expect(info.height, 900);
      expect(info.orientation, isNull);
    });

    test('reads GIF from the logical screen descriptor', () {
      final info = readImageHeader(encodeSolidGif(320, 240));

      expect(info!.container, ImageContainer.gif);
      expect(info.width, 320);
      expect(info.height, 240);
    });

    test('reads lossy WebP (VP8 )', () {
      final bytes = riffWebp(<int>[
        0x56, 0x50, 0x38, 0x20, // 'VP8 '
        0x0A, 0x00, 0x00, 0x00, // chunk size
        0x00, 0x00, 0x00, // frame tag
        0x9D, 0x01, 0x2A, // sync code
        0x80, 0x02, // width 640
        0xE0, 0x01, // height 480
      ]);

      final info = readImageHeader(bytes);

      expect(info!.container, ImageContainer.webp);
      expect(info.width, 640);
      expect(info.height, 480);
    });

    test('reads lossless WebP (VP8L)', () {
      final bytes = riffWebp(<int>[
        0x56, 0x50, 0x38, 0x4C, // 'VP8L'
        0x0A, 0x00, 0x00, 0x00, // chunk size
        0x2F, // signature
        // 14 bits of (1024-1) then 14 bits of (768-1).
        0xFF, 0xC3, 0xBF, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00,
      ]);

      final info = readImageHeader(bytes);

      expect(info!.width, 1024);
      expect(info.height, 768);
    });

    test('reads extended WebP (VP8X) canvas size', () {
      final bytes = riffWebp(<int>[
        0x56, 0x50, 0x38, 0x58, // 'VP8X'
        0x0A, 0x00, 0x00, 0x00, // chunk size
        0x00, 0x00, 0x00, 0x00, // flags
        0xFF, 0x0F, 0x00, // width - 1 = 4095
        0xBF, 0x0B, 0x00, // height - 1 = 3007
      ]);

      final info = readImageHeader(bytes);

      expect(info!.width, 4096);
      expect(info.height, 3008);
    });
  });

  group('readImageHeader — refuses everything a browser cannot render', () {
    test('returns null for containers package:image would happily recognise',
        () {
      final unrenderable = <String, List<int>>{
        // These are exactly the formats the thumbnail early-out used to accept
        // because `findDecoderForData` recognised them, causing a second
        // full-size copy to be written under the thumbnail key.
        'psd': <int>[0x38, 0x42, 0x50, 0x53, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 8],
        'ico': <int>[0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x20, 0x20, 0, 0, 1, 0, 0, 0, 0, 0],
        'bmp': <int>[0x42, 0x4D, 0x46, 0, 0, 0, 0, 0, 0, 0, 0x36, 0, 0, 0, 0x28, 0],
        'tiff': <int>[0x49, 0x49, 0x2A, 0x00, 0x08, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
        'exr': <int>[0x76, 0x2F, 0x31, 0x01, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
      };

      unrenderable.forEach((name, bytes) {
        expect(readImageHeader(Uint8List.fromList(bytes)), isNull, reason: name);
      });
    });

    test('returns null for garbage, empty and near-empty buffers', () {
      expect(readImageHeader(Uint8List(0)), isNull);
      expect(readImageHeader(Uint8List.fromList(<int>[0xFF, 0xD8, 0xFF])), isNull);
      expect(readImageHeader(Uint8List(64)), isNull); // all zeroes
      expect(
        readImageHeader(Uint8List.fromList(List<int>.generate(256, (i) => i % 251))),
        isNull,
      );
    });

    test('returns null for a RIFF file that is not WebP', () {
      final wav = Uint8List.fromList(<int>[
        0x52, 0x49, 0x46, 0x46, 0x24, 0x00, 0x00, 0x00,
        0x57, 0x41, 0x56, 0x45, // 'WAVE'
        ...List<int>.filled(20, 0),
      ]);

      expect(readImageHeader(wav), isNull);
    });

    test('returns null for a header claiming a zero dimension', () {
      expect(readImageHeader(headerOnlyJpeg(0, 600)), isNull);
      expect(readImageHeader(headerOnlyJpeg(800, 0)), isNull);
    });

    test('never throws, for any prefix of a real photo', () {
      final jpeg = withExif(encodeSolidJpg(640, 480), 6);
      for (var cut = 0; cut <= jpeg.length; cut += 7) {
        expect(
          () => readImageHeader(Uint8List.sublistView(jpeg, 0, cut)),
          returnsNormally,
          reason: 'prefix of $cut bytes',
        );
      }
      final png = encodeSolidPng(64, 64);
      for (var cut = 0; cut <= png.length; cut += 11) {
        expect(
          () => readImageHeader(Uint8List.sublistView(png, 0, cut)),
          returnsNormally,
          reason: 'png prefix of $cut bytes',
        );
      }
    });
  });

  group('readImageHeader — cost', () {
    test('sizing a 12 MP photo is bounded by its header, not its pixel count',
        () {
      // The whole point of the rewrite: `startDecode` on a file claiming this
      // geometry allocated ~70 MB and took 155 ms synchronously, and did so
      // even when fed only a 64 KB prefix — because the cost was allocation,
      // not byte-walking. The scanner is handed a file with no pixel data at
      // all and a file with real pixel data, and must answer identically and
      // instantly for both.
      final headerOnly = headerOnlyJpeg(4032, 3024);
      final real = encodeSolidJpg(2000, 1500);

      final sw = Stopwatch()..start();
      for (var i = 0; i < 200; i++) {
        readImageHeader(headerOnly);
        readImageHeader(real);
      }
      sw.stop();

      // 400 scans. Generous bound — the point is orders of magnitude, not a
      // tight benchmark: a single `startDecode` of the 4032x3024 geometry cost
      // 155 ms on its own.
      expect(sw.elapsedMilliseconds, lessThan(155));
    });
  });
}
