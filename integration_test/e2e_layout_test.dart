// The face layout, exercised on a wall that actually has several faces.
//
// The rest of the suite gives every fixture wall ONE photo, and the dock's
// face lane renders nothing below two — so the rail, the plan view and the
// layout editor were unreachable by any test, and the whole feature shipped
// behind a green run without a single assertion touching it. `tool/e2e_seed.sh` now seeds a
// four-face wall carrying NO capture metadata, which is what every photo in
// the real database looks like.
import 'dart:math' as math;

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
    // Phone-shaped, always. See usePhoneViewport: a desktop-width window is
    // not the product and hides exactly the layout faults that matter.
    usePhoneViewport(tester);
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

  testWidgets('layout: four faces get a rail of real thumbnails, a plan '
      'behind one tap, and a way into the editor', (tester) async {
    await openFacesWall(tester);
    await binding.takeScreenshot('40-faces-canvas');

    await waitFor(
      tester,
      find.byKey(const Key('face-rail')),
      'the dock face rail on a four-photo wall',
      timeout: const Duration(seconds: 20),
    );
    expect(
      find.byKey(const Key('topo-dock')),
      findsOneWidget,
      reason: 'the faces and the routes are one panel now, not two stacked '
          'panels that have to clear each other',
    );
    expect(
      find.byKey(const Key('topo-dock-body')),
      findsNothing,
      reason: 'the dock opens as ONE LINE — the photo is what the reader came '
          'for, and the panel over it used to take most of the phone',
    );
    expect(
      find.byKey(const Key('face-map-plan')),
      findsNothing,
      reason: 'the plan is a glance you ask for — mounting it permanently is '
          'what put 153pt of card between the reader and the photo',
    );
    // Real pictures, not dots: one tile per photo, and the plan tile beside
    // them.
    expect(find.byKey(const Key('face-rail-map')), findsOneWidget);

    await tapOrFail(
      tester,
      find.byKey(const Key('face-rail-map')),
      'the rail plan tile',
    );
    await settle(tester, frames: 25);
    await binding.takeScreenshot('46-face-map');

    expect(
      find.byKey(const Key('face-map-plan')),
      findsOneWidget,
      reason: 'four faces resolve to a capture-order strip, which is a real '
          'line — the plan screen must draw it',
    );
    expect(
      find.byKey(const Key('face-map-current')),
      findsOneWidget,
      reason: 'the bar naming the photo you are on is how Open knows what it '
          'is opening',
    );
    // The way into the editor is a labelled button, not a tappable caption.
    expect(find.byKey(const Key('face-map-edit')), findsOneWidget);
    expect(find.text('Edit'), findsOneWidget);

    // And back out the way we came, so the next test starts on the canvas.
    await tapOrFail(
      tester,
      find.byKey(const Key('face-map-open')),
      'the plan screen Open button',
    );
    await settle(tester, frames: 20);
    expect(find.byKey(const Key('face-rail')), findsOneWidget);
  });

  testWidgets('layout: the editor opens, shows every face, and a line is '
      'TAPPED out the way a route is', (tester) async {
    await openFacesWall(tester);

    await tapOrFail(
      tester,
      find.byKey(const Key('face-rail-map')),
      'the rail plan tile',
    );
    await settle(tester, frames: 25);
    await tapOrFail(
      tester,
      find.byKey(const Key('face-map-edit')),
      'the Edit button on the plan screen',
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

    // TAPS, one point each — the gesture every route on every topo in this
    // app is drawn with.
    final canvas = tester.getRect(find.byKey(const Key('layout-canvas')));
    final start = Offset(canvas.left + 34, canvas.top + 40);
    for (var i = 0; i < 4; i++) {
      await tester.tapAt(
        Offset(
          start.dx + (canvas.width - 68) * i / 3,
          start.dy + (canvas.height - 80) * i / 3,
        ),
      );
      await settle(tester, frames: 4);
    }
    await binding.takeScreenshot('43-layout-tapped');

    // A DIAGONAL drag on a placed point. The canvas lives in a ListView,
    // which used to claim every drag with a vertical component and scroll the
    // page instead — so moving a point is still the regression this exercises.
    await tester.dragFrom(start, const Offset(20, 30));
    await settle(tester, frames: 6);
    expect(
      find.byKey(const Key('layout-redraw-hint')),
      findsOneWidget,
      reason: 'dragging a point must not finish the line',
    );

    await tapOrFail(
      tester,
      find.byKey(const Key('layout-redraw-done')),
      'the Finish button',
    );
    await settleNetwork(tester, budget: const Duration(seconds: 6));
    await binding.takeScreenshot('43-layout-redrawn');

    expect(
      find.byKey(const Key('layout-confidence-banner')),
      findsNothing,
      reason: 'a line the contributor drew is authored, not a guess — if the '
          'banner is still up, the stroke never reached the wall and the '
          'taps went nowhere',
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

  testWidgets('layout: four faces on a RING never cover each other', (
    tester,
  ) async {
    // The exact shape the user photographed: a boulder traced as a closed
    // loop, with every thumbnail piled in the middle of it. Two things put it
    // there — an inward normal on a counter-clockwise stroke and no collision
    // handling — and both are only visible once a real ring exists, which is
    // why this test draws one rather than asserting on the seeded strip.
    await openFacesWall(tester);

    await tapOrFail(
      tester,
      find.byKey(const Key('face-rail-map')),
      'the rail plan tile',
    );
    await settle(tester, frames: 25);
    await tapOrFail(
      tester,
      find.byKey(const Key('face-map-edit')),
      'the Edit button on the plan screen',
    );
    await settle(tester, frames: 30);
    await tapOrFail(
      tester,
      find.byKey(const Key('layout-redraw')),
      'the Redraw line button',
    );
    await settle(tester, frames: 10);

    final canvas = tester.getRect(find.byKey(const Key('layout-canvas')));
    final centre = canvas.center;
    final radius = math.min(canvas.width, canvas.height) / 2 - 40;
    Offset around(double turn) => centre +
        Offset(math.cos(turn * 2 * math.pi), math.sin(turn * 2 * math.pi)) *
            radius;

    // Six taps round the rock, then one more back on the first point: that
    // last tap is the closure gesture, and the only thing that makes this a
    // boulder rather than a wall.
    for (var i = 0; i < 6; i++) {
      await tester.tapAt(around(i / 6));
      await settle(tester, frames: 4);
    }
    await tester.tapAt(around(0));
    await settleNetwork(tester, budget: const Duration(seconds: 6));
    await binding.takeScreenshot('45-layout-ring');

    final rects = <Rect>[];
    for (final element in find
        .byWidgetPredicate(
          (w) =>
              w is Container &&
              w.key is ValueKey<String> &&
              (w.key! as ValueKey<String>).value.startsWith('layout-face-') &&
              !(w.key! as ValueKey<String>).value.contains('pinned'),
        )
        .evaluate()) {
      rects.add(tester.getRect(find.byWidget(element.widget)));
    }
    expect(
      rects.length,
      4,
      reason: 'all four faces must still be drawn on the ring',
    );
    for (var i = 0; i < rects.length; i++) {
      for (var j = i + 1; j < rects.length; j++) {
        expect(
          rects[i].overlaps(rects[j]),
          isFalse,
          reason: 'thumbnails ${rects[i]} and ${rects[j]} cover each other',
        );
      }
    }

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
  });
}
