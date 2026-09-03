// The minimal draw-mode tutorial (user request, 2026-08-15: "a very minimal
// tutorial for the route drawing, important is to hint the user to touch when
// trying to draw a route").
//
// The failure it exists to catch is specific and silent. In draw mode
// `panEnabled` is false, and `_updateInteraction` cancels a pending tap once
// the finger passes the 8px slop — so dragging across the photo, which is the
// instinctive way to draw a line, does NOTHING: no point, no pan, no feedback
// of any kind. Someone whose reflex is to stroke the line gets silence and
// concludes the app is broken.
//
// So the assertions below care most about two things:
//   * a fruitless DRAG produces the hint, and
//   * a pinch does NOT — a second finger also cancels the pending tap, and
//     answering a zoom gesture with drawing advice would be worse than saying
//     nothing.

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:masi/app/theme.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/features/topo/application/draw_controller.dart';
import 'package:masi/features/topo/application/draw_hint_providers.dart';
import 'package:masi/features/topo/presentation/symbol_palette_bar.dart';
import 'package:masi/features/topo/presentation/topo_canvas.dart';

const _testWallId = 'test-wall';
const _imageSize = Size(400, 300);

Future<ProviderContainer> _pumpCanvas(WidgetTester tester) async {
  tester.view.physicalSize = Size(
    _imageSize.width,
    _imageSize.height + kSymbolPaletteBarHeight,
  );
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  // An in-memory database, not the default. `TopoCanvas` now watches
  // `canEditWallRoutesProvider` and `DrawHint` reads `SettingsStore`, so a bare
  // container opens a REAL on-disk database per test — which is slow enough on
  // Windows to look like a hang, and leaves files behind.
  final db = AppDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  final container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(db),
      nowMsProvider.overrideWithValue(() => 1000),
    ],
  );
  addTearDown(container.dispose);
  final transformation = TransformationController();
  addTearDown(transformation.dispose);

  // FIX #6 (autoDispose pending-timer gotcha) — see route_legend_row_menu_test
  // .dart. `drawControllerProvider` is autoDispose.family, and when its last
  // subscriber goes Riverpod schedules disposal on a zero-duration timer that
  // is still pending at teardown, failing the test with "a Timer is still
  // pending" — for tests that end on a provider call rather than on a widget
  // interaction that would have flushed it.
  container.listen(drawControllerProvider(_testWallId), (_, _) {});
  container.read(drawControllerProvider(_testWallId).notifier)
      .setMode(DrawMode.draw);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: MasiTheme.light,
        home: Scaffold(
          body: Column(
            children: [
              const SymbolPaletteBar(wallId: _testWallId),
              Expanded(
                child: TopoCanvas(
                  wallId: _testWallId,
                  imagePath: '/nonexistent/hint-test.jpg',
                  imageSize: _imageSize,
                  transformationController: transformation,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return container;
}

Offset _at(double x, double y) =>
    Offset(_imageSize.width * x, _imageSize.height * y + kSymbolPaletteBarHeight);

DrawHintReason _hint(ProviderContainer c) => c.read(drawHintProvider);

void main() {
  group('the message says the right thing', () {
    test('nothing to show resolves to no message at all', () {
      expect(drawHintMessage(DrawHintReason.none), isNull);
    });

    test(
      'the drag hint names the gesture that just failed; the first-time one '
      'does not, because nothing has failed yet',
      () {
        expect(
          drawHintMessage(DrawHintReason.triedToDrag),
          contains('dragging does nothing'),
        );
        expect(
          drawHintMessage(DrawHintReason.firstTime),
          isNot(contains('dragging')),
        );
        // Both have to tell you the thing to actually DO.
        expect(drawHintMessage(DrawHintReason.firstTime), contains('Tap'));
        expect(drawHintMessage(DrawHintReason.triedToDrag), contains('Tap'));
      },
    );
  });

  testWidgets(
    'dragging across empty canvas — which draws nothing — produces the hint',
    (tester) async {
      final container = await _pumpCanvas(tester);
      expect(_hint(container), DrawHintReason.none);

      final gesture = await tester.startGesture(_at(0.2, 0.3));
      await tester.pump();
      await gesture.moveTo(_at(0.5, 0.5));
      await tester.pump();
      await gesture.moveTo(_at(0.8, 0.7));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(_hint(container), DrawHintReason.triedToDrag);
      expect(
        container.read(drawControllerProvider(_testWallId)).currentPoints,
        isEmpty,
        reason: 'the premise: the drag really did add nothing',
      );
      expect(find.byKey(const Key('topo-draw-hint')), findsNothing,
          reason: 'the pill lives on TopoCanvasScreen, not the bare canvas');
    },
  );

  testWidgets('a plain tap draws a point and produces NO hint', (tester) async {
    final container = await _pumpCanvas(tester);

    await tester.tapAt(_at(0.5, 0.5));
    await tester.pumpAndSettle();

    expect(
      container.read(drawControllerProvider(_testWallId)).currentPoints,
      hasLength(1),
    );
    expect(_hint(container), DrawHintReason.none);
  });

  testWidgets(
    'a SECOND FINGER does not trigger it — a pinch cancels the pending tap '
    'too, and answering a zoom with drawing advice is worse than silence',
    (tester) async {
      final container = await _pumpCanvas(tester);

      final first = await tester.startGesture(_at(0.3, 0.3));
      await tester.pump();
      final second = await tester.startGesture(_at(0.7, 0.7));
      await tester.pump();
      await first.moveTo(_at(0.2, 0.2));
      await tester.pump();
      await first.up();
      await second.up();
      await tester.pumpAndSettle();

      expect(_hint(container), DrawHintReason.none);
    },
  );

  testWidgets('placing a point takes the hint back down', (tester) async {
    final container = await _pumpCanvas(tester);

    final gesture = await tester.startGesture(_at(0.2, 0.3));
    await tester.pump();
    await gesture.moveTo(_at(0.8, 0.7));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(_hint(container), DrawHintReason.triedToDrag);

    await tester.tapAt(_at(0.5, 0.5));
    await tester.pumpAndSettle();

    expect(
      _hint(container),
      DrawHintReason.none,
      reason: 'the advice was taken, so it stops being shown',
    );
  });

  testWidgets(
    'a second fruitless drag straight afterwards does not re-flash the hint — '
    'a fidgety finger must not be nagged',
    (tester) async {
      final container = await _pumpCanvas(tester);
      final notifier = container.read(drawHintProvider.notifier);

      expect(notifier.reportFruitlessDrag(1000), isTrue);
      notifier.dismiss();
      expect(
        notifier.reportFruitlessDrag(1500),
        isFalse,
        reason: 'inside the cooldown',
      );
      expect(_hint(container), DrawHintReason.none);

      expect(
        notifier.reportFruitlessDrag(
          1000 + DrawHint.repeatCooldown.inMilliseconds + 1,
        ),
        isTrue,
        reason: 'past the cooldown it is allowed to help again',
      );
    },
  );

  testWidgets(
    'the unprompted first-time nudge never replaces a hint answering '
    'something the climber just did',
    (tester) async {
      final container = await _pumpCanvas(tester);
      final notifier = container.read(drawHintProvider.notifier);

      notifier.reportFruitlessDrag(1000);
      expect(_hint(container), DrawHintReason.triedToDrag);
      notifier.offerFirstTime();

      expect(
        _hint(container),
        DrawHintReason.triedToDrag,
        reason: 'the specific answer outranks the generic offer',
      );
    },
  );

  testWidgets('once a route has been drawn the nudge is retired', (
    tester,
  ) async {
    final container = await _pumpCanvas(tester);
    final notifier = container.read(drawHintProvider.notifier);

    notifier.offerFirstTime();
    expect(_hint(container), DrawHintReason.firstTime);

    await notifier.markRouteDrawn();
    expect(_hint(container), DrawHintReason.none);
    expect(notifier.isFirstTimePending, isFalse);

    notifier.offerFirstTime();
    expect(
      _hint(container),
      DrawHintReason.none,
      reason: 'someone who has drawn a route does not need to be told how',
    );
  });
}
