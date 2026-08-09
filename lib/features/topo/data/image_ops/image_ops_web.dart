import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import '../image_header_size.dart';

/// Web thumbnail generation — runs the decode/resize/encode on the browser's
/// offscreen canvas instead of pure-Dart `package:image`, since `compute()`
/// is a no-op on web and a large-photo decode/resize in pure Dart would
/// freeze the UI thread. Wasm-clean: built only on `dart:js_interop` +
/// `package:web` bindings plus an import-free header scanner — the legacy
/// browser-interop libraries are intentionally unused.
///
/// Two things keep the FULL-resolution bitmap from ever being materialised
/// for a photo that is only going to be shrunk to [maxEdge] anyway (a 24.5 MP
/// import used to cost ~98 MB of RGBA here, on the main thread, at the same
/// moment the topo itself was being created):
///
///  1. The intrinsic size comes from [srcSize] when the caller already probed
///     it, and otherwise from a bounded, zero-allocation header scan
///     ([readImageHeader]) — so an already-small source returns untouched with
///     no decode at all.
///  2. When the size proves the source is bigger than we want, the decode
///     itself is asked to downsample, via `ImageBitmapOptions.resizeWidth`.
///
/// The resize is a HINT, not a contract: an engine that ignores it (WebKit
/// gives no guarantee) simply hands back the full-size bitmap and the canvas
/// step below scales it down exactly as it always did. Everything after the
/// decode is therefore driven by the bitmap's OWN dimensions, never by what
/// was asked for.
///
/// [srcSize] lets an import probe the file ONCE instead of twice: the callers
/// that reach here from a photo import (`topo_canvas_screen`/`topos_screen` →
/// `decodeImageSize` → `PhotoFiles.importPhoto`) already hold [src]'s
/// dimensions, and re-deriving them here is pure duplication. It is accepted
/// as a plain record rather than a `Size` so the native and stub backends can
/// mirror the signature without pulling in `dart:ui`, and it may carry EITHER
/// the stored or the EXIF-oriented pair — only the long/short edge is read from
/// it, and orientation can only ever swap those two.
///
/// TODO(perf): nothing in `lib/` passes [srcSize] yet — threading it end to end
/// needs four more files that were outside this change's scope:
/// `image_ops_native.dart` + `image_ops_stub.dart` (same optional parameter, so
/// the conditional-export facade stays coherent), then `PhotoFiles.importPhoto`
/// / `writePhotoBytes` (`photo_files_web.dart`, `photo_files_native.dart`) and
/// finally the two import screens that already call `decodeImageSize`. Until
/// then the second probe still happens — but it now costs a bounded header scan
/// (measured 33 us and ZERO bytes of heap on a 4032x3024 JPEG, against 86 ms
/// and +150 MB for the `package:image` `startDecode` it replaced), so this is a
/// tidiness item, not a performance one.
Future<Uint8List> generateThumbnail(
  Uint8List src, {
  int maxEdge = 512,
  int quality = 80,
  ({int width, int height})? srcSize,
}) async {
  // Scan only when the caller could not already tell us.
  //
  // A NON-NULL `edges` carries two facts, and the second one is the
  // load-bearing one: the dimensions, AND that these bytes are in a container
  // the browser can actually render. [readImageHeader] only ever recognises
  // JPEG/PNG/GIF/WebP for exactly that reason, and a caller-supplied [srcSize]
  // carries the same guarantee because its only producer is `decodeImageSize`,
  // which returns a size only after EITHER recognising one of those four
  // containers OR successfully running `createImageBitmap`.
  //
  // The long/short edge pair is orientation-INVARIANT (EXIF can only ever swap
  // the two axes), which is why neither of the two decisions made from it
  // needs to know the orientation the browser is about to apply.
  final ({int longEdge, int shortEdge})? edges;
  if (srcSize != null) {
    edges = srcSize.width >= srcSize.height
        ? (longEdge: srcSize.width, shortEdge: srcSize.height)
        : (longEdge: srcSize.height, shortEdge: srcSize.width);
  } else {
    final header = readImageHeader(src);
    edges = header == null
        ? null
        : (longEdge: header.longEdge, shortEdge: header.shortEdge);
  }

  // Cheapest possible answer: the size already proves it's small enough, so
  // return the source without decoding anything.
  //
  // Reachable ONLY for a renderable container, per the note above, and that
  // gate is the whole point of scanning for a container rather than asking a
  // decoder library what it "recognises": `package:image` also recognises PSD,
  // EXR, TGA, PVR, PNM and ICO, none of which a browser can draw. Returning
  // those bytes here would write a second full-size copy of an undisplayable
  // file under the thumbnail key, doubling its cost against the user's storage
  // quota — whereas falling through leaves `createImageBitmap` to throw, which
  // the caller's best-effort wrapper already handles by simply not writing a
  // thumbnail.
  if (edges != null && edges.longEdge <= maxEdge) {
    return src; // already small enough
  }

  final blob = web.Blob(<web.BlobPart>[src.toJS].toJS);

  // Only hint a downsample when BOTH dimensions exceed [maxEdge].
  // That single condition is what makes constraining the width alone safe
  // without knowing the EXIF orientation: whichever axis ends up as the
  // bitmap's width, it was larger than [maxEdge], so the hint can only ever
  // scale DOWN (a hint on a shorter-than-maxEdge axis would UPSCALE, costing
  // more memory than not hinting at all), and the other axis shrinks by the
  // same factor while staying comfortably above 1px for any real photo.
  // Width alone, never both: `resizeWidth` + `resizeHeight` together are
  // exact dimensions, not a bounding box, so passing both would stretch a
  // rotated photo's thumbnail.
  final hinted = edges != null && edges.shortEdge > maxEdge;
  final bitmap = await (hinted
          ? web.window.createImageBitmap(
              blob,
              web.ImageBitmapOptions(resizeWidth: maxEdge),
            )
          : web.window.createImageBitmap(blob))
      .toDart;

  final width = bitmap.width;
  final height = bitmap.height;
  final bitmapLongEdge = width >= height ? width : height;

  // Unhinted only. If the hint WAS applied, a bitmap at/below [maxEdge] is the
  // downsample working as intended — returning `src` there would hand back the
  // multi-megabyte original as the "thumbnail".
  if (!hinted && bitmapLongEdge <= maxEdge) {
    bitmap.close();
    return src; // already small enough
  }

  final scale = bitmapLongEdge > maxEdge ? maxEdge / bitmapLongEdge : 1.0;
  final targetWidth = (width * scale).round();
  final targetHeight = (height * scale).round();

  final canvas = web.OffscreenCanvas(targetWidth, targetHeight);
  final ctx = canvas.getContext('2d') as web.OffscreenCanvasRenderingContext2D;
  ctx.drawImage(bitmap, 0, 0, targetWidth, targetHeight);
  bitmap.close();

  final outBlob = await canvas
      .convertToBlob(
        web.ImageEncodeOptions(type: 'image/jpeg', quality: quality / 100),
      )
      .toDart;
  final buffer = await outBlob.arrayBuffer().toDart;
  return buffer.toDart.asUint8List();
}
