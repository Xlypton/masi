// C-5d: material-change notices.
//
// Approval is a one-time gate (C-5c), so the review queue is bypassable by the
// obvious route: submit something clean, get approved, then replace the
// content. These notices are the cheap middle ground — they block nothing and
// just let an admin see that a published topo changed shape.
//
// Two properties are worth more than the happy path here.
//
// The first is that the surface stays QUIET. Its failure mode is not "we missed
// one", it is "the queue filled up with ordinary editing and admins stopped
// reading it", so the tests that matter most are the ones asserting a rename, a
// nudged line and an added route produce nothing at all.
//
// The second is that a kind of change this build has never heard of still
// renders as something an admin can act on. The server deploys independently of
// the app, so a newer notice reaching an older client is a matter of time.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:masi/app/theme.dart';
import 'package:masi/features/account/application/auth_providers.dart';
import 'package:masi/features/moderation/application/moderation_providers.dart';
import 'package:masi/features/moderation/data/moderation_remote.dart';
import 'package:masi/features/moderation/domain/material_change.dart';
import 'package:masi/features/moderation/presentation/admin_queue_screen.dart';

const _nowMs = 1800000000000;

Map<String, dynamic> _row(
  String id, {
  String name = 'Dolomitici',
  String? actorName = 'Bela',
  String actorId = 'u-actor',
  String ownerId = 'u-owner',
  Object? changes = const {'routesRemoved': 3},
  int count = 1,
}) => {
  'id': id,
  'wallId': 'w-$id',
  'wallName': name,
  'ownerId': ownerId,
  'ownerName': 'Kata',
  'actorId': actorId,
  'actorName': actorName,
  'changesJson': changes,
  'changeCount': count,
  'firstAt': _nowMs - 60000,
  'lastAt': _nowMs - 30000,
};

class _FakeModeration implements ModerationRemote {
  _FakeModeration({this.rows = const [], this.throws = false});
  final List<Map<String, dynamic>> rows;
  final bool throws;
  final List<String> resolved = [];
  bool resolveThrows = false;

  @override
  Future<List<Map<String, dynamic>>> fetchMaterialChanges({
    int limit = 50,
  }) async {
    if (throws) throw StateError('not authorised');
    return rows;
  }

  @override
  Future<void> resolveMaterialChange(String noticeId) async {
    if (resolveThrows) throw StateError('nope');
    resolved.add(noticeId);
  }

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
  await tester.tap(find.byKey(const Key('admin-tab-changes')));
  await tester.pumpAndSettle();
  return remote;
}

void main() {
  setUp(() => _pushed = null);

  group('parsing a row', () {
    test('a row with no id, no wall or no timestamp is dropped', () {
      expect(MaterialChange.fromRow(_row('')), isNull);
      expect(MaterialChange.fromRow({..._row('a'), 'wallId': ''}), isNull);
      expect(MaterialChange.fromRow({..._row('a'), 'lastAt': null}), isNull);
      expect(MaterialChange.fromRow(const {}), isNull);
    });

    test('an actor with no profile renders a word, never a bare uid', () {
      final c = MaterialChange.fromRow(_row('a', actorName: null))!;
      expect(c.actorLabel, 'Someone');
      expect(c.actorLabel, isNot(contains('u-actor')));
    });

    test('an untitled topo still renders', () {
      expect(MaterialChange.fromRow(_row('a', name: ''))!.wallName, 'Untitled');
    });

    test('a changesJson that is not a map degrades to empty, not a crash', () {
      final c = MaterialChange.fromRow(_row('a', changes: 'nonsense'))!;
      expect(c.changes, isEmpty);
      expect(c.summary, 'Changed structurally');
    });

    test('the owner editing their own topo is flagged as such', () {
      expect(
        MaterialChange.fromRow(_row('a', actorId: 'u-owner'))!.byOwner,
        isTrue,
      );
      expect(MaterialChange.fromRow(_row('a'))!.byOwner, isFalse);
      expect(
        MaterialChange.fromRow(_row('a', actorId: 'u-owner'))!.actorSentence,
        'the owner',
      );
    });

    test(
      'a notice covering several edits does NOT claim one person made them '
      'all. Only the last actor is stored, and the case this feature exists '
      'for is a stranger reshaping a topo the owner then touches — an '
      'unqualified "the owner" would invite dismissing the row unlooked-at',
      () {
        final c = MaterialChange.fromRow(
          _row('a', actorId: 'u-owner', count: 4),
        )!;
        expect(c.actorSentence, 'last edit by the owner');
        expect(
          MaterialChange.fromRow(_row('a', count: 4))!.actorSentence,
          'last edit by Bela',
        );
      },
    );
  });

  group('the summary sentence', () {
    MaterialChange of(Map<String, Object> changes) =>
        MaterialChange.fromRow(_row('a', changes: changes))!;

    test('counts are singular or plural', () {
      expect(of({'routesRemoved': 1}).summary, '1 route removed');
      expect(of({'routesRemoved': 4}).summary, '4 routes removed');
    });

    test('removals are named first, because they are what a reader lost', () {
      final s = of({
        'coverPhotoSwapped': true,
        'routesRemoved': 2,
      }).summary;
      expect(s, startsWith('2 routes removed'));
      expect(s, contains('cover photo swapped'));
    });

    test('a replaced cover image is called out as its own thing', () {
      // The purest bait-and-switch keeps every route, name and grade and
      // changes only the image underneath.
      expect(of({'coverPhotoReplaced': true}).summary, 'Cover image replaced');
    });

    test(
      'a kind this build has never heard of still renders something actionable. '
      'The server deploys separately from the app, so an unknown kind is a '
      'matter of time, and a row that renders blank is one an admin can neither '
      'act on nor dismiss with confidence',
      () {
        expect(of({'somethingNewInV9': 7}).summary, 'Changed structurally');
      },
    );

    test('zero counts are not rendered as changes', () {
      expect(of({'routesRemoved': 0, 'geometryCleared': 0}).changeLabels, isEmpty);
    });
  });

  group('the Changes tab', () {
    testWidgets('lists each changed topo with what changed', (tester) async {
      await _pump(tester, rows: [_row('a'), _row('b', name: 'Cicus')]);

      expect(find.byKey(const Key('admin-change-row-a')), findsOne);
      expect(find.byKey(const Key('admin-change-row-b')), findsOne);
      expect(find.text('3 routes removed'), findsNWidgets(2));
    });

    testWidgets('an empty list says so plainly', (tester) async {
      await _pump(tester, rows: const []);
      expect(find.byKey(const Key('admin-changes-empty')), findsOne);
    });

    testWidgets(
      'a failure surfaces as an error, NOT as an empty list. "We could not ask" '
      'must never render as "nothing has been tampered with"',
      (tester) async {
        await _pump(tester, rows: const [], throws: true);
        expect(find.byKey(const Key('admin-changes-empty')), findsNothing);
        expect(find.textContaining("Couldn't load recent changes"), findsOne);
      },
    );

    testWidgets('the owner changing their own topo reads differently', (
      tester,
    ) async {
      await _pump(tester, rows: [_row('a', actorId: 'u-owner')]);
      expect(
        find.textContaining('the owner'),
        findsOne,
        reason: 'a stranger reshaping a topo and an owner quietly replacing '
            'their own approved content are different problems',
      );
    });

    testWidgets('repeated edits show as one row with a count', (tester) async {
      await _pump(tester, rows: [_row('a', count: 12)]);
      expect(find.byKey(const Key('admin-change-row-a')), findsOne);
      expect(find.textContaining('12 edits'), findsOne);
    });

    testWidgets('opening a row navigates to the topo', (tester) async {
      await _pump(tester, rows: [_row('a')]);
      await tester.tap(find.byKey(const Key('admin-change-open-a')));
      await tester.pumpAndSettle();
      expect(_pushed, 'w-a');
    });

    testWidgets('clearing sends the notice id, not the wall id', (tester) async {
      final remote = await _pump(tester, rows: [_row('a')]);
      await tester.tap(find.byKey(const Key('admin-change-clear-a')));
      await tester.pumpAndSettle();
      expect(remote.resolved, ['a']);
      expect(find.text('Cleared'), findsOne);
    });

    testWidgets('a failed clear says so rather than looking dismissed', (
      tester,
    ) async {
      final remote = await _pump(tester, rows: [_row('a')]);
      remote.resolveThrows = true;
      await tester.tap(find.byKey(const Key('admin-change-clear-a')));
      await tester.pumpAndSettle();
      expect(find.textContaining("Couldn't clear that"), findsOne);
    });

    testWidgets(
      'the tab carries NO count badge. A material change blocks nothing and the '
      'content was always allowed to be public; badging it would put "someone '
      'edited a topo" at the same volume as an unsafe report',
      (tester) async {
        await _pump(tester, rows: [_row('a'), _row('b')]);
        expect(find.text('Changes'), findsOne);
        expect(find.text('Changes (2)'), findsNothing);
      },
    );

    testWidgets(
      'there is NO revert or take-down control here. Both already exist where '
      'they belong, and reaching them by way of LOOKING at the topo is the '
      'right order for a surface that is a watch list, not a decision',
      (tester) async {
        await _pump(tester, rows: [_row('a')]);
        for (final label in ['Revert', 'Take down', 'Undo', 'Restore']) {
          expect(
            find.textContaining(label),
            findsNothing,
            reason: '"$label" here would be acting without having looked',
          );
        }
      },
    );
  });
}
