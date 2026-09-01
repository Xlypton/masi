// The in-app heads-up: a notification that lands WHILE the app is open.
//
// Push covers the app being closed and the bell's badge covers the user going
// to look; between them there was nothing for the case where the app is open
// and the user is not looking at the bell — which is exactly when the app is
// best placed to say something.
//
// Three rules carry it, and every one of them is about NOT talking:
//  - it never announces the backlog (the first emission is a baseline),
//  - it says nothing on the notification centre itself,
//  - a burst is one toast, not five.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:masi/app/theme.dart';
import 'package:masi/features/account/application/auth_providers.dart';
import 'package:masi/features/notifications/application/notification_providers.dart';
import 'package:masi/features/notifications/domain/app_notification.dart';
import 'package:masi/features/notifications/presentation/notification_heads_up.dart';
import 'package:masi/shared/presentation/masi_toast.dart';

const _me = 'u-me';

AppNotification _n(String id, {String kind = 'comment', int? readAt}) =>
    AppNotification.fromRow({
      'id': id,
      'kind': kind,
      'actorId': 'u-kata',
      'actorName': 'Kata',
      'wallId': 'w1',
      'createdAt': DateTime.now().millisecondsSinceEpoch,
      'readAt': readAt,
    })!;

String? _pushed;

/// Drives the widget off a controllable list stream, so a test can decide
/// exactly when a notification "arrives".
Future<StreamController<List<AppNotification>>> _pump(
  WidgetTester tester, {
  String? uid = _me,
  String initialLocation = '/',
}) async {
  final controller = StreamController<List<AppNotification>>.broadcast();
  addTearDown(controller.close);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        effectiveUidProvider.overrideWithValue(uid),
        notificationsProvider.overrideWith((ref) => controller.stream),
      ],
      child: MaterialApp.router(
        theme: MasiTheme.light,
        routerConfig: GoRouter(
          initialLocation: initialLocation,
          routes: [
            GoRoute(
              path: '/',
              builder: (_, _) =>
                  const Scaffold(body: NotificationHeadsUp()),
            ),
            GoRoute(
              path: '/notifications',
              builder: (_, _) =>
                  const Scaffold(body: NotificationHeadsUp()),
            ),
            GoRoute(
              path: '/community/topo/:wallId',
              builder: (_, state) {
                _pushed = '/community/topo/${state.pathParameters['wallId']}';
                return const Scaffold(body: SizedBox());
              },
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pump();
  return controller;
}

/// Emits [list] and advances into the toast's entrance animation without
/// settling it away again.
Future<void> _emit(
  WidgetTester tester,
  StreamController<List<AppNotification>> controller,
  List<AppNotification> list,
) async {
  controller.add(list);
  // TWO bare pumps before the animation one: the list arrives on a stream, so
  // the first frame is the one that DELIVERS the event and the second is the
  // one that shows the toast the listener asked for. Collapsing them into one
  // leaves the SnackBar inserted with a zero-height slot — its text is
  // findable but nothing inside it is hittable, which reads as a dead button
  // rather than as a missing pump.
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  setUp(() => _pushed = null);

  testWidgets(
    'the FIRST emission is a baseline and says nothing. Announcing the '
    'backlog on every cold start is how a notification system teaches people '
    'to ignore it',
    (tester) async {
      final c = await _pump(tester);
      await _emit(tester, c, [_n('a'), _n('b')]);
      expect(find.byType(MasiToastCard), findsNothing);
    },
  );

  testWidgets('an entry that arrives afterwards is announced, as a sentence', (
    tester,
  ) async {
    final c = await _pump(tester);
    await _emit(tester, c, [_n('a')]);
    await _emit(tester, c, [_n('b'), _n('a')]);
    expect(find.text('Kata commented on your topo'), findsOne);
  });

  testWidgets('tapping it opens the thing it is about', (tester) async {
    final c = await _pump(tester);
    await _emit(tester, c, [_n('a')]);
    await _emit(tester, c, [_n('b'), _n('a')]);
    await tester.tap(find.text('View'));
    await tester.pumpAndSettle();
    expect(_pushed, '/community/topo/w1');
  });

  testWidgets(
    'a burst is ONE toast naming the newest and counting the rest — five '
    'likes in a row is one thing worth knowing',
    (tester) async {
      final c = await _pump(tester);
      await _emit(tester, c, [_n('a')]);
      await _emit(tester, c, [_n('d'), _n('c'), _n('b'), _n('a')]);
      expect(find.byType(MasiToastCard), findsOne);
      expect(find.textContaining('2 more'), findsOne);
    },
  );

  testWidgets(
    'says nothing on the notification centre — the user is looking at the '
    'list the entry is being added to',
    (tester) async {
      final c = await _pump(tester, initialLocation: '/notifications');
      await _emit(tester, c, [_n('a')]);
      await _emit(tester, c, [_n('b'), _n('a')]);
      expect(find.byType(MasiToastCard), findsNothing);
    },
  );

  testWidgets(
    'an entry that arrives ALREADY read is not announced — the only way that '
    'happens is that it was read somewhere else',
    (tester) async {
      final c = await _pump(tester);
      await _emit(tester, c, [_n('a')]);
      await _emit(tester, c, [_n('b', readAt: 1900000000000), _n('a')]);
      expect(find.byType(MasiToastCard), findsNothing);
    },
  );

  testWidgets('a re-emission of the same list says nothing twice', (
    tester,
  ) async {
    final c = await _pump(tester);
    await _emit(tester, c, [_n('a')]);
    await _emit(tester, c, [_n('b'), _n('a')]);
    expect(find.byType(MasiToastCard), findsOne);
    await _emit(tester, c, [_n('b'), _n('a')]);
    expect(
      find.byType(MasiToastCard),
      findsOne,
      reason: 'still the first one, not a second queued behind it',
    );
  });

  testWidgets(
    'signed out there is no inbox, so there is nothing to announce',
    (tester) async {
      final c = await _pump(tester, uid: null);
      await _emit(tester, c, const []);
      await _emit(tester, c, [_n('a')]);
      expect(find.byType(MasiToastCard), findsNothing);
    },
  );
}
