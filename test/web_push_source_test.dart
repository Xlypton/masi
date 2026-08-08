import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Source-level pins for the WEB PUSH half of `web/sw.js`.
///
/// `flutter test` runs no JavaScript and no browser, so — exactly like
/// `test/web_shell_source_test.dart` and `test/web_shell_offline_source_test.dart`,
/// whose convention this follows rather than repeats — these are string and
/// structure assertions over the worker source. They prove the code that must
/// exist is present and shaped correctly; they do not execute it.
///
/// This file exists because push fails in two ways that no other test here can
/// see, and one of them is a security hole rather than a bug:
///
///  1. **A throw inside the `push` handler shows the user nothing.** The worker
///     is woken with the app closed, so there is no console anybody is reading
///     and no UI to degrade — the notification simply never appears, and Chrome
///     substitutes its own "This site has been updated in the background".
///     Repeated throws can also get the subscription revoked outright. So every
///     malformed-payload path has to end at a fallback, never at an exception.
///  2. **`clients.openWindow` will open ANY origin it is handed.** The URL
///     arrives inside the push payload, and `new URL(untrusted, SCOPE)` happily
///     returns `https://evil.example/` for an absolute input. Without an
///     origin check, a tap on what looks like a Masi notification opens
///     somebody else's site. That check is the single most important line in
///     the push code and it is pinned below.
///
/// The iOS caveat these pins CANNOT cover, stated here because it is the thing
/// most likely to be forgotten: on iOS, Web Push only works when the PWA has
/// been installed to the home screen (16.4+). A Safari tab receives nothing at
/// all. Since iOS PWA is this project's primary target, and no automation on
/// this machine can drive an installed home-screen PWA (see CLAUDE.md), the
/// end-to-end iOS path is HUMAN-VERIFIED ONLY. Nothing in this file, and
/// nothing in the headless-Chrome harness, speaks to it.
void main() {
  final source = File(
    p.join(Directory.current.path, 'web', 'sw.js'),
  ).readAsStringSync();

  group('the push handler is present and cannot silently do nothing', () {
    test('a `push` listener exists', () {
      expect(
        source,
        contains("self.addEventListener('push'"),
        reason:
            'without this the worker is never woken for a push at all, and '
            'the entire feature is inert in a way that looks like the server '
            'not sending anything',
      );
    });

    test(
      'it shows a notification inside `waitUntil` — a `push` handler that '
      'returns before `showNotification` resolves is killed by the browser '
      'mid-flight',
      () {
        expect(source, contains('event.waitUntil(showPush(event.data))'));
        expect(source, contains('self.registration.showNotification('));
      },
    );

    test(
      'the icon is resolved against SCOPE rather than hardcoded — a bare '
      '"/icons/..." breaks under any non-root scope, and it must be a '
      'precached asset so it renders with no network',
      () {
        expect(source, contains("new URL('icons/Icon-192.png', SCOPE).href"));
        expect(
          File(
            p.join(Directory.current.path, 'web', 'icons', 'Icon-192.png'),
          ).existsSync(),
          isTrue,
          reason: 'the pinned icon has to actually exist in web/',
        );
      },
    );
  });

  group('every malformed payload ends at the fallback, never at a throw', () {
    test('there is a fallback payload to end at', () {
      expect(source, contains('const PUSH_FALLBACK'));
    });

    test(
      '`data.json()` is wrapped in try/catch — a push body that is not JSON '
      'throws there, and that throw is what replaces the notification with '
      "Chrome's own generic one",
      () {
        final parser = _functionBody(source, 'parsePushPayload');
        expect(parser, contains('data.json()'));
        expect(parser, contains('try {'));
        expect(parser, contains('catch'));
        expect(parser, contains('return PUSH_FALLBACK'));
      },
    );

    test(
      'a non-object payload (a bare string, a number, an ARRAY) is refused '
      '— `typeof [] === "object"`, so the array check is not redundant',
      () {
        final parser = _functionBody(source, 'parsePushPayload');
        expect(parser, contains("typeof raw !== 'object'"));
        expect(parser, contains('Array.isArray(raw)'));
      },
    );
  });

  group('the tap target cannot be pointed at another origin', () {
    test(
      'sameOriginPath checks BOTH the origin and the scope path prefix — a '
      'same-origin URL outside our registration scope is still not ours, '
      'which is the same pair of checks `scopedPath` already makes',
      () {
        final guard = _functionBody(source, 'sameOriginPath');
        expect(
          guard,
          contains('resolved.origin !== SCOPE.origin'),
          reason:
              'THE security check. `new URL(untrusted, SCOPE)` returns the '
              'attacker origin verbatim for an absolute input, and the result '
              'is handed to clients.openWindow',
        );
        expect(guard, contains('resolved.pathname.startsWith(SCOPE.pathname)'));
        expect(guard, contains('catch'), reason: 'new URL throws on garbage');
      },
    );

    test(
      'the payload URL and the click URL BOTH go through it — checking only '
      'one leaves the other as the way in',
      () {
        final parser = _functionBody(source, 'parsePushPayload');
        expect(parser, contains('sameOriginPath(raw.url)'));

        final clickIndex = source.indexOf("addEventListener('notificationclick'");
        expect(clickIndex, greaterThan(-1));
        final click = source.substring(clickIndex);
        expect(click, contains('sameOriginPath('));
      },
    );

    test('an unusable URL falls back to a path of ours, not to nothing', () {
      expect(source, contains('|| PUSH_FALLBACK.url'));
    });
  });

  group('tapping focuses the app instead of opening a second window', () {
    test(
      'matchAll is consulted before openWindow — a second window on this '
      'origin is a second client contending for the same OPFS-backed '
      'database, and it also loses the user their place',
      () {
        final body = _functionBody(source, 'focusOrOpen');
        expect(body, contains('self.clients.matchAll('));
        expect(body, contains("type: 'window'"));
        expect(body, contains('client.focus()'));
        final focusAt = body.indexOf('client.focus()');
        final openAt = body.indexOf('openWindow');
        expect(
          focusAt,
          lessThan(openAt),
          reason: 'openWindow must be the fallback, not the first move',
        );
      },
    );

    test('the notification is dismissed on tap', () {
      expect(source, contains('event.notification.close()'));
    });
  });

  group('the build pipeline still owns the worker', () {
    test(
      'the two lines `tool/gen_sw_manifest.dart` rewrites are untouched and '
      'still match its regexes — push handlers were appended AFTER them, and '
      'a stamp that silently stops matching ships a worker precaching nothing',
      () {
        expect(
          RegExp(r"^const SHELL_VERSION = '[^']*';$", multiLine: true)
              .allMatches(source)
              .length,
          1,
        );
        expect(
          RegExp(r'^const PRECACHE = \[[^\]]*\];$', multiLine: true)
              .allMatches(source)
              .length,
          1,
        );
      },
    );
  });
}

/// The source text of `function <name>(...)` up to the next top-level
/// declaration.
///
/// Crude on purpose: a real JS parser is not a dependency this repo has, and
/// these assertions only need to scope a `contains` to the right function so
/// that a check passing because of an unrelated line elsewhere in a 700-line
/// file is not mistaken for the check passing.
String _functionBody(String source, String name) {
  final start = source.indexOf('function $name(');
  expect(start, greaterThan(-1), reason: 'function $name is missing entirely');
  final next = source.indexOf('\nfunction ', start + 1);
  final end = next == -1 ? source.length : next;
  return source.substring(start, end);
}
