@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart' show XFile;
// The WEB backends directly, not through the conditional-export facades: the
// facades resolve to the NATIVE implementations under the analyzer and under a
// plain `flutter test`, which is exactly why none of this code had ever been
// executed by a test before.
import 'package:masi/features/topo/data/image_dimensions_web.dart';
import 'package:masi/features/topo/data/image_ops/image_ops_web.dart';
import 'package:web/web.dart' as web;

/// The ONLY coverage that actually executes `image_ops_web.dart` and
/// `image_dimensions_web.dart`. The rest of the photo-pipeline tests run on the
/// Dart VM, where the conditional exports resolve to the NATIVE backends — so
/// before this file existed, not one line of the web photo path had ever run
/// under test.
///
/// Run it with:
///   flutter test --platform chrome test/features/topo/data/image_ops_web_test.dart
///
/// `@TestOn('browser')` keeps it out of the default `flutter test` sweep rather
/// than failing there.
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

  Uint8List exifApp1(int value) => Uint8List.fromList(<int>[
        0xFF, 0xE1, 0x00, 0x22,
        0x45, 0x78, 0x69, 0x66, 0x00, 0x00, // "Exif\0\0"
        0x49, 0x49, 0x2A, 0x00, // "II", 42
        0x08, 0x00, 0x00, 0x00, // IFD0 at +8
        0x01, 0x00, // one entry
        0x12, 0x01, 0x03, 0x00, // tag 0x0112, type SHORT
        0x01, 0x00, 0x00, 0x00, // count 1
        value, 0x00, 0x00, 0x00, // value
        0x00, 0x00, 0x00, 0x00, // next IFD
      ]);

  Uint8List withExif(Uint8List jpeg, int orientation) =>
      Uint8List.fromList(<int>[
        jpeg[0], jpeg[1],
        ...exifApp1(orientation),
        ...jpeg.sublist(2),
      ]);

  group('generateThumbnail (web)', () {
    test('returns the source untouched when it is already small enough', () async {
      final src = encodeSolidJpg(320, 240);

      final result = await generateThumbnail(src);

      expect(identical(result, src), isTrue,
          reason: 'the header scan must short-circuit before any decode');
    });

    test('downscales a large photo to a 512px long edge', () async {
      final src = encodeSolidJpg(2000, 1500);

      final result = await generateThumbnail(src);

      expect(result.length, lessThan(src.length));
      final header = readSize(result);
      expect(header.longEdge, 512);
    });

    test('honours a caller-supplied srcSize instead of re-probing', () async {
      final src = encodeSolidJpg(2000, 1500);

      final probed = await generateThumbnail(src);
      final threaded =
          await generateThumbnail(src, srcSize: (width: 2000, height: 1500));

      expect(readSize(threaded).longEdge, readSize(probed).longEdge);
    });

    test('a small source with a threaded srcSize still short-circuits', () async {
      final src = encodeSolidJpg(320, 240);

      final result = await generateThumbnail(src, srcSize: (width: 320, height: 240));

      expect(identical(result, src), isTrue);
    });

    test('does NOT hand back the source for a format the browser cannot render',
        () async {
      // A PSD header. `package:image`'s findDecoderForData recognises this, so
      // the previous early-out returned it verbatim as the "thumbnail" —
      // writing a second full-size copy of an undisplayable file against the
      // user's quota. It must reach the browser and fail instead.
      final psd = Uint8List.fromList(<int>[
        0x38, 0x42, 0x50, 0x53, 0x00, 0x01, 0, 0, 0, 0, 0, 0,
        0x00, 0x03, 0, 0, 0, 100, 0, 0, 0, 100, 0, 8, 0, 3,
      ]);

      await expectLater(generateThumbnail(psd), throwsA(anything));
    });
  });

  group('decodeImageSize (web)', () {
    test('reads a JPEG size from its header', () async {
      final size = await decodeImageSize(
        XFile.fromData(encodeSolidJpg(1024, 768), name: 'a.jpg'),
      );

      expect(size.width, 1024);
      expect(size.height, 768);
    });

    test('reads a PNG size from its header', () async {
      final size = await decodeImageSize(
        XFile.fromData(encodeSolidPng(640, 400), name: 'a.png'),
      );

      expect(size.width, 640);
      expect(size.height, 400);
    });

    test('applies EXIF orientation 6, matching what the browser paints',
        () async {
      final bytes = withExif(encodeSolidJpg(400, 200), 6);

      final size = await decodeImageSize(XFile.fromData(bytes, name: 'a.jpg'));

      expect(size.width, 200, reason: 'stored 400x200 with Orientation=6');
      expect(size.height, 400);
    });

    test('leaves EXIF orientation 1 alone', () async {
      final bytes = withExif(encodeSolidJpg(400, 200), 1);

      final size = await decodeImageSize(XFile.fromData(bytes, name: 'a.jpg'));

      expect(size.width, 400);
      expect(size.height, 200);
    });

    // The load-bearing assumption behind applying EXIF orientation at all:
    // that the bitmap the engine paints is orientation-APPLIED, so the size we
    // persist must be too. This asserts it against the REAL browser rather
    // than against our own arithmetic.
    //
    // It only proves it for whatever browser runs this file — in practice
    // Chrome/Blink. WebKit is the primary target and takes a different decode
    // path (no `ImageDecoder`), and this harness cannot run there. See the
    // on-device checklist in `image_dimensions_web.dart`.
    test('agrees with what this browser actually decodes (Chrome-only proof)',
        () async {
      for (final (orientation, expectW, expectH) in <(int, int, int)>[
        (1, 400, 200),
        (3, 400, 200),
        (6, 200, 400),
        (8, 200, 400),
      ]) {
        final bytes = withExif(encodeSolidJpg(400, 200), orientation);

        final ours =
            await decodeImageSize(XFile.fromData(bytes, name: 'a.jpg'));

        final blob = web.Blob(<web.BlobPart>[bytes.toJS].toJS);
        final bitmap = await web.window.createImageBitmap(blob).toDart;
        final browser = (bitmap.width, bitmap.height);
        bitmap.close();

        expect((ours.width.toInt(), ours.height.toInt()), (expectW, expectH),
            reason: 'our size for Orientation=$orientation');
        expect(browser, (expectW, expectH),
            reason: 'createImageBitmap size for Orientation=$orientation');
      }
    });
  });
}

/// Long/short edge of an encoded image, decoded with `package:image` purely so
/// the assertions above can read the result back.
({int longEdge, int shortEdge}) readSize(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  expect(decoded, isNotNull);
  return decoded!.width >= decoded.height
      ? (longEdge: decoded.width, shortEdge: decoded.height)
      : (longEdge: decoded.height, shortEdge: decoded.width);
}
