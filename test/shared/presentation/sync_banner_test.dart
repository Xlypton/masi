import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:masi/app/theme.dart';
import 'package:masi/shared/presentation/masi_icon.dart';
import 'package:masi/shared/presentation/sync_banner.dart';

Widget _wrap(Widget child) => MaterialApp(
  theme: MasiTheme.light,
  home: Scaffold(body: Column(children: [child])),
);

void setViewportSize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  group('SyncBanner copy', () {
    testWidgets(
      'offline renders the one agreed offline sentence, verbatim',
      (tester) async {
        await tester.pumpWidget(
          _wrap(const SyncBanner(kind: SyncBannerKind.offline)),
        );

        expect(find.byKey(const Key('sync-banner')), findsOneWidget);
        expect(
          find.text("You're offline — showing your saved topos."),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'the offline sentence is a constant on the widget, so both feeds are '
      'provably showing the SAME string rather than two hand-copied ones',
      (tester) async {
        expect(
          SyncBanner.offlineMessage,
          "You're offline — showing your saved topos.",
        );

        await tester.pumpWidget(
          _wrap(const SyncBanner(kind: SyncBannerKind.offline)),
        );
        expect(find.text(SyncBanner.offlineMessage), findsOneWidget);
      },
    );

    testWidgets(
      'offline ignores any detail it is handed — the offline sentence never '
      'grows a raw error string',
      (tester) async {
        await tester.pumpWidget(
          _wrap(
            const SyncBanner(
              kind: SyncBannerKind.offline,
              detail: 'Sync failed: connection closed',
            ),
          ),
        );

        expect(find.text(SyncBanner.offlineMessage), findsOneWidget);
        expect(find.textContaining('connection closed'), findsNothing);
      },
    );

    testWidgets(
      'syncFailed keeps the pre-existing empty-state wording verbatim, '
      "reason and all — \"Couldn't sync — <reason>.\"",
      (tester) async {
        await tester.pumpWidget(
          _wrap(
            const SyncBanner(
              kind: SyncBannerKind.syncFailed,
              detail: 'Sync failed: connection closed',
            ),
          ),
        );

        expect(
          find.text("Couldn't sync — Sync failed: connection closed."),
          findsOneWidget,
        );
      },
    );

    testWidgets('syncFailed with no reason still says something true', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(const SyncBanner(kind: SyncBannerKind.syncFailed)),
      );

      expect(find.text("Couldn't sync."), findsOneWidget);
    });
  });

  group('SyncBanner retry affordance', () {
    testWidgets('no onRetry means no retry button at all', (tester) async {
      await tester.pumpWidget(
        _wrap(const SyncBanner(kind: SyncBannerKind.syncFailed)),
      );

      expect(find.byKey(const Key('sync-banner-retry')), findsNothing);
    });

    testWidgets('onRetry renders a Retry button that actually calls back', (
      tester,
    ) async {
      var taps = 0;
      await tester.pumpWidget(
        _wrap(
          SyncBanner(
            kind: SyncBannerKind.syncFailed,
            detail: 'boom',
            onRetry: () => taps++,
          ),
        ),
      );

      expect(find.byKey(const Key('sync-banner-retry')), findsOneWidget);
      await tester.tap(find.byKey(const Key('sync-banner-retry')));
      await tester.pump();

      expect(taps, 1);
    });
  });

  group('SyncBanner iconography', () {
    testWidgets('uses MasiIcon glyphs only — never a Material/Cupertino Icon', (
      tester,
    ) async {
      for (final kind in SyncBannerKind.values) {
        await tester.pumpWidget(_wrap(SyncBanner(kind: kind)));
        expect(find.byType(MasiIcon), findsOneWidget, reason: '$kind');
        expect(find.byType(Icon), findsNothing, reason: '$kind');
      }
    });

    testWidgets(
      'offline is NOT styled as a danger/error state — being offline is not '
      'a fault and must not read like data loss',
      (tester) async {
        await tester.pumpWidget(
          _wrap(const SyncBanner(kind: SyncBannerKind.offline)),
        );
        final context = tester.element(find.byKey(const Key('sync-banner')));
        final colors = MasiColors.of(context);

        final offlineIcon = tester.widget<MasiIcon>(find.byType(MasiIcon));
        expect(offlineIcon.color, isNot(colors.gradeHard));

        await tester.pumpWidget(
          _wrap(const SyncBanner(kind: SyncBannerKind.syncFailed)),
        );
        final failedIcon = tester.widget<MasiIcon>(find.byType(MasiIcon));
        expect(failedIcon.color, colors.gradeHard);
      },
    );
  });

  group('SyncBanner layout', () {
    testWidgets(
      'a long reason at 3.0x text scale on a narrow phone does not overflow — '
      'the reason is an exception toString() and can be a paragraph',
      (tester) async {
        setViewportSize(tester, const Size(320, 800));

        await tester.pumpWidget(
          MaterialApp(
            theme: MasiTheme.light,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(3.0)),
              child: child!,
            ),
            home: Scaffold(
              body: Column(
                children: [
                  SyncBanner(
                    kind: SyncBannerKind.syncFailed,
                    detail:
                        'Sync failed: ClientException with SocketException: '
                        'Failed host lookup: '
                        "'mnaipcqbkqzffgvxpato.supabase.co' "
                        '(OS Error: nodename nor servname provided, or not '
                        'known, errno = 8)',
                    onRetry: () {},
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pump();

        expect(tester.takeException(), isNull);
      },
    );
  });
}
