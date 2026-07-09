import 'package:climbtopo/core/db/app_database.dart';
import 'package:climbtopo/core/db/database_provider.dart';
import 'package:climbtopo/features/ar/application/ar_channel.dart';
import 'package:climbtopo/features/ar/application/ar_controller.dart';
import 'package:climbtopo/features/ar/application/manual_align_controller.dart';
import 'package:climbtopo/features/ar/domain/homography.dart';
import 'package:climbtopo/features/ar/presentation/ar_overlay_painter.dart';
import 'package:climbtopo/features/ar/presentation/ar_screen.dart';
import 'package:climbtopo/features/library/application/library_providers.dart';
import 'package:climbtopo/features/topo/data/route_repository.dart';
import 'package:climbtopo/features/topo/domain/topo_route.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Covers the v2-ar-viewer AR screen contract:
///  - A1: on a non-iOS platform (the host `flutter test` always runs on —
///    `Platform.isIOS` reflects the ACTUAL test host, never the widget
///    under test, so this is inherent, not simulated), `ArScreen` renders
///    the unsupported placeholder, never a `UiKitView`, and never crashes —
///    even when the wall genuinely has a photo + routes persisted.
///  - A2/A3: [ArAlignmentStage] — the platform-agnostic widget `ArScreen`'s
///    iOS branch wraps around a real `UiKitView` — is pumped DIRECTLY here
///    with a plain placeholder `Widget` standing in for the camera surface
///    (see `ArScreen`'s class doc for why this is the documented seam:
///    `ArAlignmentStage` itself has no platform checks, so any harness can
///    exercise its overlay/toggle/gesture logic without ever touching
///    `UiKitView`). This drives the REAL `ArOverlayPainter` /
///    `ArController` / `ManualAlignController` wiring.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ArController.setMode fires a real (fire-and-forget) MethodChannel call
  // on 'climbtopo/ar' — mocked here (mirroring
  // test/features/ar/application/ar_controller_test.dart) so the
  // ArAlignmentStage group's mode-toggle interactions never hit an
  // unhandled MissingPluginException from the unregistered real channel.
  const arMethodChannel = MethodChannel('climbtopo/ar');
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(arMethodChannel, (call) async => null);
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(arMethodChannel, null);
  });

  group('ArScreen', () {
    testWidgets(
      'A1: with a photo + route persisted for the wall, the screen still '
      'renders the iOS-only placeholder (no UiKitView, no crash) on this '
      'non-iOS test host',
      (tester) async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWithValue(db),
            nowMsProvider.overrideWithValue(() => 1000),
          ],
        );
        addTearDown(container.dispose);

        final crud = container.read(libraryCrudRepositoryProvider);
        final area = await crud.createArea('Area');
        final sector = await crud.createSector(area.id, 'Sector');
        final wall = await crud.createWall(sector.id, 'Wall');
        final photoId = await crud.attachPhotoToWall(
          wall.id,
          '/tmp/wall-photo.jpg',
          1000,
          2000,
        );
        final routeRepo = RouteRepository(db, nowMs: () => 1000);
        await routeRepo.upsertRoute(
          wall.id,
          photoId,
          const TopoRoute(
            id: 1,
            number: 1,
            points: [Offset(0.1, 0.1), Offset(0.2, 0.2)],
          ),
        );

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(home: ArScreen(wallId: wall.id)),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('ar-unsupported-placeholder')),
          findsOneWidget,
        );
        expect(find.byType(UiKitView), findsNothing);
        expect(find.text('AR live view is iOS-only'), findsOneWidget);
      },
    );

    testWidgets(
      'Fix 1: entering AR for a different wall resets arControllerProvider '
      'back to ArMode.auto and manualAlignProvider back to identity, even '
      'though both are app-lifetime singletons never scoped to a wall',
      (tester) async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWithValue(db),
            nowMsProvider.overrideWithValue(() => 1000),
          ],
        );
        addTearDown(container.dispose);

        final crud = container.read(libraryCrudRepositoryProvider);
        final area = await crud.createArea('Area');
        final sector = await crud.createSector(area.id, 'Sector');
        final wallA = await crud.createWall(sector.id, 'Wall A');
        final wallB = await crud.createWall(sector.id, 'Wall B');

        // Enter AR for wall A. Neither wall has a photo/route persisted —
        // the reset must fire regardless, since it happens before the
        // photo-and-visible-route session-start gate is even checked.
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(home: ArScreen(wallId: wallA.id)),
          ),
        );
        await tester.pumpAndSettle();

        // Simulate the user switching to Manual and hand-adjusting the
        // overlay, as if this were a real wall-A AR session.
        container.read(arControllerProvider.notifier).setMode(ArMode.manual);
        container.read(manualAlignProvider.notifier).pan(const Offset(9, 9));
        expect(container.read(arControllerProvider).mode, ArMode.manual);
        expect(
          container.read(manualAlignProvider),
          isNot(Homography.identity()),
        );

        // "Back out": unmount wall A's ArScreen entirely — mirroring what a
        // real Navigator.pop does (destroys the whole route's widget
        // subtree) — before mounting wall B's. Skipping this step and
        // pumping wall B's ArScreen directly in wall A's place would NOT
        // reproduce a real "different wall" AR entry: with no Key, an
        // unchanged widget type at the same tree slot makes Flutter reuse
        // the EXISTING State (only `didUpdateWidget` fires, never
        // `initState`), so `_load`/`_resetArViewState` would never re-run —
        // unlike real navigation, where `context.push` always mounts a
        // brand-new widget subtree (and thus a brand-new `_ArScreenState`)
        // for the new route.
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();

        // Enter AR for a DIFFERENT wall: a genuinely fresh ArScreen widget
        // (a new wallId means a new route/widget in the real app), but the
        // SAME app-lifetime arControllerProvider/manualAlignProvider.
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(home: ArScreen(wallId: wallB.id)),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          container.read(arControllerProvider).mode,
          ArMode.auto,
          reason: "wall B's AR entry must not inherit wall A's Manual mode",
        );
        expect(
          container.read(manualAlignProvider),
          Homography.identity(),
          reason:
              "wall B's AR entry must not inherit wall A's leftover "
              'hand-adjusted homography',
        );
      },
    );

    testWidgets(
      'A1b: with no photo/routes at all, the screen still renders the '
      'iOS-only placeholder (platform gate wins regardless of data) — no '
      'crash',
      (tester) async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWithValue(db),
            nowMsProvider.overrideWithValue(() => 1000),
          ],
        );
        addTearDown(container.dispose);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(home: ArScreen(wallId: 'no-such-wall')),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('ar-unsupported-placeholder')),
          findsOneWidget,
        );
        expect(find.byType(UiKitView), findsNothing);
      },
    );
  });

  group('ArAlignmentStage (platform-agnostic overlay/toggle/gesture core)', () {
    const refSize = Size(1000, 2000);
    const route = TopoRoute(
      id: 1,
      number: 1,
      points: [Offset(0.1, 0.1), Offset(0.2, 0.2)],
    );

    Widget buildStage(ProviderContainer container) {
      return UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: ArAlignmentStage(
              // Stand-in for the native camera surface — ArAlignmentStage
              // never inspects this widget, so a plain Container exercises
              // exactly the same overlay/toggle/gesture code path a real
              // UiKitView would sit underneath on-device.
              cameraView: Container(key: const Key('fake-camera-view')),
              routes: [route],
              refSize: refSize,
            ),
          ),
        ),
      );
    }

    ArOverlayPainter currentPainter(WidgetTester tester) {
      final customPaint = tester.widget<CustomPaint>(
        find.byWidgetPredicate(
          (w) => w is CustomPaint && w.painter is ArOverlayPainter,
        ),
      );
      return customPaint.painter as ArOverlayPainter;
    }

    testWidgets(
      'A2: AUTO mode feeds the overlay ArController.latest\'s homography; '
      'toggling to MANUAL switches the overlay to manualAlignProvider\'s '
      'homography',
      (tester) async {
        final container = ProviderContainer();
        addTearDown(container.dispose);

        await tester.pumpWidget(buildStage(container));
        await tester.pump();

        expect(find.byKey(const Key('fake-camera-view')), findsOneWidget);
        expect(
          container.read(arControllerProvider).mode,
          ArMode.auto,
          reason: 'ArController starts in auto mode',
        );
        expect(
          currentPainter(tester).homography,
          Homography.identity(),
          reason: 'no alignment pushed yet — falls back to identity',
        );

        final pushedHomography = Homography.translation(5, 7);
        container.read(arControllerProvider.notifier).onAlignment(
          ArAlignment(
            homography: pushedHomography,
            confidence: 0.9,
            tracking: true,
          ),
        );
        await tester.pump();

        expect(
          currentPainter(tester).homography,
          pushedHomography,
          reason:
              'AUTO mode must feed the overlay from ArController.latest',
        );

        // Toggle to manual via the actual button (not the provider directly)
        // — this is the real user-facing control.
        await tester.tap(find.byKey(const Key('ar-mode-toggle')));
        await tester.pump();

        expect(container.read(arControllerProvider).mode, ArMode.manual);
        expect(
          currentPainter(tester).homography,
          Homography.identity(),
          reason:
              'MANUAL mode must feed the overlay from manualAlignProvider, '
              'not the stale auto alignment — starts at identity',
        );

        container.read(manualAlignProvider.notifier).pan(const Offset(3, 4));
        await tester.pump();

        expect(
          currentPainter(tester).homography,
          container.read(manualAlignProvider),
          reason:
              'MANUAL mode overlay must track manualAlignProvider live, '
              'and must NOT have reverted to the earlier auto alignment',
        );
        expect(
          currentPainter(tester).homography,
          isNot(pushedHomography),
        );
      },
    );

    testWidgets(
      'A3: in manual mode, a pan gesture over the overlay updates '
      "manualAlignProvider's homography away from identity",
      (tester) async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        // Start directly in manual mode so the gesture layer is present
        // from the very first frame.
        container.read(arControllerProvider.notifier).setMode(ArMode.manual);

        await tester.pumpWidget(buildStage(container));
        await tester.pump();

        expect(
          find.byKey(const Key('ar-manual-gesture-layer')),
          findsOneWidget,
        );
        expect(container.read(manualAlignProvider), Homography.identity());

        await tester.drag(
          find.byKey(const Key('ar-manual-gesture-layer')),
          const Offset(30, 20),
        );
        await tester.pump();

        expect(
          container.read(manualAlignProvider),
          isNot(Homography.identity()),
          reason: 'a pan gesture must nudge manualAlignProvider off identity',
        );

        final warped = container
            .read(manualAlignProvider)
            .warp(const Offset(0, 0));
        expect(
          warped,
          isNot(const Offset(0, 0)),
          reason: 'the origin should have visibly translated after the pan',
        );
      },
    );

    testWidgets(
      "the reset button (manual mode only) restores manualAlignProvider "
      'to identity',
      (tester) async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        container.read(arControllerProvider.notifier).setMode(ArMode.manual);
        container.read(manualAlignProvider.notifier).pan(const Offset(9, 9));

        await tester.pumpWidget(buildStage(container));
        await tester.pump();

        expect(container.read(manualAlignProvider), isNot(Homography.identity()));
        expect(find.byKey(const Key('ar-reset')), findsOneWidget);

        await tester.tap(find.byKey(const Key('ar-reset')));
        await tester.pump();

        expect(container.read(manualAlignProvider), Homography.identity());
      },
    );
  });
}
