import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show compute;
import 'package:image/image.dart' as img;

import 'outline_shape.dart';

export 'outline_shape.dart';

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
///
/// Native (iOS/Android/desktop) implementation — real `dart:io` file read +
/// `package:image` decode + a `compute()` isolate hop. AR never runs on web
/// (see `lib/core/platform/ar_support.dart`), so the web variant of this
/// function is an inert no-op; see `outline_extractor_web.dart`.
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
