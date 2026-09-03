// Visual review for the reworked notification surfaces, rendered in a REAL
// browser so the theming can be looked at rather than reasoned about.
//
//   tool/drive_web.sh integration_test/notification_surfaces_review_test.dart
//
// Screenshot-producing, and assertion-bearing where it can be: each step
// asserts the surface it is about to photograph is actually on screen, so an
// empty PNG fails here instead of being mistaken for a design decision.
//
// Deliberately does NOT boot the whole app through `e2eOverrides()`. These are
// two presentation-layer surfaces whose inputs are a list and an enum; booting
// the real app would mean seeding the live dev backend with notifications just
// to look at a row, and the row would render identically either way.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:integration_test/integration_test.dart';
import 'package:masi/app/theme.dart';
import 'package:masi/features/account/application/auth_providers.dart';
import 'package:masi/features/notifications/application/notification_providers.dart';
import 'package:masi/features/notifications/domain/app_notification.dart';
import 'package:masi/features/notifications/presentation/notifications_screen.dart';
import 'package:masi/shared/presentation/masi_toast.dart';

Future<void> settle(WidgetTester tester, {int frames = 20}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

AppNotification _n(
  String id, {
  required String kind,
  required String actor,
  String? preview,
  int ageMinutes = 5,
  bool unread = true,
  String? ascentId,
}) => AppNotification.fromRow({
  'id': id,
  'kind': kind,
  'actorId': 'u-$actor',
  'actorName': actor,
  'wallId': 'w1',
  'ascentId': ascentId,
  'preview': preview,
  'createdAt': DateTime.now()
      .subtract(Duration(minutes: ageMinutes))
      .millisecondsSinceEpoch,
  'readAt': unread ? null : DateTime.now().millisecondsSinceEpoch,
})!;

List<AppNotification> _fixture() => [
  _n('a', kind: 'comment', actor: 'Kata', preview: 'Nice line — the crux is stout'),
  _n('b', kind: 'like', actor: 'Bence', ageMinutes: 90),
  _n('c', kind: 'mention', actor: 'Zsófi', preview: 'ask @you about the topout', ageMinutes: 260, unread: false),
  _n('d', kind: 'suggestion', actor: 'Marco', ageMinutes: 60 * 30, unread: false),
  _n('e', kind: 'like', actor: 'Someone', ageMinutes: 60 * 24 * 9, unread: false, ascentId: 'as1'),
];

/// The notification centre over a hand-fed list, in [brightness].
Widget _centre(Brightness brightness) => ProviderScope(
  overrides: [
    effectiveUidProvider.overrideWithValue('u-me'),
    notificationsProvider.overrideWith((ref) => Stream.value(_fixture())),
    unreadNotificationCountProvider.overrideWith((ref) => Stream.value(2)),
  ],
  child: MaterialApp.router(
    theme: brightness == Brightness.dark ? MasiTheme.dark : MasiTheme.light,
    routerConfig: GoRouter(
      routes: [
        GoRoute(path: '/', builder: (_, _) => const NotificationsScreen()),
      ],
    ),
  ),
);

/// All four toast kinds at once, laid out as they render.
Widget _toasts(Brightness brightness) => MaterialApp(
  theme: brightness == Brightness.dark ? MasiTheme.dark : MasiTheme.light,
  home: Builder(
    builder: (context) => Scaffold(
      backgroundColor: MasiColors.of(context).ground,
      body: const Center(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 15),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              MasiToastCard(message: 'Location saved', kind: MasiToastKind.success),
              SizedBox(height: 12),
              MasiToastCard(
                message: "Couldn't save your like — please try again",
                kind: MasiToastKind.error,
              ),
              SizedBox(height: 12),
              MasiToastCard(
                message: 'Route is still saving — try again in a moment.',
                kind: MasiToastKind.warning,
              ),
              SizedBox(height: 12),
              MasiToastCard(
                message: 'Kata commented on your topo',
                kind: MasiToastKind.info,
                actionLabel: 'View',
                onAction: _noop,
              ),
            ],
          ),
        ),
      ),
    ),
  ),
);

void _noop() {}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the four toast kinds, light and dark', (tester) async {
    await tester.pumpWidget(_toasts(Brightness.light));
    await settle(tester);
    expect(find.byType(MasiToastCard), findsNWidgets(4));
    await binding.takeScreenshot('notif-01-toasts-light');

    await tester.pumpWidget(_toasts(Brightness.dark));
    await settle(tester);
    await binding.takeScreenshot('notif-02-toasts-dark');
  });

  testWidgets('the notification centre, light and dark', (tester) async {
    await tester.pumpWidget(_centre(Brightness.light));
    await settle(tester, frames: 30);
    expect(find.byKey(const Key('notification-row-a')), findsOne);
    expect(find.text('TODAY'), findsOne);
    await binding.takeScreenshot('notif-03-centre-light');

    await tester.pumpWidget(_centre(Brightness.dark));
    await settle(tester, frames: 30);
    await binding.takeScreenshot('notif-04-centre-dark');
  });
}
