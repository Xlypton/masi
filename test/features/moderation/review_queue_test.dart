// Community editing phase 3: the admin review queue and the owner's view of
// where their submission stands.
//
// The server enforces every rule these screens present; these tests cover the
// CLIENT's obligations — fail closed on the admin check, never render a
// rejection without its reason, and never silently show an empty queue when
// the real answer was "we could not ask".

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:masi/app/theme.dart';
import 'package:masi/core/db/app_database.dart' as db;
import 'package:masi/features/account/application/auth_providers.dart';
import 'package:masi/features/moderation/application/moderation_providers.dart';
import 'package:masi/features/moderation/data/moderation_remote.dart';
import 'package:masi/features/moderation/presentation/admin_queue_screen.dart';
import 'package:masi/features/moderation/presentation/moderation_banner.dart';

class _FakeRemote implements ModerationRemote {
  _FakeRemote({
    this.admin = false,
    this.queue = const [],
    this.queueThrows = false,
  });

  final bool admin;
  final List<Map<String, dynamic>> queue;
  final bool queueThrows;

  final reviewed = <(String, bool, String?)>[];

  @override
  Future<bool> isAdmin() async => admin;

  @override
  Future<List<Map<String, dynamic>>> fetchQueue({int limit = 50}) async {
    if (queueThrows) throw StateError('not authorised');
    return queue;
  }

  @override
  Future<String> reviewTopo({
    required String wallId,
    required bool approve,
    String? reason,
  }) async {
    reviewed.add((wallId, approve, reason));
    return approve ? 'published' : 'rejected';
  }

  @override
  Future<void> removeTopo({required String wallId, String? reason}) async {}

  @override
  Future<List<String>> publishedPhotoObjects(String wallId) async => const [];

  @override
  Future<int> removePublishedPhotoObjects(List<String> objectPaths) async => 0;

  @override
  Future<List<Map<String, dynamic>>> fetchWallModeration(
    Set<String> wallIds,
  ) async => const [];

  @override
  Future<int?> requestWithdrawal(String wallId) async => null;

  @override
  Future<String> cancelWithdrawal(String wallId) async => 'published';
}

Map<String, dynamic> _queueRow(
  String id, {
  String name = 'Roof Wall',
  int routes = 3,
  String? area = 'Csobánka',
}) => {
  'wallId': id,
  'wallName': name,
  'ownerId': 'owner-1',
  'submittedAt': DateTime.now()
      .subtract(const Duration(days: 2))
      .millisecondsSinceEpoch,
  'routeCount': routes,
  'areaName': area,
};

db.WallModerationRow _modRow(
  String state, {
  String? rejectionReason,
  int? withdrawRequestedAt,
}) => db.WallModerationRow(
  wallId: 'w1',
  state: state,
  rejectionReason: rejectionReason,
  withdrawRequestedAt: withdrawRequestedAt,
  updatedAt: 1,
);

Widget _wrapScreen(ProviderContainer container) => UncontrolledProviderScope(
  container: container,
  child: MaterialApp.router(
    theme: MasiTheme.light,
    routerConfig: GoRouter(
      routes: [
        GoRoute(path: '/', builder: (_, _) => const AdminQueueScreen()),
        GoRoute(
          path: '/walls/:wallId',
          builder: (_, _) => const Scaffold(body: Text('canvas')),
        ),
      ],
    ),
  ),
);

ProviderContainer _container(ModerationRemote remote, {String? uid = 'me'}) {
  final container = ProviderContainer(
    overrides: [
      moderationRemoteProvider.overrideWithValue(remote),
      // `isAdminProvider` gates on there being a signed-in uid at all, so a
      // container without one resolves to false for the wrong reason and
      // every admin assertion would pass vacuously.
      effectiveUidProvider.overrideWithValue(uid),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('ModerationQueueEntry.fromRow', () {
    test('maps the sentinel area to null so it never reaches a screen', () {
      final entry = ModerationQueueEntry.fromRow(
        _queueRow('w1', area: '__default__'),
      );
      expect(entry.areaName, isNull);
    });

    test('falls back to a placeholder for an empty name', () {
      expect(
        ModerationQueueEntry.fromRow(_queueRow('w1', name: '  ')).wallName,
        'Untitled topo',
      );
    });

    test('tolerates a row missing every optional field', () {
      final entry = ModerationQueueEntry.fromRow({'wallId': 'w1'});
      expect(entry.wallId, 'w1');
      expect(entry.routeCount, 0);
      expect(entry.submittedAt, isNull);
      expect(entry.areaName, isNull);
    });
  });

  group('AdminQueueScreen', () {
    testWidgets(
      'a NON-admin sees the moderators-only state and the queue is never '
      'even requested',
      (tester) async {
        final remote = _FakeRemote(admin: false, queue: [_queueRow('w1')]);
        await tester.pumpWidget(_wrapScreen(_container(remote)));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('admin-queue-forbidden')), findsOneWidget);
        expect(find.text('Roof Wall'), findsNothing);
      },
    );

    testWidgets('an admin sees each pending topo with enough to decide on', (
      tester,
    ) async {
      final remote = _FakeRemote(admin: true, queue: [_queueRow('w1')]);
      await tester.pumpWidget(_wrapScreen(_container(remote)));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('admin-queue-row-w1')), findsOneWidget);
      expect(find.text('Roof Wall'), findsOneWidget);
      expect(find.textContaining('3 routes'), findsOneWidget);
      expect(find.textContaining('Csobánka'), findsOneWidget);
      expect(
        find.textContaining('waited 2d'),
        findsOneWidget,
        reason: 'how long somebody has been kept waiting is the queue order',
      );
      expect(
        find.byKey(const Key('admin-queue-open-w1')),
        findsOneWidget,
        reason: 'approving something you have not looked at is the failure a '
            'review queue exists to prevent — Open must be present',
      );
    });

    testWidgets('an empty queue says so rather than rendering blank', (
      tester,
    ) async {
      await tester.pumpWidget(_wrapScreen(_container(_FakeRemote(admin: true))));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('admin-queue-empty')), findsOneWidget);
    });

    testWidgets(
      'a FAILED queue read shows an error, not an empty queue — "nothing to '
      'review" and "we could not ask" must not look alike',
      (tester) async {
        final remote = _FakeRemote(admin: true, queueThrows: true);
        await tester.pumpWidget(_wrapScreen(_container(remote)));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('admin-queue-empty')), findsNothing);
        expect(find.textContaining("Couldn't load"), findsOneWidget);
      },
    );

    testWidgets('approving calls through with approve=true', (tester) async {
      final remote = _FakeRemote(admin: true, queue: [_queueRow('w1')]);
      await tester.pumpWidget(_wrapScreen(_container(remote)));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('admin-queue-approve-w1')));
      await tester.pumpAndSettle();

      expect(remote.reviewed, [('w1', true, null)]);
    });

    testWidgets(
      'rejecting REQUIRES a reason — dismissing the prompt records nothing, '
      'because a silent rejection teaches the owner nothing',
      (tester) async {
        final remote = _FakeRemote(admin: true, queue: [_queueRow('w1')]);
        await tester.pumpWidget(_wrapScreen(_container(remote)));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('admin-queue-reject-w1')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('admin-reject-reason-field')),
          findsOneWidget,
        );

        // Submit with the field left empty.
        await tester.tap(find.byKey(const Key('admin-reject-reason-submit')));
        await tester.pumpAndSettle();

        expect(remote.reviewed, isEmpty);
      },
    );

    testWidgets('a reason typed into the prompt reaches the RPC', (
      tester,
    ) async {
      final remote = _FakeRemote(admin: true, queue: [_queueRow('w1')]);
      await tester.pumpWidget(_wrapScreen(_container(remote)));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('admin-queue-reject-w1')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('admin-reject-reason-field')),
        'Photo is too blurry to follow the lines',
      );
      // The submit action is disabled while the field is empty (see
      // `showMasiTextPrompt`'s `_canSubmit`), and it is re-enabled by a
      // controller listener — so the frame has to be pumped before the tap
      // lands on an enabled button.
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('admin-reject-reason-submit')));
      await tester.pumpAndSettle();

      expect(remote.reviewed, [
        ('w1', false, 'Photo is too blurry to follow the lines'),
      ]);
    });
  });

  group('ModerationNotice (the owner\'s view)', () {
    Widget wrap(db.WallModerationRow row) => MaterialApp(
      theme: MasiTheme.light,
      home: Scaffold(body: ModerationNotice(row: row)),
    );

    testWidgets('says nothing for a draft or a plain published topo', (
      tester,
    ) async {
      await tester.pumpWidget(wrap(_modRow('draft')));
      expect(find.byType(Container), findsNothing);

      await tester.pumpWidget(wrap(_modRow('published')));
      expect(find.byType(Container), findsNothing);
    });

    testWidgets(
      'a PENDING topo tells the owner nobody else can see it yet — without '
      'this, submitting looks exactly like publishing',
      (tester) async {
        await tester.pumpWidget(wrap(_modRow('pending')));

        expect(find.text('Waiting for review'), findsOneWidget);
        expect(find.textContaining('Only you can see'), findsOneWidget);
      },
    );

    testWidgets('a REJECTED topo shows the moderator\'s reason verbatim', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(_modRow('rejected', rejectionReason: 'Duplicate of Boulder X')),
      );

      expect(find.text('Not approved'), findsOneWidget);
      expect(find.text('Duplicate of Boulder X'), findsOneWidget);
    });

    testWidgets('a rejection with no reason still says what happened', (
      tester,
    ) async {
      await tester.pumpWidget(wrap(_modRow('rejected')));
      expect(find.text('Not approved'), findsOneWidget);
      expect(find.textContaining('did not approve'), findsOneWidget);
    });

    testWidgets('a removed topo reassures that nothing was deleted', (
      tester,
    ) async {
      await tester.pumpWidget(wrap(_modRow('removed')));
      expect(find.text('Taken down'), findsOneWidget);
      expect(find.textContaining('nothing has been deleted'), findsOneWidget);
    });

    testWidgets('a running withdrawal counts down for the owner', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(
          _modRow(
            'published',
            withdrawRequestedAt: DateTime.now()
                .subtract(const Duration(days: 3))
                .millisecondsSinceEpoch,
          ),
        ),
      );

      expect(find.text('Being withdrawn'), findsOneWidget);
      // Seven, not six. This test used to assert "in 6 days", because the old
      // implementation took `Duration.inDays`, which truncates: three days
      // into a ten-day window leaves 6.9999… days once a few microseconds of
      // wall clock have passed, and truncation reported that as 6. The banner
      // therefore under-stated the remaining time by a day for the ENTIRE
      // window, and on the last day would have read "in 0 days" on a topo that
      // was still public. Phase 5 rounds up instead — see
      // `ModerationView.daysRemaining`.
      expect(find.textContaining('in 7 days'), findsOneWidget);
    });

    testWidgets('an UNKNOWN state falls back to draft and says nothing', (
      tester,
    ) async {
      await tester.pumpWidget(wrap(_modRow('some_future_state')));
      expect(find.byType(Container), findsNothing);
    });
  });
}
