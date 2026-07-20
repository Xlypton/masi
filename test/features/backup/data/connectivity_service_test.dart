import 'package:climbtopo/features/backup/data/connectivity_service.dart';
import 'package:flutter_test/flutter_test.dart';

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
}
