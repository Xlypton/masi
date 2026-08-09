// The way into the review queue from the app (community editing, phase 3
// follow-up).
//
// Until this existed `/admin` was reachable only by typing the URL, which made
// the review surface effectively invisible in the installed PWA.
//
// The case that matters most is the negative one: a non-admin must never see
// the entry point, and neither must a reader whose admin check has not
// resolved or has failed. That is a convenience guarantee rather than a
// security one — the route is deliberately not redirect-guarded and every
// action behind it is re-checked server-side — but a moderation shortcut
// appearing for the wrong person is still a bug worth a test.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:masi/app/theme.dart';
import 'package:masi/features/account/application/auth_providers.dart';
import 'package:masi/features/account/presentation/account_screen.dart';
import 'package:masi/features/moderation/application/moderation_providers.dart';
import 'package:masi/features/moderation/data/moderation_remote.dart';

/// Answers the admin check and the queue read, and nothing else.
class _FakeRemote implements ModerationRemote {
  _FakeRemote({
    this.admin = false,
    this.queue = const [],
    this.adminThrows = false,
  });

  final bool admin;
  final List<Map<String, dynamic>> queue;
  final bool adminThrows;

  @override
  Future<bool> isAdmin() async {
    if (adminThrows) throw StateError('session expired');
    return admin;
  }

  @override
  Future<List<Map<String, dynamic>>> fetchQueue({int limit = 50}) async =>
      queue;

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
  Future<List<String>> publishedPhotoObjects(String wallId) async => const [];

  @override
  Future<Map<String, dynamic>?> deletionRequestFor(String wallId) async => null;
  @override
  Future<String> requestDeletion(String wallId, {String? reason}) async => '';
  @override
  Future<List<Map<String, dynamic>>> fetchDeletionRequests({int limit = 50}) async =>
      const [];
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
  Future<List<Map<String, dynamic>>> fetchWallModeration(
    Set<String> wallIds,
  ) async => const [];

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
  @override
  Future<int?> adminDeleteComment({
    required String commentId,
    String? reason,
  }) async => null;
}

Map<String, dynamic> _queueRow(String id) => {
  'wallId': id,
  'wallName': 'Roof Wall',
  'ownerId': 'owner-1',
  'submittedAt': 1000,
  'routeCount': 3,
  'areaName': 'Csobánka',
};

Future<void> _pump(
  WidgetTester tester, {
  required _FakeRemote remote,
  String? uid = 'me',
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        moderationRemoteProvider.overrideWithValue(remote),
        // `isAdminProvider` short-circuits to false without a signed-in uid,
        // so this has to be set or every case passes vacuously.
        effectiveUidProvider.overrideWithValue(uid),
      ],
      child: MaterialApp(
        theme: MasiTheme.light,
        home: const Scaffold(body: AccountAdminEntryPoint()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  const key = Key('account-open-admin-queue');

  testWidgets('an admin gets a way in', (tester) async {
    await _pump(tester, remote: _FakeRemote(admin: true));

    expect(find.byKey(key), findsOneWidget);
    expect(find.text('Review queue'), findsOneWidget);
  });

  testWidgets('shows how much is waiting, from the queue read itself', (
    tester,
  ) async {
    await _pump(
      tester,
      remote: _FakeRemote(
        admin: true,
        queue: [_queueRow('w1'), _queueRow('w2')],
      ),
    );

    expect(find.text('Review queue · 2 waiting'), findsOneWidget);
  });

  testWidgets(
    'an empty queue reads as "Review queue", not "0 waiting" — a confident '
    'zero is the one thing an unresolved count must never claim',
    (tester) async {
      await _pump(tester, remote: _FakeRemote(admin: true, queue: const []));

      expect(find.text('Review queue'), findsOneWidget);
      expect(find.textContaining('waiting'), findsNothing);
    },
  );

  testWidgets('a non-admin sees nothing at all', (tester) async {
    await _pump(tester, remote: _FakeRemote(admin: false));
    expect(find.byKey(key), findsNothing);
  });

  testWidgets('a signed-out reader sees nothing at all', (tester) async {
    await _pump(tester, remote: _FakeRemote(admin: true), uid: null);
    expect(
      find.byKey(key),
      findsNothing,
      reason: 'no uid means no admin, whatever the remote would have said',
    );
  });

  testWidgets(
    'a FAILED admin check hides it — fails closed, so an expired session '
    'loses the shortcut rather than a stranger gaining one',
    (tester) async {
      await _pump(tester, remote: _FakeRemote(adminThrows: true));
      expect(find.byKey(key), findsNothing);
    },
  );
}
