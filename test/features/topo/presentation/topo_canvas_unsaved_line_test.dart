// Tests for the canvas' unsaved-line back guard (`topo-canvas-draft-guard`
// in `TopoCanvasScreen` + `_handleBackIntent`).
//
// The bug this closes has two halves, and the owner chose to fix both:
//   1. Going back with a line still in progress discarded it SILENTLY — no
//      confirm, no undo, the points simply gone.
//   2. On iPhone the back gesture IS the draw gesture: an edge swipe while
//      drawing near the left edge popped the screen (and so threw the line
//      away) instead of adding a point.
//
// So `canPop` is `false` — which disables the iOS edge swipe outright — but
// ONLY while a draft line exists. That gate is the load-bearing part: an
// always-armed guard would kill swipe-back on the whole canvas, which is the
// exact shape of a regression this project has already shipped and fixed once
// (`is_safari.dart` / bug #76). Hence D3 below, which pins `canPop == true`
// in view mode.
//
// KNOWN LIMIT, asserted nowhere because it cannot be: on the web this cannot
// guard the BROWSER's own Back button — that unwinds history before Flutter
// is consulted at all. See `_handleBackIntent`'s doc.

import 'package:masi/app/theme.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/features/library/application/library_providers.dart';
import 'package:masi/features/topo/application/draw_controller.dart';
import 'package:masi/features/topo/presentation/topo_canvas_screen.dart';
import 'package:masi/shared/presentation/masi_dialogs.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// Creates a real in-memory DB + [ProviderContainer] + a persisted
/// Area/Sector/Wall, mirroring the harness pattern used throughout this
/// directory (e.g. `topo_open_community_button_test.dart`'s `_seedWall`).
/// No photo is attached: this file never needs the canvas to paint an image,
/// so it never goes near a real codec decode (see CLAUDE.md).
Future<({AppDatabase db, ProviderContainer container, String wallId})>
_seedWall() async {
  final db = AppDatabase(NativeDatabase.memory());
  final container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(db),
      nowMsProvider.overrideWithValue(() => 1000),
    ],
  );
  final crud = container.read(libraryCrudRepositoryProvider);
  final area = await crud.createArea('Area');
  final sector = await crud.createSector(area.id, 'Sector');
  final wall = await crud.createWall(sector.id, 'Wall');
  // autoDispose pending-timer gotcha (see `route_legend_gap_test.dart`'s
  // `_seedRoutes` for the full explanation): unlike every other canvas test
  // in this directory, these tests deliberately NAVIGATE AWAY from the canvas
  // mid-test, which unmounts it and disposes the providers it was watching
  // right there inside the fake-async zone. Each drift-backed provider
  // schedules a zero-duration teardown `Timer` on dispose, and with no
  // further duration-based pump to flush it flutter_test's `!timersPending`
  // invariant trips at the end of the test. Permanent listeners keep these
  // family members alive for the whole test, so the disposal happens at
  // `container.dispose()` in teardown — outside the fake clock — instead.
  container.listen(toposProvider, (_, _) {});
  container.listen(wallNameProvider(wall.id), (_, _) {});
  container.listen(wallVisibilityProvider(wall.id), (_, _) {});
  container.listen(wallOriginalsProvider(wall.id), (_, _) {});
  container.listen(drawControllerProvider(wall.id), (_, _) {});
  return (db: db, container: container, wallId: wall.id);
}

/// Flushes any zero-duration provider-teardown timers left by unmounting the
/// canvas — see [_seedWall]'s note. Called at the end of every test that
/// leaves the canvas.
Future<void> _flushTeardownTimers(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 10));
}

/// A real (minimal) [GoRouter] with a home route that PUSHES the canvas, so
/// the canvas sits on a genuine navigation stack — `context.canPop()` is
/// true, a `Navigator.maybePop` has something to pop, and "did we leave?" is
/// answerable by looking for the home button again.
///
/// [confirmDiscardLine] lets a test substitute a fake for
/// [TopoCanvasScreen.confirmDiscardLine] (default: the real
/// [showMasiConfirm]) — the seam D5 below uses to force the discard-confirm
/// call to throw and prove `_handleBackIntent`'s guard recovers rather than
/// latching.
Widget _wrap(
  ProviderContainer container,
  String wallId, {
  Future<bool> Function(
    BuildContext, {
    required String title,
    required String confirmLabel,
    String? message,
    Key? confirmKey,
    Key? cancelKey,
    Key? sheetKey,
    bool isDestructive,
  })?
  confirmDiscardLine,
}) {
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => Scaffold(
          body: Center(
            child: TextButton(
              key: const Key('home-open-canvas'),
              onPressed: () => context.push('/walls/$wallId'),
              child: const Text('open canvas'),
            ),
          ),
        ),
      ),
      GoRoute(
        path: '/walls/:wallId',
        builder: (context, state) => TopoCanvasScreen(
          wallId: state.pathParameters['wallId']!,
          confirmDiscardLine: confirmDiscardLine ?? showMasiConfirm,
        ),
      ),
    ],
  );
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp.router(theme: MasiTheme.light, routerConfig: router),
  );
}

/// A fake [TopoCanvasScreen.confirmDiscardLine] that throws on its first
/// call and resolves `true` (confirm) on every call after — D5's seam for
/// proving `_handleBackIntent`'s `_discardPromptOpen` guard is reset in a
/// `finally` rather than latched `true` forever by an exception.
class _ThrowOnceThenConfirm {
  int calls = 0;

  Future<bool> call(
    BuildContext context, {
    required String title,
    required String confirmLabel,
    String? message,
    Key? confirmKey,
    Key? cancelKey,
    Key? sheetKey,
    bool isDestructive = true,
  }) async {
    calls++;
    if (calls == 1) {
      throw StateError('injected discard-confirm failure');
    }
    return true;
  }
}

/// Pumps [_wrap] and pushes the canvas onto the stack.
Future<void> _openCanvas(
  WidgetTester tester,
  ({AppDatabase db, ProviderContainer container, String wallId}) seeded, {
  Future<bool> Function(
    BuildContext, {
    required String title,
    required String confirmLabel,
    String? message,
    Key? confirmKey,
    Key? cancelKey,
    Key? sheetKey,
    bool isDestructive,
  })?
  confirmDiscardLine,
}) async {
  await tester.pumpWidget(
    _wrap(
      seeded.container,
      seeded.wallId,
      confirmDiscardLine: confirmDiscardLine,
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('home-open-canvas')));
  await tester.pumpAndSettle();
  expect(find.byKey(const Key('topo-back-button')), findsOneWidget);
}

/// Starts an uncommitted 2-point line on [wallId] — the same
/// `addPoint`-driven draft a draw gesture produces (this directory's standard
/// way of seeding one; see `topo_overflow_test.dart`).
void _startLine(ProviderContainer container, String wallId) {
  final notifier = container.read(drawControllerProvider(wallId).notifier);
  notifier.addPoint(const Offset(0.1, 0.1));
  notifier.addPoint(const Offset(0.2, 0.2));
}

bool _canPop(WidgetTester tester) {
  final guard =
      tester.widget(find.byKey(const Key('topo-canvas-draft-guard')))
          as PopScope;
  return guard.canPop;
}

void main() {
  group('canvas back guard with a line in progress', () {
    testWidgets(
      'D1: tapping back with a line in progress does NOT leave the canvas — '
      'it asks first, and `canPop` is false so the iOS edge swipe cannot '
      'discard the line either',
      (tester) async {
        final seeded = await _seedWall();
        addTearDown(seeded.db.close);
        addTearDown(seeded.container.dispose);
        await _openCanvas(tester, seeded);

        _startLine(seeded.container, seeded.wallId);
        await tester.pump();

        expect(
          _canPop(tester),
          isFalse,
          reason:
              'with a draft line on the canvas the edge swipe must be '
              'disabled — that gesture IS the draw gesture near the left edge',
        );

        await tester.tap(find.byKey(const Key('topo-back-button')));
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('topo-discard-line-sheet')),
          findsOneWidget,
          reason: 'the line must not be discarded without being asked',
        );
        expect(
          find.byKey(const Key('topo-back-button')),
          findsOneWidget,
          reason: 'the canvas must still be on screen while the sheet is up',
        );
        expect(
          find.byKey(const Key('home-open-canvas')),
          findsNothing,
          reason: 'a back attempt with a draft must not leave the canvas',
        );
        expect(
          seeded.container
              .read(drawControllerProvider(seeded.wallId))
              .currentPoints
              .length,
          2,
          reason: 'the line is still in progress until the user answers',
        );

        // Answer, so the test does not end with a modal route still open.
        await tester.tap(find.byKey(const Key('topo-discard-line-cancel')));
        await tester.pumpAndSettle();
        await _flushTeardownTimers(tester);
      },
    );

    testWidgets(
      'D2a: confirming discards the line and leaves the canvas',
      (tester) async {
        final seeded = await _seedWall();
        addTearDown(seeded.db.close);
        addTearDown(seeded.container.dispose);
        await _openCanvas(tester, seeded);

        _startLine(seeded.container, seeded.wallId);
        await tester.pump();

        await tester.tap(find.byKey(const Key('topo-back-button')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('topo-discard-line-confirm')));
        await tester.pumpAndSettle();

        expect(
          seeded.container
              .read(drawControllerProvider(seeded.wallId))
              .currentPoints,
          isEmpty,
          reason: 'confirming means discard — the draft must be cleared',
        );
        expect(
          find.byKey(const Key('home-open-canvas')),
          findsOneWidget,
          reason: 'confirming must also leave the canvas',
        );
        expect(find.byKey(const Key('topo-back-button')), findsNothing);
        await _flushTeardownTimers(tester);
      },
    );

    testWidgets(
      'D2b: dismissing the confirm stays on the canvas with the line intact',
      (tester) async {
        final seeded = await _seedWall();
        addTearDown(seeded.db.close);
        addTearDown(seeded.container.dispose);
        await _openCanvas(tester, seeded);

        _startLine(seeded.container, seeded.wallId);
        await tester.pump();

        await tester.tap(find.byKey(const Key('topo-back-button')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('topo-discard-line-cancel')));
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('topo-discard-line-sheet')),
          findsNothing,
          reason: 'the sheet closes on "Cancel"',
        );
        expect(
          find.byKey(const Key('topo-back-button')),
          findsOneWidget,
          reason: '"Cancel" means keep drawing — do not leave',
        );
        expect(find.byKey(const Key('home-open-canvas')), findsNothing);
        expect(
          seeded.container
              .read(drawControllerProvider(seeded.wallId))
              .currentPoints
              .length,
          2,
          reason: 'the in-progress line must survive a dismissed confirm',
        );
        await _flushTeardownTimers(tester);
      },
    );

    testWidgets(
      'D3: with NO line in progress, back leaves immediately with no confirm '
      '— and `canPop` stays true, so view mode keeps its edge swipe',
      (tester) async {
        final seeded = await _seedWall();
        addTearDown(seeded.db.close);
        addTearDown(seeded.container.dispose);
        await _openCanvas(tester, seeded);

        expect(
          seeded.container
              .read(drawControllerProvider(seeded.wallId))
              .currentPoints,
          isEmpty,
        );
        expect(
          _canPop(tester),
          isTrue,
          reason:
              'the guard must not leak into view mode — an always-false '
              'canPop kills swipe-back on the whole canvas (cf. bug #76)',
        );

        await tester.tap(find.byKey(const Key('topo-back-button')));
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('topo-discard-line-sheet')),
          findsNothing,
          reason: 'nothing is at risk, so nothing may be asked',
        );
        expect(find.byKey(const Key('home-open-canvas')), findsOneWidget);
        await _flushTeardownTimers(tester);
      },
    );

    testWidgets(
      'D4: a system/gesture pop (not the in-app chevron) is guarded the same '
      'way — refused with a confirm while drawing, honoured when not',
      (tester) async {
        final seeded = await _seedWall();
        addTearDown(seeded.db.close);
        addTearDown(seeded.container.dispose);
        await _openCanvas(tester, seeded);

        _startLine(seeded.container, seeded.wallId);
        await tester.pump();

        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('topo-discard-line-sheet')),
          findsOneWidget,
          reason:
              'the PopScope must turn a refused system pop into the same '
              'confirm the chevron shows',
        );
        expect(find.byKey(const Key('home-open-canvas')), findsNothing);

        await tester.tap(find.byKey(const Key('topo-discard-line-confirm')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('home-open-canvas')), findsOneWidget);
        await _flushTeardownTimers(tester);
      },
    );

    testWidgets(
      'D5: a discard-confirm that throws recovers on the NEXT back attempt '
      'instead of latching the guard forever — regression test for the '
      'unguarded _discardPromptOpen reset',
      (tester) async {
        final seeded = await _seedWall();
        addTearDown(seeded.db.close);
        addTearDown(seeded.container.dispose);
        final fake = _ThrowOnceThenConfirm();
        await _openCanvas(tester, seeded, confirmDiscardLine: fake.call);

        _startLine(seeded.container, seeded.wallId);
        await tester.pump();

        // First attempt: the injected confirm throws.
        await tester.tap(find.byKey(const Key('topo-back-button')));
        await tester.pumpAndSettle();

        expect(fake.calls, 1);
        expect(
          find.byKey(const Key('topo-discard-line-sheet')),
          findsNothing,
          reason: 'the fake throws before any sheet is built',
        );
        expect(
          find.byKey(const Key('topo-back-button')),
          findsOneWidget,
          reason:
              'a thrown confirm must not silently leave the canvas — the '
              'user is still exactly where they were',
        );
        expect(
          find.byKey(const Key('home-open-canvas')),
          findsNothing,
          reason: 'a throw must not be treated as a confirmed discard',
        );
        expect(
          seeded.container
              .read(drawControllerProvider(seeded.wallId))
              .currentPoints
              .length,
          2,
          reason: 'the line must survive an errored confirm attempt',
        );
        expect(
          find.textContaining("Couldn't confirm"),
          findsOneWidget,
          reason:
              'a throw must surface to the user, not vanish into the '
              '`unawaited` zone silently',
        );

        // THE regression this guards: if `_discardPromptOpen` were reset
        // anywhere other than a `finally`, it would still read `true` here,
        // and `_handleBackIntent` would return at its top-of-method guard
        // with no confirm shown at all — the chevron would already be a dead
        // button on this very next tap.
        await tester.tap(find.byKey(const Key('topo-back-button')));
        await tester.pumpAndSettle();

        expect(
          fake.calls,
          2,
          reason:
              'the guard must have reset so a second back attempt calls the '
              'confirm again rather than short-circuiting silently',
        );
        expect(
          find.byKey(const Key('home-open-canvas')),
          findsOneWidget,
          reason:
              'the second attempt succeeds (fake resolves true) and the '
              'canvas is left normally, proving the guard recovered rather '
              'than being permanently wedged',
        );
        expect(
          seeded.container
              .read(drawControllerProvider(seeded.wallId))
              .currentPoints,
          isEmpty,
          reason: 'the confirmed discard on the second attempt clears it',
        );
        await _flushTeardownTimers(tester);
      },
    );
  });
}
