// The face layout, exercised on a wall that actually has several faces.
//
// The rest of the suite gives every fixture wall ONE photo, and `FacePager`
// renders nothing below two — so the pager, the minimap and the layout editor
// were unreachable by any test, and the whole feature shipped behind a green
// run without a single assertion touching it. `tool/e2e_seed.sh` now seeds a
// four-face wall carrying NO capture metadata, which is what every photo in
// the real database looks like.
import 'package:flutter/material.dart' hide Baseline;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:masi/app/router.dart' show appRouter;
import 'package:masi/main_e2e.dart' show e2eBoot;

import 'e2e_support.dart';

const String kFacesWallName = 'E2E Faces Wall';
const String kSeededAreaName = 'E2E Test Area';
const String kSeededSectorName = 'E2E Test Sector';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> openFacesWall(WidgetTester tester) async {
    await e2eBoot();
    await settleNetwork(tester, budget: const Duration(seconds: 10));
    // `appRouter` is module-level, so navigation SURVIVES a re-boot: the
    // second test in this file starts wherever the first one finished, deep
    // inside a topo, and every `find` for a Topos-root affordance then times
    // out. Drive the router home first.
    appRouter.go('/');
    await settle(tester, frames: 30);
    expect(
      find.byKey(const Key('account-send-link')),
      findsNothing,
      reason: 'the auth wall bounced us to sign-in — see the console for '
          '"masi/e2e: REAL sign-in FAILED"',
    );

    await tapOrFail(
      tester,
      find.byKey(const Key('topos-organize')),
      'the Topos "organize" (Areas) entry point',
    );
    await waitFor(
      tester,
      find.text(kSeededAreaName),
      'the seeded area — run tool/e2e_seed.sh',
      timeout: const Duration(seconds: 40),
    );
    await tapOrFail(tester, find.text(kSeededAreaName), 'the seeded area row');
    await tapOrFail(
      tester,
      find.text(kSeededSectorName),
      'the seeded sector row',
    );
    await waitFor(
      tester,
      find.text(kFacesWallName),
      'the seeded four-face wall — the fixture predates it if this fails',
      timeout: const Duration(seconds: 30),
    );
    await tapOrFail(tester, find.text(kFacesWallName), 'the four-face wall');
    await settleNetwork(tester, budget: const Duration(seconds: 8));
  }

  testWidgets('layout: four faces get a pager, a minimap and a way into the '
      'editor', (tester) async {
    await openFacesWall(tester);
    await binding.takeScreenshot('40-faces-canvas');

    await waitFor(
      tester,
      find.byKey(const Key('face-pager-dots')),
      'the face pager on a four-photo wall',
      timeout: const Duration(seconds: 20),
    );
    expect(
      find.byKey(const Key('face-pager-minimap')),
      findsOneWidget,
      reason: 'four faces resolve to a capture-order strip, which is a real '
          'line — the minimap must draw it',
    );
    // The entry point is a labelled button, not a tappable caption.
    expect(find.text('Edit'), findsOneWidget);
  });

  testWidgets('layout: the editor opens, shows every face, and a diagonal '
      'drag DRAWS instead of scrolling the page', (tester) async {
    await openFacesWall(tester);

    await tapOrFail(
      tester,
      find.byKey(const Key('face-pager-edit-layout')),
      'the Edit button on the minimap',
    );
    await settle(tester, frames: 30);
    await binding.takeScreenshot('41-layout-editor');

    expect(
      find.byKey(const Key('layout-canvas')),
      findsOneWidget,
      reason: 'the editor did not open',
    );
    expect(
      find.byKey(const Key('layout-confidence-banner')),
      findsOneWidget,
      reason: 'with no GPS and no headings anywhere, this line is a guess and '
          'has to say so',
    );

    await tapOrFail(
      tester,
      find.byKey(const Key('layout-redraw')),
      'the Redraw line button',
    );
    await settle(tester, frames: 10);
    expect(
      find.byKey(const Key('layout-redraw-hint')),
      findsOneWidget,
      reason: 'redrawing must say what to do — the canvas is a blank box '
          'otherwise',
    );
    await binding.takeScreenshot('42-layout-redrawing');

    // A DIAGONAL drag. The canvas lives in a ListView, which used to claim
    // every drag with a vertical component and scroll the page instead of
    // drawing — so this exact gesture is the regression.
    final canvas = tester.getRect(find.byKey(const Key('layout-canvas')));
    final start = Offset(canvas.left + 34, canvas.top + 40);
    final gesture = await tester.startGesture(start);
    for (var i = 1; i <= 20; i++) {
      await gesture.moveTo(
        Offset(
          start.dx + (canvas.width - 68) * i / 20,
          start.dy + (canvas.height - 80) * i / 20,
        ),
      );
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await settleNetwork(tester, budget: const Duration(seconds: 6));
    await binding.takeScreenshot('43-layout-redrawn');

    expect(
      find.byKey(const Key('layout-confidence-banner')),
      findsNothing,
      reason: 'a line the contributor drew is authored, not a guess — if the '
          'banner is still up, the stroke never reached the wall and the '
          'drag was swallowed by the scroll',
    );
    expect(
      find.byKey(const Key('layout-reset')),
      findsOneWidget,
      reason: 'an authored line must be droppable back to the automatic one',
    );

    // And back, so the fixture is left as it was found.
    await tapOrFail(
      tester,
      find.byKey(const Key('layout-reset')),
      'the reset-to-automatic action',
    );
    await settleNetwork(tester, budget: const Duration(seconds: 6));
    await waitFor(
      tester,
      find.byKey(const Key('layout-confidence-banner')),
      'the guess notice after resetting to the automatic line',
      timeout: const Duration(seconds: 15),
    );
    await binding.takeScreenshot('44-layout-reset');
  });
}
