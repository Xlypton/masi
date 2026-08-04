import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../features/account/application/auth_providers.dart';
import '../../features/backup/application/backup_providers.dart';
import '../../features/backup/application/sync_providers.dart';
import 'supabase_config.dart';
import 'supabase_providers.dart';

/// Whether the process-wide Supabase client exists at all, this run.
///
/// UF-6: `Supabase.initialize` is wrapped in a `try`/`catch` in `main.dart`
/// (bad config, no network on the very first launch, a transient outage) so a
/// failure cannot take boot down — this app is local-first and fully usable
/// with the cloud gone. But the failure was recorded NOWHERE, and every cloud
/// provider degrades to a signed-out no-op that reports SUCCESS: `SyncService`
/// answers `skippedSignedOut`, `SyncOrchestrator` reads that as
/// [SyncStatus.idle], and the user is shown a healthy, synced app whose topos
/// are on exactly one device. For an app whose entire purpose is not losing
/// work, presenting a dead cloud as a working one is the worst available
/// failure shape.
///
/// This enum is the missing fact. It distinguishes the two situations that
/// used to look identical:
///  - genuinely signed out — nothing to sync, not an error, [ready];
///  - the cloud client could not be built at all — nothing CAN be synced and
///    the app must say so, [failed].
enum CloudInitStatus {
  /// `initialize()` has not been attempted yet. Only observed before boot's
  /// attempt completes, and in unit/widget tests that never call it — which
  /// is why it must behave like "not broken" everywhere downstream: a test
  /// that overrides `syncServiceProvider` with a fake must not be told the
  /// cloud is down.
  pending,

  /// `Supabase.initialize` completed. Says nothing about connectivity or
  /// about being signed in — only that `Supabase.instance.client` exists.
  ready,

  /// `Supabase.initialize` threw. There is no client, so auth, sync and
  /// backup are all unavailable until a retry succeeds.
  failed,
}

/// Immutable snapshot of [CloudInitController].
@immutable
class CloudInitState {
  const CloudInitState._(this.status, this.error);

  const CloudInitState.pending() : this._(CloudInitStatus.pending, null);
  const CloudInitState.ready() : this._(CloudInitStatus.ready, null);
  const CloudInitState.failed(Object error)
    : this._(CloudInitStatus.failed, error);

  final CloudInitStatus status;

  /// Whatever `Supabase.initialize` threw, or `null` unless [isFailed].
  /// Retained (rather than reduced to a bool) because it is the only clue a
  /// field report will ever carry about WHY the cloud is missing.
  final Object? error;

  /// The one condition callers gate on. Deliberately false for
  /// [CloudInitStatus.pending] — see that value's doc.
  bool get isFailed => status == CloudInitStatus.failed;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CloudInitState &&
          other.status == status &&
          other.error == error);

  @override
  int get hashCode => Object.hash(status, error);

  @override
  String toString() => 'CloudInitState(status: ${status.name}, error: $error)';
}

/// The actual `Supabase.initialize` call, behind a provider so tests can
/// substitute a throwing/succeeding fake without a real network stack or a
/// real singleton.
///
/// Must complete normally on success and throw on failure — [CloudInitController]
/// classifies it on exactly that.
typedef SupabaseInitializer = Future<void> Function();

final supabaseInitializerProvider = Provider<SupabaseInitializer>(
  (ref) => initializeSupabase,
);

/// Production [SupabaseInitializer].
///
/// Re-callable: `Supabase.initialize` returns the existing singleton
/// immediately when `_isInitialized` is already set (supabase_flutter 2.16's
/// `supabase.dart`: "Supabase is already initialized. Skipping
/// reinitialization."), and a call that THREW never set that flag, so a retry
/// genuinely re-attempts the work rather than asserting.
Future<void> initializeSupabase() => Supabase.initialize(
  url: supabaseUrl,
  publishableKey: supabaseAnonKey,
  authOptions: const FlutterAuthClientOptions(
    authFlowType: AuthFlowType.pkce,
  ),
);

/// Owns [CloudInitState] and is the ONLY place `Supabase.initialize` is
/// called from — boot (`main.dart`) and every retry share one code path, so
/// the two can never drift into different init arguments or different
/// error handling.
class CloudInitController extends Notifier<CloudInitState> {
  @override
  CloudInitState build() => const CloudInitState.pending();

  /// Attempts initialization and records the outcome. Returns whether the
  /// cloud client is now usable.
  ///
  /// NEVER THROWS: a failure must not take boot down (local-first work has to
  /// keep functioning with no cloud at all), and must not take a retry tap
  /// down either. The failure is recorded in [state] instead, which is what
  /// makes it VISIBLE — see this file's header for the invisible-no-op bug
  /// this replaces.
  ///
  /// Idempotent on success: already-[CloudInitStatus.ready] returns `true`
  /// without touching the singleton again.
  ///
  /// On a success that follows a failure, every provider that reaches for
  /// `Supabase.instance.client` is invalidated. Without that the retry would
  /// be cosmetic: `supabaseClientProvider` caches the `LateInitializationError`
  /// it threw, and `syncServiceProvider` caches the `_UnavailableSyncRemote`
  /// fallback it swapped in — both would keep serving the dead values for the
  /// rest of the app run, so recovering from a boot-time outage would still
  /// require an app restart.
  Future<bool> initialize() async {
    if (state.status == CloudInitStatus.ready) return true;
    final wasFailed = state.isFailed;
    try {
      await ref.read(supabaseInitializerProvider)();
    } catch (error, stackTrace) {
      // Logged unconditionally (not behind `kDebugMode`), like
      // `logStorageDurability`: on a release web build this console line is
      // the only thing that can answer "why did nothing sync?".
      debugPrint(
        'masi/cloud: Supabase.initialize failed; the app keeps working '
        'locally but nothing will sync until this succeeds: $error\n'
        '$stackTrace',
      );
      if (ref.mounted) state = CloudInitState.failed(error);
      return false;
    }
    if (!ref.mounted) return true;
    state = const CloudInitState.ready();
    if (wasFailed) _invalidateCloudProviders();
    return true;
  }

  /// Drops every cached provider value that was derived from a
  /// not-yet-existing Supabase client.
  ///
  /// [supabaseClientProvider] is the root, and everything below it would
  /// normally rebuild transitively — except that the two providers whose
  /// whole job is to SURVIVE a missing client swallow the upstream throw and
  /// cache a fallback ([syncServiceProvider]'s `_SignedOutAuthRepository` /
  /// `_UnavailableSyncRemote`), which is exactly the kind of edge Riverpod
  /// cannot see through. They are therefore invalidated by name.
  /// Invalidation is cheap and idempotent for a provider that was never
  /// built, so over-listing costs nothing while under-listing silently keeps
  /// the app broken for the rest of the run.
  ///
  /// The `core/` -> `features/` direction here matches the existing
  /// `core/db/database_provider.dart`, which already imports
  /// `features/account` and `features/topo`.
  void _invalidateCloudProviders() {
    ref.invalidate(supabaseClientProvider);
    ref.invalidate(authRepositoryProvider);
    ref.invalidate(syncRemoteProvider);
    ref.invalidate(syncServiceProvider);
    ref.invalidate(backupRemoteProvider);
    ref.invalidate(cloudBackupServiceProvider);
  }
}

final cloudInitProvider =
    NotifierProvider<CloudInitController, CloudInitState>(
      CloudInitController.new,
    );

/// The user-facing reason string for a [CloudInitStatus.failed] cloud, phrased
/// to slot into the existing "Couldn't sync — …" surface (`SyncBanner`,
/// `topos_empty_states.dart`, `community_feed_screen.dart`) rather than
/// inventing a second vocabulary for the same news.
///
/// Names the CONSEQUENCE first, because that is the user's actual question:
/// their topos are on this device only. The exception text is appended, in
/// parentheses, for the field report.
String cloudUnavailableMessage(CloudInitState state) {
  final detail = state.error == null ? '' : ' (${state.error})';
  return "the app couldn't connect to the cloud, so nothing has been backed "
      'up yet — your topos are safe on this device$detail';
}
