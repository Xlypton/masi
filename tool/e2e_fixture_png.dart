// Emits the E2E fixture photo as base64 PNG on stdout.
//
//   dart run tool/e2e_fixture_png.dart
//
// `tool/e2e_seed.sh` pipes this into the Supabase Storage REST API so the
// seeded topo has REAL bytes behind it — the topo canvas, the community topo
// detail and the phase-7b propose-line canvas all render a photo, and the
// sync pull's photo-download path is exercised rather than skipped.
//
// Generated rather than committed as a binary, for two reasons: a checked-in
// PNG is invisible to review, and the whole point of this fixture is that its
// dimensions and content are stated in code (96x144 portrait, a smooth
// gradient) so a screenshot of it is unmistakably the fixture and not a real
// climbing photo somebody left in the dev database.
//
// Deliberately hand-rolled from `dart:io`'s ZLibCodec rather than reaching for
// `package:image`: this runs as a standalone script from a shell pipeline, so
// it must not depend on the app's pub dependencies resolving.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Fixture dimensions. Mirrored in `tool/e2e_seed.sh`'s `photos` INSERT — the
/// row's width/height must match the real bytes, or the canvas lays routes out
/// against the wrong aspect ratio.
const int fixtureWidth = 96;
const int fixtureHeight = 144;

final List<int> _crcTable = List<int>.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
  }
  return c;
});

int _crc32(List<int> bytes) {
  var c = 0xFFFFFFFF;
  for (final b in bytes) {
    c = _crcTable[(c ^ b) & 0xFF] ^ (c >> 8);
  }
  return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

List<int> _chunk(String type, List<int> data) {
  final body = <int>[...ascii.encode(type), ...data];
  return <int>[
    ...(ByteData(4)..setUint32(0, data.length)).buffer.asUint8List(),
    ...body,
    ...(ByteData(4)..setUint32(0, _crc32(body))).buffer.asUint8List(),
  ];
}

void main() {
  // Raw scanlines, filter byte 0 (none) per row, 8-bit truecolour RGB.
  final raw = <int>[];
  for (var y = 0; y < fixtureHeight; y++) {
    raw.add(0);
    for (var x = 0; x < fixtureWidth; x++) {
      raw.addAll(<int>[
        40 + (120 * y ~/ fixtureHeight),
        60 + (90 * x ~/ fixtureWidth),
        90,
      ]);
    }
  }
  final ihdr = <int>[
    ...(ByteData(8)
          ..setUint32(0, fixtureWidth)
          ..setUint32(4, fixtureHeight))
        .buffer
        .asUint8List(),
    8, // bit depth
    2, // colour type: truecolour
    0, 0, 0, // compression, filter, interlace
  ];
  final png = <int>[
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
    ..._chunk('IHDR', ihdr),
    ..._chunk('IDAT', ZLibCodec(level: 9).encode(raw)),
    ..._chunk('IEND', const <int>[]),
  ];
  stdout.write(base64.encode(png));
}
