// The notification centre, and the badge that leads to it.
//
// Three things carry this surface.
//
// The first is that the screen renders the LOCAL MIRROR and refreshes it,
// rather than rendering the fetch. That is the whole offline story: the list
// paints from cold, and a failed refresh leaves what the user already had
// standing instead of blanking it. A test that stubbed the fetch and asserted
// on the result would be testing a design this screen deliberately does not
// have.
//
// The second is that "nothing has happened" and "we could not ask" are
// different sentences. They look identical on screen and mean opposite things,
// and an inbox that renders a failed call as an empty list tells the user that
// nobody is talking to them.
//
// The third is that the read receipt never gets in the way. Tapping opens the
// thing FIRST and marks read after, and a mark that fails is swallowed —
// refusing to open a topo because a read receipt did not send would be absurd.

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:masi/app/theme.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/features/account/application/auth_providers.dart';
import 'package:masi/features/notifications/application/notification_providers.dart';
import 'package:masi/features/notifications/data/notifications_remote.dart';
import 'package:masi/features/notifications/domain/app_notification.dart';
import 'package:masi/features/notifications/presentation/notification_bell.dart';
import 'package:masi/features/notifications/presentation/notifications_screen.dart';
import 'package:masi/shared/presentation/masi_avatar.dart';

const _me = 'u-me';

AppNotification _n(
  String id, {
  String kind = 'comment',
  String? actorName = 'Kata',
  String? wallId = 'w1',
  String? ascentId,
  String? preview = 'Nice line, the crux is stout',
  int? readAt,
}) => AppNotification.fromRow({
  'id': id,
  'kind': kind,
  'actorId': 'u-kata',
  'actorName': actorName,
  'wallId': wallId,
  'ascentId': ascentId,
  'commentId': 'c-$id',
  'preview': preview,
  'createdAt': DateTime.now().millisecondsSinceEpoch - 60000,
  'readAt': readAt,
})!;

/// Fetching throws when [fetchThrows]; marking records what it was asked to do.
class _FakeRemote implements NotificationsRemote {
  _FakeRemote({this.fetchThrows = false});

  final bool fetchThrows;
  bool markThrows = false;
  final List<List<String>?> marked = [];

  @override
  Future<List<Map<String, dynamic>>> fetch({int limit = 50}) async {
    if (fetchThrows) throw StateError('offline');
    return const [];
  }

  @override
  Future<int> markRead({List<String>? ids}) async {
    if (markThrows) throw StateError('offline');
    marked.add(ids);
    return ids?.length ?? 1;
  }

  @override
  Future<int?> unreadCount() async => null;
}

String? _pushed;

/// Pumps the screen over a hand-fed list, standing in for the Drift mirror.
///
/// The list and the unread count are overridden separately rather than derived
/// from one another on purpose: the badge reads the count and the screen reads
/// the list, and a test that fused them could not catch the two disagreeing.
///
/// **`UncontrolledProviderScope` over an explicitly-owned container**, not a
/// plain `ProviderScope`, and that is load-bearing rather than stylistic.
///
/// A `ProviderScope` owns its container and disposes it while the WIDGET TREE
/// is being torn down, inside `BuildOwner.finalizeTree`. Riverpod then cancels
/// the Drift query streams underneath, and drift's
/// `StreamQueryStore.markAsClosed` schedules a zero-duration `Timer` to do the
/// actual close. By then the tree is gone, nothing will pump again, and
/// flutter_test's teardown asserts "A Timer is still pending even after the
/// widget tree was disposed."
///
/// That assertion does not merely fail the one test — it poisons the binding,
/// so every test after it in the file reports "did not complete" and the file's
/// real coverage silently collapses to whatever ran before the first failure.
/// It cost most of an afternoon precisely because the symptom (a cascade of
/// unrelated-looking failures) looks nothing like the cause.
///
/// Owning the container here moves that disposal into `addTearDown`, which runs
/// with a live binding that can still service the timer. Registering
/// `db.close` FIRST is deliberate: `addTearDown` is LIFO, so the container
/// disposes before the connection it reads from closes. Every other suite in
/// this repo (`comment_row_test`, `nav_shell_test`, `router_test`) is built the
/// same way.
Future<_FakeRemote> _pump(
  WidgetTester tester, {
  required List<AppNotification> list,
  bool fetchThrows = false,
  Widget? home,
}) async {
  final remote = _FakeRemote(fetchThrows: fetchThrows);
  final db = AppDatabase(NativeDatabase.memory());
  final container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(db),
      notificationsRemoteProvider.overrideWithValue(remote),
      effectiveUidProvider.overrideWithValue(_me),
      notificationsProvider.overrideWith((ref) => Stream.value(list)),
      unreadNotificationCountProvider.overrideWith(
        (ref) => Stream.value(list.where((n) => n.isUnread).length),
      ),
    ],
  );
  addTearDown(db.close);
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        theme: MasiTheme.light,
        routerConfig: GoRouter(
          initialLocation: '/',
          routes: [
            GoRoute(path: '/', builder: (_, _) => home ?? const NotificationsScreen()),
            GoRoute(
              path: '/notifications',
              builder: (_, _) => const NotificationsScreen(),
            ),
            GoRoute(
              path: '/community/topo/:wallId',
              builder: (_, state) {
                _pushed = '/community/topo/${state.pathParameters['wallId']}';
                return const SizedBox();
              },
            ),
            GoRoute(
              path: '/community/ascent/:id',
              builder: (_, state) {
                _pushed = '/community/ascent/${state.pathParameters['id']}';
                return const SizedBox();
              },
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return remote;
}

void main() {
  setUp(() => _pushed = null);

  group('the empty inbox', () {
    testWidgets('a genuinely empty inbox says so, and says what will fill it', (
      tester,
    ) async {
      await _pump(tester, list: const []);
      expect(find.byKey(const Key('notifications-empty')), findsOne);
      expect(find.textContaining('comments on, tags you in or likes'), findsOne);
    });

    testWidgets(
      'a FAILED refresh does NOT read as an empty inbox. The two look '
      'identical and mean opposite things, and rendering the failure as '
      '"nothing yet" tells the user nobody is talking to them',
      (tester) async {
        await _pump(tester, list: const [], fetchThrows: true);
        expect(find.byKey(const Key('notifications-empty')), findsNothing);
        expect(find.byKey(const Key('notifications-empty-offline')), findsOne);
        expect(find.textContaining("Couldn't check for new activity"), findsOne);
      },
    );

    testWidgets(
      'a failed refresh with rows already mirrored keeps them on screen — the '
      'mirror is still the truth as of the last pull, and stale beats blank',
      (tester) async {
        await _pump(tester, list: [_n('a')], fetchThrows: true);
        expect(find.byKey(const Key('notification-row-a')), findsOne);
        expect(find.byKey(const Key('notifications-empty-offline')), findsNothing);
      },
    );
  });

  group('the list', () {
    testWidgets('each entry reads as a sentence, not as a template dump', (
      tester,
    ) async {
      await _pump(tester, list: [_n('a'), _n('b', kind: 'like')]);
      expect(find.text('Kata commented on your topo'), findsOne);
      expect(find.text('Kata liked your topo'), findsOne);
    });

    testWidgets(
      'an actor with no resolvable name reads "Someone" and the raw uid is '
      'nowhere on screen',
      (tester) async {
        await _pump(tester, list: [_n('a', actorName: null)]);
        expect(find.text('Someone commented on your topo'), findsOne);
        expect(find.textContaining('u-kata'), findsNothing);
      },
    );

    testWidgets('a comment carries its excerpt; a like does not repeat the '
        'topo name it has already said', (tester) async {
      await _pump(tester, list: [
        _n('a'),
        _n('b', kind: 'like', preview: 'Dolomitici'),
      ]);
      expect(find.byKey(const Key('notification-detail-a')), findsOne);
      expect(find.byKey(const Key('notification-detail-b')), findsNothing);
    });

    testWidgets(
      'an entry of an UNKNOWN kind renders rather than crashing the screen — '
      'a build that predates a new kind must not be a build that dies on it',
      (tester) async {
        await _pump(tester, list: [_n('a', kind: 'topo_republished'), _n('b')]);
        expect(tester.takeException(), isNull);
        expect(find.byKey(const Key('notification-row-a')), findsOne);
        expect(find.text('Kata did something on your topo'), findsOne);
        expect(
          find.byKey(const Key('notification-row-b')),
          findsOne,
          reason: 'and it does not take the entries around it down with it',
        );
      },
    );

    testWidgets('only the unread ones carry a marker', (tester) async {
      await _pump(tester, list: [_n('a'), _n('b', readAt: 1900000000000)]);
      expect(find.byKey(const Key('notification-unread-a')), findsOne);
      expect(find.byKey(const Key('notification-unread-b')), findsNothing);
    });
  });

  group('the sections', () {
    testWidgets(
      'entries sit under an age heading. An inbox is scanned for "is this '
      'still current?" before it is read, and an unheaded run of rows makes '
      'that unanswerable without doing the arithmetic on every row',
      (tester) async {
        await _pump(tester, list: [_n('a')]);
        expect(find.text('TODAY'), findsOne);
      },
    );

    testWidgets('only the sections that have something in them get a heading', (
      tester,
    ) async {
      await _pump(tester, list: [_n('a')]);
      expect(find.text('THIS WEEK'), findsNothing);
      expect(find.text('EARLIER'), findsNothing);
    });

    testWidgets(
      'every row leads with the actor, badged with what they did — a '
      'notification is a thing a PERSON did, and the leading column is too '
      'valuable to spend on a status dot',
      (tester) async {
        await _pump(tester, list: [_n('a')]);
        expect(
          find.descendant(
            of: find.byKey(const Key('notification-row-a')),
            matching: find.byType(MasiAvatar),
          ),
          findsOne,
        );
      },
    );
  });

  group('tapping through', () {
    testWidgets('opens the topo the notification is about', (tester) async {
      await _pump(tester, list: [_n('a')]);
      await tester.tap(find.byKey(const Key('notification-row-a')));
      await tester.pumpAndSettle();
      expect(_pushed, '/community/topo/w1');
    });

    testWidgets('opens the ASCENT when the entry is about one, not its wall', (
      tester,
    ) async {
      await _pump(tester, list: [_n('a', ascentId: 'as1')]);
      await tester.tap(find.byKey(const Key('notification-row-a')));
      await tester.pumpAndSettle();
      expect(_pushed, '/community/ascent/as1');
    });

    testWidgets('marks that entry read, and only that one', (tester) async {
      final remote = await _pump(tester, list: [_n('a'), _n('b')]);
      await tester.tap(find.byKey(const Key('notification-row-a')));
      await tester.pumpAndSettle();
      expect(remote.marked.single, ['a']);
    });

    testWidgets(
      'a read receipt that FAILS still opens the thing. Refusing to open a '
      'topo because a piece of bookkeeping did not send would be absurd',
      (tester) async {
        final remote = await _pump(tester, list: [_n('a')]);
        remote.markThrows = true;
        await tester.tap(find.byKey(const Key('notification-row-a')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(_pushed, '/community/topo/w1');
      },
    );
  });

  group('mark all read', () {
    testWidgets('marks everything in one call', (tester) async {
      final remote = await _pump(tester, list: [_n('a'), _n('b')]);
      await tester.tap(find.byKey(const Key('notifications-mark-all')));
      await tester.pumpAndSettle();
      expect(remote.marked, [null], reason: 'null means "all of mine"');
    });

    testWidgets(
      'is absent when nothing is unread. A control that does nothing teaches '
      'the user that tapping things here has no effect',
      (tester) async {
        await _pump(tester, list: [_n('a', readAt: 1900000000000)]);
        expect(find.byKey(const Key('notifications-mark-all')), findsNothing);
      },
    );

    testWidgets('a failure says so rather than looking done', (tester) async {
      final remote = await _pump(tester, list: [_n('a')]);
      remote.markThrows = true;
      await tester.tap(find.byKey(const Key('notifications-mark-all')));
      await tester.pumpAndSettle();
      expect(find.textContaining("Couldn't mark those read"), findsOne);
    });
  });

  group('the badge', () {
    testWidgets('counts the unread, and disappears at zero', (tester) async {
      await _pump(
        tester,
        list: [_n('a'), _n('b'), _n('c', readAt: 1900000000000)],
        home: const Scaffold(appBar: null, body: NotificationBell()),
      );
      expect(find.byKey(const Key('notifications-badge')), findsOne);
      expect(find.text('2'), findsOne);

      await _pump(
        tester,
        list: [_n('c', readAt: 1900000000000)],
        home: const Scaffold(body: NotificationBell()),
      );
      expect(find.byKey(const Key('notifications-badge')), findsNothing);
    });

    testWidgets(
      'a big count reads "9+" rather than a number no 16-px circle can hold',
      (tester) async {
        await _pump(
          tester,
          list: [for (var i = 0; i < 23; i++) _n('n$i')],
          home: const Scaffold(body: NotificationBell()),
        );
        expect(find.text('9+'), findsOne);
        expect(find.text('23'), findsNothing);
      },
    );

    testWidgets('leads to the notification centre', (tester) async {
      await _pump(
        tester,
        list: [_n('a')],
        home: const Scaffold(body: NotificationBell()),
      );
      await tester.tap(find.byKey(const Key('notifications-button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('notifications-screen')), findsOne);
    });
  });
}
