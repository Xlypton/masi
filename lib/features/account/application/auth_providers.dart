import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/supabase_providers.dart';
import '../../../core/db/database_provider.dart';
import '../../../core/db/settings_store.dart';
import '../data/auth_repository.dart';

/// The [AuthRepository] the rest of the `account` feature talks to.
///
/// Defaults to the real [SupabaseAuthRepository] wired to the shared
/// [supabaseClientProvider]; override this in tests with a fake
/// implementation (see `test/features/account/presentation/
/// account_screen_test.dart`) so nothing ever hits the real network.
final authRepositoryProvider = Provider<AuthRepository>(
  (ref) => SupabaseAuthRepository(ref.watch(supabaseClientProvider)),
);

/// Live [AuthSessionState]: signed-out or signed-in-with-email, sourced from
/// [authRepositoryProvider]'s [AuthRepository.authStateChanges] stream.
/// Mirrors the `library_providers.dart` pattern of a thin `StreamProvider`
/// over a repository method (e.g. `toposProvider`/`watchTopos`) rather than
/// a Notifier, since there is no local mutable state to own here — every
/// emission just reflects what Supabase's `onAuthStateChange` (or a test
/// fake) reports.
final authStateProvider = StreamProvider<AuthSessionState>(
  (ref) => ref.watch(authRepositoryProvider).authStateChanges(),
);

/// Holds the uid of the last account that had a real session on this device,
/// persisted in the local-only `AppSettings` table via [SettingsStore] so it
/// survives an app restart AND a hard sign-out.
///
/// This is the root fix for L4 and for the native silent-empty-library bug:
/// local data ownership must NOT depend on a reachable network. A captive
/// portal answering gotrue's token refresh with an HTML body is classified as
/// a non-retryable `AuthUnknownException`, so gotrue calls `_removeSession()`
/// and erases the persisted session — after which the live uid is null, every
/// `_ownOrUnowned` guard collapses to `ownerId IS NULL`, and the user's whole
/// library becomes invisible and unwritable while reporting success. Keeping
/// the uid locally means that scenario degrades to "offline", not "somebody
/// else".
///
/// Lifecycle (driven by `app/last_known_uid_bootstrap.dart`'s
/// `handleAuthStateForLastKnownUid`, wired in `MasiApp.build`):
///  - [remember] on every auth emission that carries a session uid.
///  - [forget] ONLY on a signed-out emission whose
///    [AuthSessionState.signOutCause] is [AuthSignOutCause.userInitiated].
///    `sessionExpired`/`sessionMissing`/unknown(cross-tab) must NOT clear it.
///  - [hydrate] once at boot, awaited in `main.dart`'s `bootApp` before
///    `runApp`, so no provider ever observes a spuriously-null uid on the
///    first frame.
///
/// [state] is the read path and is always updated SYNCHRONOUSLY, before the
/// async persist — so an account switch never serves a stale uid for the
/// duration of a drift write.
class LastKnownUid extends Notifier<String?> {
  @override
  String? build() => null;

  /// Loads the persisted uid into [state]. Never throws: `main()` awaits this
  /// before `runApp`, and an unopenable/failed database must degrade to "no
  /// last-known uid" rather than a white screen — the same log-and-continue
  /// stance `main()` takes around `Supabase.initialize`.
  Future<void> hydrate() async {
    try {
      final stored = await ref
          .read(settingsStoreProvider)
          .read(SettingsStore.lastKnownUidKey);
      if (stored != null && stored.isNotEmpty) state = stored;
    } catch (e, st) {
      debugPrint('lastKnownUid hydrate failed; continuing without it: $e\n$st');
    }
  }

  /// Records [uid] as the last known local session owner.
  ///
  /// Short-circuits when [state] already equals [uid]: `SyncOrchestrator`
  /// listens to UNFILTERED `db.tableUpdates()`, so a redundant write here
  /// would schedule a full sync push on every hourly `tokenRefreshed`
  /// re-emission of the same session. Only a genuine account change writes —
  /// and that legitimately warrants a push.
  Future<void> remember(String uid) async {
    if (uid.isEmpty || state == uid) return;
    state = uid;
    try {
      await ref
          .read(settingsStoreProvider)
          .write(SettingsStore.lastKnownUidKey, uid);
    } catch (e, st) {
      debugPrint('lastKnownUid persist failed: $e\n$st');
    }
  }

  /// Clears the last known uid — user-initiated sign-out ONLY.
  Future<void> forget() async {
    state = null;
    try {
      await ref
          .read(settingsStoreProvider)
          .remove(SettingsStore.lastKnownUidKey);
    } catch (e, st) {
      debugPrint('lastKnownUid clear failed: $e\n$st');
    }
  }
}

final lastKnownUidProvider = NotifierProvider<LastKnownUid, String?>(
  LastKnownUid.new,
);

/// THE single "who am I, for LOCAL data" door. Every local read/write scoping
/// decision — `watchTopos`' owner filter, `_ownOrUnowned`, `listOwnAreas`,
/// `listOwnSectors`, the logbook query, my-profile lookups, "is this mine"
/// badges — must resolve its uid here and nowhere else.
///
/// Resolution order:
///  1. The live session uid, read through the SYNCHRONOUS door
///     ([AuthRepository.currentSession]), which survives a retryable
///     auth-stream error because gotrue's offline refresh ticker only
///     `addError()`s and leaves the in-memory session intact.
///  2. Otherwise [lastKnownUidProvider].
///
/// The `ref.watch(authStateProvider)` below exists for REACTIVITY ONLY — its
/// value is deliberately discarded. That is the whole point: the old
/// `toposProvider` read `ref.watch(authStateProvider).asData?.value.uid`, and
/// `asData` is null for `AsyncError` just as much as for `AsyncLoading`, so a
/// single transient stream error collapsed the owner filter to
/// `owner_id IS NULL` and rendered "No topos yet" as a SUCCESSFUL empty
/// stream (no Retry affordance). Watching without trusting gives the rebuild
/// on sign-in/out/account-switch without the false signed-out.
///
/// `ref.watch` on a `StreamProvider` never rethrows a create-time failure —
/// an uninitialized Supabase makes [authStateProvider] a permanent
/// `AsyncError` (see `router.dart`'s doc), not a throw. The synchronous read
/// below CAN throw (`supabaseClientProvider` reads a `late` field), so it
/// keeps the try/catch this provider inherited from [currentUidProvider]:
/// absent auth degrades to signed-out, never crashes a create/edit path.
final effectiveUidProvider = Provider<String?>((ref) {
  ref.watch(authStateProvider);
  String? liveUid;
  try {
    liveUid = ref.read(authRepositoryProvider).currentSession.uid;
  } catch (_) {
    liveUid = null;
  }
  if (liveUid != null && liveUid.isNotEmpty) return liveUid;
  return ref.watch(lastKnownUidProvider);
});

/// Whether this device knows who its local data belongs to — i.e.
/// [effectiveUidProvider] resolved to something.
///
/// The router's web auth gate consumes this to tell "signed-in but offline"
/// (a persisted/last-known session, backend unreachable) apart from "never
/// signed in here", instead of failing closed on `authStateProvider.hasError`.
final hasKnownLocalSessionProvider = Provider<bool>(
  (ref) => ref.watch(effectiveUidProvider) != null,
);

/// Lazily-evaluated `String? Function()` form of [effectiveUidProvider], for
/// the repository constructors that take a `currentUid` seam and call it
/// per-INSERT/per-query.
///
/// Name and type are unchanged from before §1c so all seven repository
/// providers that pass `currentUid: ref.watch(currentUidProvider)`
/// (`database_provider.dart`, `library_providers.dart`, `ascents_providers.dart`,
/// `profile_providers.dart`, `likes_providers.dart`, `comments_providers.dart`)
/// inherit the last-known-uid fallback with no edit — ONE door, not seven
/// call-site patches. The uid is still read inside the closure (lazily, per
/// call) so this provider never rebuilds on auth changes and there is no
/// provider-construction cycle with the repository providers that consume it.
final currentUidProvider = Provider<String? Function()>((ref) {
  return () => ref.read(effectiveUidProvider);
});

/// Whether the web-only "must be signed in" auth wall (see `router.dart`'s
/// top-level redirect, `_webAuthGateRedirect`) is active for this app run.
///
/// Defaults to [kIsWeb]: on native (iOS/Android) the wall must be a total
/// no-op — this app is local-first and stays fully usable signed out there,
/// unchanged from before the wall existed. Only on web is an unauthenticated
/// visitor blocked from every route except the sign-in view
/// (`webAuthGateSignInPath`) until they complete a magic-link sign-in.
///
/// Deliberately a plain, override-able `Provider<bool>` — the redirect logic
/// itself must NEVER inline a bare `kIsWeb` check, so widget tests can force
/// the gate on or off (see `router_test.dart`'s "web auth wall" group)
/// without needing a real web build to flip the compile-time constant.
/// `kIsWeb` is used ONLY here, as this provider's default value.
final webAuthGateEnabledProvider = Provider<bool>((ref) => kIsWeb);
