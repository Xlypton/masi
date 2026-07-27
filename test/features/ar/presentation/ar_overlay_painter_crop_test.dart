// Pixel-level tests proving the AR ghost `outline` is actually CROPPED to
// the rock region (Task 3b — see the class docs on `ArOverlayPainter.rockMask`
// / `ArOverlayPainter.cropBox`), rather than merely asserting on recorded
// `Canvas` method calls.
//
// Real render-to-image, in a REAL async context (plain `test()`, not
// `fake_async`/`testWidgets` + fake-time `pump()`): `ui.decodeImageFromPixels`
// and `Picture.toImage` are genuine engine-level async work that only
// progresses on a real event loop -- mirroring the existing
// `ar_overlay_painter_test.dart`'s own `_createTinyImage` helper, which
// already awaits a real `ui.decodeImageFromPixels` inside a plain `test()`
// (not `testWidgets`) successfully.
//
// Deliberately built from raw RGBA bytes only (never a real JPEG/PNG asset
// decode -- that hangs under this suite's tooling).
import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:masi/features/ar/domain/homography.dart';
import 'package:masi/features/ar/presentation/ar_overlay_painter.dart';

/// A fully opaque `size`x`size` white image, used as the ghost `outline`
/// stand-in: any pixel where it ends up painted should read back with the
/// saveLayer's ~45% alpha; anywhere cropped away should read back as fully
/// transparent.
Future<ui.Image> _opaqueWhiteImage(int size) {
  final completer = Completer<ui.Image>();
  final bytes = Uint8List(size * size * 4);
  for (var i = 0; i < size * size; i++) {
    final o = i * 4;
    bytes[o] = 0xFF;
    bytes[o + 1] = 0xFF;
    bytes[o + 2] = 0xFF;
    bytes[o + 3] = 0xFF;
  }
  ui.decodeImageFromPixels(bytes, size, size, ui.PixelFormat.rgba8888, completer.complete);
  return completer.future;
}

/// A `size`x`size` rock-silhouette mask whose LEFT half (`x < size/2`) is
/// fully opaque (alpha 255) and whose RIGHT half is fully transparent (alpha
/// 0) -- mirrors the paint-ready mask shape `decodeRockMaskAlpha` produces
/// (constant tint RGB, per-texel alpha carrying the silhouette).
Future<ui.Image> _halfMaskImage(int size) {
  final completer = Completer<ui.Image>();
  final bytes = Uint8List(size * size * 4);
  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      final i = (y * size + x) * 4;
      bytes[i] = 0x00;
      bytes[i + 1] = 0xE5;
      bytes[i + 2] = 0xFF;
      bytes[i + 3] = x < size / 2 ? 0xFF : 0x00;
    }
  }
  ui.decodeImageFromPixels(bytes, size, size, ui.PixelFormat.rgba8888, completer.complete);
  return completer.future;
}

/// Paints [painter] into a real `size`x`size` raster and returns its pixels
/// as straight (non-premultiplied) RGBA, so the alpha byte at any pixel can
/// be read directly.
Future<ByteData> _renderStraightRgba(ArOverlayPainter painter, int size) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  painter.paint(canvas, Size(size.toDouble(), size.toDouble()));
  final picture = recorder.endRecording();
  final image = await picture.toImage(size, size);
  final data = await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
  expect(data, isNotNull);
  return data!;
}

/// The alpha byte (0-255) at pixel ([x], [y]) of a straight-RGBA [data]
/// buffer of a `size`x`size` image.
int _alphaAt(ByteData data, int size, int x, int y) {
  final i = (y * size + x) * 4;
  return data.getUint8(i + 3);
}

/// The green byte (0-255) at pixel ([x], [y]) of a straight-RGBA [data]
/// buffer of a `size`x`size` image.
int _greenAt(ByteData data, int size, int x, int y) {
  final i = (y * size + x) * 4;
  return data.getUint8(i + 1);
}

/// The blue byte (0-255) at pixel ([x], [y]) of a straight-RGBA [data]
/// buffer of a `size`x`size` image.
int _blueAt(ByteData data, int size, int x, int y) {
  final i = (y * size + x) * 4;
  return data.getUint8(i + 2);
}

void main() {
  const size = 16;
  const refSize = Size(16, 16);
  const palette = [Colors.green];

  test(
    'Case A (cropBox, no rockMask): the ghost is clipped to the crop '
    'rectangle -- present on the LEFT half, absent on the RIGHT',
    () async {
      final outline = await _opaqueWhiteImage(size);
      final painter = ArOverlayPainter(
        routes: const [],
        refSize: refSize,
        homography: Homography.identity(),
        palette: palette,
        outline: outline,
        rockMask: null,
        cropBox: const Rect.fromLTRB(0, 0, 0.5, 1.0),
      );

      final data = await _renderStraightRgba(painter, size);

      final leftAlpha = _alphaAt(data, size, 4, 8);
      final rightAlpha = _alphaAt(data, size, 12, 8);

      // ~45% of 255 (the saveLayer's 0x73 alpha) -- generously bounded to
      // tolerate rounding/antialiasing.
      expect(leftAlpha, greaterThan(40));
      expect(rightAlpha, lessThanOrEqualTo(5));
    },
  );

  test(
    'Case B (rockMask, no cropBox): the ghost is clipped to the per-pixel '
    'silhouette -- present where the mask is opaque, absent where it is not',
    () async {
      final outline = await _opaqueWhiteImage(size);
      final mask = await _halfMaskImage(size);
      final painter = ArOverlayPainter(
        routes: const [],
        refSize: refSize,
        homography: Homography.identity(),
        palette: palette,
        outline: outline,
        rockMask: mask,
        cropBox: null,
      );

      final data = await _renderStraightRgba(painter, size);

      final leftAlpha = _alphaAt(data, size, 4, 8);
      final rightAlpha = _alphaAt(data, size, 12, 8);

      expect(leftAlpha, greaterThan(40));
      expect(rightAlpha, lessThanOrEqualTo(5));
    },
  );

  test(
    'Case C (neither rockMask nor cropBox): unchanged fallback behavior -- '
    'the ghost still covers the WHOLE frame',
    () async {
      final outline = await _opaqueWhiteImage(size);
      final painter = ArOverlayPainter(
        routes: const [],
        refSize: refSize,
        homography: Homography.identity(),
        palette: palette,
        outline: outline,
        rockMask: null,
        cropBox: null,
      );

      final data = await _renderStraightRgba(painter, size);

      final leftAlpha = _alphaAt(data, size, 4, 8);
      final rightAlpha = _alphaAt(data, size, 12, 8);

      expect(leftAlpha, greaterThan(40));
      expect(rightAlpha, greaterThan(40));
    },
  );

  test(
    'rockMask takes precedence over cropBox when both are provided',
    () async {
      final outline = await _opaqueWhiteImage(size);
      final mask = await _halfMaskImage(size);
      // A cropBox that would (if honored) restrict to the right half --
      // opposite of the mask's left half -- so this proves the mask wins.
      final painter = ArOverlayPainter(
        routes: const [],
        refSize: refSize,
        homography: Homography.identity(),
        palette: palette,
        outline: outline,
        rockMask: mask,
        cropBox: const Rect.fromLTRB(0.5, 0, 1.0, 1.0),
      );

      final data = await _renderStraightRgba(painter, size);

      final leftAlpha = _alphaAt(data, size, 4, 8);
      final rightAlpha = _alphaAt(data, size, 12, 8);

      // Mask says LEFT is the rock -- if cropBox had won, this would be
      // reversed (left absent, right present).
      expect(leftAlpha, greaterThan(40));
      expect(rightAlpha, lessThanOrEqualTo(5));
    },
  );

  group('rock silhouette highlight', () {
    test(
      'highlight-on + mask present: the mask silhouette is drawn (follows '
      'the mask shape, not a bounding rectangle) -- cyan tint on the LEFT '
      'half where the mask is opaque, untouched on the RIGHT half where it '
      "isn't",
      () async {
        final mask = await _halfMaskImage(size);
        final painter = ArOverlayPainter(
          routes: const [],
          refSize: refSize,
          homography: Homography.identity(),
          palette: palette,
          outline: null,
          rockBox: const Rect.fromLTRB(0, 0, 1, 1),
          rockMask: mask,
        );

        final data = await _renderStraightRgba(painter, size);

        final leftAlpha = _alphaAt(data, size, 4, 8);
        final leftGreen = _greenAt(data, size, 4, 8);
        final leftBlue = _blueAt(data, size, 4, 8);
        final rightAlpha = _alphaAt(data, size, 12, 8);

        // ~40% of 255 (the silhouette saveLayer's 0x66 alpha) -- generously
        // bounded to tolerate rounding/antialiasing.
        expect(leftAlpha, greaterThan(20));
        expect(leftGreen, greaterThan(0));
        expect(leftBlue, greaterThan(0));
        expect(rightAlpha, lessThanOrEqualTo(5));
      },
    );

    test(
      'highlight-on + no mask: falls back to the cyan bounding-box rectangle '
      '-- both halves show cyan',
      () async {
        final painter = ArOverlayPainter(
          routes: const [],
          refSize: refSize,
          homography: Homography.identity(),
          palette: palette,
          outline: null,
          rockBox: const Rect.fromLTRB(0, 0, 1, 1),
          rockMask: null,
        );

        final data = await _renderStraightRgba(painter, size);

        final leftAlpha = _alphaAt(data, size, 4, 8);
        final rightAlpha = _alphaAt(data, size, 12, 8);

        expect(leftAlpha, greaterThan(20));
        expect(rightAlpha, greaterThan(20));
      },
    );
  });
}
