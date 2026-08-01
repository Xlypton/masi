import 'dart:async';
import 'dart:convert';

import 'package:masi/core/config/supabase_config.dart';
import 'package:masi/features/backup/data/connectivity_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart'
    show BaseClient, BaseRequest, ClientException, StreamedResponse;

/// A fake [BaseClient] that resolves every request synchronously to a
/// scripted status (or throws [throwOn]) — never touches real DNS/sockets,
/// mirroring `geocoding_service_test.dart`'s identically-shaped
/// `_FakeHttpClient`. [lastRequest] lets tests assert on the exact URL and
/// headers the probe sent.
class _FakeHttpClient extends BaseClient {
  _FakeHttpClient({this.statusCode = 200, this.throwOn});

  final int statusCode;
  final Object? throwOn;

  BaseRequest? lastRequest;
  int sendCount = 0;

  @override
  Future<StreamedResponse> send(BaseRequest request) async {
    lastRequest = request;
    sendCount++;
    final throwable = throwOn;
    if (throwable != null) throw throwable;
    return StreamedResponse(Stream.value(utf8.encode('{}')), statusCode);
  }
}

/// Web port Phase 4 (auth + sync on web), task 4:
/// `connectivity_plus`'s web implementation can only report online/offline
/// (no wifi-vs-cellular distinction exists in a browser -- see
/// WEB_PORT_BRIEF.md ss2), and gating the `wifiOnly` upload gate on an
/// unreliable web signal would silently strand backups in the `offline`
/// status forever. [SystemConnectivityService.currentStatus] must
/// short-circuit to [NetworkStatus.wifi] on web, before ever touching the
/// real `Connectivity()` platform channel (which `flutter_test`'s VM target
/// can't service anyway).
void main() {
  group('SystemConnectivityService web short-circuit', () {
    test(
      'currentStatus() returns wifi on web without ever calling the real '
      'Connectivity() plugin (constructing with isWeb: true and no plugin '
      'instance still resolves -- proving the platform channel is never '
      'touched)',
      () async {
        final service = SystemConnectivityService(null, true);
        expect(await service.currentStatus(), NetworkStatus.wifi);
      },
    );

    test(
      'defaults (isWeb omitted) fall back to the real kIsWeb, which is '
      'false under flutter test\'s VM target',
      () {
        // Constructing with the real Connectivity() plugin and no isWeb
        // override must not throw merely by existing (checkConnectivity()
        // itself is exercised elsewhere/on-device, not here -- this only
        // proves the constructor's default doesn't force the web branch).
        final service = SystemConnectivityService();
        expect(service, isNotNull);
      },
    );
  });

  group('§1d (S4): isBackendReachable — the real reachability probe', () {
    test(
      'a 2xx response means reachable, and the probe hits '
      '<supabaseUrl>/auth/v1/health carrying the publishable apikey',
      () async {
        final client = _FakeHttpClient();
        final service = SystemConnectivityService(null, null, client);

        expect(await service.isBackendReachable(), isTrue);

        final request = client.lastRequest;
        expect(request, isNotNull);
        expect(request!.method, 'GET');
        expect(request.url, SystemConnectivityService.probeUri);
        expect(request.url.toString(), '$supabaseUrl/auth/v1/health');
        expect(request.headers['apikey'], supabaseAnonKey);
      },
    );

    test(
      'a 5xx (or any other) HTTP response ALSO means reachable — the origin '
      'answered, which is precisely what this probe asks. Only a transport '
      'failure means offline; treating a 500 as offline would mislabel a '
      'backend outage as "you have no connection"',
      () async {
        final service = SystemConnectivityService(
          null,
          null,
          _FakeHttpClient(statusCode: 503),
        );

        expect(await service.isBackendReachable(), isTrue);
      },
    );

    test('a 401 also means reachable (reachable-but-not-authenticated)', () async {
      final service = SystemConnectivityService(
        null,
        null,
        _FakeHttpClient(statusCode: 401),
      );

      expect(await service.isBackendReachable(), isTrue);
    });

    test(
      'a transport failure (ClientException — how a failed browser fetch() '
      'surfaces through package:http) means NOT reachable',
      () async {
        final service = SystemConnectivityService(
          null,
          null,
          _FakeHttpClient(throwOn: ClientException('Failed to fetch')),
        );

        expect(await service.isBackendReachable(), isFalse);
      },
    );

    test('a timeout means NOT reachable, and never propagates', () async {
      final service = SystemConnectivityService(
        null,
        null,
        _FakeHttpClient(throwOn: TimeoutException('too slow')),
      );

      expect(await service.isBackendReachable(), isFalse);
    });

    test(
      'the probe runs on WEB too — the isWeb short-circuit that makes '
      'currentStatus() report wifi unconditionally must NOT leak into it, '
      'because that unconditional wifi is exactly why SyncStatus.offline was '
      'unreachable in production (S4)',
      () async {
        final client = _FakeHttpClient();
        final service = SystemConnectivityService(null, true, client);

        expect(await service.currentStatus(), NetworkStatus.wifi);
        expect(await service.isBackendReachable(), isTrue);
        expect(
          client.sendCount,
          1,
          reason: 'the probe really issued a request on the web path',
        );
      },
    );

    test('the probe is bounded by a 5s timeout', () {
      expect(SystemConnectivityService.probeTimeout, const Duration(seconds: 5));
    });
  });
}
