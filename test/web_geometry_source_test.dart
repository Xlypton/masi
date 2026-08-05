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

    // The splash is held across the cold-launch viewport settle on standalone
    // iOS (the top safe-area inset lands a beat after the first frame, and
    // everything bound to it jumps down while the inset-blind full-bleed topo
    // canvas does not). That hold reads the viewport instead of faking it —
    // the safe mechanism — but a hold with no ceiling would be indistinguish-
    // able from the boot hang that #19 had to grow a retry affordance for.
    // So: pin that the settle loop always has an escape hatch. Asserted as a
    // property (any `performance.now()` deadline comparison or a setTimeout
    // fallback), not as the exact expression, so a rephrase still counts.
    test('the standalone splash hold is bounded, never open-ended', () {
      final source = _read('web/index.html');
      final settle = RegExp(
        r'requestAnimationFrame\s*\(\s*settle\s*\)',
      ).hasMatch(source);
      if (!settle) return; // hold removed entirely — nothing to bound.
      expect(
        RegExp(r'performance\.now\s*\(\s*\)\s*>=|setTimeout').hasMatch(source),
        isTrue,
        reason: 'the splash-hold loop in web/index.html recurses through '
            'requestAnimationFrame with no deadline or timeout in sight. If '
            'the viewport never goes quiet, the branded splash stays up '
            'forever and the app looks hung with no retry affordance — the '
            'exact failure mode #19 had to be fixed for. Keep the hard cap.',
      );
    });
  });
}
