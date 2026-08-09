// The admin "delete any comment" control on `CommentRow`
// (`lib/features/community/presentation/comment_row.dart`) — visible ONLY to
// a signed-in admin, per `adminContentAction`
// (`lib/features/moderation/domain/admin_delete_policy.dart`).
//
// This is a security-relevant gate: the two tests that matter most are that a
// non-admin (by far the common case) and a signed-out viewer see NOTHING,
// even when the underlying remote would happily answer `isAdmin: true`. The
// widget itself draws the control; the actual authorisation is re-checked
// server-side by the `admin_delete_comment` RPC (see that file's doc) — this
// suite only proves the CLIENT decided correctly whether to draw the button
// at all.
//
// No Drift database is stood up here: every [Comment] below is built with
// `ownerId: null`, so `CommentRow` skips `profileDisplayNameProvider`/
// `profileAvatarUrlProvider` entirely (see that widget's doc on why a
// signed-out author's lookups are skipped rather than asked for a name they
// cannot have) and nothing here ever touches `appDatabaseProvider`.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:masi/app/theme.dart';
import 'package:masi/features/account/application/auth_providers.dart';
import 'package:masi/features/backup/application/sync_orchestrator.dart';
import 'package:masi/features/community/data/comments_repository.dart';
import 'package:masi/features/community/presentation/comment_row.dart';
import 'package:masi/features/moderation/application/moderation_providers.dart';
import 'package:masi/features/moderation/data/moderation_remote.dart';

/// A [ModerationRemote] whose `isAdmin()` answer is dialled in per test, and
/// which records every `adminDeleteComment` call — the seam
/// `AdminDeleteService.deleteComment` actually reads, so no service-level
/// override is needed to observe whether a delete happened.
///
/// Every other member just satisfies the interface; none of these tests
/// exercise them. Shape copied from `review_queue_test.dart`'s
/// `_FakeRemote`/`admin_delete_service_test.dart`'s `_RecordingModerationRemote`.
class _FakeModerationRemote implements ModerationRemote {
  _FakeModerationRemote({Future<bool> Function()? isAdmin})
    : _isAdmin = isAdmin ?? (() async => false);

  final Future<bool> Function() _isAdmin;

  /// Every `adminDeleteComment` call received, in order.
  final List<({String commentId, String? reason})> deletedComments = [];

  int? deleteCommentResult = 999;

  @override
  Future<bool> isAdmin() => _isAdmin();

  @override
  Future<int?> adminDeleteComment({
    required String commentId,
    String? reason,
  }) async {
    deletedComments.add((commentId: commentId, reason: reason));
    return deleteCommentResult;
  }

  // --- Unused by these tests; just satisfies the interface. ---

  @override
  Future<List<Map<String, dynamic>>> fetchWallModeration(
    Set<String> wallIds,
  ) async => const [];

  @override
  Future<List<Map<String, dynamic>>> fetchQueue({int limit = 50}) async =>
      const [];

  @override
  Future<String> reviewTopo({
    required String wallId,
    required bool approve,
    String? reason,
  }) async => approve ? 'published' : 'rejected';

  @override
  Future<void> removeTopo({required String wallId, String? reason}) async {}

  @override
  Future<List<Map<String, dynamic>>> fetchAbandoned({
    int inactiveDays = 90,
    int limit = 50,
  }) async => const [];

  @override
  Future<List<String>> publishedPhotoObjects(String wallId) async => const [];

  @override
  Future<Map<String, dynamic>?> deletionRequestFor(String wallId) async => null;
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
  Future<int> removePublishedPhotoObjects(List<String> objectPaths) async => 0;

  @override
  Future<int?> requestWithdrawal(String wallId) async => null;

  @override
  Future<String> cancelWithdrawal(String wallId) async => 'published';

  @override
  Future<int?> adminDeleteTopo({required String wallId, String? reason}) async =>
      null;
  @override
  Future<int?> adminRestoreTopo({
    required String wallId,
    String? reason,
  }) async => null;
  @override
  Future<int?> adminDeleteAscent({
    required String ascentId,
    String? reason,
  }) async => null;
}

/// Stands in for the real [SyncOrchestrator] so the confirm-then-delete test
/// never touches its debounce/retry/connectivity/appDatabase plumbing.
/// `AdminDeleteService.deleteComment`'s `_settle` step reads
/// `syncOrchestratorProvider.notifier` unconditionally — see that method's
/// doc — so this needs to exist even though the comment-delete path never
/// touches `moderationRepositoryProvider` (its `wallIds` set is always
/// empty for a comment). Mirrors `admin_delete_service_test.dart`'s
/// `_NoopSyncOrchestrator` exactly.
class _NoopSyncOrchestrator extends SyncOrchestrator {
  @override
  SyncOrchestratorState build() => const SyncOrchestratorState();

  @override
  Future<void> pullNow({bool throttled = false}) async {}
}

ProviderContainer _container({required ModerationRemote remote, String? uid = 'admin-1'}) {
  final container = ProviderContainer(
    overrides: [
      moderationRemoteProvider.overrideWithValue(remote),
      // `isAdminProvider` short-circuits to false without a uid at all — see
      // that provider's doc — so this must be settable independently of
      // whatever the fake remote would answer.
      effectiveUidProvider.overrideWithValue(uid),
      syncOrchestratorProvider.overrideWith(_NoopSyncOrchestrator.new),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Comment _comment({String id = 'c1'}) => Comment(
  id: id,
  wallId: 'w1',
  body: 'Nice line!',
  authorName: 'Someone',
  // Deliberately null: skips profileDisplayNameProvider/profileAvatarUrlProvider
  // entirely (see CommentRow's doc), so no Drift database is needed anywhere
  // in this file.
  createdAt: 1000,
  updatedAt: 1000,
);

Widget _wrap(ProviderContainer container, Comment comment, {String keyPrefix = 'test-comment'}) {
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: MasiTheme.light,
      home: Scaffold(body: CommentRow(comment: comment, keyPrefix: keyPrefix)),
    ),
  );
}

void main() {
  testWidgets('an admin sees the delete control on a comment', (tester) async {
    final remote = _FakeModerationRemote(isAdmin: () async => true);
    await tester.pumpWidget(_wrap(_container(remote: remote), _comment()));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('test-comment-c1-admin-delete')),
      findsOneWidget,
    );
  });

  testWidgets(
    'SECURITY: a signed-in NON-admin sees no delete control, even though the '
    'row itself still renders normally',
    (tester) async {
      final remote = _FakeModerationRemote(isAdmin: () async => false);
      await tester.pumpWidget(_wrap(_container(remote: remote), _comment()));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('test-comment-c1-admin-delete')),
        findsNothing,
      );
      // The row itself is unaffected by the admin gate.
      expect(find.text('Nice line!'), findsOneWidget);
    },
  );

  testWidgets(
    'SECURITY: a signed-out viewer sees no delete control even when the '
    'remote would answer isAdmin: true — isAdminProvider short-circuits on a '
    'null uid, and adminContentAction checks isSignedIn independently; this '
    'asserts the pair holds even if one gate were ever removed',
    (tester) async {
      final remote = _FakeModerationRemote(isAdmin: () async => true);
      await tester.pumpWidget(
        _wrap(_container(remote: remote, uid: null), _comment()),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('test-comment-c1-admin-delete')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'fails closed while the admin lookup is still in flight — the real-world '
    'first-frame case `asData?.value ?? false` exists for',
    (tester) async {
      final remote = _FakeModerationRemote(
        isAdmin: () => Completer<bool>().future, // never completes
      );
      await tester.pumpWidget(_wrap(_container(remote: remote), _comment()));
      await tester.pump(); // one frame only — pumpAndSettle would hang

      expect(
        find.byKey(const Key('test-comment-c1-admin-delete')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'tapping the control shows a confirm sheet before deleting anything, and '
    'confirming calls through with the right comment id',
    (tester) async {
      final remote = _FakeModerationRemote(isAdmin: () async => true)
        ..deleteCommentResult = 4242;
      await tester.pumpWidget(_wrap(_container(remote: remote), _comment()));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('test-comment-c1-admin-delete')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('test-comment-c1-admin-delete-confirm')),
        findsOneWidget,
        reason: 'a destructive admin action must be confirmed, not fired '
            'straight from the icon tap',
      );
      expect(
        remote.deletedComments,
        isEmpty,
        reason: 'showing the confirm sheet must not itself delete anything',
      );

      await tester.tap(
        find.byKey(const Key('test-comment-c1-admin-delete-confirm')),
      );
      await tester.pumpAndSettle();

      expect(remote.deletedComments, [(commentId: 'c1', reason: null)]);
    },
  );

  testWidgets('dismissing the confirm sheet deletes nothing', (tester) async {
    final remote = _FakeModerationRemote(isAdmin: () async => true);
    await tester.pumpWidget(_wrap(_container(remote: remote), _comment()));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('test-comment-c1-admin-delete')));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('test-comment-c1-admin-delete-confirm')),
      findsNothing,
    );
    expect(remote.deletedComments, isEmpty);
  });
}
