import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Guards against the class of bug fixed 2026-08-05: the web build declared
/// NO text font (`build/web/assets/FontManifest.json` held only
/// `MaterialIcons`/`CupertinoIcons`), so BOTH shipped web renderers fell back
/// to fetching Roboto cross-origin from `https://fonts.gstatic.com` on every
/// boot, awaited with no timeout before first frame
/// (`_engine/engine/initialization.dart:154,206-220`) and never precached by
/// the service worker (cross-origin, `web/sw.js:233`). Offline, the splash
/// screen hung forever; online-but-blocked (content blocker / iCloud Private
/// Relay / carrier DNS), the app rendered with no text font at all.
///
/// The fix bundles Roboto locally under the family name `Roboto` exactly,
/// which is what SUPPRESSES the remote fetch on both renderers — verified
/// from these two literal-'Roboto' conditionals in the SDK source:
///
///   - skwasm (production): `_skwasm_impl/skwasm_impl/font_collection.dart`
///     — `loadAssetFonts` only skips adding the remote-fetching
///     `FontFamily('Roboto', [FontAsset(_robotoUrl, ...)])` when
///     `manifest.families.any((family) => family.name == 'Roboto')` is
///     already true.
///   - canvaskit (JS fallback): `_engine/engine/canvaskit/fonts.dart` — same
///     shape: `loadedRoboto` is set only when a manifest family's `.name`
///     equals the literal `'Roboto'`, and the remote download is queued only
///     when it is not.
///
/// This test does not re-derive the fetch/await/precache chain (that is
/// documented, not re-verified per run) — it pins the ONE fact an SDK
/// upgrade could silently break: that the sentinel family name checked by
/// both renderers is still the literal string `'Roboto'`, and that our own
/// `pubspec.yaml` still declares a font family with exactly that name. If a
/// future engine renamed its sentinel (or switched to a different default
/// family), this suppression trick would stop working and the cross-origin
/// fetch would silently come back — with no visible failure until someone
/// hit an offline boot or a blocked fonts.gstatic.com.
void main() {
  group('web font source agreement (bug: unbounded gstatic Roboto fetch)', () {
    // Locate the web engine SDK by ASCENDING from the test executable rather
    // than assuming a fixed depth. Under `flutter test` that executable is
    // <flutter>/bin/cache/artifacts/engine/<host>/flutter_tester — NOT
    // .../dart-sdk/bin/dart — so a hardcoded parent count would silently
    // SKIP this test instead of running it, which is worse than failing.
    // Same technique as test/web_geometry_source_test.dart.
    File? findUnderSdk(String relativeFromWebSdkLib) {
      final relative = p.join('flutter_web_sdk', 'lib', relativeFromWebSdkLib);
      var dir = File(Platform.resolvedExecutable).parent;
      for (var i = 0; i < 10; i++) {
        final candidate = File(p.join(dir.path, relative));
        if (candidate.existsSync()) return candidate;
        if (dir.parent.path == dir.path) break; // hit the filesystem root
        dir = dir.parent;
      }
      return null;
    }

    test(
        'skwasm font_collection.dart still gates the remote Roboto fetch on '
        "the literal family name 'Roboto'", () {
      final file = findUnderSdk(
        p.join('_skwasm_impl', 'skwasm_impl', 'font_collection.dart'),
      );
      if (file == null) {
        fail(
          'skwasm font_collection.dart not found under the resolved SDK — '
          'cannot verify the suppression sentinel on this machine. This is '
          'a FAILURE, not a skip: a guard that goes green when it cannot '
          'check anything is worthless. Either the SDK layout moved (ascend '
          'from Platform.resolvedExecutable further, or re-derive the '
          'relative path from the current flutter_web_sdk tree) or the file '
          'was renamed/removed upstream — re-point findUnderSdk\'s relative '
          'path and re-verify the literal-\'Roboto\' sentinel still exists '
          'before restoring this test.',
        );
      }
      final source = file.readAsStringSync();
      final match = RegExp(
        r'''family\.name\s*==\s*['"]Roboto['"]''',
      ).hasMatch(source);
      expect(
        match,
        isTrue,
        reason:
            'expected ${file.path} to still contain a condition comparing a '
            "manifest family's `.name` against the literal string 'Roboto' "
            '(loadAssetFonts\'s guard against re-adding the remote-fetching '
            'FontFamily). If the SDK renamed or restructured this sentinel, '
            'our pubspec.yaml font family name no longer suppresses the '
            'cross-origin fonts.gstatic.com fetch on the skwasm renderer — '
            'that fetch is awaited with no timeout before first frame and is '
            'never precached by our service worker (cross-origin). Re-read '
            'the new source and update BOTH this guard and pubspec.yaml\'s '
            'font family name to match; do not just delete this test.',
      );
    });

    test(
        'canvaskit fonts.dart still gates the remote Roboto fetch on the '
        "literal family name 'Roboto'", () {
      final file = findUnderSdk(
        p.join('_engine', 'engine', 'canvaskit', 'fonts.dart'),
      );
      if (file == null) {
        fail(
          'canvaskit fonts.dart not found under the resolved SDK — cannot '
          'verify the suppression sentinel on this machine. This is a '
          'FAILURE, not a skip: a guard that goes green when it cannot '
          'check anything is worthless. Either the SDK layout moved '
          '(ascend from Platform.resolvedExecutable further, or re-derive '
          'the relative path from the current flutter_web_sdk tree) or the '
          'file was renamed/removed upstream — re-point findUnderSdk\'s '
          'relative path and re-verify the literal-\'Roboto\' sentinel '
          'still exists before restoring this test.',
        );
      }
      final source = file.readAsStringSync();
      final match = RegExp(
        r'''family\.name\s*==\s*['"]Roboto['"]''',
      ).hasMatch(source);
      expect(
        match,
        isTrue,
        reason:
            'expected ${file.path} to still contain a condition comparing a '
            "manifest family's `.name` against the literal string 'Roboto' "
            '(loadAssetFonts\'s `loadedRoboto` guard). If the SDK renamed or '
            'restructured this sentinel, our pubspec.yaml font family name '
            'no longer suppresses the cross-origin fonts.gstatic.com fetch '
            'on the canvaskit (JS-fallback) renderer. Re-read the new source '
            'and update BOTH this guard and pubspec.yaml\'s font family name '
            'to match; do not just delete this test.',
      );
    });

    test('pubspec.yaml declares a font family named exactly Roboto', () {
      // Parsed with a targeted regex rather than `package:yaml`: `yaml` is
      // only a TRANSITIVE dependency here (pulled in via `checked_yaml`),
      // and importing it directly would trip `depend_on_referenced_packages`
      // (flutter_lints 6.0.0). `- family: Roboto` on its own line, followed
      // only by trailing whitespace, cannot match a differently-named family
      // (e.g. a mutation to `RobotoX`) because `\s*$` anchors end-of-line.
      final pubspecFile = File(p.join(Directory.current.path, 'pubspec.yaml'));
      expect(pubspecFile.existsSync(), isTrue,
          reason: 'expected to find pubspec.yaml at the repo root');
      final source = pubspecFile.readAsStringSync();
      final hasRobotoFamily = RegExp(
        r'^\s*-\s*family:\s*Roboto\s*$',
        multiLine: true,
      ).hasMatch(source);
      expect(
        hasRobotoFamily,
        isTrue,
        reason: 'pubspec.yaml\'s flutter.fonts must declare a family named '
            "exactly 'Roboto' — that literal name is what both web "
            "renderers' suppression conditionals key on (see the two tests "
            'above). Any other name leaves the remote fonts.gstatic.com '
            'fetch in place on web.',
      );
    });
  });
}
