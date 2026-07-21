// Intended-behavior tests for RouteMetadataSheet's grade-system handling,
// grade validation, and colorBand computation (Subtask A5, assertions
// A5a-A5e). These encode the SPEC (CLIMBTOPO.md / DESIGN.md's "Grade bands"
// table, reproduced as H1-H6 in the plan) — NOT current behavior. A failing
// assertion here means the CODE is wrong, never that this test should be
// loosened.
//
// Boilerplate (ProviderContainer seeding + buildSheet wrapper) copied from
// the `RouteMetadataSheet` group in test/widget_test.dart.

import 'package:climbtopo/app/theme.dart';
import 'package:climbtopo/core/grades/grade_system.dart';
import 'package:climbtopo/features/topo/application/draw_controller.dart';
import 'package:climbtopo/features/topo/domain/topo_route.dart';
import 'package:climbtopo/features/topo/presentation/route_metadata_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// FIX #6 (family-keyed `drawControllerProvider`): stand-in wallId, paired
/// consistently everywhere this file constructs `RouteMetadataSheet` or
/// reads the provider directly.
const _testWallId = 'test-wall';

/// Pumps [RouteMetadataSheet] directly with a seeded [drawControllerProvider]
/// inside a [ProviderScope] + [MaterialApp], per the sheet's class-doc
/// testability contract: no image decode, no real canvas/photo path.
Widget _buildSheet({
  required ProviderContainer container,
  required int routeId,
  TopoRoute? initial,
}) {
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: MasiTheme.light,
      home: Scaffold(
        body: RouteMetadataSheet(
          wallId: _testWallId,
          routeId: routeId,
          initial: initial,
        ),
      ),
    ),
  );
}

/// Seeds [container] with a single committed route (≥2 points, per
/// `commitRoute`'s no-op-under-2-points contract) and returns its id.
int _seedRoute(ProviderContainer container) {
  // FIX #6 (autoDispose pending-timer gotcha): keep this family member
  // alive for the whole test -- mirrors what a mounted RouteMetadataSheet's
  // `ref.watch` does; without it, the bare `.notifier`/state reads below
  // (and any later assertion-time reads) each schedule an autoDispose
  // teardown `Timer(Duration.zero, ...)` that must be flushed by a
  // duration-based pump before the test ends, or flutter_test's
  // `!timersPending` invariant trips. See route_legend_gap_test.dart's
  // `_seedRoutes` for the fuller explanation.
  container.listen(drawControllerProvider(_testWallId), (_, _) {});
  final notifier = container.read(drawControllerProvider(_testWallId).notifier);
  notifier.addPoint(const Offset(0.1, 0.1));
  notifier.addPoint(const Offset(0.2, 0.2));
  notifier.commitRoute();
  return container.read(drawControllerProvider(_testWallId)).routes.single.id;
}

void main() {
  group('RouteMetadataSheet intent (A5)', () {
    testWidgets(
      'A5a: the grade-system control offers exactly two options -- French '
      'and UIAA -- and no third (H1)',
      (tester) async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final routeId = _seedRoute(container);

        await tester.pumpWidget(
          _buildSheet(container: container, routeId: routeId),
        );
        await tester.pump();

        final gradeSystemKeys = tester.allWidgets
            .map((w) => w.key)
            .whereType<ValueKey<String>>()
            .map((k) => k.value)
            .where((v) => v.startsWith('topo-meta-gradesystem-'))
            .toSet();

        expect(
          gradeSystemKeys,
          {'topo-meta-gradesystem-french', 'topo-meta-gradesystem-uiaa'},
          reason:
              'H1: the grade-system picker must offer exactly French + UIAA '
              'and nothing else; found keys: $gradeSystemKeys',
        );
      },
    );

    testWidgets(
      'A5b: French grade options are French-ladder tokens only; switching '
      'to UIAA repopulates with UIAA-ladder tokens only (H2)',
      (tester) async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final routeId = _seedRoute(container);

        await tester.pumpWidget(
          _buildSheet(container: container, routeId: routeId),
        );
        await tester.pump();

        // Default grade system is French (per RouteMetadataSheet.initState).
        await tester.tap(find.byKey(const Key('topo-meta-grade')));
        await tester.pumpAndSettle();
        expect(
          find.text('6a'),
          findsOneWidget,
          reason: 'French ladder must offer "6a"',
        );
        expect(
          find.text('6a+'),
          findsOneWidget,
          reason: 'French ladder must offer "6a+"',
        );
        expect(
          find.text('VI'),
          findsNothing,
          reason: 'UIAA token "VI" must not leak into the French ladder',
        );
        // Close the dropdown without selecting (tap far outside its menu).
        await tester.tapAt(const Offset(5, 5));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('topo-meta-gradesystem-uiaa')));
        await tester.pump();

        await tester.tap(find.byKey(const Key('topo-meta-grade')));
        await tester.pumpAndSettle();
        expect(
          find.text('VI'),
          findsOneWidget,
          reason: 'UIAA ladder must offer "VI" after switching systems',
        );
        expect(
          find.text('VI+'),
          findsOneWidget,
          reason: 'UIAA ladder must offer "VI+" after switching systems',
        );
        expect(
          find.text('6a'),
          findsNothing,
          reason: 'French token "6a" must not leak into the UIAA ladder',
        );
      },
    );

    testWidgets(
      'A5c: French grades map to the SPEC colorBand (H6: green <=4, blue '
      '5-6a, orange 6a+-6c+, red 7a-7c+, purple >=8a), and the sheet renders '
      'the same band it computes (H3/H5/H6)',
      (tester) async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final routeId = _seedRoute(container);

        // SPEC (H6) expressed on representative French grades. The French
        // ladder has no bare '4' token (see grade_system.dart -- it is
        // split into 4a/4b/4c), so '4c' (the hardest rung of the "4" tier)
        // stands in for "French 4".
        const specGradeToBand = {
          '4c': GradeBand.beginner, // green
          '5c': GradeBand.intermediate, // blue
          '6b': GradeBand.advanced, // orange
          '7a': GradeBand.hard, // red
          '8a': GradeBand.elite, // purple
        };

        // 1) The pure grade service -- what the sheet's own band feedback
        // badge is built on (see RouteMetadataSheet.build: `band =
        // bandForSortKey(gradeSortKey(...))`) -- must classify every
        // representative grade into the SPEC band.
        for (final entry in specGradeToBand.entries) {
          final computed = bandForSortKey(
            gradeSortKey(GradeSystem.french, entry.key),
          );
          expect(
            computed,
            entry.value,
            reason:
                'H6: French ${entry.key} must classify as ${entry.value}, '
                'got $computed',
          );
        }

        // 2) End-to-end: selecting one representative grade in the actual
        // sheet UI must render that SAME band's label + the theme's
        // grade-band color for it -- guards against the UI wiring using a
        // different mapping than the grade service.
        await tester.pumpWidget(
          _buildSheet(container: container, routeId: routeId),
        );
        await tester.pump();

        await tester.tap(find.byKey(const Key('topo-meta-grade')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('6b').last);
        await tester.pumpAndSettle();

        const expectedBand = GradeBand.advanced;
        expect(
          find.text(gradeBandLabel(expectedBand)),
          findsOneWidget,
          reason:
              'Sheet must show the "${gradeBandLabel(expectedBand)}" band '
              'badge label after selecting French 6b',
        );

        final context = tester.element(find.byType(RouteMetadataSheet));
        final colors = MasiColors.of(context);
        final expectedColor = gradeBandColor(colors, expectedBand);

        final swatches = tester
            .widgetList<Container>(
              find.descendant(
                of: find.byType(RouteMetadataSheet),
                matching: find.byType(Container),
              ),
            )
            .where((c) {
              final decoration = c.decoration;
              return decoration is BoxDecoration &&
                  decoration.shape == BoxShape.circle;
            })
            .toList();
        expect(
          swatches,
          hasLength(1),
          reason:
              'Expected exactly one circular band-color swatch in the '
              'rendered badge; found ${swatches.length}',
        );
        expect(
          (swatches.single.decoration as BoxDecoration).color,
          expectedColor,
          reason:
              'Badge swatch color must equal gradeBandColor(colors, '
              '$expectedBand) for French 6b',
        );
      },
    );

    testWidgets(
      'A5d: topo-meta-save persists name/grade/style/description via '
      'setRouteMetadata; topo-meta-cancel leaves the route unchanged (B5)',
      (tester) async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final routeId = _seedRoute(container);
        final before = container.read(drawControllerProvider(_testWallId)).routes.single;

        // --- Cancel path: edits typed in but never saved must not mutate
        // the route in drawControllerProvider's state.
        await tester.pumpWidget(
          _buildSheet(container: container, routeId: routeId),
        );
        await tester.pump();

        await tester.enterText(
          find.byKey(const Key('topo-meta-name')),
          'Should Not Persist',
        );
        // ensureVisible before EVERY targeted tap below (not just Save/
        // Cancel): RouteMetadataSheet carries no Key, so the second
        // `_buildSheet` pump further down (the "save path") reuses this
        // SAME State/scroll-position via Flutter's normal element diffing
        // rather than mounting fresh -- whatever this block scrolls to
        // stays scrolled for the next block too, so every control must be
        // scrolled into view right before it's tapped rather than assumed
        // reachable from a fresh top-of-sheet scroll offset.
        await tester.ensureVisible(find.byKey(const Key('topo-meta-grade')));
        await tester.tap(find.byKey(const Key('topo-meta-grade')));
        await tester.pumpAndSettle();
        // '6b' (not '7a'): the dropdown menu overlay only lays out a
        // lazily-scrolled window of the 30-token French ladder, and '7a'
        // sits below the initially-visible fold (see debugging notes in
        // this subtask's report) -- '6b' is within it.
        await tester.tap(find.text('6b').last);
        await tester.pumpAndSettle();
        await tester.ensureVisible(
          find.byKey(const Key('topo-meta-style-trad')),
        );
        await tester.tap(find.byKey(const Key('topo-meta-style-trad')));
        await tester.pump();
        await tester.enterText(
          find.byKey(const Key('topo-meta-description')),
          'unsaved notes',
        );

        // The sheet grew (beta-URL/style-tags/stars sections) and now
        // overflows the default 800x600 test surface; its body is a real
        // SingleChildScrollView (see RouteMetadataSheet.build), so
        // Save/Cancel must be scrolled into view before tapping, same as
        // any other off-screen-but-scrollable control.
        await tester.ensureVisible(find.byKey(const Key('topo-meta-cancel')));
        await tester.tap(find.byKey(const Key('topo-meta-cancel')));
        await tester.pump();

        final afterCancel =
            container.read(drawControllerProvider(_testWallId)).routes.single;
        expect(
          afterCancel.name,
          before.name,
          reason: 'topo-meta-cancel must not persist the typed name',
        );
        expect(
          afterCancel.gradeRaw,
          before.gradeRaw,
          reason: 'topo-meta-cancel must not persist the selected grade',
        );
        expect(
          afterCancel.style,
          before.style,
          reason: 'topo-meta-cancel must not persist the selected style',
        );
        expect(
          afterCancel.description,
          before.description,
          reason: 'topo-meta-cancel must not persist the typed description',
        );
        expect(afterCancel.name, isNot('Should Not Persist'));

        // --- Save path: the same kind of edits, saved this time, must land
        // on the route via setRouteMetadata.
        await tester.pumpWidget(
          _buildSheet(container: container, routeId: routeId),
        );
        await tester.pump();

        await tester.enterText(
          find.byKey(const Key('topo-meta-name')),
          'Le Toit',
        );
        await tester.ensureVisible(find.byKey(const Key('topo-meta-grade')));
        await tester.tap(find.byKey(const Key('topo-meta-grade')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('6b').last);
        await tester.pumpAndSettle();
        await tester.ensureVisible(
          find.byKey(const Key('topo-meta-style-trad')),
        );
        await tester.tap(find.byKey(const Key('topo-meta-style-trad')));
        await tester.pump();
        await tester.enterText(
          find.byKey(const Key('topo-meta-description')),
          'crux at the roof',
        );

        await tester.ensureVisible(find.byKey(const Key('topo-meta-save')));
        await tester.tap(find.byKey(const Key('topo-meta-save')));
        await tester.pump();

        final afterSave = container.read(drawControllerProvider(_testWallId)).routes.single;
        expect(afterSave.name, 'Le Toit');
        expect(afterSave.gradeSystem, GradeSystem.french);
        expect(afterSave.gradeRaw, '6b');
        expect(afterSave.style, 'trad');
        expect(afterSave.description, 'crux at the roof');
      },
    );

    testWidgets(
      'A5e: gradeRaw/gradeSystem preserve the exact token passed to '
      'setRouteMetadata while gradeSortKey is derived from the NORMALIZED '
      'grade (H4)',
      (tester) async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final routeId = _seedRoute(container);

        // Drive setRouteMetadata directly with a non-canonically-cased raw
        // token. The sheet's own dropdown only ever offers canonical
        // ladder spellings (see A5b) -- it has no free-text grade entry --
        // so this exercises the setRouteMetadata/TopoRoute contract that
        // RouteMetadataSheet._save itself relies on, rather than routing
        // through UI that structurally cannot type arbitrary casing.
        final notifier = container.read(drawControllerProvider(_testWallId).notifier);
        await notifier.setRouteMetadata(
          routeId,
          gradeSystem: GradeSystem.french,
          gradeRaw: '6A+',
        );

        final route = container.read(drawControllerProvider(_testWallId)).routes.single;
        expect(
          route.gradeRaw,
          '6A+',
          reason:
              'H4: gradeRaw must preserve the entered token exactly '
              '(including case), not normalize it',
        );
        expect(route.gradeSystem, GradeSystem.french);

        // Sanity: normalization actually changes this token's casing, so
        // the following is a real assertion that ordering is NOT keyed off
        // raw-string equality with the un-normalized token.
        expect(normalizeGrade(GradeSystem.french, '6A+'), '6a+');
        expect(
          route.gradeSortKey,
          gradeSortKey(GradeSystem.french, '6a+'),
          reason:
              'gradeSortKey must be derived from the normalized grade '
              '("6a+"), not the raw entered token ("6A+")',
        );
      },
    );
  });
}
