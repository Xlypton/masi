// Signed-in E2E regression flow, driven headless in Chrome.
//
//   tool/drive_web.sh integration_test/e2e_signed_in_test.dart      (macOS)
//   flutter drive --driver=test_driver/integration_test.dart \      (Windows)
//     --target=integration_test/e2e_signed_in_test.dart \
//     -d web-server --browser-name=chrome --driver-port=4444 \
//     --headless --no-web-resources-cdn --timeout=600
//
// Boots through `e2eOverrides()` from `lib/main_e2e.dart` — the SAME wiring
// the interactive browser build uses — so a bug found by hand in Chrome and a
// bug found here cannot be artifacts of two different harnesses.
//
// DELIBERATELY ASSERTION-HEAVY. `web_smoke_test.dart` guards every interaction
// behind `if (tester.any(...))` and contains zero `expect()` calls, so it
// passes whether or not the app did anything — it proves "did not throw", not
// "worked" (CLAUDE.md says as much). This file instead FAILS when a step is
// unreachable, which is the only way an autonomous run can catch a regression
// rather than silently skipping past it.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:masi/app/router.dart' show appRouter;
import 'package:masi/main.dart' show bootApp;
import 'package:masi/main_e2e.dart' show e2eOverrides, e2eTestEmail;

/// Shimmer-safe replacement for `pumpAndSettle`.
///
/// `MasiShimmer` (and any perpetual animation) never reaches a settled frame,
/// so `pumpAndSettle` against a screen using one hangs until its timeout —
/// a documented trap in `docs/DEV_SETUP.md` §10. Pumping a fixed budget of
/// frames is immune to that and still lets async work land.
Future<void> settle(
  WidgetTester tester, {
  int frames = 40,
  Duration step = const Duration(milliseconds: 100),
}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(step);
  }
}

/// Taps [finder], failing with [what] if it never appeared.
Future<void> tapOrFail(
  WidgetTester tester,
  Finder finder,
  String what,
) async {
  expect(finder, findsWidgets, reason: 'expected to find $what');
  await tester.tap(finder.first);
  await settle(tester);
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('signed-in: boots past the auth wall and round-trips '
      'Area -> Sector -> Wall', (tester) async {
    // Unique per run so the assertions below cannot be satisfied by a row
    // left behind in OPFS by an EARLIER run — the e2e uid is deliberately
    // stable, so the local library genuinely persists between runs.
    final stamp = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
    final areaName = 'E2E Area $stamp';
    final sectorName = 'E2E Sector $stamp';
    final wallName = 'E2E Wall $stamp';

    bootApp(overrides: e2eOverrides());
    await settle(tester, frames: 60);
    await binding.takeScreenshot('01-signed-in-home');

    // The auth wall must NOT have bounced us to the sign-in view. If the
    // gate override ever regresses, every later step would fail with a
    // confusing "can't find the FAB" — assert the real cause here instead.
    expect(
      find.byKey(const Key('account-send-link')),
      findsNothing,
      reason: 'auth wall redirected to the sign-in view despite a '
          'signed-in session — webAuthGateEnabledProvider override broke',
    );

    // --- Areas ---
    await tapOrFail(
      tester,
      find.byKey(const Key('topos-organize')),
      'the Topos "organize" (Areas) entry point',
    );
    await binding.takeScreenshot('02-areas');

    await tapOrFail(
      tester,
      find.byKey(const Key('area-add-fab')),
      'the add-Area FAB',
    );
    await tester.enterText(find.byKey(const Key('crud-name-field')), areaName);
    await settle(tester, frames: 10);
    await tapOrFail(
      tester,
      find.byKey(const Key('crud-name-submit')),
      'the Area name submit button',
    );
    expect(
      find.text(areaName),
      findsWidgets,
      reason: 'the new Area did not appear in the Areas list after create',
    );
    await binding.takeScreenshot('03-area-created');

    // --- Sectors ---
    await tapOrFail(tester, find.text(areaName), 'the new Area row');
    await tapOrFail(
      tester,
      find.byKey(const Key('sector-add-fab')),
      'the add-Sector FAB',
    );
    await tester.enterText(
      find.byKey(const Key('crud-name-field')),
      sectorName,
    );
    await settle(tester, frames: 10);
    await tapOrFail(
      tester,
      find.byKey(const Key('crud-name-submit')),
      'the Sector name submit button',
    );
    expect(
      find.text(sectorName),
      findsWidgets,
      reason: 'the new Sector did not appear under its Area after create',
    );
    await binding.takeScreenshot('04-sector-created');

    // --- Walls ---
    await tapOrFail(tester, find.text(sectorName), 'the new Sector row');
    await tapOrFail(
      tester,
      find.byKey(const Key('wall-add-fab')),
      'the add-Wall FAB',
    );
    await tester.enterText(find.byKey(const Key('crud-name-field')), wallName);
    await settle(tester, frames: 10);
    await tapOrFail(
      tester,
      find.byKey(const Key('crud-name-submit')),
      'the Wall name submit button',
    );
    expect(
      find.text(wallName),
      findsWidgets,
      reason: 'the new Wall did not appear under its Sector after create',
    );
    await binding.takeScreenshot('05-wall-created');

    // --- Persistence round-trip ---
    // Navigate back up to Areas and confirm the Area is still listed. This
    // is a re-read through the drift/OPFS query path, not a widget-tree
    // leftover: the Areas screen rebuilt from `watchAreas` after the
    // Sector/Wall writes committed.
    await tester.pageBack();
    await settle(tester);
    await tester.pageBack();
    await settle(tester);
    expect(
      find.text(areaName),
      findsWidgets,
      reason: 'the Area vanished from the list after navigating back — the '
          'write did not survive a re-read from drift',
    );
    await binding.takeScreenshot('06-round-trip');
  });

  testWidgets('signed-in: the Account screen reports the session', (
    tester,
  ) async {
    bootApp(overrides: e2eOverrides());
    await settle(tester, frames: 60);

    // `/account` is a top-level sibling of the bottom-nav shell (see
    // `webAuthGateSignInPath`), not one of its tabs, so drive the module-level
    // router directly rather than hunting for a nav affordance.
    appRouter.go('/account');
    await settle(tester, frames: 40);
    await binding.takeScreenshot('07-account-signed-in');

    // Reaching /account signed-in must show the signed-IN body (the session's
    // email), never the magic-link form.
    expect(
      find.byKey(const Key('account-email-label')),
      findsWidgets,
      reason: 'Account screen did not render the signed-in body',
    );
    expect(
      find.textContaining(e2eTestEmail),
      findsWidgets,
      reason: 'Account screen did not report the signed-in session email',
    );
    expect(
      find.byKey(const Key('account-send-link')),
      findsNothing,
      reason: 'Account screen showed the magic-link form for a signed-in user',
    );
  });
}
