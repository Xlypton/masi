import 'package:connectivity_plus/connectivity_plus.dart';

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
  SystemConnectivityService([Connectivity? connectivity])
    : _connectivity = connectivity ?? Connectivity();

  final Connectivity _connectivity;

  @override
  Future<NetworkStatus> currentStatus() async {
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
