// Tests for RouteMetadataSheet's save-through (`_writeDraft` /
// `topo-meta-pop-guard`).
//
// The bug: the sheet only ever wrote on Save, so every OTHER way out of it —
// swipe it down, tap the scrim, press back — threw away everything typed,
// silently. On a phone browser those are the easy gestures, and the sheet is
// where a route's name, grade and description are entered.
//
// The shape of the fix, and what each group below pins:
//  * S1/S2 — edits land as they are made, without Save: discrete controls
//    (grade/style/tags/stars) write immediately, free text writes on a
//    debounce.
//  * S3 — dismissing the sheet without submitting keeps what was typed, even
//    inside the debounce window (the pop flush).
//  * S4 — save-through obeys the sheet's ONE validation rule
//    (`_betaUrlInvalid`) WITHOUT taking the rest of the form down with it: the
//    invalid URL is never persisted, but every other field still is. It used
//    to refuse the write as a whole, which silently lost the other fields on
//    the way out — the pop flush calls the same method, so it refused again
//    and the typed name was gone. See S4b.
//  * S5 — Cancel still means DISCARD. Save-through protects against
//    ACCIDENTAL loss; an explicit Cancel is not accidental, so anything
//    save-through already wrote is reverted (this is the pre-existing
//    contract `route_metadata_intent_test.dart`'s A5d/B5 pins, kept intact).
//  * S6 — the whole point, end to end: a draft written by save-through and
//    then dismissed WITHOUT Save is still on the form when the sheet reopens.
//
// What save-through must NOT do — write a draft the sync push then publishes —
// is pinned separately in `route_metadata_draft_dirty_test.dart`, which needs a
// real database because `dirty` is a column rather than `DrawState`.
//
// Boilerplate (ProviderContainer seeding) mirrors
// `route_metadata_intent_test.dart`'s.

import 'package:masi/app/theme.dart';
import 'package:masi/core/grades/grade_system.dart';
import 'package:masi/features/topo/application/draw_controller.dart';
import 'package:masi/features/topo/domain/topo_route.dart';
import 'package:masi/features/topo/presentation/route_metadata_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _testWallId = 'test-wall';

/// Just past [kRouteMetadataDraftDebounce], so a pump of this length is
/// guaranteed to have flushed a pending text write.
const _pastDebounce = Duration(milliseconds: 700);

/// Seeds [container] with a single committed route and returns its id.
/// See `route_metadata_intent_test.dart`'s `_seedRoute` for why the family
/// member is kept alive with a permanent listener.
int _seedRoute(ProviderContainer container) {
  container.listen(drawControllerProvider(_testWallId), (_, _) {});
  final notifier = container.read(drawControllerProvider(_testWallId).notifier);
  notifier.addPoint(const Offset(0.1, 0.1));
  notifier.addPoint(const Offset(0.2, 0.2));
  notifier.commitRoute();
  return container.read(drawControllerProvider(_testWallId)).routes.single.id;
}

TopoRoute _route(ProviderContainer container) =>
    container.read(drawControllerProvider(_testWallId)).routes.single;

/// Pumps the sheet directly, per its class-doc testability contract.
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

/// Pumps a host screen whose button opens the sheet as a REAL modal bottom
/// sheet — the production presentation (see
/// `TopoCanvasScreen._openMetadataSheet`) — so a dismissal can be driven
/// through the Navigator the way a swipe-down/scrim tap does.
Widget _buildModalHost({
  required ProviderContainer container,
  required int routeId,
  TopoRoute? initial,
}) {
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: MasiTheme.light,
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              key: const Key('host-open-meta-sheet'),
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                builder: (_) => RouteMetadataSheet(
                  wallId: _testWallId,
                  routeId: routeId,
                  initial: initial,
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
}

/// Like [_buildModalHost], but reads the route's CURRENT metadata out of the
/// controller each time the sheet is opened, which is what production does
/// (`TopoCanvasScreen._openMetadataSheet` passes the route it opened for). That
/// is what makes a REOPEN meaningful: a fixed `initial` captured once would
/// pre-fill the second open with the first open's stale values.
Widget _buildReopeningModalHost({
  required ProviderContainer container,
  required int routeId,
}) {
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: MasiTheme.light,
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              key: const Key('host-open-meta-sheet'),
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                builder: (_) => RouteMetadataSheet(
                  wallId: _testWallId,
                  routeId: routeId,
                  initial: _route(container),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  group('RouteMetadataSheet save-through', () {
    testWidgets(
      'S1: text typed into the sheet reaches the route WITHOUT tapping Save '
      '(debounced, one write for a burst of edits — never one per keystroke)',
      (tester) async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final routeId = _seedRoute(container);

        var writes = 0;
        container.listen(
          drawControllerProvider(_testWallId),
          (_, _) => writes++,
        );

        await tester.pumpWidget(
          _buildSheet(container: container, routeId: routeId),
        );
        await tester.pump();

        // Three edits in quick succession, all inside one debounce window.
        await tester.enterText(find.byKey(const Key('topo-meta-name')), 'Le');
        await tester.enterText(find.byKey(const Key('topo-meta-name')), 'Le T');
        await tester.enterText(
          find.byKey(const Key('topo-meta-name')),
          'Le Toit',
        );
        expect(
          writes,
          0,
          reason:
              'a write per keystroke is exactly what the debounce exists to '
              'prevent — each write is a full route upsert that also flags '
              'the row dirty for sync',
        );

        await tester.pump(_pastDebounce);

        expect(
          _route(container).name,
          'Le Toit',
          reason: 'the settled text must reach the route with no Save tap',
        );
        expect(
          writes,
          1,
          reason: 'three edits inside one window must collapse to one write',
        );
      },
    );

    testWidgets(
      'S2: discrete controls (grade, style, star) write immediately — they '
      'are single taps, with no keystroke burst to debounce',
      (tester) async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final routeId = _seedRoute(container);

        await tester.pumpWidget(
          _buildSheet(container: container, routeId: routeId),
        );
        await tester.pump();

        await tester.ensureVisible(find.byKey(const Key('topo-meta-grade')));
        await tester.tap(find.byKey(const Key('topo-meta-grade')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('6b').last);
        await tester.pumpAndSettle();

        expect(
          _route(container).gradeRaw,
          '6b',
          reason: 'picking a grade must persist it without a Save tap',
        );
        expect(_route(container).gradeSystem, GradeSystem.french);
        expect(
          _route(container).gradeSortKey,
          isNotNull,
          reason:
              'the sort key must be recomputed by the same setRouteMetadata '
              'path Save uses — a graded route with no sort key sorts wrong',
        );

        await tester.ensureVisible(
          find.byKey(const Key('topo-meta-style-trad')),
        );
        await tester.tap(find.byKey(const Key('topo-meta-style-trad')));
        await tester.pump();
        expect(_route(container).style, 'trad');

        await tester.ensureVisible(find.byKey(const Key('topo-meta-stars-2')));
        await tester.tap(find.byKey(const Key('topo-meta-stars-2')));
        await tester.pump();
        expect(_route(container).stars, 2);
      },
    );

    testWidgets(
      'S3: dismissing the sheet without submitting KEEPS what was typed — '
      'including a dismissal inside the debounce window',
      (tester) async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final routeId = _seedRoute(container);

        await tester.pumpWidget(
          _buildModalHost(container: container, routeId: routeId),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('host-open-meta-sheet')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('topo-meta-pop-guard')), findsOneWidget);

        await tester.enterText(
          find.byKey(const Key('topo-meta-name')),
          'Survives Dismissal',
        );
        // NO pump past the debounce: dismiss immediately, which is precisely
        // the window the pop flush exists to cover.
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('topo-meta-pop-guard')),
          findsNothing,
          reason: 'the sheet must actually be gone — the guard never blocks',
        );
        expect(
          _route(container).name,
          'Survives Dismissal',
          reason:
              'dismissing without submitting must not throw away typed '
              'metadata — that is the whole point of save-through',
        );
      },
    );

    testWidgets(
      'S4: an invalid beta URL is never persisted, but it no longer takes the '
      'rest of the form down with it — the other fields still save through, '
      'carrying the route\'s LAST VALID link',
      (tester) async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final routeId = _seedRoute(container);
        container
            .read(drawControllerProvider(_testWallId).notifier)
            .setRouteMetadata(
              routeId,
              betaVideoUrl: 'https://example.com/old-beta',
            );
        await tester.pump();
        final before = _route(container);

        await tester.pumpWidget(
          _buildSheet(container: container, routeId: routeId, initial: before),
        );
        await tester.pump();

        await tester.enterText(
          find.byKey(const Key('topo-meta-name')),
          'Has A Bad Link',
        );
        await tester.ensureVisible(find.byKey(const Key('topo-meta-beta-url')));
        await tester.enterText(
          find.byKey(const Key('topo-meta-beta-url')),
          'htp:/nope',
        );
        await tester.pump(_pastDebounce);

        expect(
          find.text('Enter a valid https:// link'),
          findsOneWidget,
          reason: 'the inline error must be showing — the field is invalid',
        );
        expect(
          _route(container).betaVideoUrl,
          'https://example.com/old-beta',
          reason:
              'save-through must never persist a value the sheet itself '
              'refuses to save — the previous valid link is kept instead',
        );
        expect(
          _route(container).name,
          'Has A Bad Link',
          reason:
              'the name is a DIFFERENT field and was typed validly: refusing '
              'it because of the URL is exactly the silent data loss this '
              'sheet exists to avoid (see S4b)',
        );
        expect(before.name, isNot('Has A Bad Link'));

        // Fix the URL: it lands too, without a Save tap.
        await tester.enterText(
          find.byKey(const Key('topo-meta-beta-url')),
          'https://example.com/beta',
        );
        await tester.pump(_pastDebounce);

        expect(_route(container).betaVideoUrl, 'https://example.com/beta');
        expect(_route(container).name, 'Has A Bad Link');
      },
    );

    testWidgets(
      'S4b: typing a name while the beta URL is invalid and then DISMISSING '
      'the sheet keeps the name — the dismissal flush used to refuse the same '
      'write and throw it away silently',
      (tester) async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final routeId = _seedRoute(container);

        await tester.pumpWidget(
          _buildModalHost(container: container, routeId: routeId),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('host-open-meta-sheet')));
        await tester.pumpAndSettle();

        await tester.ensureVisible(find.byKey(const Key('topo-meta-beta-url')));
        await tester.enterText(
          find.byKey(const Key('topo-meta-beta-url')),
          'htp://x',
        );
        await tester.enterText(
          find.byKey(const Key('topo-meta-name')),
          'Must Survive A Bad URL',
        );
        // Dismiss inside the debounce window, so this goes through the pop
        // flush — the path that used to silently drop everything.
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('topo-meta-pop-guard')), findsNothing);
        expect(
          _route(container).name,
          'Must Survive A Bad URL',
          reason:
              'the name was valid and typed — an unrelated invalid field must '
              'not silently discard it on the way out',
        );
        expect(
          _route(container).betaVideoUrl,
          isNull,
          reason:
              'and the invalid URL itself must still never be persisted (the '
              'route had no link to fall back to, so it stays without one)',
        );
      },
    );

    testWidgets(
      'S5: Cancel still discards — save-through writes are reverted to the '
      'route as the sheet found it',
      (tester) async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final routeId = _seedRoute(container);
        // Give the route real pre-existing metadata, so "revert" has
        // something to restore rather than just clearing to null.
        container
            .read(drawControllerProvider(_testWallId).notifier)
            .setRouteMetadata(
              routeId,
              name: 'Original',
              gradeSystem: GradeSystem.french,
              gradeRaw: '6a',
              style: 'sport',
              description: 'original notes',
              styleTags: const ['crimpy'],
              stars: 1,
            );
        await tester.pump();
        final before = _route(container);

        await tester.pumpWidget(
          _buildSheet(
            container: container,
            routeId: routeId,
            initial: before,
          ),
        );
        await tester.pump();

        await tester.enterText(
          find.byKey(const Key('topo-meta-name')),
          'Should Not Survive Cancel',
        );
        await tester.pump(_pastDebounce);
        // Save-through has written by now — that is what makes the revert
        // load-bearing rather than academic.
        expect(_route(container).name, 'Should Not Survive Cancel');

        await tester.ensureVisible(find.byKey(const Key('topo-meta-cancel')));
        await tester.tap(find.byKey(const Key('topo-meta-cancel')));
        await tester.pump();

        final after = _route(container);
        expect(after.name, 'Original');
        expect(after.gradeRaw, '6a');
        expect(after.gradeSystem, GradeSystem.french);
        expect(after.style, 'sport');
        expect(after.description, 'original notes');
        expect(after.styleTags, ['crimpy']);
        expect(after.stars, 1);
        expect(
          after.gradeSortKey,
          before.gradeSortKey,
          reason: 'the revert must restore the derived sort key too',
        );
      },
    );

    testWidgets(
      'S6: the original point of save-through, end to end — a draft written '
      'without Save is still ON THE FORM when the sheet is reopened, so the '
      'climber picks up where they left off',
      (tester) async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final routeId = _seedRoute(container);

        await tester.pumpWidget(
          _buildReopeningModalHost(container: container, routeId: routeId),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('host-open-meta-sheet')));
        await tester.pumpAndSettle();

        await tester.enterText(
          find.byKey(const Key('topo-meta-name')),
          'Work In Progress',
        );
        await tester.ensureVisible(find.byKey(const Key('topo-meta-stars-3')));
        await tester.tap(find.byKey(const Key('topo-meta-stars-3')));
        await tester.pump(_pastDebounce);

        // Dismiss WITHOUT Save — the accidental-dismissal case.
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('topo-meta-pop-guard')), findsNothing);

        // Reopen.
        await tester.tap(find.byKey(const Key('host-open-meta-sheet')));
        await tester.pumpAndSettle();

        expect(
          find.widgetWithText(TextField, 'Work In Progress'),
          findsOneWidget,
          reason:
              'the reopened sheet must be pre-filled from the draft — a blank '
              'field here means the dismissal ate the work, which is the whole '
              'bug save-through was built to fix',
        );
        expect(
          _route(container).stars,
          3,
          reason: 'the discrete control\'s draft survived too',
        );
      },
    );
  });
}
