/// Minimal, VALID, metadata-free photo bytes for tests that push or publish a
/// photo.
///
/// Why this exists: publishing strips identifying metadata from the public copy
/// and **refuses to upload a container it cannot parse** (W-3 — see
/// `lib/features/backup/data/published_photo_metadata.dart`). Test fixtures used
/// to be a handful of filler bytes, which is not a photo, so every shared-upload
/// test would quietly exercise the refusal path instead of the path it meant to
/// test.
///
/// **Metadata-free is load-bearing.** With nothing to strip, the publish-side
/// rewrite is a no-op that hands back its input unchanged, so byte-identity
/// assertions (`privateStorage[...] == the bytes written`) keep working exactly
/// as they did — the fixture change is invisible to every test that is not
/// specifically about stripping.
library;

import 'dart:typed_data';

/// A structurally valid baseline JPEG: SOI, one quantisation table, a scan, EOI.
///
/// [fill] varies the quantisation table and the scan payload so two fixtures are
/// distinguishable, the way the old `List.filled(16, fill)` was. It is not a
/// decodable IMAGE — no frame header, no Huffman tables — and does not need to
/// be: nothing under test decodes pixels, and adding them would only make the
/// fixture longer without making any assertion stronger.
Uint8List fixtureJpegBytes([int fill = 7]) => Uint8List.fromList([
  0xFF, 0xD8, // SOI
  // DQT: length 19 = 2 (length) + 1 (precision/id) + 16 (table).
  0xFF, 0xDB, 0x00, 0x13, 0x00, ...List<int>.filled(16, fill),
  // SOS: length 8, one component, then the entropy-coded bytes. The 0xFF 0x00
  // is a real stuffed byte — a parser that kept scanning for markers past SOS
  // would misread it, so leaving it here keeps that bug detectable.
  0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F, 0x00,
  fill, 0xFF, 0x00, fill,
  0xFF, 0xD9, // EOI
]);

/// The same bytes with an EXIF APP1 spliced in, for tests that need publishing
/// to actually have something to remove.
///
/// The payload carries a GPS IFD pointer (tag 0x8825) and a camera make, which
/// is what makes it a useful negative: after a strip, neither may appear
/// anywhere in the published bytes.
Uint8List fixtureJpegWithExifBytes([int fill = 7]) {
  const exifBody = <int>[
    0x45, 0x78, 0x69, 0x66, 0x00, 0x00, // "Exif\0\0"
    0x4D, 0x4D, 0x00, 0x2A, 0x00, 0x00, 0x00, 0x08, // TIFF header, IFD0 @ 8
    0x00, 0x02, // two entries
    0x88, 0x25, 0x00, 0x04, 0, 0, 0, 1, 0, 0, 0, 0x1A, // GPSInfoIFDPointer
    0x01, 0x0F, 0x00, 0x02, 0, 0, 0, 4, 0x41, 0x42, 0x43, 0x00, // Make "ABC"
    0, 0, 0, 0, // no next IFD
  ];
  final plain = fixtureJpegBytes(fill);
  return Uint8List.fromList([
    0xFF, 0xD8,
    0xFF, 0xE1,
    ((exifBody.length + 2) >> 8) & 0xFF, (exifBody.length + 2) & 0xFF,
    ...exifBody,
    ...plain.sublist(2),
  ]);
}

/// The GPS-pointer tag bytes, for asserting they are absent after a strip.
const List<int> kFixtureGpsTagBytes = [0x88, 0x25];

/// The camera-make value, for the same purpose.
const List<int> kFixtureMakeBytes = [0x41, 0x42, 0x43];
