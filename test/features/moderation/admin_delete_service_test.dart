// `AdminDeleteService` (`lib/features/moderation/application/
// moderation_providers.dart`) — an admin's power to delete/restore ANY topo,
// ascent or comment. Two properties matter more than the happy path:
//
//  1. `deleteTopo` enumerates the wall's published photo objects BEFORE
//     calling `admin_delete_topo`, never after. The shared-photo SELECT
//     policy is `is_wall_public(wallId)`, and the RPC flips that to false —
//     so enumerating afterwards always finds nothing and always leaves
//     world-readable image bytes behind (the exact W-2 shape). The order is
//     asserted via a call log, not inferred from the result.
//  2. The RPC's own errors are NEVER swallowed — an admin who believes they
//     deleted something they did not is the worst outcome this feature has.
//     Only `_settle` (the local-mirror refresh that runs AFTER the RPC has
//     already committed) is allowed to swallow, because by the time it runs
//     the action has already succeeded server-side.

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/features/backup/application/sync_orchestrator.dart';
import 'package:masi/features/moderation/application/moderation_providers.dart';
import 'package:masi/features/moderation/data/moderation_remote.dart';

/// Records everything the service calls, in the ORDER it called them, and
/// lets each RPC's answer (or failure) be dialled in per test.
class _RecordingModerationRemote implements ModerationRemote {
  _RecordingModerationRemote({
    this.photoObjects = const [],
    this.photoBytesRemoved = 0,
    this.deleteTopoResult = 1000,
    this.deleteTopoError,
    this.restoreTopoResult,
    this.deleteAscentResult,
    this.deleteCommentResult,
  });

  final List<String> photoObjects;
  final int photoBytesRemoved;
  final int? deleteTopoResult;
  final Object? deleteTopoError;
  final int? restoreTopoResult;
  final int? deleteAscentResult;
  final int? deleteCommentResult;

  /// The ORDER the three takedown-adjacent calls actually happened in — the
  /// whole point of this fake.
  final List<String> calls = [];

  List<String>? removedPaths;
  ({String wallId, String? reason})? deletedTopo;
  ({String wallId, String? reason})? restoredTopo;
  ({String ascentId, String? reason})? deletedAscent;
  ({String commentId, String? reason})? deletedComment;

  @override
  Future<List<String>> publishedPhotoObjects(String wallId) async {
    calls.add('publishedPhotoObjects');
    return photoObjects;
  }

  @override
  Future<int?> adminDeleteTopo({required String wallId, String? reason}) async {
    calls.add('adminDeleteTopo');
    deletedTopo = (wallId: wallId, reason: reason);
    if (deleteTopoError != null) throw deleteTopoError!;
    return deleteTopoResult;
  }

  @override
  Future<int> removePublishedPhotoObjects(List<String> objectPaths) async {
    calls.add('removePublishedPhotoObjects');
    removedPaths = objectPaths;
    return photoBytesRemoved;
  }

  @override
  Future<int?> adminRestoreTopo({
    required String wallId,
    String? reason,
  }) async {
    restoredTopo = (wallId: wallId, reason: reason);
    return restoreTopoResult;
  }

  @override
  Future<int?> adminDeleteAscent({
    required String ascentId,
    String? reason,
  }) async {
    deletedAscent = (ascentId: ascentId, reason: reason);
    return deleteAscentResult;
  }

  @override
  Future<int?> adminDeleteComment({
    required String commentId,
    String? reason,
  }) async {
    deletedComment = (commentId: commentId, reason: reason);
    return deleteCommentResult;
  }

  // --- Everything below is unused by these tests, and just satisfies the
  // interface. ---

  @override
  Future<bool> isAdmin() async => true;
  @override
  Future<List<Map<String, dynamic>>> fetchQueue({int limit = 50}) async =>
      const [];
  @override
  Future<List<Map<String, dynamic>>> fetchWallModeration(
    Set<String> wallIds,
  ) async => const [];
  @override
  Future<String> reviewTopo({
    required String wallId,
    required bool approve,
    String? reason,
  }) async => 'published';
  @override
  Future<void> removeTopo({required String wallId, String? reason}) async {}
  @override
  Future<List<Map<String, dynamic>>> fetchAbandoned({
    int inactiveDays = 90,
    int limit = 50,
  }) async => const [];
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
  Future<List<Map<String, dynamic>>> fetchMaterialChanges({
    int limit = 50,
  }) async => const [];
  @override
  Future<void> resolveMaterialChange(String noticeId) async {}
  @override
  Future<int?> requestWithdrawal(String wallId) async => null;
  @override
  Future<String> cancelWithdrawal(String wallId) async => 'published';
}

/// Stands in for the real [SyncOrchestrator] so the "does the RPC work"
/// tests below never touch its debounce/retry/connectivity plumbing.
class _NoopSyncOrchestrator extends SyncOrchestrator {
  @override
  SyncOrchestratorState build() => const SyncOrchestratorState();

  @override
  Future<void> pullNow({bool throttled = false}) async {}
}

ProviderContainer _container(
  ModerationRemote remote, {
  SyncOrchestrator Function() syncOrchestrator = _NoopSyncOrchestrator.new,
}) {
  final db = AppDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  final container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(db),
      moderationRemoteProvider.overrideWithValue(remote),
      syncOrchestratorProvider.overrideWith(syncOrchestrator),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('deleteTopo', () {
    test(
      'enumerates photo objects BEFORE the RPC and removes them AFTER — the '
      'shared-photo SELECT policy is is_wall_public(wallId), which the RPC '
      'makes false, so enumerating afterwards would always find nothing and '
      'silently leave the bytes',
      () async {
        final remote = _RecordingModerationRemote(
          photoObjects: const ['shared/p1.jpg', 'shared/p2.jpg', 'shared/p3.jpg'],
          photoBytesRemoved: 2,
          deleteTopoResult: 555000,
        );
        final container = _container(remote);

        final result = await container
            .read(adminDeleteServiceProvider)
            .deleteTopo(wallId: 'w1', reason: 'spam');

        expect(remote.calls, [
          'publishedPhotoObjects',
          'adminDeleteTopo',
          'removePublishedPhotoObjects',
        ]);
        expect(remote.removedPaths, [
          'shared/p1.jpg',
          'shared/p2.jpg',
          'shared/p3.jpg',
        ]);
        expect(remote.deletedTopo, (wallId: 'w1', reason: 'spam'));

        // Enumerated (3) and removed (2) are DELIBERATELY different — a test
        // that conflated the two would still pass if they happened to match.
        expect(result.deletedAt, 555000);
        expect(result.photoObjects, 3);
        expect(result.photoBytesRemoved, 2);
      },
    );

    test(
      'an RPC that throws propagates out of deleteTopo, and the byte removal '
      'never runs — an admin who believes they deleted something they did '
      'not is the worst outcome this feature has',
      () async {
        final remote = _RecordingModerationRemote(
          photoObjects: const ['shared/p1.jpg'],
          deleteTopoError: StateError('not authorised'),
        );
        final container = _container(remote);

        await expectLater(
          container
              .read(adminDeleteServiceProvider)
              .deleteTopo(wallId: 'w1'),
          throwsA(isA<StateError>()),
        );

        expect(remote.calls, [
          'publishedPhotoObjects',
          'adminDeleteTopo',
        ], reason: 'the byte removal must not run after a failed delete');
      },
    );
  });

  group('restoreTopo', () {
    test(
      'returns null when the fake returns null — a double tap on an '
      'already-restored topo is not an error',
      () async {
        final remote = _RecordingModerationRemote(restoreTopoResult: null);
        final container = _container(remote);

        final result = await container
            .read(adminDeleteServiceProvider)
            .restoreTopo(wallId: 'w1', reason: 'mistake');

        expect(result, isNull);
        expect(remote.restoredTopo, (wallId: 'w1', reason: 'mistake'));
      },
    );

    test('returns the restore instant when the fake has one', () async {
      final remote = _RecordingModerationRemote(restoreTopoResult: 42);
      final container = _container(remote);

      final result = await container
          .read(adminDeleteServiceProvider)
          .restoreTopo(wallId: 'w1');

      expect(result, 42);
    });
  });

  group('deleteAscent / deleteComment', () {
    test('deleteAscent passes the ascent id through and returns the instant', () async {
      final remote = _RecordingModerationRemote(deleteAscentResult: 777);
      final container = _container(remote);

      final result = await container
          .read(adminDeleteServiceProvider)
          .deleteAscent(ascentId: 'a1', reason: 'abusive');

      expect(result, 777);
      expect(remote.deletedAscent, (ascentId: 'a1', reason: 'abusive'));
    });

    test(
      'deleteComment passes the comment id through and returns the instant',
      () async {
        final remote = _RecordingModerationRemote(deleteCommentResult: 888);
        final container = _container(remote);

        final result = await container
            .read(adminDeleteServiceProvider)
            .deleteComment(commentId: 'c1', reason: 'spam');

        expect(result, 888);
        expect(remote.deletedComment, (commentId: 'c1', reason: 'spam'));
      },
    );
  });

  group('the settle step never lets its own failure escape', () {
    // NOTE ON WHAT THIS DOES **NOT** TEST: an earlier version of this test
    // tried to break `syncOrchestratorProvider` itself (a `Notifier`) and
    // assert that `_ref.read(syncOrchestratorProvider.notifier)` throws.
    // Empirically it does not: reading `.notifier` on a `NotifierProvider`
    // returns the notifier object WITHOUT propagating a `build()`-time
    // failure — Riverpod only surfaces that failure when the STATE is read
    // (`ref.watch`/`container.read(provider)`), which `_settle` never does.
    // A method called on that object afterwards (`pullNow()`) keeps working
    // too, since the instance's plain Dart fields and its `ref`/`state`
    // plumbing are independent of whether `build()` itself succeeded. So a
    // broken `syncOrchestratorProvider` was never actually going to throw
    // here at all — see this file's — and the caller's — final report for
    // this as a documented FINDING rather than a lib fix.
    //
    // What genuinely CAN throw inside `_settle` is `refreshWallModeration`,
    // which reads `moderationRepositoryProvider` — an ordinary `Provider`,
    // where a `build()` failure DOES propagate through `container.read` in
    // the normal way. That is what this test breaks instead.
    test(
      'deleteTopo still returns its result even when refreshWallModeration\'s '
      'own dependency (moderationRepositoryProvider, via appDatabaseProvider) '
      'cannot be built — a broken local mirror must never make an '
      'already-committed server-side delete look like it failed',
      () async {
        final remote = _RecordingModerationRemote(
          photoObjects: const ['shared/p1.jpg'],
          photoBytesRemoved: 1,
          deleteTopoResult: 42,
        );
        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWith(
              (ref) => throw StateError('db unavailable in this test'),
            ),
            moderationRemoteProvider.overrideWithValue(remote),
            syncOrchestratorProvider.overrideWith(_NoopSyncOrchestrator.new),
          ],
        );
        addTearDown(container.dispose);

        // Sanity check: this container's moderationRepositoryProvider — what
        // `refreshWallModeration` reads — really does throw on build (wrapped
        // by Riverpod as a `ProviderException`, not a bare `StateError`), so
        // the assertion below is about the swallow, not a vacuous pass
        // because nothing was actually broken.
        expect(
          () => container.read(moderationRepositoryProvider),
          throwsA(anything),
        );

        final result = await container
            .read(adminDeleteServiceProvider)
            .deleteTopo(wallId: 'w1', reason: 'spam');

        expect(result.deletedAt, 42);
        expect(result.photoObjects, 1);
        expect(result.photoBytesRemoved, 1);
      },
    );
  });
}
