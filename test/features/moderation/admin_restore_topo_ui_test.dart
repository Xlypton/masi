// The "Removed" admin tab — the UI for `admin_restore_topo`, which existed
// server-side (and even had a service method, `AdminDeleteService.restoreTopo`)
// with no caller anywhere in the app. A reversible admin takedown was
// therefore one-way in practice: there was no button that led to it.
//
// Three properties carry this surface, and all three are tested here rather
// than assumed:
//
//  1. It is admin-only, and fails CLOSED — an unknown (loading) or errored
//     admin check must render nothing, not "show it anyway because we cannot
//     tell". This is `AdminQueueScreen`'s existing top-level gate
//     (`ref.watch(isAdminProvider).asData?.value ?? false`); this file proves
//     the new tab inherits it rather than re-deriving its own, weaker check.
//  2. Restoring is confirmed first. The RPC must not fire on the first tap —
//     only on answering the confirmation sheet.
//  3. The outcome is reported honestly: a failing RPC shows a visible error,
//     never a silent no-op that leaves the admin believing it worked.

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
import 'package:masi/features/backup/application/sync_orchestrator.dart';
import 'package:masi/features/moderation/application/moderation_providers.dart';
import 'package:masi/features/moderation/data/admin_deletion_log_remote.dart';
import 'package:masi/features/moderation/data/moderation_remote.dart';
import 'package:masi/features/moderation/presentation/admin_queue_screen.dart';

Map<String, dynamic> _row(
  String wallId, {
  int createdAt = 5000000,
  String? reason = 'spam',
}) => {
  'id': 'log-$wallId',
  'actorId': 'admin-1',
  'action': 'admin_delete',
  'targetType': 'wall',
  'targetId': wallId,
  'reason': reason,
  'createdAt': createdAt,
};

class _FakeAdminDeletionLogRemote implements AdminDeletionLogRemote {
  _FakeAdminDeletionLogRemote({this.rows = const [], this.throws = false});
  final List<Map<String, dynamic>> rows;
  final bool throws;

  @override
  Future<List<Map<String, dynamic>>> fetchAdminDeletedTopos({
    int limit = 50,
  }) async {
    if (throws) throw StateError('not authorised');
    return rows;
  }
}

/// Satisfies every member of [ModerationRemote] — most are unused by these
/// tests and just return an inert default, exactly like the sibling fakes
/// next to this file (`deletion_requests_test.dart`'s `_FakeModeration`,
/// `admin_delete_service_test.dart`'s `_RecordingModerationRemote`).
class _FakeModeration implements ModerationRemote {
  _FakeModeration({this.adminAnswer = true});

  /// What `isAdmin()` answers — the fake's only configurable input besides
  /// [restoreResult]/[restoreError], since [isAdminProvider] is the gate
  /// under test in most of this file.
  final bool adminAnswer;

  int? restoreResult = 999;
  Object? restoreError;

  /// The ORDER-preserving record of every `adminRestoreTopo` call — the
  /// whole point of the fake for assertions 2 and 3.
  final List<({String wallId, String? reason})> restored = [];

  @override
  Future<bool> isAdmin() async => adminAnswer;

  @override
  Future<int?> adminRestoreTopo({
    required String wallId,
    String? reason,
  }) async {
    restored.add((wallId: wallId, reason: reason));
    if (restoreError != null) throw restoreError!;
    return restoreResult;
  }

  // --- Everything below is unused by these tests. ---
  @override
  Future<List<Map<String, dynamic>>> fetchWallModeration(
    Set<String> wallIds,
  ) async => const [];
  @override
  Future<List<Map<String, dynamic>>> fetchQueue({int limit = 50}) async =>
      const [];
  @override
  Future<List<Map<String, dynamic>>> fetchAbandoned({
    int inactiveDays = 90,
    int limit = 50,
  }) async => const [];
  @override
  Future<List<Map<String, dynamic>>> fetchMaterialChanges({
    int limit = 50,
  }) async => const [];
  @override
  Future<void> resolveMaterialChange(String noticeId) async {}
  @override
  Future<Map<String, dynamic>?> deletionRequestFor(String wallId) async =>
      null;
  @override
  Future<String> requestDeletion(String wallId, {String? reason}) async => '';
  @override
  Future<List<Map<String, dynamic>>> fetchDeletionRequests({
    int limit = 50,
  }) async => const [];
  @override
  Future<String> reviewDeletion({
    required String requestId,
    required bool approve,
    String? note,
  }) async => approve ? 'approved' : 'rejected';
  @override
  Future<String> reviewTopo({
    required String wallId,
    required bool approve,
    String? reason,
  }) async => 'published';
  @override
  Future<void> removeTopo({required String wallId, String? reason}) async {}
  @override
  Future<List<String>> publishedPhotoObjects(String wallId) async => const [];
  @override
  Future<int> removePublishedPhotoObjects(List<String> objectPaths) async =>
      0;
  @override
  Future<int?> adminDeleteTopo({
    required String wallId,
    String? reason,
  }) async => null;
  @override
  Future<int?> adminDeleteAscent({
    required String ascentId,
    String? reason,
  }) async => null;
  @override
  Future<int?> adminDeleteComment({
    required String commentId,
    String? reason,
  }) async => null;
  @override
  Future<int?> requestWithdrawal(String wallId) async => null;
  @override
  Future<String> cancelWithdrawal(String wallId) async => 'published';
}

/// Stands in for the real [SyncOrchestrator] so `restoreTopo`'s post-RPC
/// `_settle` step never touches its debounce/retry/connectivity plumbing —
/// same reasoning as `admin_delete_service_test.dart`'s `_NoopSyncOrchestrator`.
class _NoopSyncOrchestrator extends SyncOrchestrator {
  @override
  SyncOrchestratorState build() => const SyncOrchestratorState();

  @override
  Future<void> pullNow({bool throttled = false}) async {}
}

String? _pushed;

Future<
  ({_FakeModeration remote, _FakeAdminDeletionLogRemote log})
>
_pumpAdmin(
  WidgetTester tester, {
  List<Map<String, dynamic>> rows = const [],
  bool logThrows = false,
}) async {
  final remote = _FakeModeration();
  final log = _FakeAdminDeletionLogRemote(rows: rows, throws: logThrows);
  final db = AppDatabase(NativeDatabase.memory());
  addTearDown(db.close);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        moderationRemoteProvider.overrideWithValue(remote),
        adminDeletionLogRemoteProvider.overrideWithValue(log),
        effectiveUidProvider.overrideWithValue('admin'),
        appDatabaseProvider.overrideWithValue(db),
        syncOrchestratorProvider.overrideWith(_NoopSyncOrchestrator.new),
      ],
      child: MaterialApp.router(
        theme: MasiTheme.light,
        routerConfig: GoRouter(
          initialLocation: '/',
          routes: [
            GoRoute(path: '/', builder: (_, _) => const AdminQueueScreen()),
            GoRoute(
              path: '/walls/:wallId',
              builder: (_, state) {
                _pushed = state.pathParameters['wallId'];
                return const SizedBox();
              },
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  // The tab bar is scrollable and "Removed" is the sixth tab, so it can sit
  // outside the default test viewport — scroll it into view before tapping,
  // or the tap silently misses and the sheet never switches off "Deletions".
  await tester.ensureVisible(find.byKey(const Key('admin-tab-removed')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('admin-tab-removed')));
  await tester.pumpAndSettle();
  return (remote: remote, log: log);
}

void main() {
  setUp(() => _pushed = null);

  group('assertion 1 — a NON-admin never sees the restore affordance', () {
    testWidgets('no tabs at all render, so no "Removed" tab and no restore button', (
      tester,
    ) async {
      final remote = _FakeModeration(adminAnswer: false);
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            moderationRemoteProvider.overrideWithValue(remote),
            adminDeletionLogRemoteProvider.overrideWithValue(
              _FakeAdminDeletionLogRemote(rows: [_row('w1')]),
            ),
            effectiveUidProvider.overrideWithValue('someone'),
            appDatabaseProvider.overrideWithValue(db),
            syncOrchestratorProvider.overrideWith(_NoopSyncOrchestrator.new),
          ],
          child: MaterialApp.router(
            theme: MasiTheme.light,
            routerConfig: GoRouter(
              initialLocation: '/',
              routes: [
                GoRoute(
                  path: '/',
                  builder: (_, _) => const AdminQueueScreen(),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('admin-tab-removed')), findsNothing);
      expect(find.byKey(const Key('admin-removed-row-w1')), findsNothing);
      expect(find.byKey(const Key('admin-restore-w1')), findsNothing);
    });
  });

  group(
    'assertion 5 — a loading or errored admin check renders NO restore '
    'affordance (fail closed)',
    () {
      testWidgets('isAdminProvider still loading', (tester) async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              // Never resolves within this test's lifetime.
              isAdminProvider.overrideWith(
                (ref) => Completer<bool>().future,
              ),
              adminDeletionLogRemoteProvider.overrideWithValue(
                _FakeAdminDeletionLogRemote(rows: [_row('w1')]),
              ),
              appDatabaseProvider.overrideWithValue(db),
              syncOrchestratorProvider.overrideWith(_NoopSyncOrchestrator.new),
            ],
            child: MaterialApp.router(
              theme: MasiTheme.light,
              routerConfig: GoRouter(
                initialLocation: '/',
                routes: [
                  GoRoute(
                    path: '/',
                    builder: (_, _) => const AdminQueueScreen(),
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('admin-tab-removed')), findsNothing);
        expect(find.byKey(const Key('admin-restore-w1')), findsNothing);
      });

      testWidgets('isAdminProvider errored', (tester) async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              isAdminProvider.overrideWith(
                (ref) async => throw StateError('network unavailable'),
              ),
              adminDeletionLogRemoteProvider.overrideWithValue(
                _FakeAdminDeletionLogRemote(rows: [_row('w1')]),
              ),
              appDatabaseProvider.overrideWithValue(db),
              syncOrchestratorProvider.overrideWith(_NoopSyncOrchestrator.new),
            ],
            child: MaterialApp.router(
              theme: MasiTheme.light,
              routerConfig: GoRouter(
                initialLocation: '/',
                routes: [
                  GoRoute(
                    path: '/',
                    builder: (_, _) => const AdminQueueScreen(),
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('admin-tab-removed')), findsNothing);
        expect(find.byKey(const Key('admin-restore-w1')), findsNothing);
      });
    },
  );

  group('an admin sees the Removed tab and its listing', () {
    testWidgets('lists each admin-deleted topo waiting on a restore', (
      tester,
    ) async {
      await _pumpAdmin(
        tester,
        rows: [_row('w1', reason: 'spam'), _row('w2', reason: null)],
      );
      expect(find.byKey(const Key('admin-removed-row-w1')), findsOne);
      expect(find.byKey(const Key('admin-removed-row-w2')), findsOne);
      expect(find.byKey(const Key('admin-restore-w1')), findsOne);
      expect(find.byKey(const Key('admin-restore-w2')), findsOne);
    });

    testWidgets('an empty list says so plainly', (tester) async {
      await _pumpAdmin(tester, rows: const []);
      expect(find.byKey(const Key('admin-removed-empty')), findsOne);
    });

    testWidgets(
      'a failure to load surfaces as an error, not an empty list — an admin '
      'must not read "we could not ask" as "nothing to restore"',
      (tester) async {
        await _pumpAdmin(tester, rows: const [], logThrows: true);
        expect(find.byKey(const Key('admin-removed-empty')), findsNothing);
        expect(find.textContaining("Couldn't load removed topos"), findsOne);
      },
    );

    testWidgets('opening the topo navigates to it', (tester) async {
      await _pumpAdmin(tester, rows: [_row('w1')]);
      await tester.tap(find.byKey(const Key('admin-removed-open-w1')));
      await tester.pumpAndSettle();
      expect(_pushed, 'w1');
    });
  });

  group(
    'assertions 2 & 3 — the first tap only opens a confirm, and answering it '
    'calls admin_restore_topo with the correct wall id',
    () {
      testWidgets('tapping Restore opens a confirm sheet; the RPC has not fired yet', (
        tester,
      ) async {
        final fakes = await _pumpAdmin(tester, rows: [_row('w1')]);
        await tester.tap(find.byKey(const Key('admin-restore-w1')));
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('admin-restore-confirm-w1')),
          findsOne,
          reason: 'the confirm sheet must be showing',
        );
        expect(
          fakes.remote.restored,
          isEmpty,
          reason: 'the RPC must not be called before the confirm is answered',
        );
      });

      testWidgets('answering YES calls admin_restore_topo with that wall id', (
        tester,
      ) async {
        final fakes = await _pumpAdmin(tester, rows: [_row('w1', reason: 'spam')]);
        await tester.tap(find.byKey(const Key('admin-restore-w1')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('admin-restore-confirm-yes-w1')));
        await tester.pumpAndSettle();

        expect(fakes.remote.restored, hasLength(1));
        expect(fakes.remote.restored.single.wallId, 'w1');
        expect(fakes.remote.restored.single.reason, 'spam');
        expect(find.textContaining('Restored'), findsOne);
      });

      testWidgets('backing out of the confirm calls nothing', (tester) async {
        final fakes = await _pumpAdmin(tester, rows: [_row('w1')]);
        await tester.tap(find.byKey(const Key('admin-restore-w1')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('admin-restore-confirm-no-w1')));
        await tester.pumpAndSettle();

        expect(fakes.remote.restored, isEmpty);
      });

      testWidgets(
        'a double-tap-shaped restore (RPC returns null — already restored) '
        'reports that plainly rather than an identical bare "Restored"',
        (tester) async {
          final fakes = await _pumpAdmin(tester, rows: [_row('w1')]);
          fakes.remote.restoreResult = null;
          await tester.tap(find.byKey(const Key('admin-restore-w1')));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const Key('admin-restore-confirm-yes-w1')));
          await tester.pumpAndSettle();

          expect(find.textContaining('Already restored'), findsOne);
        },
      );
    },
  );

  group(
    'assertion 4 — a failing RPC surfaces a visible error, never a silent '
    'no-op',
    () {
      testWidgets('the RPC throwing shows an error snackbar', (tester) async {
        final fakes = await _pumpAdmin(tester, rows: [_row('w1')]);
        fakes.remote.restoreError = StateError('not authorised');
        await tester.tap(find.byKey(const Key('admin-restore-w1')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('admin-restore-confirm-yes-w1')));
        await tester.pumpAndSettle();

        expect(find.textContaining("Couldn't restore that topo"), findsOne);
        expect(
          find.textContaining('Restored'),
          findsNothing,
          reason: 'a failed restore must never look like a successful one',
        );
      });
    },
  );
}
