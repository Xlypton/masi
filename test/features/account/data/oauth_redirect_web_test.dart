@TestOn('chrome')
library;

// Direct browser tests of `oauth_redirect_web.dart`'s STAGE-1 watchdog.
// `flutter test` runs on the Dart VM by default and cannot load a
// `dart.library.js_interop`-gated file at all — this file only runs under
// `flutter test --platform chrome` (headless Chrome, the same chromedriver
// this repo already uses for `tool/drive_web.sh`).
//
// The bug this proves a fix for is real-browser-observable but NOT
// device-observable from here: an iOS home-screen standalone PWA silently
// ignores an out-of-scope top-level navigation. Headless desktop Chrome has
// no such scope restriction, so we can't literally reproduce "standalone PWA
// refuses" — but we CAN reproduce the exact shape of the bug: a
// `location.assign(url)` call that raises no exception yet never actually
// navigates. Chrome does this for its own reasons when the URL's scheme has
// no registered handler (e.g. a made-up custom scheme): the assignment is a
// silent no-op, same as the standalone-PWA case. That is what the tests
// below drive.
import 'package:flutter_test/flutter_test.dart';
import 'package:masi/features/account/data/oauth_redirect_web.dart' as oauth;

void main() {
  setUp(() {
    // 2s of real waiting per test would make this suite miserable. The
    // watchdog's own doc explains why shrinking the grace changes nothing
    // about correctness — it only ever returns `false` if this document is
    // still alive to return anything at all.
    oauth.watchdogGrace = const Duration(milliseconds: 30);
  });

  tearDown(() {
    oauth.watchdogGrace = const Duration(milliseconds: 2000);
  });

  test('canRedirectTopLevel is true on web', () {
    expect(oauth.canRedirectTopLevel(), isTrue);
  });

  test('an empty url is refused immediately, before the watchdog applies', () {
    // No `await` on a delay here — if this took `watchdogGrace` to resolve,
    // that alone would indicate the empty-url short-circuit regressed.
    expect(oauth.redirectTopLevel(''), completion(isFalse));
  });

  test(
    'a navigation the browser silently no-ops on (unregistered scheme) is '
    'reported as false once the watchdog elapses — this is the bug fix: the '
    'browser does not throw, so the old code returned true unconditionally',
    () async {
      final result = await oauth.redirectTopLevel(
        'x-masi-test-nonexistent-scheme://silently-ignored',
      );
      expect(
        result,
        isFalse,
        reason:
            'the page is still here to observe this result at all, which is '
            'itself proof no navigation actually happened',
      );
    },
  );

  test(
    'the watchdog actually waits — a silent no-op does not resolve before '
    'watchdogGrace has elapsed',
    () async {
      oauth.watchdogGrace = const Duration(milliseconds: 200);
      final sw = Stopwatch()..start();
      await oauth.redirectTopLevel(
        'x-masi-test-nonexistent-scheme://silently-ignored',
      );
      sw.stop();
      expect(
        sw.elapsedMilliseconds,
        greaterThanOrEqualTo(180),
        reason:
            'a watchdog that returns false immediately (rather than after '
            'waiting) would defeat its own purpose: it would also fire on a '
            'navigation that is genuinely still in flight',
      );
    },
  );
}
