// Pins the `dart:io` gate — the rule, and the fact that its THREE copies say
// the same thing.
//
// The gate is stated in three places and CLAUDE.md says to "keep the regex
// byte-identical" across them, but until this file nothing enforced that:
//
//   1. `tool/build_web.sh`            — the local build gate (POSIX ERE)
//   2. `.github/workflows/ci.yml`     — the required CI job (POSIX ERE)
//   3. `tool/gate.dart`'s [dartIoDirective] — the cross-platform runner (Dart)
//
// A documented invariant with nothing checking it is a comment, and this one
// fails in a particularly quiet way. `dart:io` on web COMPILES — Dart stubs the
// library and throws at RUNTIME — so a divergence here does not redden a build.
// It ships a bundle that boots fine and then throws the first time a `File(...)`
// is reached, e.g. while rendering a photo.
//
// The second thing pinned here is the FALSE POSITIVE that the regex shape
// exists to avoid: a raw substring search for `dart:io` returns ~43 hits on a
// clean tree, because the conditional-import seam files' doc comments name
// `dart:io` while explaining the split. That form kept the gate red on correct
// code, which is the fastest way to teach a team to stop reading it.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/gate.dart';

/// The regex literal as it appears inside a shell `grep -rlE "…" lib` call.
///
/// Terminated on `" lib` rather than on the first `"`: the pattern itself
/// contains escaped quotes (`['\"]`), so a naive "up to the next quote" match
/// silently truncates it — and two identically-truncated strings compare equal,
/// which would make the parity assertion below pass without comparing the part
/// that matters.
String? _shellRegexIn(String path) {
  final text = File(path).readAsStringSync();
  final m = RegExp(r'grep -rlE "(.*)" lib').firstMatch(text);
  return m?.group(1);
}

void main() {
  group('dart:io gate', () {
    test('the shell regex is byte-identical in build_web.sh and ci.yml', () {
      final fromScript = _shellRegexIn('tool/build_web.sh');
      final fromCi = _shellRegexIn('.github/workflows/ci.yml');

      expect(fromScript, isNotNull,
          reason: 'no `grep -rlE "…"` found in tool/build_web.sh — the local '
              'gate has moved or been removed');
      expect(fromCi, isNotNull,
          reason: 'no `grep -rlE "…"` found in .github/workflows/ci.yml — the '
              'required CI job has moved or been removed');
      // Guards the assertion itself: if the extraction above ever truncates,
      // two identically-truncated strings still compare equal and this test
      // would pass while comparing nothing.
      expect(fromScript!.length, greaterThan(40),
          reason: 'extracted regex looks truncated: "$fromScript"');
      expect(fromScript, contains('dart:io'));

      expect(fromCi, fromScript,
          reason: 'CLAUDE.md requires these be byte-identical. Any divergence '
              'lets a real leak past one of them, or reddens one of them on '
              'clean code.');
    });

    test('the Dart implementation agrees with the shell regex, term for term',
        () {
      final shell = _shellRegexIn('tool/build_web.sh')!;

      // Translated, not copied: POSIX ERE has no `\t`, and `[[:space:]]` is the
      // portable spelling of the character class Dart writes as `[ \t]`. What
      // must match is the MEANING — optional leading whitespace, the directive
      // keyword, mandatory whitespace, then a quoted `dart:io`.
      expect(shell, contains('(import|export)'));
      expect(shell, contains('dart:io'));
      expect(shell, startsWith('^'),
          reason: 'anchoring at line start is the whole point — it is what '
              'separates a directive from prose that merely mentions dart:io');

      expect(dartIoDirective.pattern, contains('(import|export)'));
      expect(dartIoDirective.pattern, contains('dart:io'));
      expect(dartIoDirective.isMultiLine, isTrue,
          reason: 'without multiLine, `^` anchors to the start of the whole '
              'FILE, so only a dart:io directive on line 1 would ever be '
              'found — the gate would pass on every real offender.');
    });

    test('matches real directives and ignores prose that merely names dart:io',
        () {
      for (final directive in [
        "import 'dart:io';",
        'import "dart:io";',
        "export 'dart:io';",
        "  import 'dart:io' show File;",
        "\timport 'dart:io';",
      ]) {
        expect(dartIoDirective.hasMatch('$directive\n'), isTrue,
            reason: 'should have matched: $directive');
      }

      for (final prose in [
        "/// Uses `dart:io` on native and package:web on the web.",
        "// import 'dart:io'; <- the thing this seam replaces",
        "const s = 'dart:io';",
        "import 'dart:io_extras.dart';",
      ]) {
        expect(dartIoDirective.hasMatch('$prose\n'), isFalse,
            reason: 'should NOT have matched: $prose\n'
                'A gate that fires on its own explanatory comments is one '
                'everybody learns to ignore.');
      }
    });

    test('lib/ is clean — the live invariant, enforced by `flutter test` and '
        'not only by whoever remembers to run the build script', () {
      expect(dartIoOffenders(Directory('lib')), isEmpty);
    });

    test('a real offender IS found, and a _native.dart seam is not', () async {
      final dir = await Directory.systemTemp.createTemp('masi-dartio-gate');
      addTearDown(() async {
        try {
          await dir.delete(recursive: true);
        } on FileSystemException {
          // Windows can hold a transient handle; the temp dir is disposable.
        }
      });

      File('${dir.path}${Platform.pathSeparator}offender.dart')
          .writeAsStringSync("import 'dart:io';\nvoid main() {}\n");
      File('${dir.path}${Platform.pathSeparator}seam_native.dart')
          .writeAsStringSync("import 'dart:io';\nvoid main() {}\n");
      File('${dir.path}${Platform.pathSeparator}innocent.dart')
          .writeAsStringSync("/// mentions dart:io in prose only\n");

      final offenders = dartIoOffenders(dir);

      expect(offenders, hasLength(1),
          reason: 'exactly the one non-seam file should be reported; got '
              '$offenders');
      expect(offenders.single, endsWith('offender.dart'));
    });
  });
}
