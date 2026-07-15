import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show compute;
import 'package:image/image.dart' as img;

/// Converts [src] into a sparse, transparent-background line drawing suitable
/// for an AR alignment overlay: opaque (solid [lineR]/[lineG]/[lineB], alpha
/// 255) exactly where a strong edge was detected, fully transparent (alpha 0)
/// everywhere else.
///
/// [src] is first downscaled (preserving aspect ratio, never upscaled) so its
/// larger side is at most [maxDim], converted to grayscale, blurred slightly
/// to suppress fine texture noise, then run through Sobel edge detection.
/// Each edge pixel's luminance/magnitude is compared against [threshold]: at
/// or below it the output pixel is fully transparent; above it the output
/// pixel is fully opaque in the requested line color. There are no partial
/// alphas, so flat/textured-but-weak regions are genuinely transparent (no
/// color wash) and only clean, strong edges survive (a sparse line drawing
/// rather than noisy fine detail). The returned RGBA image is the same size
/// as the (resized) edge map.
///
/// Pure and synchronous — does no file or platform I/O, and never mutates
/// [src] (resizing always produces an independent copy before any further
/// processing). Safe to run on a background isolate (see [extractOutline]).
img.Image outlineFromImage(
  img.Image src, {
  int maxDim = 800,
  int lineR = 0,
  int lineG = 0,
  int lineB = 0,
  int threshold = 60,
}) {
  final largerSide = src.width > src.height ? src.width : src.height;
  final scale = largerSide > maxDim ? maxDim / largerSide : 1.0;
  final targetWidth = (src.width * scale).round();

  // copyResize always returns a distinct Image (a clone when no resize is
  // actually needed), so `src` is never touched by the grayscale/blur/sobel
  // steps below.
  final resized = img.copyResize(src, width: targetWidth);
  final gray = img.grayscale(resized);
  // Blur before edge detection to suppress fine texture (rock grain, chalk
  // marks, etc.) so only genuine structural edges survive Sobel.
  final blurred = img.gaussianBlur(gray, radius: 2);
  final edges = img.sobel(blurred);

  final out = img.Image(
    width: edges.width,
    height: edges.height,
    numChannels: 4,
  );
  for (final p in edges) {
    final magnitude = p.luminance.round().clamp(0, 255);
    if (magnitude > threshold) {
      out.setPixelRgba(p.x, p.y, lineR, lineG, lineB, 255);
    } else {
      out.setPixelRgba(p.x, p.y, 0, 0, 0, 0);
    }
  }
  return out;
}

/// Arguments for [_computeOutlineBytes], passed across the `compute()`
/// isolate boundary. Every field is a plain, transferable type (a [String]
/// and an [int]), so this class crosses fine.
class _OutlineArgs {
  const _OutlineArgs(this.path, this.maxDim);

  final String path;
  final int maxDim;
}

/// The decoded-and-outlined result of [_computeOutlineBytes]: raw RGBA pixel
/// bytes plus the dimensions they're laid out at. [rgba] is a [Uint8List],
/// which — like the rest of this holder's fields — crosses the `compute()`
/// isolate boundary cheaply (transferable).
class _OutlineBytes {
  const _OutlineBytes(this.rgba, this.width, this.height);

  final Uint8List rgba;
  final int width;
  final int height;
}

/// Runs on a background isolate via [compute]: reads the image file at
/// [_OutlineArgs.path], decodes it, runs it through [outlineFromImage]
/// (downscaled so its larger side is at most [_OutlineArgs.maxDim]), and
/// returns the RGBA pixel bytes + dimensions. Returns `null` if the file
/// can't be read or decoded — never throws (any exception here would
/// otherwise crash the background isolate instead of surfacing to
/// [extractOutline]'s try/catch).
Future<_OutlineBytes?> _computeOutlineBytes(_OutlineArgs args) async {
  try {
    final bytes = await File(args.path).readAsBytes();
    final decoded = img.decodeImage(bytes);
    if (decoded == null) {
      return null;
    }
    final outline = outlineFromImage(decoded, maxDim: args.maxDim);
    final rgba = outline.getBytes(order: img.ChannelOrder.rgba);
    return _OutlineBytes(rgba, outline.width, outline.height);
  } catch (_) {
    return null;
  }
}

/// Reads the image file at [path], runs [outlineFromImage] on it (downscaled
/// so its larger side is at most [maxDim]), and returns the result decoded as
/// a [ui.Image] ready to paint.
///
/// The file read + decode + edge-detection work (all synchronous, CPU-heavy
/// pixel processing) runs off the main isolate via [compute], so it never
/// blocks UI/gesture handling while a large photo is being processed; only
/// the final [ui.decodeImageFromPixels] step (which must run on the isolate
/// that owns the Flutter engine) happens back on the calling isolate.
///
/// Never throws: any failure (missing file, unreadable/undecodable image
/// data) is swallowed and `null` is returned instead.
Future<ui.Image?> extractOutline(String path, {int maxDim = 800}) async {
  try {
    final res = await compute(_computeOutlineBytes, _OutlineArgs(path, maxDim));
    if (res == null) {
      return null;
    }

    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      res.rgba,
      res.width,
      res.height,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    return await completer.future;
  } catch (_) {
    return null;
  }
}
