import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Parses the REAL repo `pubspec.yaml` off disk (same precedent as
/// `test/core/db/post_commit_flush_test.dart`, which reads `pubspec.lock`
/// directly rather than mocking it) and asserts the Roboto font declaration
/// added to fix the unbounded gstatic fetch (see `test/web_font_source_test
/// .dart` for the SDK-side half of that guard) is actually wired up: a
/// `family: Roboto` entry exists, every asset path it names exists on disk
/// and is non-empty, and the declared weights include 400.
///
/// Parsed with a targeted regex rather than `package:yaml`: `yaml` is only a
/// TRANSITIVE dependency here (pulled in via `checked_yaml`), and importing
/// it directly in a test would trip `depend_on_referenced_packages`
/// (flutter_lints 6.0.0, already enabled — see analysis_options.yaml). The
/// pubspec's `fonts:` block has a small, stable shape, so a conservative
/// regex is enough and adds no new dependency.
void main() {
  test(
      'pubspec.yaml declares a Roboto font family whose assets exist, are '
      'non-empty, and include weight 400', () {
    final pubspecFile = File(p.join(Directory.current.path, 'pubspec.yaml'));
    expect(pubspecFile.existsSync(), isTrue,
        reason: 'expected to find pubspec.yaml at the repo root');
    final source = pubspecFile.readAsStringSync();

    // Every "- family: <name>" line marks the start of a family block; the
    // block runs until the next "- family:" line or end of file. Matching
    // this way (rather than assuming there is exactly one family) means a
    // future second font family does not break this test.
    final familyStarts = RegExp(
      r'^[ \t]*-[ \t]*family:[ \t]*(.+?)[ \t]*$',
      multiLine: true,
    ).allMatches(source).toList();
    expect(
      familyStarts,
      isNotEmpty,
      reason: 'pubspec.yaml has no `- family:` entries under flutter.fonts '
          'at all — expected at least the Roboto declaration added for the '
          'web-boot-font fix.',
    );

    String? robotoBlock;
    for (var i = 0; i < familyStarts.length; i++) {
      if (familyStarts[i].group(1) != 'Roboto') continue;
      final blockStart = familyStarts[i].end;
      final blockEnd = i + 1 < familyStarts.length
          ? familyStarts[i + 1].start
          : source.length;
      robotoBlock = source.substring(blockStart, blockEnd);
      break;
    }

    expect(
      robotoBlock,
      isNotNull,
      reason: 'pubspec.yaml must declare a font family named exactly '
          "'Roboto' under flutter.fonts — that literal name is what "
          'suppresses the cross-origin fonts.gstatic.com fetch on both web '
          'renderers (see test/web_font_source_test.dart). Found families: '
          '${familyStarts.map((m) => m.group(1)).toList()}',
    );

    final assetPaths = RegExp(r'asset:[ \t]*(\S+)')
        .allMatches(robotoBlock!)
        .map((m) => m.group(1)!)
        .toList();
    expect(
      assetPaths,
      isNotEmpty,
      reason: 'the Roboto family block declares no `asset:` entries',
    );

    for (final assetPath in assetPaths) {
      final file = File(p.join(Directory.current.path, assetPath));
      expect(
        file.existsSync(),
        isTrue,
        reason: 'pubspec.yaml declares asset $assetPath for the Roboto '
            'family, but no such file exists on disk. A pubspec entry '
            'pointing at a missing font file builds fine and fails silently '
            'at runtime — `flutter build web` does not catch this.',
      );
      expect(
        file.lengthSync(),
        greaterThan(0),
        reason: 'declared Roboto asset $assetPath exists but is empty (0 '
            'bytes) — a truncated/corrupt copy would still pass an '
            '`existsSync()`-only check.',
      );
    }

    final weights = RegExp(r'weight:[ \t]*(\d+)')
        .allMatches(robotoBlock)
        .map((m) => int.parse(m.group(1)!))
        .toList();
    expect(
      weights,
      contains(400),
      reason: 'the Roboto family must declare weight 400 (Regular) — found '
          'weights: $weights. Regular is the weight almost every default '
          'TextStyle in lib/app/theme.dart resolves to '
          '(FontWeight.w400/w400-ish body/title styles).',
    );
  });
}
