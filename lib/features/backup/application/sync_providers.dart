import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/supabase_providers.dart';
import '../../../core/db/database_provider.dart';
import '../../account/application/auth_providers.dart';
import '../../account/data/auth_repository.dart';
import '../../topo/data/photo_files.dart';
import '../domain/shared_topo_scope.dart';
import '../data/sync_remote.dart';
import '../data/sync_service.dart';
import 'backup_providers.dart';

/// The [SyncRemote] the row-level sync engine talks to.
///
/// Defaults to the real [SupabaseSyncRemote] wired to the shared
/// [supabaseClientProvider]; override this in tests with an in-memory fake
/// (see `test/features/backup/data/sync_service_test.dart`'s
/// `FakeSyncRemote`) so nothing ever hits the real network. Like
/// [supabaseClientProvider] itself, reading this provider directly throws
/// if Supabase was never initialized — [syncServiceProvider] below reads it
/// through a guard rather than watching it unguarded, so constructing the
/// service never throws even in that case.
final syncRemoteProvider = Provider<SyncRemote>(
  (ref) => SupabaseSyncRemote(ref.watch(supabaseClientProvider)),
);

/// A signed-out-only [AuthRepository] used ONLY as [syncServiceProvider]'s
/// fallback when reading the real [authRepositoryProvider] throws (Supabase
/// never initialized) — mirrors `currentUidProvider`'s
/// "unavailable auth degrades to signed-out, never a crash" stance. Every
/// method beyond [currentSession] is unreachable from [SyncService] (it
/// only ever reads `.currentSession.uid`) and exists purely to satisfy the
/// interface.
class _SignedOutAuthRepository implements AuthRepository {
  const _SignedOutAuthRepository();

  @override
  Stream<AuthSessionState> authStateChanges() => const Stream.empty();

  @override
  AuthSessionState get currentSession => const AuthSessionState.signedOut();

  @override
  Future<void> sendMagicLink(String email) async {}

  @override
  Future<void> signInWithGoogle() async {}

  @override
  Future<void> verifyEmailOtp(String email, String code) async {}

  @override
  Future<void> signOut() async {}
}

/// A [SyncRemote] whose every method throws — used ONLY as
/// [syncServiceProvider]'s fallback when reading the real
/// [syncRemoteProvider] throws (Supabase never initialized). Safe to wire
/// in because [SyncService.pushOwn]/[SyncService.pullOwnAndShared] both
/// check `currentSession.uid == null` (via the matching
/// [_SignedOutAuthRepository] fallback) and return a `skippedSignedOut`
/// result BEFORE ever calling into `_remote` — so these methods are
/// unreachable in practice; they throw rather than silently no-op so a
/// future refactor that removes that early-return gets a loud failure
/// instead of a silent one.
class _UnavailableSyncRemote implements SyncRemote {
  const _UnavailableSyncRemote();

  Never _unavailable() => throw UnsupportedError(
    'SyncRemote is unavailable because Supabase was not initialized; this '
    'should be unreachable since SyncService always checks '
    'currentSession.uid == null before calling into the remote.',
  );

  @override
  Future<List<TablePushOutcome>> upsertOwnRows(
    String uid,
    Map<String, List<Map<String, dynamic>>> tablesToRows,
  ) => _unavailable();

  @override
  Future<Map<String, List<Map<String, dynamic>>>> fetchOwnRows(String uid) =>
      _unavailable();

  @override
  Future<Map<String, List<Map<String, dynamic>>>> fetchSharedTopos({
    SharedTopoScope scope = const SharedTopoScope.unbounded(),
  }) => _unavailable();

  @override
  Future<Map<String, List<Map<String, dynamic>>>> fetchSharedAscents() =>
      _unavailable();

  @override
  Future<Map<String, List<Map<String, dynamic>>>> fetchEngagementByParentIds({
    required List<String> ascentIds,
    required List<String> wallIds,
  }) => _unavailable();

  @override
  Future<void> uploadPhoto({
    required String uid,
    required String photoId,
    required String ext,
    required List<int> bytes,
  }) => _unavailable();

  @override
  Future<List<int>?> downloadPhoto({
    required String uid,
    required String objectPath,
  }) => _unavailable();

  @override
  Future<Set<String>> listPhotoObjectPaths(String uid) => _unavailable();

  @override
  Future<void> uploadSharedPhoto({
    required String photoId,
    required String ext,
    required List<int> bytes,
  }) => _unavailable();

  @override
  Future<List<int>?> downloadSharedPhoto(String objectPath) => _unavailable();

  @override
  Future<Set<String>> listSharedPhotoObjectPaths() => _unavailable();

  @override
  Future<void> removePhoto({
    required String uid,
    required String photoId,
    required String ext,
  }) => _unavailable();

  @override
  Future<Set<String>> removeSharedPhoto({
    required String photoId,
    required String ext,
  }) => _unavailable();

  @override
  Future<List<Map<String, dynamic>>> fetchProfiles(Set<String> uids) =>
      _unavailable();

  @override
  Future<List<String>> fetchVisibleWallIds(List<String> ids) =>
      _unavailable();
}

/// The [SyncService] the "sync now" entry point(s) call into, wired to the
/// app-wide database, backup repository (for its LWW import machinery),
/// sync remote, auth session, and connectivity + `wifiOnly` seams.
/// Overridable wholesale in tests (or piecemeal via its upstream
/// providers).
///
/// Reading [authRepositoryProvider] and [syncRemoteProvider] is GUARDED
/// here (try/catch, falling back to [_SignedOutAuthRepository] /
/// [_UnavailableSyncRemote]) rather than watched directly — both
/// transitively read [supabaseClientProvider], which throws if
/// `Supabase.initialize` never ran (first-launch-offline / test setups
/// without Supabase). `cloudBackupServiceProvider` does NOT guard this and
/// will throw when constructed in that state; this provider deliberately
/// does not repeat that, mirroring how `currentUidProvider` degrades to
/// signed-out instead of crashing.
final syncServiceProvider = Provider<SyncService>((ref) {
  AuthRepository authRepository;
  try {
    authRepository = ref.watch(authRepositoryProvider);
  } catch (_) {
    authRepository = const _SignedOutAuthRepository();
  }

  SyncRemote remote;
  try {
    remote = ref.watch(syncRemoteProvider);
  } catch (_) {
    remote = const _UnavailableSyncRemote();
  }

  return SyncService(
    db: ref.watch(appDatabaseProvider),
    backupRepository: ref.watch(backupRepositoryProvider),
    remote: remote,
    authRepository: authRepository,
    connectivity: ref.watch(connectivityServiceProvider),
    photoFiles: PhotoFiles(),
    wifiOnly: () => ref.read(wifiOnlySettingProvider),
  );
});
