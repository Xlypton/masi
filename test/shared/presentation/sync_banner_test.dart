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
    testWidgets('offline renders the one agreed offline sentence, verbatim', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(const SyncBanner(kind: SyncBannerKind.offline)),
      );

      expect(find.byKey(const Key('sync-banner')), findsOneWidget);
      expect(
        find.text("You're offline — showing your saved topos."),
        findsOneWidget,
      );
    });

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

  group('SyncBanner dismiss affordance', () {
    testWidgets(
      'offline is closable: onDismiss renders the close button and tapping it '
      'calls back exactly once',
      (tester) async {
        var dismissals = 0;
        await tester.pumpWidget(
          _wrap(
            SyncBanner(
              kind: SyncBannerKind.offline,
              onDismiss: () => dismissals++,
            ),
          ),
        );

        expect(find.byKey(const Key('sync-banner-dismiss')), findsOneWidget);
        await tester.tap(find.byKey(const Key('sync-banner-dismiss')));
        await tester.pump();

        expect(dismissals, 1);
      },
    );

    testWidgets('no onDismiss means no close affordance at all', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(const SyncBanner(kind: SyncBannerKind.offline)),
      );

      expect(find.byKey(const Key('sync-banner-dismiss')), findsNothing);
    });

    // The load-bearing half of this feature's scope. "Couldn't sync" is the
    // ONLY signal that the user's work may not have reached the cloud, and
    // `sharedPhotosWithheld` is the only account of a visibly incomplete feed
    // — a closable version of either is how a real problem becomes invisible.
    // Asserted with `onDismiss` deliberately SUPPLIED, so this pins the
    // widget's own structural guard rather than the call sites' discipline.
    for (final kind in const [
      SyncBannerKind.syncFailed,
      SyncBannerKind.sharedPhotosWithheld,
    ]) {
      testWidgets(
        '$kind is NOT dismissible even when handed an onDismiss — only being '
        'offline is a message the user is allowed to have finished reading',
        (tester) async {
          var dismissals = 0;
          await tester.pumpWidget(
            _wrap(SyncBanner(kind: kind, onDismiss: () => dismissals++)),
          );

          expect(find.byKey(const Key('sync-banner-dismiss')), findsNothing);
          expect(find.byKey(const Key('sync-banner')), findsOneWidget);
          expect(find.text(SyncBanner.messageFor(kind)), findsOneWidget);
          expect(dismissals, 0);
        },
      );
    }

    testWidgets(
      'the close button does not push the offline banner into an overflow at '
      '3.0x text scale on a narrow phone',
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
                  SyncBanner(kind: SyncBannerKind.offline, onDismiss: () {}),
                ],
              ),
            ),
          ),
        );
        await tester.pump();

        expect(tester.takeException(), isNull);
        expect(find.byKey(const Key('sync-banner-dismiss')), findsOneWidget);
      },
    );
  });

  group('SyncBanner iconography', () {
    /// The LEADING glyph each kind must render. The assertions below are about
    /// this exact mapping rather than "some MasiIcon is present", so the
    /// dismissible offline variant (which legitimately renders a second
    /// MasiIcon, the close glyph) cannot weaken them.
    const leadingGlyph = {
      SyncBannerKind.offline: 'phone_off',
      SyncBannerKind.syncFailed: 'warning',
      SyncBannerKind.sharedPhotosWithheld: 'warning',
    };

    testWidgets('uses MasiIcon glyphs only — never a Material/Cupertino Icon', (
      tester,
    ) async {
      for (final kind in SyncBannerKind.values) {
        await tester.pumpWidget(_wrap(SyncBanner(kind: kind)));
        expect(find.byType(MasiIcon), findsOneWidget, reason: '$kind');
        expect(
          tester.widget<MasiIcon>(find.byType(MasiIcon)).name,
          leadingGlyph[kind],
          reason: '$kind',
        );
        expect(find.byType(Icon), findsNothing, reason: '$kind');
      }
    });

    testWidgets(
      'the closable offline banner adds the brand close glyph and nothing '
      'else — the leading glyph is still exactly phone_off, and a '
      'Material/Cupertino Icon still never appears (masi_close.svg is the '
      "app's only close glyph)",
      (tester) async {
        await tester.pumpWidget(
          _wrap(SyncBanner(kind: SyncBannerKind.offline, onDismiss: () {})),
        );

        expect(
          tester.widgetList<MasiIcon>(find.byType(MasiIcon)).map((i) => i.name),
          ['phone_off', 'close'],
        );
        expect(find.byType(Icon), findsNothing);
      },
    );

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

    // Same treatment, and the same reasoning, as `_StorageWarningBanner`'s
    // viewport-share cap: the invariant is "the list stays reachable", which is
    // a statement about the screen. `maxLines` alone is not a height bound —
    // three lines at a 3.0x accessibility text scale are as tall as a dozen at
    // 1.0x.
    group('the height cap', () {
      const long =
          'Sync failed: ClientException with SocketException: Failed host '
          "lookup: 'mnaipcqbkqzffgvxpato.supabase.co' (OS Error: nodename nor "
          'servname provided, or not known, errno = 8) while pulling walls, '
          'sectors, areas, photos, routes, comments, likes and ascents from '
          'the backup endpoint';

      Future<void> pumpAt(
        WidgetTester tester,
        Size size, {
        double textScale = 1.0,
      }) async {
        setViewportSize(tester, size);
        await tester.pumpWidget(
          MaterialApp(
            theme: MasiTheme.light,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(textScale)),
              child: child!,
            ),
            home: Scaffold(
              body: Column(
                children: [
                  const SyncBanner(
                    kind: SyncBannerKind.syncFailed,
                    detail: long,
                  ),
                  // Stands in for the list: it is what must stay reachable.
                  Expanded(child: Container(key: const Key('the-list'))),
                ],
              ),
            ),
          ),
        );
        await tester.pump();
      }

      testWidgets('leaves most of a small viewport to the list', (
        tester,
      ) async {
        const surface = Size(400, 420);
        await pumpAt(tester, surface, textScale: 3.0);

        // MEASURED uncapped at exactly these settings: 407 px of a 420 px
        // surface, i.e. the entire screen.
        expect(
          tester.getSize(find.byKey(const Key('sync-banner'))).height,
          lessThan(surface.height * 0.5),
          reason:
              'a notice that eats the viewport hides the very thing the '
              'user opened the app for',
        );
        expect(
          tester.getSize(find.byKey(const Key('the-list'))).height,
          greaterThan(0),
          reason: 'the list was starved to 0px by the banner above it',
        );
        expect(tester.takeException(), isNull);
      });

      testWidgets('an ordinary phone viewport is unaffected — the cap must not '
          'shrink the normal case', (tester) async {
        await pumpAt(tester, const Size(390, 844));

        expect(
          find.textContaining('Failed host lookup'),
          findsOneWidget,
          reason: 'the reason still reads in full at a normal text scale',
        );
      });
    });
  });
}
