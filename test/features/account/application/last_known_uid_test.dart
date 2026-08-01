import 'dart:async';

import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/core/db/settings_store.dart';
import 'package:masi/features/account/application/auth_providers.dart';
import 'package:masi/features/account/data/auth_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Stream-driven [AuthRepository] double: [currentSession] is the synchronous
/// door `effectiveUidProvider` reads, [emit] drives `authStateProvider`.
/// Mirrors `FakeAuthRepository` in
/// `test/features/backup/data/sync_service_test.dart`, which only needed
/// `currentSession` (push/pull are one-shot) — this one adds the stream half.
class StreamingFakeAuthRepository implements AuthRepository {
  StreamingFakeAuthRepository(this.currentSession);

  @override
  AuthSessionState currentSession;

  final _controller = StreamController<AuthSessionState>.broadcast();

  /// Sets [currentSession] AND pushes the same value down the stream, the way
  /// gotrue does (its synchronous getter and its stream never disagree).
  void emit(AuthSessionState state) {
    currentSession = state;
    _controller.add(state);
  }

  /// Pushes a stream error WITHOUT touching [currentSession] — exactly what
  /// gotrue's offline 10s refresh ticker does
  /// (`notifyException` -> `addError(AuthRetryableFetchException)`).
  void emitError(Object error) => _controller.addError(error);

  @override
  Stream<AuthSessionState> authStateChanges() => _controller.stream;

  @override
  Future<void> sendMagicLink(String email) async {}
  @override
  Future<void> signInWithGoogle() async {}
  @override
  Future<void> verifyEmailOtp(String email, String code) async {}
  @override
  Future<void> signOut() async {}

  Future<void> dispose() => _controller.close();
}

const _signedOut = AuthSessionState.signedOut();
final _signedInU1 = AuthSessionState.signedIn('u1@example.com', uid: 'user-u1');

void main() {
  late AppDatabase db;

  ({ProviderContainer container, StreamingFakeAuthRepository auth}) make({
    AuthSessionState initial = _signedOut,
  }) {
    db = AppDatabase(NativeDatabase.memory());
    final auth = StreamingFakeAuthRepository(initial);
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        nowMsProvider.overrideWithValue(() => 1000),
        authRepositoryProvider.overrideWithValue(auth),
      ],
    );
    // Teardown ORDER is load-bearing (tearDowns run in reverse registration
    // order, so this list disposes container -> auth -> db). Riverpod v3
    // PAUSES a provider's internal stream subscription while nothing is
    // actively listening, and a paused subscription never delivers `done` —
    // so closing the controller first makes `StreamController.close()`'s
    // future hang forever and every such test dies on the 30s timeout. The
    // consumer must be disposed before the producer is closed. (Reproducible
    // with a bare `container.read(authStateProvider)`; unrelated to §1c.)
    addTearDown(db.close);
    addTearDown(auth.dispose);
    addTearDown(container.dispose);
    return (container: container, auth: auth);
  }

  group('LastKnownUid', () {
    test('build() starts null', () {
      final t = make();
      expect(t.container.read(lastKnownUidProvider), isNull);
    });

    test('remember writes through to SettingsStore and updates state', () async {
      final t = make();
      await t.container.read(lastKnownUidProvider.notifier).remember('user-u1');
      expect(t.container.read(lastKnownUidProvider), 'user-u1');
      expect(
        await t.container
            .read(settingsStoreProvider)
            .read(SettingsStore.lastKnownUidKey),
        'user-u1',
      );
    });

    test('hydrate restores a persisted uid into state', () async {
      final t = make();
      await t.container
          .read(settingsStoreProvider)
          .write(SettingsStore.lastKnownUidKey, 'user-u1');
      expect(t.container.read(lastKnownUidProvider), isNull);
      await t.container.read(lastKnownUidProvider.notifier).hydrate();
      expect(t.container.read(lastKnownUidProvider), 'user-u1');
    });

    test('forget clears both state and the persisted value', () async {
      final t = make();
      final notifier = t.container.read(lastKnownUidProvider.notifier);
      await notifier.remember('user-u1');
      await notifier.forget();
      expect(t.container.read(lastKnownUidProvider), isNull);
      expect(
        await t.container
            .read(settingsStoreProvider)
            .read(SettingsStore.lastKnownUidKey),
        isNull,
      );
    });

    test('re-remembering the same uid does not write again', () async {
      // SyncOrchestrator listens to UNFILTERED db.tableUpdates(), so a
      // redundant app_settings write would schedule a full sync push on every
      // hourly tokenRefreshed re-emission.
      final t = make();
      final notifier = t.container.read(lastKnownUidProvider.notifier);
      await notifier.remember('user-u1');
      await t.container
          .read(settingsStoreProvider)
          .remove(SettingsStore.lastKnownUidKey);
      await notifier.remember('user-u1');
      expect(
        await t.container
            .read(settingsStoreProvider)
            .read(SettingsStore.lastKnownUidKey),
        isNull,
        reason: 'the second remember of an identical uid must be a no-op',
      );
    });

    test('hydrate degrades silently when the store throws', () async {
      // Must never break boot: main() awaits hydrate() before runApp.
      final broken = AppDatabase(NativeDatabase.memory());
      await broken.close();
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(broken),
          nowMsProvider.overrideWithValue(() => 1000),
          authRepositoryProvider.overrideWithValue(
            StreamingFakeAuthRepository(_signedOut),
          ),
        ],
      );
      addTearDown(container.dispose);
      await expectLater(
        container.read(lastKnownUidProvider.notifier).hydrate(),
        completes,
      );
      expect(container.read(lastKnownUidProvider), isNull);
    });
  });

  group('effectiveUidProvider', () {
    test('prefers the live session uid', () {
      final t = make(initial: _signedInU1);
      expect(t.container.read(effectiveUidProvider), 'user-u1');
    });

    test('is null when there is no session and no lastKnownUid', () {
      final t = make();
      expect(t.container.read(effectiveUidProvider), isNull);
    });

    test('falls back to lastKnownUid after a sessionExpired sign-out — L4', () async {
      final t = make(initial: _signedInU1);
      await t.container.read(lastKnownUidProvider.notifier).remember('user-u1');
      // Hard sign-out: gotrue's _removeSession() has run, so the
      // SYNCHRONOUS door now reports signed-out too.
      t.auth.emit(
        const AuthSessionState.signedOut(
          cause: AuthSignOutCause.sessionExpired,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(t.container.read(effectiveUidProvider), 'user-u1');
    });

    test('survives an auth-stream error with the session still in memory', () async {
      // The offline-refresh case: addError() only, currentSession intact.
      final t = make(initial: _signedInU1);
      final sub = t.container.listen(effectiveUidProvider, (_, _) {});
      addTearDown(sub.close);
      t.auth.emitError(Exception('AuthRetryableFetchException'));
      await Future<void>.delayed(Duration.zero);
      expect(t.container.read(authStateProvider).hasError, isTrue);
      expect(
        t.container.read(effectiveUidProvider),
        'user-u1',
        reason: 'asData is null on AsyncError; the sync door is not',
      );
    });

    test('is null after a user-initiated sign-out', () async {
      final t = make(initial: _signedInU1);
      final notifier = t.container.read(lastKnownUidProvider.notifier);
      await notifier.remember('user-u1');
      t.auth.emit(
        const AuthSessionState.signedOut(
          cause: AuthSignOutCause.userInitiated,
        ),
      );
      await notifier.forget();
      await Future<void>.delayed(Duration.zero);
      expect(t.container.read(effectiveUidProvider), isNull);
    });

    test('rebuilds when lastKnownUid changes', () async {
      final t = make();
      final seen = <String?>[];
      final sub = t.container.listen(
        effectiveUidProvider,
        (_, next) => seen.add(next),
        fireImmediately: true,
      );
      addTearDown(sub.close);
      await t.container.read(lastKnownUidProvider.notifier).remember('user-u1');
      // Riverpod v3 flushes dependant rebuilds + listener notifications
      // through its own scheduler, not synchronously on the state write, so
      // the emission is only observable after a pump. (The recomputation
      // itself is eager on `read` — see the currentUidProvider group.)
      await t.container.pump();
      expect(seen, [null, 'user-u1']);
    });

    test('degrades to lastKnownUid when auth cannot be built at all', () async {
      // No authRepositoryProvider override => supabaseClientProvider throws
      // (Supabase.instance is a late field). authStateProvider must become an
      // AsyncError, NOT crash, and the fallback must still work.
      final only = AppDatabase(NativeDatabase.memory());
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(only),
          nowMsProvider.overrideWithValue(() => 1000),
        ],
      );
      addTearDown(only.close);
      addTearDown(container.dispose);
      await container.read(lastKnownUidProvider.notifier).remember('user-u1');
      expect(container.read(effectiveUidProvider), 'user-u1');
    });
  });

  group('hasKnownLocalSessionProvider', () {
    test('true with a live session, false with nothing', () {
      expect(
        make(initial: _signedInU1).container.read(hasKnownLocalSessionProvider),
        isTrue,
      );
      expect(make().container.read(hasKnownLocalSessionProvider), isFalse);
    });

    test('true offline on lastKnownUid alone — signed-in-offline', () async {
      final t = make();
      await t.container.read(lastKnownUidProvider.notifier).remember('user-u1');
      expect(t.container.read(hasKnownLocalSessionProvider), isTrue);
    });
  });

  group('currentUidProvider delegates to the same door', () {
    test('agrees with effectiveUidProvider, including the fallback', () async {
      final t = make();
      expect(t.container.read(currentUidProvider)(), isNull);
      await t.container.read(lastKnownUidProvider.notifier).remember('user-u1');
      expect(t.container.read(currentUidProvider)(), 'user-u1');
      expect(
        t.container.read(currentUidProvider)(),
        t.container.read(effectiveUidProvider),
      );
    });
  });
}
