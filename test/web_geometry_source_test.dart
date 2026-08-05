import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Guards against the class of bug that shipped 2026-08-05: a `web/index.html`
/// tweak added for a COSMETIC 1px hairline (#74) silently displaced every
/// touch target from painted content on the installed iOS PWA — "Continue
/// with Google" looked dead because taps on it never reached it.
///
/// Root cause (proven from the Flutter 3.44.2 engine sources, not guessed):
/// on iOS, `FullPageDimensionsProvider.computePhysicalSize()`
/// (lib/web_ui/lib/src/engine/view_embedder/dimensions_provider/
/// full_page_dimensions_provider.dart:81-84) reads
/// `document.documentElement.clientWidth/clientHeight` — DELIBERATELY, to
/// dodge a WebKit bug where `visualViewport` reports the wrong size after a
/// rotation. That `physicalSize` is the SAME value
/// `EngineFlutterView.handleFrameworkResize` (lib/web_ui/lib/src/engine/
/// window.dart:211-231) uses to set `<flutter-view>`'s CSS width/height, and
/// `<flutter-view>` (`DomManager.rootElement`, NOT its `<flt-glass-pane>`
/// child) is the exact element `computeEventOffsetToTarget`
/// (lib/web_ui/lib/src/engine/pointer_binding/
/// event_position_helper.dart:30-64) measures every native pointer event's
/// `offsetX/offsetY` against. So the box Flutter PAINTS into and the box it
/// HIT-TESTS against are one and the same, sized from `clientHeight`/
/// `clientWidth` on iOS — which is exactly the property the #74 fix
/// unconditionally aliased to `window.innerHeight/innerWidth`, defeating the
/// engine's own correctness fix and letting the mismatch persist instead of
/// settling after one frame. `full_page_embedding_strategy.dart:35-47`
/// separately pins `<flutter-view>` at `top: 0; left: 0` with an explicit
/// width/height (overriding the stretch its `top/right/bottom/left: 0`
/// insets would otherwise give it) inside a `<body>` that is
/// `position: fixed; inset: 0` across the WHOLE viewport
/// (full_page_embedding_strategy.dart:50-58) — so any further CSS offset
/// applied directly to `<flutter-view>` (the second #74 tweak, a
/// standalone-only `top: -2px`) is the same class of mistake: it perturbs
/// the one geometry input the engine treats as ground truth for both paint
/// and touch.
///
/// This file cannot execute the standalone-PWA code path (headless Chrome
/// never matches `display-mode: standalone`, and there is no iOS engine
/// here) — it pins the SOURCE PROPERTY so the mistake cannot silently ship
/// again, the same role `test/web_hosting_config_test.dart` plays for
/// `_headers`. The real-coordinate device check lives in
/// `tool/verify_pointer_geometry.py`.
String _read(String relativePath) {
  final file = File(p.join(Directory.current.path, relativePath));
  expect(file.existsSync(), isTrue, reason: 'expected $relativePath to exist');
  return file.readAsStringSync();
}

void main() {
  group('web/index.html geometry safety (bug: iOS PWA touch-offset)', () {
    // Asserted as a PROPERTY — any `Object.defineProperty`/`defineProperty`
    // call naming the literal property `clientHeight` or `clientWidth` as
    // its second argument, regardless of which object it targets
    // (`document.documentElement`, `Element.prototype`, a saved reference,
    // etc.) or how it's formatted. A bare-substring check for the exact
    // original snippet would go green again the moment someone rephrased the
    // same override, which is exactly how #74's second attempt slipped past
    // review the first time.
    test('never overrides clientHeight/clientWidth on any object', () {
      final source = _read('web/index.html');
      final match = RegExp(
        r'[dD]efineProperty\s*\([^,]+,\s*[\x27\x22]client(?:Height|Width)[\x27\x22]',
      ).firstMatch(source);
      expect(
        match,
        isNull,
        reason: 'found a defineProperty override of ${match?.group(0)} — on '
            'iOS this is exactly the property the web engine reads to size '
            '`<flutter-view>` for BOTH painting and native pointer hit-testing '
            '(full_page_dimensions_provider.dart). Aliasing it to '
            'window.innerHeight/innerWidth defeats the engine\'s own '
            'iOS-rotation workaround and can leave view geometry permanently '
            'unsettled, displacing every touch target from painted content — '
            'this shipped once already and made "Continue with Google" '
            'appear dead. Do not reintroduce it; if the #74 hairline needs '
            'fixing again, find a mechanism that never touches a property '
            'the engine treats as sizing/hit-test ground truth.',
      );
    });

    // Asserted as a PROPERTY — any CSS rule whose selector contains
    // `flutter-view` and whose declaration block sets `top` or `transform`,
    // regardless of media-query wrapper, `!important`, or exact value. This
    // is `<flutter-view>`'s own box: the element the engine positions at
    // `top:0;left:0` with an explicit width/height inside a viewport-filling
    // `<body>`, and the SAME element (`DomManager.rootElement`)
    // `computeEventOffsetToTarget` measures every native pointer event
    // against directly.
    test('never offsets <flutter-view> itself via CSS top/transform', () {
      final source = _read('web/index.html');
      final match = RegExp(
        r'flutter-view\s*\{[^}]*\b(top|transform)\s*:',
        dotAll: true,
      ).firstMatch(source);
      expect(
        match,
        isNull,
        reason: 'found a CSS rule setting `${match?.group(1)}` on '
            '`flutter-view` — that element is positioned by the web engine '
            'itself (full_page_embedding_strategy.dart) at the exact box it '
            'both paints into and hit-tests against. A page-level offset '
            'here previously shipped as a "2px overscan" for a cosmetic '
            'hairline (#74) and is the same class of mistake as the '
            'clientHeight override above. Style flt-scene-host/canvas '
            'instead if a purely visual nudge is ever needed again, never '
            'flutter-view.',
      );
    });

    // THE INVARIANT, not another "don't do the thing we already thought of".
    //
    // The engine's embedding-strategy constructor removes EVERY
    // `meta[name="viewport"]` on the page — unconditionally, the `remove()`
    // sits outside the assert so it happens in release too — and appends its
    // own, AFTER the browser has already laid the page out with ours
    // (full_page_embedding_strategy.dart). Any difference between the two
    // strings is therefore a mid-life viewport change.
    //
    // On iOS that is not cosmetic. The engine's ONE geometry input there is
    // `documentElement.clientWidth/clientHeight` — the LAYOUT viewport — and
    // the only resize it subscribes to is the VISUAL viewport, so it cannot
    // observe a layout-viewport-only change and has no path to invalidate it.
    // Shipping `viewport-fit=cover` here (which the engine's string omits)
    // flipped viewport-fit a beat after boot: the view translated, its bottom
    // clipped, and touch landed off painted content until a real rotation
    // forced WebKit to re-resolve. Device-confirmed: rotating fixed it, a
    // synthetic visualViewport resize did not.
    //
    // Compared as a PARSED ARGUMENT MAP, so formatting/order/whitespace
    // differences don't fail it and a real semantic divergence does. This also
    // fails on an SDK UPGRADE that changes the engine's string — which is the
    // point: without it, this fix silently rots.
    test('our viewport meta matches the one the engine will install', () {
      Map<String, String> parseViewport(String content) {
        return {
          for (final part in content.split(','))
            if (part.trim().isNotEmpty)
              part.split('=').first.trim(): part.contains('=')
                  ? part.split('=').sublist(1).join('=').trim()
                  : '',
        };
      }

      final ours = RegExp(
        r'<meta\s+name="viewport"\s+content="([^"]*)"',
      ).firstMatch(_read('web/index.html'));
      expect(ours, isNotNull, reason: 'no viewport meta in web/index.html');

      // Locate the web engine sources by ASCENDING from the test executable
      // until a directory contains `flutter_web_sdk`, rather than assuming a
      // fixed depth. Under `flutter test` the executable is
      // <flutter>/bin/cache/artifacts/engine/<host>/flutter_tester — NOT
      // .../dart-sdk/bin/dart — so a hardcoded parent count silently skips
      // this test instead of running it, which is worse than failing.
      const relative =
          'flutter_web_sdk/lib/_engine/engine/view_embedder/'
          'embedding_strategy/full_page_embedding_strategy.dart';
      File? found;
      var dir = File(Platform.resolvedExecutable).parent;
      for (var i = 0; i < 10; i++) {
        final candidate = File(p.join(dir.path, relative));
        if (candidate.existsSync()) {
          found = candidate;
          break;
        }
        if (dir.parent.path == dir.path) break; // hit the filesystem root
        dir = dir.parent;
      }
      final engineFile = found ?? File(relative);
      if (!engineFile.existsSync()) {
        // Skip rather than fail: a differently-laid-out SDK must not turn this
        // guard into a red herring. It still runs on this machine and in CI.
        markTestSkipped('engine source not found at ${engineFile.path}');
        return;
      }

      // `..content =` is followed by one or more adjacent Dart string literals.
      final assignment = RegExp(
        r'\.\.content\s*=\s*((?:\s*'
        "'[^']*'"
        r')+)\s*;',
      ).firstMatch(engineFile.readAsStringSync());
      expect(
        assignment,
        isNotNull,
        reason: 'could not find the engine\'s `..content =` viewport '
            'assignment in ${engineFile.path} — the engine may have been '
            'restructured; re-read it and update this guard rather than '
            'deleting it.',
      );
      final theirs = RegExp("'([^']*)'")
          .allMatches(assignment!.group(1)!)
          .map((m) => m.group(1)!)
          .join();

      expect(
        parseViewport(ours!.group(1)!),
        equals(parseViewport(theirs)),
        reason: 'web/index.html\'s viewport meta disagrees with the string '
            'the engine installs at runtime ("$theirs"). The engine removes '
            'ours and appends its own after first layout, so any difference '
            'becomes a viewport change mid-boot — and on iOS the layout '
            'viewport is the engine\'s only geometry input, with no way to '
            'observe or invalidate a change to it. This exact divergence '
            '(`viewport-fit=cover`) shipped a visible shift plus offset touch '
            'that only a device rotation cleared. If the SDK changed its '
            'string, match the new one here; do not weaken this test.',
      );
    });
  });
}
