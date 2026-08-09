import 'dart:js_interop';
import 'dart:typed_data';
import 'dart:ui';

import 'package:image_picker/image_picker.dart';
import 'package:web/web.dart' as web;

import 'image_header_size.dart';

/// Web pixel-dimension probe for a picked photo.
///
/// Reads the intrinsic size out of the file's own header via [readImageHeader]
/// — a bounded walk of JPEG markers / PNG+GIF+WebP fixed offsets that allocates
/// nothing proportional to the pixel count. It replaces two much more expensive
/// probes, in this order:
///
///  1. Originally, `createImageBitmap` on the whole file purely to read two
///     integers: ~98 MB of RGBA for a 24.5 MP photo, materialised and thrown
///     away during topo CREATION — the least recoverable moment to lose the
///     session on a memory-constrained iPhone Safari PWA.
///  2. Then `package:image`'s `findDecoderForData(...).startDecode(...)`, which
///     reads as a header call but is not one: for JPEG it allocates the full
///     DCT block grid (measured on a real 4032x3024 file: ~70 MB of Int32,
///     ~100 MB RSS, 155 ms SYNCHRONOUS on the main thread) — 1.5x WORSE than
///     the bitmap it replaced, and on the Dart/wasm heap, which never shrinks
///     back, instead of browser image memory that `bitmap.close()` frees.
///
/// The header scan costs neither. See `image_header_size.dart` for why it is
/// hand-rolled, and why WebCodecs `ImageDecoder` — which would report display
/// dimensions and moot the orientation reasoning below — is not the primary
/// path (WebKit does not implement it, and WebKit is the primary target).
///
/// ## EXIF orientation is applied, and rests on ONE assumption
///
/// The header reports the RAW STORED size, but every consumer of this value
/// sees the ORIENTED image, so an `Orientation` of 5..8 transposes the pair.
/// The assumption underneath that is: **the bitmap Flutter's web engine paints
/// for this photo is orientation-APPLIED.**
///
/// Evidence for it (measured in headless Chrome, against a 40x20 JPEG tagged
/// `Orientation=6`, header 40x20): `createImageBitmap` with default options
/// and with every explicit `imageOrientation` value, `<img>.naturalWidth/
/// Height`, and WebCodecs `ImageDecoder`'s display size ALL report 20x40. The
/// engine path matters most — Flutter decodes through `ImageDecoder` and reads
/// `displayWidth`/`displayHeight`, not `codedWidth`/`codedHeight`
/// (`canvaskit/image_web_codecs.dart`, `skwasm_impl/codecs.dart`).
///
/// **MUST STILL BE VERIFIED ON WEBKIT — this is the gap.** All of the above was
/// measured in Chrome/Blink; the primary target is an installed iPhone Safari
/// PWA, where the engine takes a DIFFERENT decode path because WebKit ships no
/// `ImageDecoder` (it falls back to `createImageBitmap`/`<img>`). If Safari
/// disagreed, every rotated photo would store transposed dimensions and every
/// route line drawn on it would be skewed by the aspect ratio. To close it, on
/// a real iPhone (Safari tab AND home-screen PWA, they can differ):
///
///  1. Import a portrait photo taken with the phone held sideways, i.e. one
///     whose EXIF `Orientation` is 6 or 8 (iOS writes these routinely).
///  2. Read back the `Photos` row's `width`/`height` and confirm the pair
///     matches what the topo canvas paints — portrait stays portrait.
///  3. Draw a route line across the photo, reload, and confirm it lands where
///     it was drawn (a transposed size shows up as a proportional skew, not as
///     a wrong-looking image).
///
/// If step 2 comes back transposed, the fix is local: stop applying
/// `ImageHeaderInfo.swapsAxes` here and return the stored pair. Nothing else in
/// the pipeline reads the orientation tag.
///
/// Falls back to the original full `createImageBitmap` decode for anything the
/// scanner cannot parse — HEIC above all, which iOS can still hand us and which
/// no pure-Dart decoder in this build understands.
///
/// Wasm-clean: `dart:js_interop` + `package:web` for the fallback, and an
/// import-free pure-Dart scanner for the fast path.
Future<Size> decodeImageSize(XFile xfile) async {
  final bytes = await xfile.readAsBytes();
  final header = readImageHeader(bytes);
  if (header != null) {
    return Size(
      header.orientedWidth.toDouble(),
      header.orientedHeight.toDouble(),
    );
  }
  return _sizeByFullDecode(bytes);
}

/// The original full-decode probe, kept verbatim as the fallback for formats
/// with no header this build can read (HEIC). Deliberately left on
/// `createImageBitmap`'s DEFAULT options rather than pinning
/// `imageOrientation: 'from-image'`: the default already is `from-image` per
/// spec (and measurably so in Chrome — see [decodeImageSize]), while an
/// explicit enum value is the one thing an older WebKit could reject outright
/// with a `TypeError`, and this is the path iOS's own HEIC photos land on.
Future<Size> _sizeByFullDecode(Uint8List bytes) async {
  final blob = web.Blob(<web.BlobPart>[bytes.toJS].toJS);
  final bitmap = await web.window.createImageBitmap(blob).toDart;
  final size = Size(bitmap.width.toDouble(), bitmap.height.toDouble());
  bitmap.close();
  return size;
}
