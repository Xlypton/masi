import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:masi/app/theme.dart';
import 'package:masi/shared/presentation/masi_icon.dart';
import 'package:masi/shared/presentation/masi_loading_indicator.dart';
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

/// Intercepts `Clipboard.setData` and hands back whatever the widget wrote.
///
/// `SystemChannels.platform` has no implementation under `flutter_test`, so
/// without this the copy button's `Clipboard.setData` throws a
/// `MissingPluginException` — which the sheet catches and reports as "couldn't
/// copy". Asserting the CONTENT is the point: a copy action that copies the
/// truncated headline instead of the full exception would be worse than none.
List<String> _captureClipboard(WidgetTester tester) {
  final copied = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add((call.arguments as Map)['text'] as String);
      }
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
  return copied;
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

    // THE HEIGHT FIX, at the copy level. The banner used to print the whole
    // exception `toString()` — three lines and ~122 px on a real 390x844
    // phone, of which the part that fit was a half-printed backend URL. It now
    // says only what happened; the reason is one tap away (see the details
    // group below), which is where an exception `toString()` belongs.
    testWidgets(
      'syncFailed shows ONLY the headline on the banner — the raw reason is '
      'not printed inline',
      (tester) async {
        await tester.pumpWidget(
          _wrap(
            const SyncBanner(
              kind: SyncBannerKind.syncFailed,
              detail: 'Sync failed: connection closed',
            ),
          ),
        );

        expect(find.text("Couldn't sync"), findsOneWidget);
        expect(find.textContaining('connection closed'), findsNothing);
      },
    );

    testWidgets('syncFailed with no reason still says something true', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(const SyncBanner(kind: SyncBannerKind.syncFailed)),
      );

      expect(find.text("Couldn't sync"), findsOneWidget);
    });

    // The visible text is the collapsed line, but a screen-reader user has no
    // ⓘ-sized affordance for "read the rest", so the SPOKEN label is the full
    // sentence. Without this, the redesign would have taken information away
    // from exactly the users who cannot get it back.
    testWidgets(
      'the accessible label carries the FULL message, reason and all',
      (tester) async {
        final handle = tester.ensureSemantics();
        await tester.pumpWidget(
          _wrap(
            const SyncBanner(
              kind: SyncBannerKind.syncFailed,
              detail: 'Sync failed: connection closed',
            ),
          ),
        );

        expect(
          find.bySemanticsLabel(
            "Couldn't sync — Sync failed: connection closed.",
          ),
          findsOneWidget,
        );
        handle.dispose();
      },
    );

    test(
      'messageFor still composes the pre-existing full sentence, verbatim',
      () {
        expect(
          SyncBanner.messageFor(
            SyncBannerKind.syncFailed,
            'Sync failed: connection closed',
          ),
          "Couldn't sync — Sync failed: connection closed.",
        );
        expect(
          SyncBanner.messageFor(SyncBannerKind.syncFailed),
          "Couldn't sync.",
        );
      },
    );
  });

  group('SyncBanner details disclosure', () {
    const long =
        'Sync failed: own rows fetch failed: ClientException: Failed to fetch, '
        'uri=https://mnaipcqbkqzffgvxpato.supabase.co/rest/v1/walls';

    testWidgets(
      'EVERY kind offers the disclosure — at a large accessibility text scale '
      'even a fixed one-line sentence ellipsizes, and the sheet is then the '
      'only way to read it',
      (tester) async {
        for (final kind in SyncBannerKind.values) {
          await tester.pumpWidget(_wrap(SyncBanner(kind: kind)));
          expect(
            find.byKey(const Key('sync-banner-details')),
            findsOneWidget,
            reason: '$kind',
          );
        }
      },
    );

    testWidgets(
      'THE OTHER HALF OF THE FIX: the ⓘ opens a sheet carrying the FULL '
      'technical error — the truncated URL on the banner was useless to the '
      'user AND useless in a bug report; the whole string is not',
      (tester) async {
        await tester.pumpWidget(
          _wrap(
            const SyncBanner(kind: SyncBannerKind.syncFailed, detail: long),
          ),
        );

        expect(find.textContaining('mnaipcqbkqzffgvxpato'), findsNothing);

        await tester.tap(find.byKey(const Key('sync-banner-details')));
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('sync-banner-details-sheet')),
          findsOneWidget,
        );
        expect(
          find.text("Couldn't sync — $long."),
          findsOneWidget,
          reason: 'the sheet is where the whole reason lives now',
        );
      },
    );

    testWidgets('the sheet copies the FULL text, not the collapsed headline', (
      tester,
    ) async {
      final copied = _captureClipboard(tester);

      await tester.pumpWidget(
        _wrap(const SyncBanner(kind: SyncBannerKind.syncFailed, detail: long)),
      );
      await tester.tap(find.byKey(const Key('sync-banner-details')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('sync-banner-details-copy')));
      // Explicit pumps rather than `pumpAndSettle`: while a MasiPendingButton's
      // future is in flight it holds a live spinner gate, which never settles.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));

      expect(copied, ["Couldn't sync — $long."]);
      expect(find.text('Copied'), findsOneWidget);
    });

    testWidgets(
      'a clipboard that refuses does not throw out of a button press — the '
      'text is selectable, so there is a real fallback to point at',
      (tester) async {
        // A handler that REFUSES, which is what a browser without clipboard
        // permission does. (An absent handler is not the same thing: the test
        // binding answers unhandled platform-channel calls itself, so the copy
        // would silently "succeed" and this test would prove nothing.)
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') {
              throw PlatformException(code: 'clipboard-denied');
            }
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );

        await tester.pumpWidget(
          _wrap(
            const SyncBanner(kind: SyncBannerKind.syncFailed, detail: long),
          ),
        );
        await tester.tap(find.byKey(const Key('sync-banner-details')));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('sync-banner-details-copy')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 1));

        expect(tester.takeException(), isNull);
        expect(find.textContaining("Couldn't copy"), findsOneWidget);
        expect(
          find.byKey(const Key('sync-banner-details-text')),
          findsOneWidget,
        );
      },
    );
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
            onRetry: () async => taps++,
          ),
        ),
      );

      expect(find.byKey(const Key('sync-banner-retry')), findsOneWidget);
      await tester.tap(find.byKey(const Key('sync-banner-retry')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));

      expect(taps, 1);
    });

    // The user reported that Retry "usually" fixes it — which is what an
    // INVISIBLE retry feels like. As a plain `VoidCallback` on a bare
    // TextButton, both call sites discarded the returned future and this widget
    // read only `detail`, so nothing on screen changed for the entire pull.
    testWidgets(
      'Retry shows a live pending cue for the whole round trip, so the button '
      'cannot read as dead while the pull is in flight',
      (tester) async {
        final gate = Completer<void>();
        await tester.pumpWidget(
          _wrap(
            SyncBanner(
              kind: SyncBannerKind.syncFailed,
              detail: 'boom',
              onRetry: () => gate.future,
            ),
          ),
        );

        expect(find.byKey(MasiLoadingIndicator.spinnerKey), findsNothing);

        await tester.tap(find.byKey(const Key('sync-banner-retry')));
        // Past MasiMotion.loadingRevealDelay (180 ms) — the anti-flash gate
        // deliberately shows nothing for a pull that finishes instantly.
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));

        expect(
          find.byKey(MasiLoadingIndicator.spinnerKey),
          findsOneWidget,
          reason:
              'a retry that looks idle for the whole round trip reads as '
              'a dead button',
        );

        gate.complete();
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));

        expect(find.byKey(MasiLoadingIndicator.spinnerKey), findsNothing);
      },
    );

    testWidgets('an in-flight retry swallows a second tap', (tester) async {
      final gate = Completer<void>();
      var taps = 0;
      await tester.pumpWidget(
        _wrap(
          SyncBanner(
            kind: SyncBannerKind.syncFailed,
            detail: 'boom',
            onRetry: () {
              taps++;
              return gate.future;
            },
          ),
        ),
      );

      await tester.tap(find.byKey(const Key('sync-banner-retry')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('sync-banner-retry')));
      await tester.pump();

      expect(taps, 1);

      gate.complete();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
    });
  });

  group('SyncBanner dismiss affordance', () {
    // THE USER'S DECISION, pinned. This group used to assert the exact
    // opposite for `syncFailed`/`sharedPhotosWithheld` — that the close button
    // was structurally impossible for them, on the grounds that "a closable
    // version of it is how silent data loss becomes invisible". The user
    // reversed that, and the old justification did not survive checking
    // anyway: this banner renders `lastPullError`, which is PULL-only, so a
    // failed PUSH — the case where the user's work may genuinely not have
    // reached the cloud — never sets it. See `SyncBanner.onDismiss`.
    for (final kind in SyncBannerKind.values) {
      testWidgets(
        '$kind is closable: onDismiss renders the close button and tapping it '
        'calls back exactly once',
        (tester) async {
          var dismissals = 0;
          await tester.pumpWidget(
            _wrap(SyncBanner(kind: kind, onDismiss: () => dismissals++)),
          );

          expect(find.byKey(const Key('sync-banner-dismiss')), findsOneWidget);
          await tester.tap(find.byKey(const Key('sync-banner-dismiss')));
          await tester.pump();

          expect(dismissals, 1, reason: '$kind');
        },
      );
    }

    testWidgets('no onDismiss means no close affordance at all', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(const SyncBanner(kind: SyncBannerKind.offline)),
      );

      expect(find.byKey(const Key('sync-banner-dismiss')), findsNothing);
    });

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
    /// this exact mapping rather than "some MasiIcon is present", so the extra
    /// glyphs the row legitimately carries (the ⓘ, and the close button) cannot
    /// weaken them.
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
        expect(
          tester.widgetList<MasiIcon>(find.byType(MasiIcon)).first.name,
          leadingGlyph[kind],
          reason: '$kind',
        );
        expect(find.byType(Icon), findsNothing, reason: '$kind');
      }
    });

    testWidgets(
      'the full closable banner renders exactly the leading glyph, the details '
      'glyph and the brand close glyph — and still never a Material/Cupertino '
      'Icon (masi_close.svg is the app\'s only close glyph)',
      (tester) async {
        await tester.pumpWidget(
          _wrap(SyncBanner(kind: SyncBannerKind.offline, onDismiss: () {})),
        );

        expect(
          tester.widgetList<MasiIcon>(find.byType(MasiIcon)).map((i) => i.name),
          ['phone_off', 'info', 'close'],
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

        final offlineIcon = tester
            .widgetList<MasiIcon>(find.byType(MasiIcon))
            .first;
        expect(offlineIcon.color, isNot(colors.gradeHard));

        await tester.pumpWidget(
          _wrap(const SyncBanner(kind: SyncBannerKind.syncFailed)),
        );
        final failedIcon = tester
            .widgetList<MasiIcon>(find.byType(MasiIcon))
            .first;
        expect(
          failedIcon.color,
          colors.gradeHard,
          reason:
              'the severity colour survives the collapse — it must still '
              'read as an error',
        );
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
                    onRetry: () async {},
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
    // one line at a 3.0x accessibility text scale is as tall as three at 1.0x.
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

        expect(
          tester.getSize(find.byKey(const Key('sync-banner'))).height,
          lessThan(surface.height * 0.3),
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

      // The cap is a share of the viewport, not a pixel ceiling, so it has to
      // be tightened when the body it bounds shrinks — otherwise 0.4 stops
      // being a cap and becomes permission. What it now actually guards is
      // this screen's real case: a shell-level notice
      // (`storage_retry_banner.dart`) stacked above this banner. At 0.4 apiece
      // that pair could claim 80% of the viewport between them.
      testWidgets(
        'a shell notice PLUS this banner cannot between them claim most of '
        'the screen',
        (tester) async {
          const surface = Size(400, 420);
          await pumpAt(tester, surface, textScale: 3.0);

          expect(
            tester.getSize(find.byKey(const Key('sync-banner'))).height,
            lessThanOrEqualTo(surface.height * 0.25 + 0.5),
            reason: 'two stacked 0.4-capped notices leave the list a sliver',
          );
        },
      );

      // THE MEASURED REGRESSION GUARD. The old three-line block was ~122 px on
      // a 390x844 phone — 1.4 topo rows, on every frame, forever. One line of
      // bodyMedium beside icon-sized controls cannot be that.
      testWidgets(
        'the collapsed banner is roughly ONE line tall — materially shorter '
        'than the ~122px three-line block it replaced',
        (tester) async {
          await pumpAt(tester, const Size(390, 844));

          expect(
            tester.getSize(find.byKey(const Key('sync-banner'))).height,
            lessThan(80),
            reason: 'measured before the collapse: ~122px, i.e. 1.4 topo rows',
          );
        },
      );

      testWidgets(
        'an ordinary phone viewport still says what happened — the collapse '
        'takes the reason away, never the headline',
        (tester) async {
          await pumpAt(tester, const Size(390, 844));

          expect(find.text("Couldn't sync"), findsOneWidget);
          expect(find.byKey(const Key('sync-banner-details')), findsOneWidget);
        },
      );
    });
  });
}
