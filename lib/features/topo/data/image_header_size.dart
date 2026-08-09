/// A bounded, ZERO-ALLOCATION scan of an image file's HEADER.
///
/// This exists because reading two integers out of a photo used to cost the
/// whole photo. Both earlier approaches were pathological on the primary
/// target (an installed iPhone Safari PWA, during topo CREATION — the least
/// recoverable moment to lose the session):
///
///  * `createImageBitmap` on the full file materialised the entire RGBA
///    surface — ~98 MB for a 24.5 MP photo — purely to read `.width`/`.height`.
///  * `package:image`'s `findDecoderForData(bytes)?.startDecode(bytes)` is NOT
///    a header read despite its name: for JPEG it reaches
///    `JpegData.readInfo → _readFrame → JpegFrame.prepare()`, which allocates
///    the full DCT block grid up front. Measured on a real 4032x3024 / 9.2 MB
///    JPEG: 285,768 `Int32List(64)` objects, ~70 MB of Int32 payload, ~100 MB
///    RSS delta and **155 ms synchronous on the main thread** — and worse in
///    kind than the bitmap, because it lands on the Dart/wasm heap, which
///    never shrinks back, rather than in browser image memory that
///    `bitmap.close()` frees immediately.
///
/// So the scan is hand-rolled here instead. It walks container markers with a
/// fixed number of small integer reads, allocates nothing whose size depends
/// on the image's pixel count (nothing at all beyond the returned record), and
/// touches only the first few kilobytes of a typical file.
///
/// ## Why not WebCodecs `ImageDecoder`
///
/// `ImageDecoder`'s `tracks[0].displayWidth/displayHeight` would also answer
/// the question, and would report DISPLAY dimensions, removing the EXIF
/// reasoning below entirely. It is not the primary path because **WebKit does
/// not implement `ImageDecoder`** — iPhone Safari, standalone PWA included, is
/// exactly the platform this app is optimised for, so a Chrome-only fast path
/// would leave the target device on the slow one. A marker scan works
/// everywhere and needs no feature detection.
///
/// ## Why only these four containers
///
/// [ImageContainer] deliberately enumerates JPEG/PNG/GIF/WebP and nothing
/// else: those are the raster formats every browser can actually render.
/// `package:image` additionally "recognises" PSD, EXR, TGA, PVR, PNM, BMP,
/// TIFF and ICO — recognising them is worse than useless here, because a
/// caller that treats "recognised" as "renderable" will happily hand those
/// bytes onward to a browser that cannot draw them. A `null` from
/// [readImageHeader] means "ask the browser", which is the correct and safe
/// answer for HEIC (iOS's own camera format, which nothing in this build can
/// parse) as much as for a PSD.
///
/// Platform-free by construction: `dart:typed_data` is the only import, so
/// this runs identically on the VM, dart2js and wasm — and, unlike everything
/// else in the web photo pipeline, it is directly unit-testable under a plain
/// `flutter test`.
library;

import 'dart:typed_data';

/// The raster containers this scanner understands — i.e. exactly the ones a
/// browser can be relied on to decode. See the library doc for why the list is
/// deliberately short.
enum ImageContainer { jpeg, png, gif, webp }

/// What a header scan can tell us about an image without decoding it.
final class ImageHeaderInfo {
  const ImageHeaderInfo({
    required this.container,
    required this.width,
    required this.height,
    this.orientation,
  });

  /// The container the magic bytes identified.
  final ImageContainer container;

  /// The RAW STORED width, exactly as the container's header records it —
  /// before any EXIF orientation is applied. See [orientedWidth].
  final int width;

  /// The RAW STORED height. See [orientedHeight].
  final int height;

  /// The EXIF `Orientation` tag (1..8) when the file carries a readable one,
  /// otherwise `null`.
  ///
  /// `null` MUST be read as "don't know", never as "1": the only safe response
  /// to an unreadable tag is to leave the stored axes alone, since inventing a
  /// transpose would rotate a correctly-sized photo.
  final int? orientation;

  /// Whether [orientation] is one of the four values that TRANSPOSE the image
  /// — 5..8, the 90°/270° rotations and their mirrored twins. 1..4 (identity,
  /// the two mirrors, 180°) leave the axes as stored.
  bool get swapsAxes {
    final o = orientation;
    return o != null && o >= 5 && o <= 8;
  }

  /// Width as a viewer sees it, i.e. after EXIF orientation.
  int get orientedWidth => swapsAxes ? height : width;

  /// Height as a viewer sees it, i.e. after EXIF orientation.
  int get orientedHeight => swapsAxes ? width : height;

  /// The larger stored axis. Orientation-INVARIANT (EXIF can only ever swap
  /// the two axes), so it is safe to ask without knowing [orientation].
  int get longEdge => width >= height ? width : height;

  /// The smaller stored axis. Orientation-invariant, as [longEdge].
  int get shortEdge => width >= height ? height : width;
}

/// [bytes]'s container, stored pixel dimensions and (JPEG only) EXIF
/// orientation, read from the header alone — or `null` when [bytes] is not one
/// of the four containers in [ImageContainer], is truncated before its size
/// fields, or claims a nonsense size.
///
/// Never throws, and never guesses: every ambiguous input resolves to `null`,
/// because a wrong size here is persisted into `Photos.width`/`height` and
/// silently skews every route line drawn on the photo. `null` is the caller's
/// signal to fall back to a real browser decode.
ImageHeaderInfo? readImageHeader(Uint8List bytes) {
  if (bytes.length < 12) return null;
  if (bytes[0] == 0xFF && bytes[1] == 0xD8) return _scanJpeg(bytes);
  if (_matches(bytes, 0, const <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) {
    return _scanPng(bytes);
  }
  if (_matches(bytes, 0, const <int>[0x47, 0x49, 0x46, 0x38])) return _scanGif(bytes);
  if (_matches(bytes, 0, const <int>[0x52, 0x49, 0x46, 0x46]) &&
      _matches(bytes, 8, const <int>[0x57, 0x45, 0x42, 0x50])) {
    return _scanWebp(bytes);
  }
  return null;
}

bool _matches(Uint8List b, int at, List<int> magic) {
  if (at + magic.length > b.length) return false;
  for (var i = 0; i < magic.length; i++) {
    if (b[at + i] != magic[i]) return false;
  }
  return true;
}

/// Big-endian u16. Callers bounds-check first.
int _be16(Uint8List b, int o) => (b[o] << 8) | b[o + 1];

/// Big-endian u32, built with MULTIPLICATION rather than `<< 24` on purpose:
/// on dart2js `int` is a JS number and `<<` is 32-bit *signed*, so
/// `0xFF << 24` is negative there. Multiplication is exact and identical on
/// the VM, dart2js and wasm.
int _be32(Uint8List b, int o) =>
    b[o] * 0x1000000 + b[o + 1] * 0x10000 + b[o + 2] * 0x100 + b[o + 3];

/// Little-endian u32; see [_be32] for why this multiplies.
int _le32(Uint8List b, int o) =>
    b[o] + b[o + 1] * 0x100 + b[o + 2] * 0x10000 + b[o + 3] * 0x1000000;

/// JPEG: walk the marker chain from SOI to the first SOFn, collecting the
/// EXIF `Orientation` from APP1 along the way.
///
/// Every step is a jump of `length` bytes to the next marker — the entropy-
/// coded scan data is never entered (the walk stops at SOS), and nothing
/// proportional to the image is allocated. This is the ~14 ms → sub-millisecond
/// replacement for `startDecode`'s 155 ms block-grid allocation.
ImageHeaderInfo? _scanJpeg(Uint8List b) {
  final n = b.length;
  int? width;
  int? height;
  int? orientation;

  var i = 2; // past SOI
  while (i + 1 < n) {
    if (b[i] != 0xFF) {
      // Not on a marker boundary. A well-formed header never lands here, but
      // resyncing beats bailing out on a file with a stray padding byte.
      i++;
      continue;
    }
    // 0xFF may be repeated as fill before the marker code.
    var j = i + 1;
    while (j < n && b[j] == 0xFF) {
      j++;
    }
    if (j >= n) break;
    final marker = b[j];
    i = j + 1;

    // Standalone markers carry no length segment: TEM (0x01), RSTn (0xD0..D7),
    // SOI (0xD8), EOI (0xD9).
    if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD8)) continue;
    if (marker == 0xD9) break; // EOI
    if (marker == 0xDA) break; // SOS — entropy data follows, stop scanning.

    if (i + 1 >= n) break;
    final len = _be16(b, i);
    if (len < 2) break; // malformed
    final segStart = i + 2;
    final segEnd = i + len; // exclusive
    if (segEnd > n) break; // truncated segment

    if (width == null && _isStartOfFrame(marker)) {
      // SOFn payload: precision(1) height(2) width(2) components(1) ...
      if (segEnd - segStart >= 5) {
        height = _be16(b, segStart + 1);
        width = _be16(b, segStart + 3);
      }
    } else if (marker == 0xE1 && orientation == null) {
      orientation = _exifOrientation(b, segStart, segEnd);
    }

    // A well-formed file puts APP1 before SOFn, so this normally exits at the
    // frame header having already seen the orientation.
    if (width != null && orientation != null) break;
    i = segEnd;
  }

  if (width == null || height == null || width <= 0 || height <= 0) return null;
  return ImageHeaderInfo(
    container: ImageContainer.jpeg,
    width: width,
    height: height,
    orientation: orientation,
  );
}

/// SOF0..SOF15 — every frame header, baseline and progressive alike — minus
/// the three codes in that range that mean something else: DHT (0xC4), JPG
/// (0xC8, reserved) and DAC (0xCC).
bool _isStartOfFrame(int marker) =>
    marker >= 0xC0 &&
    marker <= 0xCF &&
    marker != 0xC4 &&
    marker != 0xC8 &&
    marker != 0xCC;

/// The EXIF `Orientation` (0x0112) value inside the APP1 segment spanning
/// `[start, end)`, or `null` for anything unreadable.
///
/// Bounded twice over: it can only ever read inside the segment it was handed,
/// and it refuses an IFD claiming an implausible entry count rather than
/// walking wherever a corrupt file points it.
int? _exifOrientation(Uint8List b, int start, int end) {
  // "Exif\0\0" identifier, then an 8-byte TIFF header.
  if (end - start < 6 + 8) return null;
  if (!_matches(b, start, const <int>[0x45, 0x78, 0x69, 0x66, 0x00, 0x00])) {
    return null;
  }
  final t = start + 6; // TIFF header origin; all offsets are relative to it.
  final bool little;
  if (b[t] == 0x49 && b[t + 1] == 0x49) {
    little = true;
  } else if (b[t] == 0x4D && b[t + 1] == 0x4D) {
    little = false;
  } else {
    return null;
  }
  int u16(int o) => little ? (b[o] | (b[o + 1] << 8)) : _be16(b, o);
  int u32(int o) => little ? _le32(b, o) : _be32(b, o);

  if (u16(t + 2) != 42) return null; // TIFF magic
  final ifd0 = t + u32(t + 4);
  if (ifd0 < t || ifd0 + 2 > end) return null;
  final entries = u16(ifd0);
  // IFD0 realistically holds a few dozen tags; anything wilder is corruption.
  if (entries <= 0 || entries > 512) return null;
  for (var k = 0; k < entries; k++) {
    final e = ifd0 + 2 + k * 12;
    if (e + 12 > end) return null;
    if (u16(e) != 0x0112) continue;
    if (u16(e + 2) != 3) return null; // must be SHORT
    final value = u16(e + 8); // fits in the inline value field
    return (value >= 1 && value <= 8) ? value : null;
  }
  return null;
}

/// PNG: the IHDR chunk is at a FIXED offset — 8-byte signature, 4-byte length,
/// `IHDR`, then width and height as big-endian u32. Two reads, no walk.
///
/// No orientation is reported: the `eXIf` chunk exists but is vanishingly rare
/// in practice, and PNG's own spec has no rotation concept, so `null`
/// ("don't know" → don't transpose) is both the honest and the safe answer.
ImageHeaderInfo? _scanPng(Uint8List b) {
  if (b.length < 24) return null;
  if (!_matches(b, 12, const <int>[0x49, 0x48, 0x44, 0x52])) return null; // IHDR
  final width = _be32(b, 16);
  final height = _be32(b, 20);
  if (width <= 0 || height <= 0) return null;
  return ImageHeaderInfo(
    container: ImageContainer.png,
    width: width,
    height: height,
  );
}

/// GIF: the logical screen descriptor sits immediately after the 6-byte
/// signature — width and height as little-endian u16.
ImageHeaderInfo? _scanGif(Uint8List b) {
  if (b.length < 10) return null;
  // 'GIF87a' / 'GIF89a' — byte 4 is '7' or '9', byte 5 is 'a'.
  if ((b[4] != 0x37 && b[4] != 0x39) || b[5] != 0x61) return null;
  final width = b[6] | (b[7] << 8);
  final height = b[8] | (b[9] << 8);
  if (width <= 0 || height <= 0) return null;
  return ImageHeaderInfo(
    container: ImageContainer.gif,
    width: width,
    height: height,
  );
}

/// WebP: a RIFF container whose FIRST chunk names the variant — `VP8 ` (lossy),
/// `VP8L` (lossless) or `VP8X` (extended, which carries the canvas size
/// directly). All three keep their dimensions within the first 30 bytes.
ImageHeaderInfo? _scanWebp(Uint8List b) {
  if (b.length < 30) return null;
  int? width;
  int? height;

  if (_matches(b, 12, const <int>[0x56, 0x50, 0x38, 0x20])) {
    // 'VP8 ': keyframe payload at 20 — 3-byte frame tag, then the sync code.
    if (b[23] == 0x9D && b[24] == 0x01 && b[25] == 0x2A) {
      width = (b[26] | (b[27] << 8)) & 0x3FFF;
      height = (b[28] | (b[29] << 8)) & 0x3FFF;
    }
  } else if (_matches(b, 12, const <int>[0x56, 0x50, 0x38, 0x4C])) {
    // 'VP8L': 0x2F signature, then 14 bits of (width-1) and 14 of (height-1).
    if (b[20] == 0x2F) {
      final bits = _le32(b, 21);
      width = (bits % 0x4000) + 1;
      height = ((bits ~/ 0x4000) % 0x4000) + 1;
    }
  } else if (_matches(b, 12, const <int>[0x56, 0x50, 0x38, 0x58])) {
    // 'VP8X': 4 flag bytes, then canvas (width-1) and (height-1) as 24-bit LE.
    width = (b[24] | (b[25] << 8) | (b[26] << 16)) + 1;
    height = (b[27] | (b[28] << 8) | (b[29] << 16)) + 1;
  }

  if (width == null || height == null || width <= 0 || height <= 0) return null;
  return ImageHeaderInfo(
    container: ImageContainer.webp,
    width: width,
    height: height,
  );
}
