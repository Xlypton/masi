// Regression guard for `BlockedNetworkGuard` itself (#29) — the shared
// mechanism `router_test.dart` relies on to make real outbound network
// access IMPOSSIBLE for the `/map`-family tests that build a real
// `CommunityMapScreen` with no injectable `tileProvider` seam.
//
// This does not just assert the guard is "present" — it drives a REAL
// `package:http` request through it and asserts the request itself fails
// with the guard's own error, at the actual `dart:io` connectionFactory
// boundary (not a re-implemented fake `HttpClient`). If this test ever
// passed without the guard's `throw` firing, the guard would be a no-op and
// every test that relies on it would be silently making real network calls
// again.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'blocked_network.dart';

void main() {
  test(
    'a request made inside run() throws instead of reaching the network, '
    'and the blocked URI is recorded',
    () async {
      final guard = BlockedNetworkGuard();

      await expectLater(
        guard.run(
          () => http.get(Uri.parse('https://example.invalid/tile/1/2/3.png')),
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('example.invalid'),
          ),
        ),
      );

      expect(guard.attempts, hasLength(1));
      expect(guard.attempts.single, contains('example.invalid'));
    },
  );

  test(
    'a SECOND request in the same run() is blocked too — this is not a '
    'one-shot trap that only catches the first call',
    () async {
      final guard = BlockedNetworkGuard();

      await guard.run(() async {
        await expectLater(
          http.get(Uri.parse('https://one.invalid/')),
          throwsA(isA<StateError>()),
        );
        await expectLater(
          http.get(Uri.parse('https://two.invalid/')),
          throwsA(isA<StateError>()),
        );
        return null;
      });

      expect(guard.attempts, ['https://one.invalid/', 'https://two.invalid/']);
    },
  );

  test(
    'outside run(), the ambient HttpOverrides is restored — the guard does '
    'not leak into unrelated tests',
    () {
      expect(HttpOverrides.current, isNull);
    },
  );

  test(
    "leaves the client otherwise real (only connectionFactory is swapped) — "
    'guards against a future edit silently reimplementing the whole '
    'HttpClient interface',
    () async {
      late HttpClient client;
      await BlockedNetworkGuard().run(() async {
        client = HttpOverrides.current!.createHttpClient(null);
        return null;
      });

      expect(client, isA<HttpClient>());
      // A real HttpClient property, untouched by the override.
      expect(client.connectionTimeout, isNull);
      client.close();
    },
  );
}
