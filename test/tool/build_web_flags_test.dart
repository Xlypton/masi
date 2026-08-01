import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// `tool/build_web.sh` is the locally-runnable definition of done for the
/// web build, and two of its flags are load-bearing in ways nothing else in
/// the repo can catch:
///
///  - `--no-web-resources-cdn` is what makes the renderer a SAME-ORIGIN
///    asset. Without it `flutter_bootstrap.js` resolves `skwasm.js` /
///    `skwasm.wasm` against `https://www.gstatic.com/flutter-canvaskit/<rev>/`
///    and an offline first paint dies on that cross-origin fetch (design doc
///    §2a).
///  - `--pwa-strategy=none` is what stops Flutter's DEPRECATED cleanup
///    service worker being registered on top of ours. With it omitted, the
///    generated bootstrap ends in
///    `_flutter.loader.load({serviceWorkerSettings: {...}})`, whose loader
///    calls `navigator.serviceWorker.getRegistration()` and — finding OUR
///    registration — registers `flutter_service_worker.js` at the same scope,
///    replacing ours with a shim that unregisters itself and
///    `client.navigate()`s every client. That is an every-other-load reload
///    loop plus a permanently dead offline shell.
///
/// A shell script cannot be unit-tested directly, so this pins the two flags
/// and the two post-build gates by scanning the script's source. The real
/// end-to-end proof is `tool/build_web.sh` itself, whose gates fail the build.
String _buildScript() {
  final file = File(
    p.join(Directory.current.path, 'tool', 'build_web.sh'),
  );
  expect(file.existsSync(), isTrue, reason: 'expected ${file.path} to exist');
  return file.readAsStringSync();
}

void main() {
  group('tool/build_web.sh renderer + service-worker flags', () {
    test('builds with --no-web-resources-cdn', () {
      expect(
        _buildScript(),
        contains('--no-web-resources-cdn'),
        reason: 'without it the renderer is fetched from gstatic.com and the '
            'app cannot paint its first frame offline (design doc §2a)',
      );
    });

    test('builds with --pwa-strategy=none', () {
      expect(
        _buildScript(),
        contains('--pwa-strategy=none'),
        reason: "with Flutter's serviceWorkerSettings still emitted, the "
            'loader registers flutter_service_worker.js OVER web/sw.js and '
            'the shim unregisters itself + reloads every client',
      );
    });

    test('gates the emitted bootstrap on useLocalCanvasKit', () {
      expect(
        _buildScript(),
        contains('"useLocalCanvasKit":true'),
        reason: 'the buildConfig key is the only reliable signal that the '
            'renderer is same-origin — a raw `gstatic` grep can never be 0, '
            'because the minified loader embeds the fallback URL as a string '
            'literal regardless of the flag',
      );
    });

    test('gates the emitted bootstrap on a BARE _flutter.loader.load() call',
        () {
      // NOT a `grep -q serviceWorkerSettings` absence gate. That literal is
      // unachievable for the same reason the spec's `grep -c gstatic == 0` is:
      // flutter_bootstrap.js inlines the MINIFIED flutter.js loader, whose own
      // `load({serviceWorkerSettings:e,...}={})` signature and
      // `{serviceWorkerVersion:r,...}` destructure contain both identifiers
      // unconditionally. Measured on a real --pwa-strategy=none build: one
      // occurrence of each, both inside the loader, with the generated tail
      // already correct.
      //
      // What the flag actually controls is the generated call site
      // (flutter_tools/lib/src/web/bootstrap.dart:674-688):
      //   offline-first -> `_flutter.loader.load({ serviceWorkerSettings: … });`
      //   none          -> `_flutter.loader.load();`
      final script = _buildScript();
      expect(
        script,
        contains(r'^_flutter\.loader\.load\(\);$'),
        reason: 'the bare-call grep is the positive signal that '
            '--pwa-strategy=none took effect',
      );
      expect(
        script,
        contains(r'_flutter\.loader\.load({'),
        reason: 'and the argument-object grep is the negative one',
      );
    });
  });
}
