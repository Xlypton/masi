// The accent dot on the Topos home's account avatar: somebody has suggested an
// edit to one of this user's topos and it is still waiting for an answer.
//
// The trap, and the reason for the second group below. `mySuggestionsProvider`
// is an `autoDispose FutureProvider` over a NETWORK fetch — it resolves once at
// mount and then never again on its own. So a dot rendered off it alone is dark
// on exactly the day a suggestion arrives: the app was already open (or, on an
// installed PWA, backgrounded) when it landed. `ToposScreen` therefore observes
// `AppLifecycleState.resumed` and invalidates the provider, and the test that
// matters here is the one that proves the dot reflects a value which arrived
// ONLY after that invalidation — not merely that a first resolve can light it.

import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:masi/app/theme.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/features/account/application/auth_providers.dart';
import 'package:masi/features/account/data/auth_repository.dart';
import 'package:masi/features/backup/application/backup_providers.dart';
import 'package:masi/features/backup/application/sync_orchestrator.dart';
import 'package:masi/features/backup/data/connectivity_service.dart';
import 'package:masi/features/library/application/library_providers.dart';
import 'package:masi/features/library/data/library_crud_repository.dart';
import 'package:masi/features/library/presentation/topos_screen.dart';
import 'package:masi/features/moderation/application/suggestion_providers.dart';
import 'package:masi/features/moderation/data/suggestions_remote.dart';
import 'package:masi/features/moderation/domain/edit_suggestion.dart';

import '../../../support/async_drain.dart';

const _dot = Key('topos-account-suggestions-dot');

class _FakeSyncOrchestrator extends SyncOrchestrator {
  @override
  SyncOrchestratorState build() => const SyncOrchestratorState();

  @override
  Future<void> pullNow({bool throttled = false}) async {}
}

class _ReachableConnectivity implements ConnectivityService {
  @override
  Future<bool> isBackendReachable() async => true;

  @override
  Future<NetworkStatus> currentStatus() async => NetworkStatus.wifi;

  @override
  Stream<NetworkStatus> statusChanges() => const Stream.empty();
}

/// A [SuggestionsRemote] that answers [fetchForMe] from a SCRIPT — one entry per
/// call, so a test can make the FIRST resolve empty and the SECOND non-empty and
/// therefore tell "the provider re-ran" apart from "the provider happened to
/// return something". The last entry repeats once the script runs out.
class _ScriptedSuggestionsRemote implements SuggestionsRemote {
  _ScriptedSuggestionsRemote(this.script);

  final List<List<Map<String, dynamic>>> script;
  int calls = 0;

  @override
  Future<List<Map<String, dynamic>>> fetchForMe({int limit = 50}) async {
    final index = calls < script.length ? calls : script.length - 1;
    calls++;
    return script[index];
  }

  @override
  Future<String> suggest({
    required String wallId,
    required SuggestionKind kind,
    required Map<String, Object?> patch,
    String? note,
    String? routeId,
    String? photoId,
  }) async => throw UnimplementedError();

  @override
  Future<String> resolve({
    required String suggestionId,
    required bool accept,
    String? note,
  }) async => throw UnimplementedError();
}

/// One row in the shape `EditSuggestion.fromRow` parses — camelCase keys, and a
/// patch whose field is on `kSuggestableFields`' whitelist for the kind (a patch
/// with nothing applicable left parses to null, i.e. no suggestion at all, which
/// would silently defeat every assertion in this file).
Map<String, dynamic> _row(String id) => {
  'id': id,
  'wallId': 'w-1',
  'wallName': 'Warm Up Slab',
  'authorId': 'uid-helper',
  'kind': 'topo.metadata',
  'patch': {'name': 'Better Name'},
  'note': null,
  'createdAt': '2026-08-10T10:00:00Z',
  'state': 'open',
};

ProviderContainer _makeContainer(_ScriptedSuggestionsRemote remote) {
  final db = AppDatabase(NativeDatabase.memory());
  final container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(db),
      nowMsProvider.overrideWithValue(() => 1000),
      connectivityServiceProvider.overrideWithValue(_ReachableConnectivity()),
      syncOrchestratorProvider.overrideWith(_FakeSyncOrchestrator.new),
      // The avatar (and therefore the dot's host) only renders for a real
      // signed-in email; `effectiveUidProvider` is what `mySuggestionsProvider`
      // actually keys on, and it reads the SYNCHRONOUS session door, which no
      // `authStateProvider` override can reach — so both are overridden.
      authStateProvider.overrideWith(
        (ref) => Stream.value(const AuthSessionState.signedIn('me@masi.test')),
      ),
      effectiveUidProvider.overrideWithValue('uid-me'),
      suggestionsRemoteProvider.overrideWithValue(remote),
      toposProvider.overrideWith(
        (ref) => Stream.value(const [
          TopoRef(
            wallId: 'w-1',
            name: 'Warm Up Slab',
            thumbnailPath: null,
            routeCount: 1,
            createdAt: 1000,
          ),
        ]),
      ),
    ],
  );
  addTearDown(db.close);
  addTearDown(container.dispose);
  return container;
}

Widget _wrap(ProviderContainer container) {
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(path: '/', builder: (context, state) => const ToposScreen()),
      GoRoute(
        path: '/walls/:wallId',
        builder: (context, state) => const SizedBox(),
      ),
      GoRoute(path: '/areas', builder: (context, state) => const SizedBox()),
      GoRoute(path: '/account', builder: (context, state) => const SizedBox()),
    ],
  );
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp.router(theme: MasiTheme.light, routerConfig: router),
  );
}

Future<void> _drain(WidgetTester tester) async {
  await drainAsync(tester, rounds: 6, settle: false);
  await tester.pumpAndSettle();
}

/// Drives the FULL lifecycle sequence, not a single jump.
///
/// `AppLifecycleListener` (mounted inside the framework's own widgets) asserts
/// on illegal transitions, so `resumed -> paused` throws rather than being
/// treated as "the app went away". The real sequences are
/// `resumed -> inactive -> hidden -> paused` and its reverse.
Future<void> _background(WidgetTester tester) async {
  for (final state in const [
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(state);
    await tester.pump();
  }
}

Future<void> _foreground(WidgetTester tester) async {
  for (final state in const [
    AppLifecycleState.hidden,
    AppLifecycleState.inactive,
    AppLifecycleState.resumed,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(state);
    await tester.pump();
  }
  await _drain(tester);
}

void main() {
  testWidgets('the avatar shows the accent dot when suggestions are waiting', (
    tester,
  ) async {
    final remote = _ScriptedSuggestionsRemote([
      [_row('s-1')],
    ]);
    final container = _makeContainer(remote);
    await tester.pumpWidget(_wrap(container));
    await _drain(tester);

    expect(find.byKey(const Key('topos-account-avatar')), findsOneWidget);
    expect(find.byKey(_dot), findsOneWidget);
    // The dot is a badge on the avatar, not a replacement for it.
    expect(
      find.descendant(
        of: find.byKey(const Key('topos-account-button')),
        matching: find.byKey(_dot),
      ),
      findsOneWidget,
    );
  });

  testWidgets('and NOT otherwise (an empty inbox draws nothing)', (
    tester,
  ) async {
    final remote = _ScriptedSuggestionsRemote([const []]);
    final container = _makeContainer(remote);
    await tester.pumpWidget(_wrap(container));
    await _drain(tester);

    expect(find.byKey(const Key('topos-account-avatar')), findsOneWidget);
    expect(find.byKey(_dot), findsNothing);
  });

  testWidgets('a FAILED lookup draws nothing either — a badge invented off an '
      'unresolved fetch would point at an inbox that may be empty', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory());
    // Registered BEFORE the container's, so LIFO teardown disposes the
    // container (cancelling Riverpod's live Drift watches) before the
    // connection closes — the reverse order hangs waiting on the background
    // executor.
    addTearDown(db.close);
    final container = ProviderContainer(
      // Riverpod v3 retries a failing provider on a backoff; without this the
      // provider sits in AsyncLoading-with-error and leaves pending timers.
      retry: (retryCount, error) => null,
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        nowMsProvider.overrideWithValue(() => 1000),
        connectivityServiceProvider.overrideWithValue(_ReachableConnectivity()),
        syncOrchestratorProvider.overrideWith(_FakeSyncOrchestrator.new),
        authStateProvider.overrideWith(
          (ref) =>
              Stream.value(const AuthSessionState.signedIn('me@masi.test')),
        ),
        effectiveUidProvider.overrideWithValue('uid-me'),
        mySuggestionsProvider.overrideWith(
          (ref) => Future<List<EditSuggestion>>.error(
            Exception('inbox fetch failed'),
          ),
        ),
        toposProvider.overrideWith((ref) => Stream.value(const <TopoRef>[])),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(_wrap(container));
    await _drain(tester);

    expect(find.byKey(_dot), findsNothing);
  });

  testWidgets(
    'THE ONE THAT MATTERS: the dot reflects a value that arrived only after a '
    'resume-triggered invalidation — a stale first resolve does not leave it '
    'dark',
    (tester) async {
      // First resolve: nothing waiting. Second: a suggestion landed while the
      // app was in the background. Nothing but the resume can produce the
      // second answer, so a dot appearing below is proof the invalidation ran.
      final remote = _ScriptedSuggestionsRemote([
        const [],
        [_row('s-late')],
      ]);
      final container = _makeContainer(remote);
      await tester.pumpWidget(_wrap(container));
      await _drain(tester);

      expect(remote.calls, 1);
      expect(
        find.byKey(_dot),
        findsNothing,
        reason: 'nothing was waiting at mount',
      );

      // Backgrounded, then brought back to the foreground — on an installed
      // iOS PWA this is every tab switch and every app re-open.
      await _background(tester);
      await _foreground(tester);

      expect(
        remote.calls,
        greaterThan(1),
        reason: 'resume must re-ask the server, not reuse the resolved value',
      );
      expect(
        find.byKey(_dot),
        findsOneWidget,
        reason: 'the dot must reflect the answer that arrived on resume',
      );
    },
  );

  testWidgets(
    'the dot also goes AWAY on resume once the inbox has been emptied '
    '(the invalidation is not one-directional)',
    (tester) async {
      final remote = _ScriptedSuggestionsRemote([
        [_row('s-1')],
        const [],
      ]);
      final container = _makeContainer(remote);
      await tester.pumpWidget(_wrap(container));
      await _drain(tester);

      expect(find.byKey(_dot), findsOneWidget);

      await _background(tester);
      await _foreground(tester);

      expect(find.byKey(_dot), findsNothing);
    },
  );

  testWidgets(
    'a NON-resume lifecycle transition does not re-ask (inactive/paused are '
    'not "the user came back")',
    (tester) async {
      final remote = _ScriptedSuggestionsRemote([const []]);
      final container = _makeContainer(remote);
      await tester.pumpWidget(_wrap(container));
      await _drain(tester);
      expect(remote.calls, 1);

      // Going AWAY (inactive -> hidden -> paused) is not "the user came back",
      // so nothing here may re-ask; only the resumed edge does.
      await _background(tester);
      await _drain(tester);

      expect(remote.calls, 1);
    },
  );
}
