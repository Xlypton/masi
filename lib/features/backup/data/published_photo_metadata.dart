/// Removes identifying metadata from a photo's bytes before the copy that goes
/// to the PUBLIC bucket (weakness W-1's sibling, W-3).
///
/// ## Why this exists
///
/// The picker deliberately asks for full metadata (`requestFullMetadata: true`)
/// because that is how a wall gets its coordinates — see
/// `extractGpsFromImageBytes`. That is correct for placing a topo, but the very
/// same bytes are then uploaded a SECOND time to `shared/<photoId><ext>` in a
/// world-readable bucket, EXIF and all.
///
/// The sharp edge is specific to this app rather than generic privacy hygiene:
/// a climber can deliberately publish a topo for an access-sensitive crag
/// WITHOUT coordinates, precisely so the location is not broadcast — and the
/// EXIF GPS IFD hands it over anyway. Camera serial numbers and capture
/// timestamps ride along too.
///
/// ## Why this is a byte-level rewrite and not a decode/re-encode
///
/// The obvious implementation — `decodeImage` then `encodeJpg` — was rejected
/// on three counts, each of which has already bitten this project once:
///
/// 1. **It is lossy.** Re-encoding recompresses the climber's photo. Decision
///    D-5 says the user's own photos are never silently degraded; publishing a
///    visibly worse copy than the one on the device is the same broken promise
///    wearing a different hat.
/// 2. **It blocks the main thread.** A multi-megapixel pure-Dart pixel decode
///    freezes the browser for hundreds of ms to seconds, with no worker isolate
///    on web to offload to. `photo_gps.dart` was rewritten away from exactly
///    that, for exactly that reason — see its doc.
/// 3. **It cannot run in a widget test.** Driving a real image-codec decode
///    hangs under fake-async (see CLAUDE.md), so a decode-based strip would be
///    untestable at the level that matters.
///
/// Walking the container's segment/chunk structure and dropping the metadata
/// blocks is lossless, costs one linear scan, touches no pixel, and is trivially
/// testable.
///
/// ## Orientation is preserved on purpose — do not "simplify" this away
///
/// **This app does not bake EXIF orientation into its stored pixels.** It
/// relies on the decoder honouring the Orientation tag at display time; there
/// is already a known import-time-prober-vs-display-time-decoder disagreement
/// that `TopoCanvas._effectiveImageSize` exists to absorb. So dropping APP1
/// wholesale — the one-line version of this function — would silently rotate
/// every published photo for every viewer, turning a privacy fix into a visible
/// data-corruption bug.
///
/// So: the Orientation tag is read before the strip, and if it is anything
/// other than "normal" a MINIMAL replacement APP1 carrying only that one tag is
/// synthesised (see [_buildOrientationOnlyApp1]). Nothing else survives.
///
/// Never throws. Anything it cannot confidently parse it returns UNCHANGED —
/// and callers must treat that as a refusal to publish, not as a success; see
/// [strippedForPublishing]'s return contract.
library;

import 'dart:typed_data';

/// The outcome of a strip attempt.
///
/// Deliberately not just `Uint8List` — "I could not parse this" and "there was
/// nothing to remove" produce identical bytes but must lead to opposite
/// decisions. Collapsing them is how a leak ships looking like a no-op.
enum PhotoStripOutcome {
  /// Metadata was found and removed. [PhotoStripResult.bytes] is safe to
  /// publish.
  stripped,

  /// Parsed cleanly; there was no metadata to remove. Safe to publish.
  alreadyClean,

  /// Not a container this code understands well enough to rewrite safely.
  /// The bytes are returned verbatim and **must not be published** — see
  /// [PhotoStripResult.isSafeToPublish].
  unsupportedFormat,

  /// A container that looked right but whose structure did not parse (truncated
  /// segment, bad length, garbage where a marker belongs). Same rule: **do not
  /// publish**.
  malformed,
}

/// What [strippedForPublishing] decided, and the bytes that go with it.
class PhotoStripResult {
  const PhotoStripResult(this.outcome, this.bytes);

  final PhotoStripOutcome outcome;

  /// The bytes to publish — but ONLY when [isSafeToPublish]. For the two
  /// failure outcomes these are the ORIGINAL, still-identifying bytes, returned
  /// so a caller can log their length or hash, never so it can upload them.
  final Uint8List bytes;

  /// Whether [bytes] may go to the public bucket.
  ///
  /// **Fails closed.** If this code cannot prove it removed the metadata, the
  /// answer is no. The alternative — publish the original and hope — makes the
  /// unparseable case leak silently, which is precisely the failure this whole
  /// file exists to prevent. A topo that fails to publish is a visible,
  /// retryable problem; a topo that publishes someone's GPS is not recoverable
  /// once the bytes are in a world-readable bucket and cached.
  bool get isSafeToPublish =>
      outcome == PhotoStripOutcome.stripped ||
      outcome == PhotoStripOutcome.alreadyClean;
}

/// Returns [bytes] with identifying metadata removed, ready for the public
/// bucket — or a result whose [PhotoStripResult.isSafeToPublish] is false.
///
/// Dispatches on the container's magic number, not on a filename extension: an
/// `.jpg` that is really a PNG is common enough (and a `.png` that is really a
/// JPEG commoner still) that trusting the extension would route real photos
/// down the wrong parser and report [PhotoStripOutcome.malformed] on bytes that
/// were fine.
PhotoStripResult strippedForPublishing(List<int> bytes) {
  final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
  if (_looksLikeJpeg(data)) return _stripJpeg(data);
  if (_looksLikePng(data)) return _stripPng(data);
  return PhotoStripResult(PhotoStripOutcome.unsupportedFormat, data);
}

bool _looksLikeJpeg(Uint8List b) =>
    b.length >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF;

const List<int> _pngMagic = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

bool _looksLikePng(Uint8List b) {
  if (b.length < _pngMagic.length) return false;
  for (var i = 0; i < _pngMagic.length; i++) {
    if (b[i] != _pngMagic[i]) return false;
  }
  return true;
}

// ---------------------------------------------------------------------------
// JPEG
// ---------------------------------------------------------------------------

/// Segments carrying identity, dropped wholesale.
///
/// - `APP1` (0xE1) — EXIF (GPS IFD, capture time, make/model/serial) and XMP.
/// - `APP2` (0xE2) — usually an ICC profile, which is a COLOUR profile and is
///   deliberately NOT here; see [_kJpegKeep]. It is listed in this comment only
///   to record that its omission is a decision, not an oversight.
/// - `APP13` (0xED) — Photoshop IRB, which carries IPTC (creator, location,
///   copyright, contact details).
/// - `COM` (0xFE) — free-text comment.
/// - Every other `APPn` — vendor blobs (APP3 Meta, APP4/5 camera-specific,
///   APP12 Ducky, APP14 Adobe). Unknown provenance, no rendering role.
///
/// The rule is allow-list, not deny-list: everything in [_kJpegKeep] survives,
/// everything else in the APPn/COM range does not. A deny-list would silently
/// pass tomorrow's new metadata segment straight through.
const Set<int> _kJpegKeep = {
  0xE0, // APP0 — JFIF density/thumbnail header. Structural; some decoders sulk.
  0xE2, // APP2 — ICC colour profile. Dropping it shifts the published colours.
};

PhotoStripResult _stripJpeg(Uint8List data) {
  final out = BytesBuilder(copy: false);
  var i = 2; // past SOI
  var removedAny = false;
  int? orientation;

  out.add(Uint8List.sublistView(data, 0, 2));

  while (true) {
    // Markers may be preceded by any number of 0xFF fill bytes.
    if (i >= data.length) return PhotoStripResult(PhotoStripOutcome.malformed, data);
    if (data[i] != 0xFF) return PhotoStripResult(PhotoStripOutcome.malformed, data);
    var marker = i + 1;
    while (marker < data.length && data[marker] == 0xFF) {
      marker++;
    }
    if (marker >= data.length) {
      return PhotoStripResult(PhotoStripOutcome.malformed, data);
    }
    final code = data[marker];

    // SOS: everything after it is entropy-coded scan data, which is NOT
    // segment-structured and must be copied verbatim to the end. No metadata
    // lives past here, so this is the correct place to stop parsing rather
    // than risk misreading compressed data as markers.
    if (code == 0xDA) {
      out.add(Uint8List.sublistView(data, i));
      break;
    }

    // Standalone markers: no length field, no payload.
    if (code == 0xD9 /* EOI */ ||
        (code >= 0xD0 && code <= 0xD7) /* RSTn */ ||
        code == 0x01 /* TEM */) {
      out.add(Uint8List.sublistView(data, i, marker + 1));
      i = marker + 1;
      if (code == 0xD9) break;
      continue;
    }

    if (marker + 2 >= data.length) {
      return PhotoStripResult(PhotoStripOutcome.malformed, data);
    }
    final length = (data[marker + 1] << 8) | data[marker + 2];
    // A segment length counts its own two length bytes, so anything under 2 is
    // structurally impossible and would make `end` walk backwards.
    if (length < 2) return PhotoStripResult(PhotoStripOutcome.malformed, data);
    final end = marker + 1 + length;
    if (end > data.length) {
      return PhotoStripResult(PhotoStripOutcome.malformed, data);
    }

    final isMetadata =
        (code >= 0xE0 && code <= 0xEF && !_kJpegKeep.contains(code)) ||
        code == 0xFE;

    if (isMetadata) {
      // Read orientation out of the EXIF APP1 before discarding it — this is
      // the one piece of an APP1 that has to survive, because the app never
      // baked it into the pixels. See this library's doc.
      if (code == 0xE1) {
        orientation ??= _readExifOrientation(
          Uint8List.sublistView(data, marker + 3, end),
        );
      }
      removedAny = true;
    } else {
      out.add(Uint8List.sublistView(data, i, end));
    }
    i = end;
  }

  if (!removedAny) {
    return PhotoStripResult(PhotoStripOutcome.alreadyClean, data);
  }

  var result = out.takeBytes();
  // Re-insert a minimal APP1 carrying ONLY the orientation, immediately after
  // SOI, when the original said the image is not stored upright. Orientation 1
  // is "normal" and needs no tag at all.
  if (orientation != null && orientation != 1) {
    final app1 = _buildOrientationOnlyApp1(orientation);
    final rebuilt = BytesBuilder(copy: false)
      ..add(Uint8List.sublistView(result, 0, 2))
      ..add(app1)
      ..add(Uint8List.sublistView(result, 2));
    result = rebuilt.takeBytes();
  }
  return PhotoStripResult(PhotoStripOutcome.stripped, result);
}

/// Reads tag 0x0112 (Orientation) out of an APP1 payload, or null.
///
/// Only IFD0 is walked — orientation lives there, and following the EXIF
/// sub-IFD pointer would mean parsing structures this function has no other
/// reason to touch. Returns null for anything unexpected; a missing orientation
/// is treated as "normal", which is also what a decoder does.
int? _readExifOrientation(Uint8List app1) {
  // "Exif\0\0"
  if (app1.length < 14) return null;
  if (app1[0] != 0x45 || app1[1] != 0x78 || app1[2] != 0x69 || app1[3] != 0x66) {
    return null; // XMP or another APP1 flavour, not EXIF.
  }
  if (app1[4] != 0x00 || app1[5] != 0x00) return null;

  final tiff = Uint8List.sublistView(app1, 6);
  if (tiff.length < 8) return null;
  final bool big;
  if (tiff[0] == 0x4D && tiff[1] == 0x4D) {
    big = true;
  } else if (tiff[0] == 0x49 && tiff[1] == 0x49) {
    big = false;
  } else {
    return null;
  }
  int u16(int o) => big ? (tiff[o] << 8) | tiff[o + 1] : (tiff[o + 1] << 8) | tiff[o];
  int u32(int o) => big
      ? (tiff[o] << 24) | (tiff[o + 1] << 16) | (tiff[o + 2] << 8) | tiff[o + 3]
      : (tiff[o + 3] << 24) | (tiff[o + 2] << 16) | (tiff[o + 1] << 8) | tiff[o];

  if (u16(2) != 0x002A) return null;
  final ifd0 = u32(4);
  if (ifd0 < 8 || ifd0 + 2 > tiff.length) return null;
  final count = u16(ifd0);
  for (var e = 0; e < count; e++) {
    final entry = ifd0 + 2 + e * 12;
    if (entry + 12 > tiff.length) return null;
    if (u16(entry) != 0x0112) continue;
    // SHORT (3). The value sits in the first 2 bytes of the 4-byte value field.
    if (u16(entry + 2) != 3) return null;
    final value = u16(entry + 8);
    return (value >= 1 && value <= 8) ? value : null;
  }
  return null;
}

/// A 34-byte APP1 whose entire content is one Orientation tag.
///
/// Big-endian ("MM") because it makes the constant readable, not for any
/// technical reason — both byte orders are equally legal.
Uint8List _buildOrientationOnlyApp1(int orientation) {
  return Uint8List.fromList([
    0xFF, 0xE1,
    0x00, 0x22, // length: 34, counting these two bytes
    0x45, 0x78, 0x69, 0x66, 0x00, 0x00, // "Exif\0\0"
    0x4D, 0x4D, // big-endian
    0x00, 0x2A, // TIFF magic 42
    0x00, 0x00, 0x00, 0x08, // IFD0 at offset 8
    0x00, 0x01, // one entry
    0x01, 0x12, // tag 0x0112 Orientation
    0x00, 0x03, // type SHORT
    0x00, 0x00, 0x00, 0x01, // count 1
    (orientation >> 8) & 0xFF, orientation & 0xFF, 0x00, 0x00, // value, padded
    0x00, 0x00, 0x00, 0x00, // no next IFD
  ]);
}

// ---------------------------------------------------------------------------
// PNG
// ---------------------------------------------------------------------------

/// Metadata chunks, dropped. Everything else — critical chunks and the
/// colour/rendering ancillaries (`gAMA`, `cHRM`, `sRGB`, `iCCP`, `tRNS`, …) —
/// is copied through untouched, so the decoded image is bit-identical.
///
/// A deny-list is right here where it was wrong for JPEG: PNG's ancillary
/// chunks are overwhelmingly rendering-relevant, so dropping unknown ones would
/// change how images look, and the metadata-bearing set is small and stable.
const Set<String> _kPngDrop = {
  'eXIf', // EXIF, including a GPS IFD.
  'tEXt', 'zTXt', 'iTXt', // Text, where authoring tools park anything at all.
  'tIME', // Last-modification timestamp.
};

PhotoStripResult _stripPng(Uint8List data) {
  final out = BytesBuilder(copy: false)
    ..add(Uint8List.sublistView(data, 0, _pngMagic.length));
  var i = _pngMagic.length;
  var removedAny = false;

  while (i < data.length) {
    // length(4) + type(4) + data(length) + crc(4)
    if (i + 8 > data.length) {
      return PhotoStripResult(PhotoStripOutcome.malformed, data);
    }
    final length =
        (data[i] << 24) | (data[i + 1] << 16) | (data[i + 2] << 8) | data[i + 3];
    if (length < 0) return PhotoStripResult(PhotoStripOutcome.malformed, data);
    final end = i + 12 + length;
    if (end > data.length) {
      return PhotoStripResult(PhotoStripOutcome.malformed, data);
    }
    final type = String.fromCharCodes(data, i + 4, i + 8);

    if (_kPngDrop.contains(type)) {
      removedAny = true;
    } else {
      out.add(Uint8List.sublistView(data, i, end));
    }
    i = end;
    if (type == 'IEND') break;
  }

  return removedAny
      ? PhotoStripResult(PhotoStripOutcome.stripped, out.takeBytes())
      : PhotoStripResult(PhotoStripOutcome.alreadyClean, data);
}
