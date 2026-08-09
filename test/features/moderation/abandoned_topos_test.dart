// C-11: abandoned topos.
//
// Owner approval of edits is final (C-5c), which is right until the owner stops
// opening the app. Then suggestions pile up, nothing is applied, and "the owner
// approves edits" becomes "nobody can fix this" — for a topo the whole
// community relies on.
//
// The two things worth testing here are what the surface REFUSES to do. It does
// not offer to transfer ownership, because that is irreversible and aimed at a
// real person's work; and it does not wear an urgency badge, because a slow
// condition that was already true yesterday must not compete for the same
// attention as an unsafe report.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:masi/app/theme.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/features/account/application/auth_providers.dart';
import 'package:masi/features/moderation/application/moderation_providers.dart';
import 'package:masi/features/moderation/data/moderation_remote.dart';
import 'package:masi/features/moderation/domain/abandoned_topo.dart';
import 'package:masi/features/moderation/presentation/admin_queue_screen.dart';

const _nowMs = 1800000000000; // a fixed clock, so "waiting N months" is stable
const _day = 86400000;

Map<String, dynamic> _row(
  String id, {
  String name = 'Dolomitici',
  String? owner = 'Kata',
  int open = 3,
  int? oldestDaysAgo = 400,
}) => {
  'wallId': id,
  'wallName': name,
  'ownerId': 'u-$id',
  'ownerName': owner,
  'openSuggestions': open,
  'oldestSuggestionAt': oldestDaysAgo == null
      ? null
      : _nowMs - oldestDaysAgo * _day,
  'lastOwnerActivityAt': _nowMs - 500 * _day,
};

class _FakeModeration implements ModerationRemote {
  _FakeModeration({this.rows = const [], this.throws = false});
  final List<Map<String, dynamic>> rows;
  final bool throws;
  int calls = 0;

  @override
  Future<List<Map<String, dynamic>>> fetchAbandoned({
    int inactiveDays = 90,
    int limit = 50,
  }) async {
    calls++;
    if (throws) throw StateError('not authorised');
    return rows;
  }

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
  Future<int> removePublishedPhotoObjects(List<String> paths) async => 0;
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
  @override
  Future<int?> adminDeleteComment({
    required String commentId,
    String? reason,
  }) async => null;
}

String? _pushed;

Future<void> _pump(
  WidgetTester tester, {
  required List<Map<String, dynamic>> rows,
  bool throws = false,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        moderationRemoteProvider.overrideWithValue(
          _FakeModeration(rows: rows, throws: throws),
        ),
        nowMsProvider.overrideWithValue(() => _nowMs),
        effectiveUidProvider.overrideWithValue('admin'),
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
  await tester.tap(find.byKey(const Key('admin-tab-abandoned')));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => _pushed = null);

  group('parsing a row', () {
    test('a row with no wallId or no timestamp is dropped, not half-built', () {
      expect(AbandonedTopo.fromRow(_row('', oldestDaysAgo: 400)), isNull);
      expect(AbandonedTopo.fromRow(_row('a', oldestDaysAgo: null)), isNull);
      expect(AbandonedTopo.fromRow(const {}), isNull);
    });

    test('an owner with no profile renders a label, never a bare uid', () {
      final topo = AbandonedTopo.fromRow(_row('a', owner: null))!;
      expect(topo.ownerLabel, 'Unknown owner');
      expect(topo.ownerLabel, isNot(contains('u-a')));
    });

    test('an untitled topo still renders', () {
      expect(AbandonedTopo.fromRow(_row('a', name: ''))!.wallName, 'Untitled');
    });
  });

  group('the summary sentence', () {
    AbandonedTopo topo({int open = 3, int days = 400}) =>
        AbandonedTopo.fromRow(_row('a', open: open, oldestDaysAgo: days))!;

    test('a long wait is stated in years, not 400 days', () {
      expect(topo(days: 400).summary(_nowMs), '3 suggestions waiting 13 months');
      expect(topo(days: 900).summary(_nowMs), contains('years'));
    });

    test('a short wait stays in days', () {
      expect(topo(days: 30).summary(_nowMs), '3 suggestions waiting 30 days');
    });

    test('one suggestion is singular', () {
      expect(topo(open: 1, days: 30).summary(_nowMs), startsWith('1 suggestion '));
    });

    test('a future timestamp clamps to zero rather than reading as negative', () {
      final t = AbandonedTopo.fromRow(_row('a', oldestDaysAgo: -10))!;
      expect(t.waiting(_nowMs), Duration.zero);
      expect(t.summary(_nowMs), contains('today'));
    });
  });

  group('the Stalled tab', () {
    testWidgets('lists each stalled topo with how long it has been stuck', (
      tester,
    ) async {
      await _pump(tester, rows: [_row('a'), _row('b', name: 'Cicus')]);

      expect(find.byKey(const Key('admin-abandoned-row-a')), findsOne);
      expect(find.byKey(const Key('admin-abandoned-row-b')), findsOne);
      expect(find.textContaining('3 suggestions waiting'), findsNWidgets(2));
    });

    testWidgets('an empty list says so plainly', (tester) async {
      await _pump(tester, rows: const []);
      expect(find.byKey(const Key('admin-abandoned-empty')), findsOne);
    });

    testWidgets(
      'a failure surfaces as an error, NOT as an empty list. "We could not '
      'ask" must never render as "nothing is abandoned"',
      (tester) async {
        await _pump(tester, rows: const [], throws: true);
        expect(find.byKey(const Key('admin-abandoned-empty')), findsNothing);
        expect(find.textContaining("Couldn't load stalled topos"), findsOne);
      },
    );

    testWidgets('opening a row navigates to the topo', (tester) async {
      await _pump(tester, rows: [_row('a')]);
      await tester.tap(find.byKey(const Key('admin-abandoned-open-a')));
      await tester.pumpAndSettle();
      expect(_pushed, 'a');
    });

    testWidgets(
      'the tab carries NO count badge. Abandonment was already true yesterday '
      'and will be true tomorrow; badging it makes it compete with an unsafe '
      'report for the same urgency',
      (tester) async {
        await _pump(tester, rows: [_row('a'), _row('b')]);
        expect(find.text('Stalled'), findsOne);
        expect(find.text('Stalled (2)'), findsNothing);
      },
    );

    testWidgets(
      'there is NO transfer-ownership control. The remedy is irreversible and '
      'aimed at a real person\'s work, so this surface reports and stops',
      (tester) async {
        await _pump(tester, rows: [_row('a')]);
        for (final label in ['Transfer', 'Take over', 'Reassign', 'Claim']) {
          expect(
            find.textContaining(label),
            findsNothing,
            reason: '"$label" would make taking a topo the easy path',
          );
        }
      },
    );
  });
}
