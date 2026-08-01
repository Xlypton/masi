import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:http/http.dart' as http;

import '../../../core/config/supabase_config.dart';

/// Coarse network status the backup engine cares about — collapses
/// `connectivity_plus`'s finer-grained [ConnectivityResult] list into just
/// what `wifiOnly` gating needs to decide.
enum NetworkStatus {
  /// Wifi or ethernet — "unmetered enough" to upload on.
  wifi,

  /// Cellular data only.
  cellular,

  /// No network reachable at all.
  none,

  /// Some other/unclassified transport (e.g. bluetooth, vpn-only).
  other,
}

/// Seam over `connectivity_plus`'s platform plugin so tests can force a
/// status (wifi/cellular/none) without a real platform channel. Mirrors the
/// `AuthRepository`/`BackupRemote` injectable-abstraction pattern used
/// elsewhere in this feature.
abstract class ConnectivityService {
  Future<NetworkStatus> currentStatus();

  /// True when the app can actually reach its backend RIGHT NOW, proven by a
  /// cheap round trip rather than inferred from the network interface.
  ///
  /// S4 fix (§1d): [currentStatus] is INTERFACE state only. It reports
  /// "connected" behind a captive portal, on a wifi network with no route,
  /// and — on web — returns [NetworkStatus.wifi] unconditionally (a browser
  /// cannot distinguish transports at all). `SyncStatus.offline` was
  /// therefore only ever producible by the `wifiOnly` skip, which is off by
  /// default and has no UI, i.e. it was unreachable in production. This is
  /// the signal that makes it both reachable and truthful.
  ///
  /// Never throws: any transport error, non-response or timeout resolves to
  /// `false`, mirroring `NominatimGeocodingService.search`'s best-effort
  /// never-throws contract.
  Future<bool> isBackendReachable();
}

/// Collapses `connectivity_plus`'s finer-grained [ConnectivityResult] list
/// into this app's [NetworkStatus].
///
/// Lifted verbatim out of [SystemConnectivityService.currentStatus]'s former
/// inline if-chain; top-level (rather than a private method) purely so the
/// mapping is directly unit-testable without a platform channel. §1e T7
/// additionally shares it with `statusChanges()`, so a one-shot read and a
/// stream event can never disagree — the extraction lands HERE rather than
/// in §1e (reconciliation decision #3) only because §1d rewrites this file
/// first and every fragment must emit a complete, compiling file.
NetworkStatus classifyConnectivityResults(List<ConnectivityResult> results) {
  if (results.contains(ConnectivityResult.wifi) ||
      results.contains(ConnectivityResult.ethernet)) {
    return NetworkStatus.wifi;
  }
  if (results.contains(ConnectivityResult.mobile)) {
    return NetworkStatus.cellular;
  }
  if (results.isEmpty || results.contains(ConnectivityResult.none)) {
    return NetworkStatus.none;
  }
  return NetworkStatus.other;
}

/// Real [ConnectivityService], backed by `connectivity_plus` (for
/// [currentStatus]) and a plain HTTP GET against the app's own Supabase
/// origin (for [isBackendReachable]).
class SystemConnectivityService implements ConnectivityService {
  SystemConnectivityService([
    Connectivity? connectivity,
    bool? isWeb,
    http.Client? httpClient,
  ]) : _connectivity = connectivity ?? Connectivity(),
       _isWeb = isWeb ?? kIsWeb,
       _httpClient = httpClient;

  final Connectivity _connectivity;

  /// Defaults to the real compile-time [kIsWeb] — only overridable (via the
  /// constructor's `isWeb` positional arg) so a unit test can exercise the
  /// web short-circuit below without a real browser test runner, mirroring
  /// `photo_source_sheet.dart`'s `showCameraOption` seam.
  ///
  /// Deliberately consulted ONLY by [currentStatus]: [isBackendReachable]
  /// behaves identically on every platform (S4).
  final bool _isWeb;

  /// Injected in tests (a fake `BaseClient`); `null` in production, where a
  /// plain `http.Client()` is created per probe and closed again — a probe
  /// happens at most once per failed sync, so there is nothing worth keeping
  /// open. Mirrors `NominatimGeocodingService`'s injectable-client seam.
  final http.Client? _httpClient;

  /// Bound on the probe. Long enough to survive a slow mobile round trip,
  /// short enough that a failed sync classifies itself promptly.
  @visibleForTesting
  static const Duration probeTimeout = Duration(seconds: 5);

  /// GoTrue's unauthenticated health endpoint on the app's OWN Supabase
  /// origin — the cheapest request that proves this backend answered.
  /// Deliberately not a third-party captive-portal-detection URL: what
  /// matters is whether the origin the sync engine talks to is reachable,
  /// not whether the internet at large is.
  @visibleForTesting
  static Uri get probeUri {
    final base = supabaseUrl.endsWith('/')
        ? supabaseUrl.substring(0, supabaseUrl.length - 1)
        : supabaseUrl;
    return Uri.parse('$base/auth/v1/health');
  }

  @override
  Future<bool> isBackendReachable() async {
    final client = _httpClient ?? http.Client();
    try {
      // The publishable/anon key is sent so the request is accepted by the
      // API gateway regardless of route policy; it is the same key the app
      // already ships (see supabase_config.dart) and carries no privilege.
      await client
          .get(probeUri, headers: const {'apikey': supabaseAnonKey})
          .timeout(probeTimeout);
      // ANY HTTP response at all — 2xx, 401, 404, 503 — proves the origin
      // answered, which is exactly what "reachable" means here. Only a
      // transport failure or a timeout lands in the catch below.
      return true;
    } catch (_) {
      return false;
    } finally {
      // Only close what this method created; an injected client belongs to
      // the caller.
      if (_httpClient == null) client.close();
    }
  }

  @override
  Future<NetworkStatus> currentStatus() async {
    // `connectivity_plus`'s web implementation can only report
    // online/offline (no wifi-vs-cellular distinction exists in a browser —
    // see WEB_PORT_BRIEF.md §2) and its exact online mapping varies by
    // browser, so treat any web session as [NetworkStatus.wifi]
    // unconditionally: the `wifiOnly` upload gate exists to avoid burning a
    // user's cellular data plan, a concept that doesn't apply to a desktop/
    // laptop browser tab, and gating web uploads on an unreliable signal
    // would silently strand backups in [SyncStatus.offline] forever.
    if (_isWeb) return NetworkStatus.wifi;
    return classifyConnectivityResults(await _connectivity.checkConnectivity());
  }
}
