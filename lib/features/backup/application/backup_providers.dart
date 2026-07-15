import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/supabase_providers.dart';
import '../../../core/db/database_provider.dart';
import '../../account/application/auth_providers.dart';
import '../../topo/data/photo_files.dart';
import '../data/backup_remote.dart';
import '../data/backup_repository.dart';
import '../data/cloud_backup_service.dart';
import '../data/connectivity_service.dart';

/// Provides the [BackupRepository] wired to the app-wide [AppDatabase],
/// matching the repo-provider pattern used elsewhere
/// (`lib/core/db/database_provider.dart`). Overridable in tests with an
/// in-memory `appDatabaseProvider`.
final backupRepositoryProvider = Provider<BackupRepository>(
  (ref) => BackupRepository(ref.watch(appDatabaseProvider)),
);

/// The [BackupRemote] the cloud backup engine talks to.
///
/// Defaults to the real [SupabaseBackupRemote] wired to the shared
/// [supabaseClientProvider]; override this in tests with an in-memory fake
/// (see `test/features/backup/data/cloud_backup_service_test.dart`) so
/// nothing ever hits the real network.
final backupRemoteProvider = Provider<BackupRemote>(
  (ref) => SupabaseBackupRemote(ref.watch(supabaseClientProvider)),
);

/// The [ConnectivityService] `wifiOnly` push gating reads from.
///
/// Defaults to the real [SystemConnectivityService] (backed by
/// `connectivity_plus`); override this in tests with a fake that reports a
/// fixed [NetworkStatus].
final connectivityServiceProvider = Provider<ConnectivityService>(
  (ref) => SystemConnectivityService(),
);

/// Whether cloud backup pushes should be restricted to wifi (skipping on
/// cellular/no connection). A plain in-memory toggle — deliberately minimal;
/// nothing here persists it across app launches yet.
class WifiOnlySetting extends Notifier<bool> {
  @override
  bool build() => false;

  void set(bool value) => state = value;
}

final wifiOnlySettingProvider = NotifierProvider<WifiOnlySetting, bool>(
  WifiOnlySetting.new,
);

/// The [CloudBackupService] the "back up now" / "restore" entry points call
/// into, wired to the app-wide backup repository, auth session, remote, and
/// connectivity + `wifiOnly` seams above. Overridable wholesale in tests
/// (or piecemeal via its upstream providers).
final cloudBackupServiceProvider = Provider<CloudBackupService>(
  (ref) => CloudBackupService(
    backupRepository: ref.watch(backupRepositoryProvider),
    authRepository: ref.watch(authRepositoryProvider),
    remote: ref.watch(backupRemoteProvider),
    connectivity: ref.watch(connectivityServiceProvider),
    photoFiles: PhotoFiles(),
    wifiOnly: () => ref.read(wifiOnlySettingProvider),
  ),
);
