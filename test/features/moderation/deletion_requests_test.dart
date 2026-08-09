// The Deletions tab: an owner asking permission to destroy a topo that has
// been public.
//
// Two properties carry this surface, and both are about what it REFUSES to let
// an admin do carelessly.
//
// The first is that the ascent count is never hidden. Routes can be re-drawn
// and a photo re-taken; somebody's record of a climb they did cannot, and that
// is the whole of §3.3. So it is on the row, in the confirmation sheet, and
// stated even at zero — "no ascents logged" is the fact that makes an approval
// easy, and omitting it would leave its absence ambiguous.
//
// The second is that approving DELETES NOTHING. It grants permission; the owner
// still performs the deletion. An admin who misreads that in either direction
// decides badly — believing they are destroying a topo makes them hesitate over
// a control that is safe, and believing the opposite makes them approve too
// freely — so the sheet says it out loud.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:masi/app/theme.dart';
import 'package:masi/features/account/application/auth_providers.dart';
import 'package:masi/features/moderation/application/moderation_providers.dart';
import 'package:masi/features/moderation/data/moderation_remote.dart';
import 'package:masi/features/moderation/domain/deletion_request.dart';
import 'package:masi/features/moderation/presentation/admin_queue_screen.dart';

Map<String, dynamic> _row(
  String id, {
  String name = 'Dolomitici',
  String? requester = 'Kata',
  String? reason = 'Rebuilt it as a new topo',
  int routes = 4,
  int ascents = 11,
}) => {
  'id': id,
  'wallId': 'w-$id',
  'wallName': name,
  'requesterId': 'u-$id',
  'requesterName': requester,
  'reason': reason,
  'routeCount': routes,
  'ascentCount': ascents,
  'createdAt': 1800000000000,
};

class _FakeModeration implements ModerationRemote {
  _FakeModeration({this.rows = const [], this.throws = false});
  final List<Map<String, dynamic>> rows;
  final bool throws;
  final List<({String id, bool approve, String? note})> reviewed = [];
  bool reviewThrows = false;

  @override
  Future<List<Map<String, dynamic>>> fetchDeletionRequests({
    int limit = 50,
  }) async {
    if (throws) throw StateError('not authorised');
    return rows;
  }

  @override
  Future<String> reviewDeletion({
    required String requestId,
    required bool approve,
    String? note,
  }) async {
    if (reviewThrows) throw StateError('nope');
    reviewed.add((id: requestId, approve: approve, note: note));
    return approve ? 'approved' : 'rejected';
  }

  @override
  Future<Map<String, dynamic>?> deletionRequestFor(String wallId) async => null;
  @override
  Future<String> requestDeletion(String wallId, {String? reason}) async => '';
  @override
  Future<List<Map<String, dynamic>>> fetchMaterialChanges({
    int limit = 50,
  }) async => const [];
  @override
  Future<void> resolveMaterialChange(String noticeId) async {}
  @override
  Future<bool> isAdmin() async => true;
  @override
  Future<List<Map<String, dynamic>>> fetchQueue({int limit = 50}) async =>
      const [];
  @override
  Future<List<Map<String, dynamic>>> fetchAbandoned({
    int inactiveDays = 90,
    int limit = 50,
  }) async => const [];
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

Future<_FakeModeration> _pump(
  WidgetTester tester, {
  required List<Map<String, dynamic>> rows,
  bool throws = false,
}) async {
  final remote = _FakeModeration(rows: rows, throws: throws);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        moderationRemoteProvider.overrideWithValue(remote),
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
  await tester.tap(find.byKey(const Key('admin-tab-deletions')));
  await tester.pumpAndSettle();
  return remote;
}

void main() {
  setUp(() => _pushed = null);

  group('parsing a row', () {
    test('a row with no id, wall or timestamp is dropped', () {
      expect(DeletionRequest.fromRow(_row('')), isNull);
      expect(DeletionRequest.fromRow({..._row('a'), 'wallId': ''}), isNull);
      expect(DeletionRequest.fromRow({..._row('a'), 'createdAt': null}), isNull);
      expect(DeletionRequest.fromRow(const {}), isNull);
    });

    test('a requester with no profile renders a label, never a bare uid', () {
      final r = DeletionRequest.fromRow(_row('a', requester: null))!;
      expect(r.requesterLabel, 'Unknown owner');
      expect(r.requesterLabel, isNot(contains('u-a')));
    });

    test('a missing count reads as zero rather than crashing', () {
      final r = DeletionRequest.fromRow({..._row('a'), 'ascentCount': null})!;
      expect(r.ascentCount, 0);
      expect(r.costsOthers, isFalse);
    });
  });

  group('what is at stake', () {
    DeletionRequest of({int routes = 4, int ascents = 11}) =>
        DeletionRequest.fromRow(_row('a', routes: routes, ascents: ascents))!;

    test('ascents are named last, because they are what the eye stops on', () {
      expect(of().stakes, '4 routes · 11 ascents logged');
    });

    test('singulars', () {
      expect(of(routes: 1, ascents: 1).stakes, '1 route · 1 ascent logged');
    });

    test(
      'ZERO ascents is stated, not omitted. "no ascents logged" is the fact '
      'that makes an approval easy, and leaving it out would make its absence '
      'ambiguous with a row that simply failed to load the number',
      () {
        expect(of(ascents: 0).stakes, endsWith('no ascents logged'));
        expect(of(ascents: 0).costsOthers, isFalse);
        expect(of(ascents: 1).costsOthers, isTrue);
      },
    );
  });

  group('the Deletions tab', () {
    testWidgets('lists each request with what would be lost', (tester) async {
      await _pump(tester, rows: [_row('a'), _row('b', name: 'Cicus')]);
      expect(find.byKey(const Key('admin-deletion-row-a')), findsOne);
      expect(find.byKey(const Key('admin-deletion-row-b')), findsOne);
      expect(find.text('4 routes · 11 ascents logged'), findsNWidgets(2));
    });

    testWidgets('an empty queue says so plainly', (tester) async {
      await _pump(tester, rows: const []);
      expect(find.byKey(const Key('admin-deletions-empty')), findsOne);
    });

    testWidgets(
      'a failure surfaces as an error, NOT as an empty list — somebody has '
      'been told a moderator will look at their request',
      (tester) async {
        await _pump(tester, rows: const [], throws: true);
        expect(find.byKey(const Key('admin-deletions-empty')), findsNothing);
        expect(find.textContaining("Couldn't load deletion requests"), findsOne);
      },
    );

    testWidgets('opening the topo navigates to it, not to the request', (
      tester,
    ) async {
      await _pump(tester, rows: [_row('a')]);
      await tester.tap(find.byKey(const Key('admin-deletion-open-w-a')));
      await tester.pumpAndSettle();
      expect(_pushed, 'w-a');
    });

    testWidgets(
      'approving asks first, and the sheet says it DELETES NOTHING — an admin '
      'who thinks this destroys the topo will hesitate over a safe control, '
      'and one who thinks the opposite will approve too freely',
      (tester) async {
        final remote = await _pump(tester, rows: [_row('a')]);
        await tester.tap(find.byKey(const Key('admin-deletion-approve-a')));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('admin-deletion-approve-confirm')), findsOne);
        expect(find.textContaining('does not delete anything now'), findsOne);
        expect(
          find.textContaining('11 ascents logged'),
          findsWidgets,
          reason: 'the number that should change the answer is in the sheet',
        );
        expect(remote.reviewed, isEmpty, reason: 'nothing before confirming');

        await tester.tap(find.byKey(const Key('admin-deletion-approve-yes')));
        await tester.pumpAndSettle();
        expect(remote.reviewed.single.id, 'a');
        expect(remote.reviewed.single.approve, isTrue);
      },
    );

    testWidgets('backing out of the confirm approves nothing', (tester) async {
      final remote = await _pump(tester, rows: [_row('a')]);
      await tester.tap(find.byKey(const Key('admin-deletion-approve-a')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('admin-deletion-approve-no')));
      await tester.pumpAndSettle();
      expect(remote.reviewed, isEmpty);
    });

    testWidgets(
      'declining carries the reason to the owner — `deletion_requests` is '
      'readable by its requester, so a silent refusal teaches them nothing '
      'and guarantees they ask again',
      (tester) async {
        final remote = await _pump(tester, rows: [_row('a')]);
        await tester.tap(find.byKey(const Key('admin-deletion-decline-a')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('admin-deletion-decline-reason-field')),
          'People still climb here',
        );
        // Pump before tapping: the submit button is disabled while the field is
        // empty and only re-enables on the rebuild that `enterText`'s onChanged
        // schedules, so tapping in the same frame hits a dead control.
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('admin-deletion-decline-reason-submit')),
        );
        await tester.pumpAndSettle();
        expect(remote.reviewed.single.approve, isFalse);
        expect(remote.reviewed.single.note, 'People still climb here');
      },
    );

    testWidgets(
      'an empty reason declines NOTHING — the prompt holds rather than letting '
      'a refusal through with no explanation',
      (tester) async {
        // Its own test, not a first step in the one above: the prompt stays
        // open on an empty submit, so a follow-up tap in the same test lands on
        // the modal barrier and dismisses it, and the second half then measures
        // the dismissal rather than the decline.
        final remote = await _pump(tester, rows: [_row('a')]);
        await tester.tap(find.byKey(const Key('admin-deletion-decline-a')));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('admin-deletion-decline-reason-submit')),
        );
        await tester.pumpAndSettle();
        expect(remote.reviewed, isEmpty);
        expect(
          find.byKey(const Key('admin-deletion-decline-reason-field')),
          findsOne,
          reason: 'the prompt is still open, waiting for a reason',
        );
      },
    );

    testWidgets('a failed decision says so rather than looking done', (
      tester,
    ) async {
      final remote = await _pump(tester, rows: [_row('a')]);
      remote.reviewThrows = true;
      await tester.tap(find.byKey(const Key('admin-deletion-approve-a')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('admin-deletion-approve-yes')));
      await tester.pumpAndSettle();
      expect(find.textContaining("Couldn't record that decision"), findsOne);
    });

    testWidgets(
      'the tab carries NO count badge. A bar where everything is badged is a '
      'bar where nothing is, and the one that must survive a busy day is the '
      'unsafe report (C-12)',
      (tester) async {
        await _pump(tester, rows: [_row('a'), _row('b')]);
        expect(find.text('Deletions'), findsOne);
        expect(find.text('Deletions (2)'), findsNothing);
      },
    );

    testWidgets(
      'there is NO delete control here. Approving grants permission and the '
      'owner performs the deletion, so an admin mis-tap costs nobody a topo',
      (tester) async {
        await _pump(tester, rows: [_row('a')]);
        for (final label in ['Delete now', 'Delete topo', 'Remove']) {
          expect(find.textContaining(label), findsNothing);
        }
      },
    );
  });
}
