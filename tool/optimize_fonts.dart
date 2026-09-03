// Strips TrueType hinting from the bundled Roboto faces, in place.
//
// WHY THIS IS SAFE, AND WHY THE OBVIOUS BIGGER WIN IS NOT TAKEN.
//
// The three bundled Roboto TTFs carry ~195 KB (raw) of TrueType hinting
// bytecode -- the `fpgm`/`prep`/`cvt ` tables plus per-glyph instructions.
// Every renderer this app actually ships to ignores it:
//
//   - web (skwasm and canvaskit alike) rasterizes through Skia, which uses its
//     own autohinter and does not execute TrueType instructions for canvas
//     text. Stripping them cannot change a pixel there.
//   - native iOS never reaches these files for body text at all: no `TextStyle`
//     in `MasiTheme` sets a `fontFamily` (grep `fontFamily` in lib/ -- there
//     are no hits), so on iOS the null family resolves to the platform's own
//     SF Pro. The bundled Roboto exists for the reason `pubspec.yaml`'s comment
//     gives: the literal family name 'Roboto' is what stops BOTH web renderers
//     issuing a cross-origin fetch for it on the boot path.
//
// What is deliberately NOT done here: subsetting to Latin. That would save
// another ~101 KB gzipped, and it would do it by deleting 275 Cyrillic, 75
// Greek and 100 Vietnamese codepoints from a COMMUNITY app whose area names,
// route names and comments are user-generated. Climbers in Russia, Greece,
// Ukraine and Bulgaria would get tofu boxes where their own crag names used to
// be. That is a product decision with a visible cost to real users, not a
// build optimization, so it is left to a human to make explicitly rather than
// taken here for a number.
//
// Idempotent: re-running on already-stripped files is a no-op in effect (the
// tables are already gone), so it is safe in a build script or a hook.
//
// Usage:  dart run tool/optimize_fonts.dart [--check]
//         --check  exits 1 if any font still carries hinting, changing nothing.
import 'dart:io';

const _fonts = <String>[
  'assets/fonts/Roboto-Regular.ttf',
  'assets/fonts/Roboto-Medium.ttf',
  'assets/fonts/Roboto-Bold.ttf',
];

/// The tables `pyftsubset --no-hinting` removes outright. Presence of any of
/// them means the file has not been stripped yet.
const _hintingTables = <String>['fpgm', 'prep', 'cvt ', 'gasp'];

/// Reads the 4-byte table tags out of a TrueType/OpenType header, without a
/// font library -- the directory is fixed-layout, so this needs no dependency
/// and works in CI with nothing installed.
Set<String> _tableTags(File file) {
  final bytes = file.readAsBytesSync();
  if (bytes.length < 12) return <String>{};
  final numTables = (bytes[4] << 8) | bytes[5];
  final tags = <String>{};
  for (var i = 0; i < numTables; i++) {
    final offset = 12 + i * 16;
    if (offset + 4 > bytes.length) break;
    tags.add(String.fromCharCodes(bytes.sublist(offset, offset + 4)));
  }
  return tags;
}

void main(List<String> args) {
  final check = args.contains('--check');
  var offenders = 0;

  for (final path in _fonts) {
    final file = File(path);
    if (!file.existsSync()) {
      stderr.writeln('  MISSING: $path');
      exitCode = 1;
      continue;
    }
    final hinted = _tableTags(file).intersection(_hintingTables.toSet());
    if (hinted.isEmpty) {
      stdout.writeln('    ok: $path carries no hinting tables');
      continue;
    }
    offenders++;
    if (check) {
      stdout.writeln('    HINTED: $path still has ${hinted.join(', ')}');
      continue;
    }
    // The strip itself needs real font surgery (glyph instructions live inside
    // `glyf`, not just in the standalone tables), so it shells out to
    // fontTools rather than reimplementing it. Run it once, commit the result;
    // this is not part of the per-build path.
    final result = Process.runSync('pyftsubset', <String>[
      path,
      '--output-file=$path',
      '--unicodes=*',
      '--no-hinting',
      '--desubroutinize',
      '--drop-tables+=DSIG',
      '--layout-features=*',
      '--glyph-names',
      '--notdef-outline',
      '--recommended-glyphs',
    ]);
    if (result.exitCode != 0) {
      stderr.writeln('    FAILED on $path: ${result.stderr}');
      stderr.writeln('    (needs `pip install fonttools`)');
      exitCode = 1;
      continue;
    }
    stdout.writeln('    stripped: $path');
  }

  if (check && offenders > 0) {
    stderr.writeln('$offenders font(s) still carry hinting; '
        'run `dart run tool/optimize_fonts.dart`');
    exitCode = 1;
  }
}
