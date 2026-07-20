import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

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
}

/// Real [ConnectivityService], backed by `connectivity_plus`.
class SystemConnectivityService implements ConnectivityService {
  SystemConnectivityService([Connectivity? connectivity, bool? isWeb])
    : _connectivity = connectivity ?? Connectivity(),
      _isWeb = isWeb ?? kIsWeb;

  final Connectivity _connectivity;

  /// Defaults to the real compile-time [kIsWeb] — only overridable (via the
  /// constructor's `isWeb` positional arg) so a unit test can exercise the
  /// web short-circuit below without a real browser test runner, mirroring
  /// `photo_source_sheet.dart`'s `showCameraOption` seam.
  final bool _isWeb;

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
    final results = await _connectivity.checkConnectivity();
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
}
