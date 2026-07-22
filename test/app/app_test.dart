import 'dart:async';

import 'package:masi/app/app.dart';
import 'package:masi/app/router.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/features/account/application/auth_providers.dart';
import 'package:masi/features/account/data/auth_repository.dart';
import 'package:masi/features/backup/application/sync_orchestrator.dart';
import 'package:masi/features/backup/application/sync_providers.dart';
import 'package:masi/features/backup/data/backup_repository.dart';
import 'package:masi/features/backup/data/connectivity_service.dart';
import 'package:masi/features/backup/data/sync_remote.dart';
import 'package:masi/features/backup/data/sync_service.dart';
import 'package:masi/features/library/presentation/topos_screen.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show StringCodec;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// A [SyncRemote] that does no real work but counts pull-side
/// (`fetchOwnRows`) calls — every `pullOwnAndShared()` call that gets past
/// `SyncService`'s signed-out guard calls `fetchOwnRows` exactly once, so
/// this is a reliable proxy for "how many times did `SyncOrchestrator`
/// actually invoke `pullOwnAndShared()`". Duplicated locally from
/// `sync_orchestrator_test.dart`'s identically-named, file-private class
/// (mirrors `community_feed_union_test.dart`'s stated convention of
/// duplicating rather than sharing file-private test doubles).
class _CountingSyncRemote implements SyncRemote {
  int pullCallCount = 0;

  @override
  Future<void> upsertOwnRows(
    String uid,
    Map<String, List<Map<String, dynamic>>> tablesToRows,
  ) async {}

  @override
  Future<Map<String, List<Map<String, dynamic>>>> fetchOwnRows(String uid) async {
    pullCallCount++;
    return {for (final t in syncTableNames) t: <Map<String, dynamic>>[]};
  }

  @override
  Future<Map<String, List<Map<String, dynamic>>>> fetchSharedTopos() async {
    return {
      for (final t in syncTableNames)
        if (t != 'ascents') t: <Map<String, dynamic>>[],
    };
  }

  @override
  Future<Map<String, List<Map<String, dynamic>>>> fetchSharedAscents() async {
    return {'ascents': <Map<String, dynamic>>[]};
  }

  @override
  Future<List<Map<String, dynamic>>> fetchProfiles(Set<String> uids) async => const [];

  @override
  Future<void> uploadPhoto({
    required String uid,
    required String photoId,
    required String ext,
    required List<int> bytes,
  }) async {}

  @override
  Future<List<int>?> downloadPhoto({required String uid, required String objectPath}) async =>
      null;

  @override
  Future<Set<String>> listPhotoObjectPaths(String uid) async => {};

  @override
  Future<void> uploadSharedPhoto({
    required String photoId,
    required String ext,
    required List<int> bytes,
  }) async {}

  @override
  Future<List<int>?> downloadSharedPhoto(String objectPath) async => null;

  @override
  Future<Set<String>> listSharedPhotoObjectPaths() async => {};

  @override
  Future<void> removePhoto({
    required String uid,
    required String photoId,
    required String ext,
  }) async {}

  @override
  Future<void> removeSharedPhoto({
    required String photoId,
    required String ext,
  }) async {}
}

/// Minimal [AuthRepository] test double standing in for the auth session
/// [SyncService] itself reads (`currentSession.uid`) — duplicated locally
/// from `sync_orchestrator_test.dart`'s identically-named class.
class _FakeAuthRepository implements AuthRepository {
  _FakeAuthRepository(this.currentSession);

  @override
  AuthSessionState currentSession;

  @override
  Stream<AuthSessionState> authStateChanges() => const Stream.empty();

  @override
  Future<void> sendMagicLink(String email) async {}

  @override
  Future<void> signInWithGoogle() async {}

  @override
  Future<void> verifyEmailOtp(String email, String code) async {}

  @override
  Future<void> signOut() async {}
}

/// Always-wifi [ConnectivityService] double — duplicated locally from
/// `sync_orchestrator_test.dart`'s identically-named class. [SyncService]'s
/// constructor requires one even though `pullOwnAndShared()` (the only path
/// this file's new #57 test exercises) never actually reads it.
class _FakeConnectivityService implements ConnectivityService {
  @override
  Future<NetworkStatus> currentStatus() async => NetworkStatus.wifi;
}

/// Mirrors `router_test.dart`'s `_makeContainer`: a fresh in-memory database
/// so `ToposScreen` (the `/` route) has something real to watch, without
/// touching the real filesystem/sqlite. `authStateProvider` is also
/// overridden to a known signed-out stream — the real
/// `authRepositoryProvider` reaches `Supabase.instance.client`, which throws
/// when `Supabase.initialize` never ran (true in this test process),
/// surfacing as an `AsyncError` that would otherwise route `AccountScreen`
/// to its (unrelated, out-of-scope) error-state body instead of the normal
/// signed-out one this test actually wants to drive.
ProviderContainer _makeContainer() {
  final db = AppDatabase(NativeDatabase.memory());
  final container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(db),
      nowMsProvider.overrideWithValue(() => 1000),
      authStateProvider.overrideWith(
        (ref) => Stream.value(const AuthSessionState.signedOut()),
      ),
      // `MasiApp` permanently `ref.watch`es `syncOrchestratorProvider`
      // (see its doc comment), so ANY real table write in a test that
      // mounts it — e.g. this file's claim-on-sign-in row update below —
      // now schedules a real debounced-push `Timer`. Left at the real 2s
      // production default, that `Timer` would still be pending when
      // `testWidgets` tears down the widget tree, tripping Flutter test's
      // "A Timer is still pending" invariant. A few milliseconds is easily
      // covered by `_drain`'s pump cycles below, so the timer always fires
      // (and stops being "pending") well before any test here ends.
      syncDebounceDurationProvider.overrideWithValue(
        const Duration(milliseconds: 5),
      ),
    ],
  );
  addTearDown(db.close);
  addTearDown(container.dispose);
  return container;
}

/// Mirrors `router_test.dart`'s `_drain`: advances real Drift async work
/// interleaved with fake-clock pumps to get past the initial
/// `CircularProgressIndicator`.
Future<void> _drain(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 30));
  }
  await tester.pumpAndSettle();
}

/// Simulates the engine delivering an app-lifecycle transition, the way a
/// real OS foreground/background event would — via the SAME `flutter/
/// lifecycle` platform channel `WidgetsFlutterBinding` really listens on
/// (`ServicesBinding.initInstances`'s `SystemChannels.lifecycle
/// .setMessageHandler(_handleLifecycleMessage)`), rather than calling
/// `WidgetsBinding`'s own `handleAppLifecycleStateChanged` directly — that
/// method is `@protected` (only callable from within the binding's own
/// class hierarchy), so an external test calling it directly would trip
/// the analyzer's `invalid_use_of_protected_member` check. Going through
/// `TestDefaultBinaryMessenger.handlePlatformMessage` (the documented,
/// non-deprecated, test-sanctioned entry point for "send a mock message to
/// the framework as if it came from the platform") exercises the exact
/// same code path a real transition would, INCLUDING the framework's own
/// synthesized intermediate states (e.g. paused -> resumed synthesizes
/// through `hidden`/`inactive` first — see `ServicesBinding
/// ._generateStateTransitions`) — harmless here since `MasiApp.
/// didChangeAppLifecycleState` only ever reacts to the terminal `paused`/
/// `resumed` states this helper's caller actually asks for.
Future<void> _setAppLifecycleState(WidgetTester tester, AppLifecycleState state) async {
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    'flutter/lifecycle',
    const StringCodec().encodeMessage(state.toString()),
    null,
  );
}

void main() {
  // `appRouter` is a module-level singleton (see `router_test.dart`'s
  // identical caveat) whose location persists across tests in this file.
  setUp(() => appRouter.go('/'));

  group('MasiApp global tap-to-dismiss keyboard (#20)', () {
    testWidgets(
      'MaterialApp.router wraps its routed content in a translucent '
      'GestureDetector whose onTap unfocuses the current focus',
      (tester) async {
        final container = _makeContainer();

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MasiApp(),
          ),
        );
        await _drain(tester);

        expect(find.byType(ToposScreen), findsOneWidget);

        final gestureDetectorFinder = find.byWidgetPredicate(
          (widget) =>
              widget is GestureDetector &&
              widget.behavior == HitTestBehavior.translucent &&
              widget.onTap != null,
        );
        expect(
          gestureDetectorFinder,
          findsOneWidget,
          reason:
              "MaterialApp.router's builder must wrap child in a "
              'translucent tap-to-dismiss GestureDetector',
        );
        // It must actually sit ABOVE the routed content (an ancestor), not
        // just exist somewhere unrelated in the tree.
        expect(
          find.ancestor(
            of: find.byType(ToposScreen),
            matching: gestureDetectorFinder,
          ),
          findsOneWidget,
        );

        // Now prove it actually dismisses the keyboard: navigate to the
        // Account screen (which has a real text field), focus that field,
        // then tap empty space elsewhere on screen and confirm focus drops.
        await tester.tap(find.byKey(const Key('topos-account-button')));
        await _drain(tester);

        expect(find.byKey(const Key('account-email-field')), findsOneWidget);
        await tester.tap(find.byKey(const Key('account-email-field')));
        await tester.pump();
        expect(
          tester.testTextInput.hasAnyClients,
          isTrue,
          reason: 'tapping the field must focus it and show the keyboard',
        );

        // Tap a point well above the field (still inside the signed-out
        // card, on the non-interactive title text / blank padding) so the
        // tap resolves to the outer GestureDetector rather than the field
        // itself re-focusing.
        final fieldTopLeft = tester.getTopLeft(
          find.byKey(const Key('account-email-field')),
        );
        await tester.tapAt(Offset(fieldTopLeft.dx, fieldTopLeft.dy - 40));
        await tester.pump();

        expect(
          tester.testTextInput.hasAnyClients,
          isFalse,
          reason: 'tapping empty space must dismiss the keyboard',
        );
      },
    );
  });

  group('MasiApp claim-on-sign-in bootstrap (C3)', () {
    testWidgets(
      'a real signed-out -> signed-in auth-state transition claims a '
      'previously-unowned local row for the new uid, exactly once',
      (tester) async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        await db
            .into(db.areas)
            .insert(
              AreasCompanion.insert(
                id: 'area-unowned',
                createdAt: 1000,
                updatedAt: 1000,
                name: 'Unowned Area',
              ),
            );

        // A single-subscription controller: `authStateProvider` subscribes
        // once and stays subscribed, so this supports any number of `add()`
        // calls before or after that single `listen()` — same reasoning as
        // `FakeAuthRepository` in `account_screen_test.dart`.
        final authController = StreamController<AuthSessionState>();
        addTearDown(authController.close);
        authController.add(const AuthSessionState.signedOut());

        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWithValue(db),
            nowMsProvider.overrideWithValue(() => 2000),
            authStateProvider.overrideWith((ref) => authController.stream),
            // See `_makeContainer`'s identical override above: the
            // claimOwnership row UPDATE below is a real table write, which
            // (now that `MasiApp` permanently watches
            // `syncOrchestratorProvider`) schedules a real debounced-push
            // `Timer` — keep it short so `_drain` lets it fire before this
            // test ends, instead of tripping the "Timer still pending"
            // widget-test invariant with the real 2s production default.
            syncDebounceDurationProvider.overrideWithValue(
              const Duration(milliseconds: 5),
            ),
          ],
        );
        addTearDown(container.dispose);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MasiApp(),
          ),
        );
        await _drain(tester);

        // Still signed-out: the row must remain unclaimed.
        var row = await (db.select(
          db.areas,
        )..where((t) => t.id.equals('area-unowned'))).getSingle();
        expect(row.ownerId, isNull);

        // Fire the signed-out -> signed-in edge.
        authController.add(
          const AuthSessionState.signedIn('a@b.com', uid: 'u1'),
        );
        await _drain(tester);

        row = await (db.select(
          db.areas,
        )..where((t) => t.id.equals('area-unowned'))).getSingle();
        expect(row.ownerId, 'u1');
        expect(row.dirty, isTrue);
        expect(row.updatedAt, 2000);

        // A second emission of the SAME signed-in session (e.g. a token
        // refresh) must not re-claim / re-touch the now-owned row again —
        // flip `nowMs` forward and confirm `updatedAt` does NOT move again.
        authController.add(
          const AuthSessionState.signedIn('a@b.com', uid: 'u1'),
        );
        await _drain(tester);

        row = await (db.select(
          db.areas,
        )..where((t) => t.id.equals('area-unowned'))).getSingle();
        expect(
          row.updatedAt,
          2000,
          reason: 'the claim must fire only once, on the actual '
              'signed-out -> signed-in edge, not on every re-emission',
        );
      },
    );
  });

  group('#57: resumed lifecycle triggers a pull', () {
    testWidgets(
      'AppLifecycleState.resumed calls pullNow(throttled: true) — a real '
      'pullOwnAndShared() reaches the remote once the resume-pull throttle '
      'window has elapsed since the last pull; AppLifecycleState.paused '
      'never pulls',
      (tester) async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final remote = _CountingSyncRemote();
        // Mutable (not a fixed closure) so the test can advance the clock
        // PAST `SyncOrchestrator._resumePullThrottle` (30s) between resume
        // events below — with a clock that never moves, every resume after
        // the first would be throttled as a no-op (by design: it's the
        // same guard that stops web tab-focus from hammering Supabase).
        var nowMs = 1000;
        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWithValue(db),
            nowMsProvider.overrideWithValue(() => nowMs),
            // Starts already signed-in: `SyncOrchestrator`'s edge-detector
            // treats the loading -> signed-in FIRST emission as an edge
            // too (see its doc: "signed-out (or unknown, e.g. still-
            // loading)... -> signed-in"), so mounting fires exactly ONE
            // pull immediately, before this test ever touches the
            // lifecycle — accounted for below rather than worked around,
            // since it's real, correct, pre-existing behavior this test
            // must not disturb.
            authStateProvider.overrideWith(
              (ref) => Stream.value(
                const AuthSessionState.signedIn('u1@example.com', uid: 'u1'),
              ),
            ),
            syncDebounceDurationProvider.overrideWithValue(
              const Duration(milliseconds: 5),
            ),
            syncServiceProvider.overrideWithValue(
              SyncService(
                db: db,
                backupRepository: BackupRepository(db),
                remote: remote,
                authRepository: _FakeAuthRepository(
                  const AuthSessionState.signedIn('u1@example.com', uid: 'u1'),
                ),
                connectivity: _FakeConnectivityService(),
              ),
            ),
          ],
        );
        addTearDown(container.dispose);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MasiApp(),
          ),
        );
        await _drain(tester);

        expect(
          remote.pullCallCount,
          1,
          reason: 'the mount-time signed-in edge already pulled once, '
              'before any lifecycle event fires',
        );

        // Backgrounding the app must still never pull (only push).
        await _setAppLifecycleState(tester, AppLifecycleState.paused);
        await _drain(tester);
        expect(
          remote.pullCallCount,
          1,
          reason: 'paused must push, never pull',
        );

        // Returning to the foreground, once the throttle window has
        // elapsed since the mount-time pull, must trigger exactly one more
        // pull.
        nowMs += const Duration(seconds: 31).inMilliseconds;
        await _setAppLifecycleState(tester, AppLifecycleState.resumed);
        await _drain(tester);
        expect(remote.pullCallCount, 2);

        // A second resume (e.g. a later background/foreground cycle),
        // again once the throttle window has elapsed, must trigger another
        // pull too — this is a plain re-invocation, not a one-shot edge
        // like the sign-in trigger.
        await _setAppLifecycleState(tester, AppLifecycleState.paused);
        await _drain(tester);
        nowMs += const Duration(seconds: 31).inMilliseconds;
        await _setAppLifecycleState(tester, AppLifecycleState.resumed);
        await _drain(tester);
        expect(remote.pullCallCount, 3);
      },
    );

    testWidgets(
      'a resume that fires again BEFORE the resume-pull throttle window has '
      'elapsed since the last pull is a no-op — it never reaches the '
      'remote a second time',
      (tester) async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final remote = _CountingSyncRemote();
        // Fixed clock: with the throttle in play, every resume in this
        // test after the mount-time pull is deliberately made WITHIN the
        // 30s window (see `_resumePullThrottle`'s doc), so it must be
        // skipped as a no-op.
        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWithValue(db),
            nowMsProvider.overrideWithValue(() => 1000),
            authStateProvider.overrideWith(
              (ref) => Stream.value(
                const AuthSessionState.signedIn('u1@example.com', uid: 'u1'),
              ),
            ),
            syncDebounceDurationProvider.overrideWithValue(
              const Duration(milliseconds: 5),
            ),
            syncServiceProvider.overrideWithValue(
              SyncService(
                db: db,
                backupRepository: BackupRepository(db),
                remote: remote,
                authRepository: _FakeAuthRepository(
                  const AuthSessionState.signedIn('u1@example.com', uid: 'u1'),
                ),
                connectivity: _FakeConnectivityService(),
              ),
            ),
          ],
        );
        addTearDown(container.dispose);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MasiApp(),
          ),
        );
        await _drain(tester);

        expect(
          remote.pullCallCount,
          1,
          reason: 'the mount-time signed-in edge already pulled once',
        );

        // Two rapid resumes, clock unchanged — the SECOND must be
        // throttled, exactly the web tab-focus-spam scenario this guard
        // exists for.
        await _setAppLifecycleState(tester, AppLifecycleState.paused);
        await _drain(tester);
        await _setAppLifecycleState(tester, AppLifecycleState.resumed);
        await _drain(tester);
        await _setAppLifecycleState(tester, AppLifecycleState.paused);
        await _drain(tester);
        await _setAppLifecycleState(tester, AppLifecycleState.resumed);
        await _drain(tester);

        expect(
          remote.pullCallCount,
          1,
          reason: 'rapid resumes within the throttle window must collapse '
              'into the single already-completed mount-time pull, not '
              'trigger a second network round-trip',
        );
      },
    );
  });
}
