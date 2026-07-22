import 'package:masi/app/theme.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/features/ar/application/ar_channel.dart';
import 'package:masi/features/ar/application/ar_controller.dart';
import 'package:masi/features/ar/application/manual_align_controller.dart';
import 'package:masi/features/ar/domain/homography.dart';
import 'package:masi/features/ar/presentation/ar_overlay_painter.dart';
import 'package:masi/features/ar/presentation/ar_screen.dart';
import 'package:masi/features/library/application/library_providers.dart';
import 'package:masi/features/topo/data/route_repository.dart';
import 'package:masi/features/topo/domain/topo_route.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// Stands in for the real `path_provider` platform channel plugin (no mock
/// registered in this suite's plain `flutter test` host) — needed only by
/// the web retry-remount group below, which mounts a real [ArScreen] with a
/// persisted photo. See `ar_screen_test.dart`'s identically-named fake for
/// the full rationale (an unmocked `getApplicationDocumentsPath()` call made
/// from inside `ArScreen._load`'s async lifecycle never settles under
/// `pumpAndSettle`, hanging the test on `_loading`'s spinner).
class _FakePathProviderPlatform extends PathProviderPlatform {
  @override
  Future<String?> getApplicationDocumentsPath() async =>
      '/tmp/ar_web_manual_test_docs';
}

/// Covers Subtask C of the web-AR MVP: [ArAlignmentStage.autoTracking],
/// which forces web (no continuous ARKit/ARCore-style tracking session —
/// see `ar_support.dart`'s `arSupportsAutoTracking`) into an
/// always-effectively-manual, hand-aligned experience: no mode-toggle/
/// re-scan FAB, and locking is a pure-Dart `arLockedProvider` flip rather
/// than a native `lockManual` platform-channel call.
///
/// Mirrors `ar_screen_test.dart`'s `ArAlignmentStage` group's pattern of
/// pumping [ArAlignmentStage] directly (with a harmless placeholder
/// `cameraView`) against a real [ProviderContainer] — the same documented
/// seam that group's own class doc explains — just with `autoTracking:
/// false` this time, and no mocked `masi/ar` `MethodChannel` at all:
/// the whole point of this flag is that web never touches that channel, so
/// if any of the paths under test somehow DID reach a real platform-channel
/// call, it would throw `MissingPluginException` (no mock registered here)
/// rather than silently succeed — a deliberate regression trip-wire.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Same refSize/viewSize pairing as ar_screen_test.dart's ArAlignmentStage
  // group: fitInto(1000x2000, 400x800) scales by exactly 0.4 on both axes
  // (no letterboxing), so the route-space center (0.5, 0.5) always lands
  // exactly on the view center (200, 400) — not load-bearing for any
  // assertion in this file, but keeps the fixture directly comparable.
  const refSize = Size(1000, 2000);
  const viewSize = Size(400, 800);
  const route = TopoRoute(
    id: 1,
    number: 1,
    points: [Offset(0.1, 0.1), Offset(0.2, 0.2)],
  );

  /// Pins the test surface's logical size to exactly `viewSize` — see
  /// ar_screen_test.dart's `pinViewSize` for why this matters (the default
  /// 800x600 test surface would otherwise clamp an 800-tall SizedBox).
  void pinViewSize(WidgetTester tester) {
    tester.view.physicalSize = viewSize;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  /// Builds [ArAlignmentStage] directly (never [ArScreen] — see this file's
  /// class doc) with a plain placeholder `cameraView`, standing in for
  /// web's real `getUserMedia` surface exactly as it stands in for a
  /// `UiKitView` in `ar_screen_test.dart`.
  ///
  /// `autoTracking: null` (the default) omits the constructor argument
  /// entirely, so [ArAlignmentStage]'s own `= true` default takes over —
  /// this is what C5 needs to genuinely exercise the ctor default rather
  /// than an explicitly-passed `true`.
  Widget buildStage(
    ProviderContainer container, {
    bool? autoTracking,
    bool active = true,
  }) {
    if (active) {
      container.read(arControllerProvider.notifier).markActive(true);
    }
    final stage = autoTracking == null
        ? ArAlignmentStage(
            cameraView: Container(key: const Key('fake-camera-view')),
            routes: const [route],
            refSize: refSize,
          )
        : ArAlignmentStage(
            cameraView: Container(key: const Key('fake-camera-view')),
            routes: const [route],
            refSize: refSize,
            autoTracking: autoTracking,
          );
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: MasiTheme.light,
        home: Scaffold(
          body: SizedBox(
            width: viewSize.width,
            height: viewSize.height,
            child: stage,
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

  group('ArAlignmentStage with autoTracking: false (web manual-only)', () {
    testWidgets(
      'C1: with ArController still at its literal auto default (no explicit '
      'setMode — autoTracking:false alone must be what forces the manual '
      'UI), the mode-toggle and re-scan FABs are absent, the reset and lock '
      'FABs are present, and the manual gesture layer is present',
      (tester) async {
        pinViewSize(tester);
        final container = ProviderContainer();
        addTearDown(container.dispose);

        await tester.pumpWidget(buildStage(container, autoTracking: false));
        await tester.pump();

        expect(
          container.read(arControllerProvider).mode,
          ArMode.auto,
          reason:
              'ArController.build() still defaults to ArMode.auto — this '
              'test deliberately does NOT call setMode(manual), so any '
              'manual-mode UI seen below is driven purely by '
              'autoTracking:false',
        );
        expect(find.byKey(const Key('ar-mode-toggle')), findsNothing);
        expect(find.byKey(const Key('ar-rescan')), findsNothing);
        expect(find.byKey(const Key('ar-reset')), findsOneWidget);
        expect(find.byKey(const Key('ar-lock')), findsOneWidget);
        expect(
          find.byKey(const Key('ar-manual-gesture-layer')),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'C2: dragging the manual gesture layer moves manualAlignProvider away '
      'from identity, exactly like the native manual-mode drag path',
      (tester) async {
        pinViewSize(tester);
        final container = ProviderContainer();
        addTearDown(container.dispose);

        await tester.pumpWidget(buildStage(container, autoTracking: false));
        await tester.pump();

        expect(container.read(manualAlignProvider), Homography.identity());

        await tester.drag(
          find.byKey(const Key('ar-manual-gesture-layer')),
          const Offset(30, -20),
        );
        await tester.pump();

        expect(
          container.read(manualAlignProvider),
          isNot(Homography.identity()),
          reason:
              'the drag must reach ManualAlignController.pan through the '
              'gesture layer exactly as it does in native manual mode',
        );
      },
    );

    testWidgets(
      'C3: once locked, the manual gesture layer is gone but the overlay '
      'keeps rendering the SAME (frozen) manual composite it held right '
      'before the lock — it must never fall back to the fitted ghost the '
      'way native locked-but-not-yet-tracked does, since web has no native '
      'world anchor to hand rendering off to',
      (tester) async {
        pinViewSize(tester);
        final container = ProviderContainer();
        addTearDown(container.dispose);

        await tester.pumpWidget(buildStage(container, autoTracking: false));
        await tester.pump();

        // Hand-adjust first, so the manual composite is distinguishable
        // from the plain fitted ghost fallback.
        container.read(manualAlignProvider.notifier).pan(const Offset(9, 9));
        await tester.pump();
        final fit = Homography.fitInto(refSize, viewSize);
        final homographyBeforeLock = currentPainter(tester).homography;
        expect(homographyBeforeLock, isNot(fit));

        // Toggle arLockedProvider directly rather than tapping ar-lock:
        // this is the exact seam ArAlignmentStage.onToggleLock's web branch
        // reduces to (a pure-Dart arLockedProvider.toggle(), no channel
        // call at all — see that method), so this exercises precisely the
        // same rendering path a real tap would, without needing a mocked
        // `masi/ar` MethodChannel in this file at all.
        container.read(arLockedProvider.notifier).toggle();
        await tester.pump();

        expect(container.read(arLockedProvider), isTrue);
        expect(
          find.byKey(const Key('ar-manual-gesture-layer')),
          findsNothing,
        );
        expect(
          currentPainter(tester).homography,
          homographyBeforeLock,
          reason:
              'locking on web must freeze the manual composite exactly '
              'where it was, not reset to the fitted ghost',
        );
        expect(currentPainter(tester).homography, isNot(fit));
      },
    );

    testWidgets(
      'C5: default ArAlignmentStage (autoTracking omitted, so true — the '
      'ctor default) in manual mode still shows the mode-toggle FAB — the '
      'native path stays byte-for-byte unchanged',
      (tester) async {
        pinViewSize(tester);
        final container = ProviderContainer();
        addTearDown(container.dispose);
        container.read(arControllerProvider.notifier).setMode(ArMode.manual);

        await tester.pumpWidget(buildStage(container));
        await tester.pump();

        expect(find.byKey(const Key('ar-mode-toggle')), findsOneWidget);
      },
    );
  });

  group(
    'ArScreen: arSupportedProvider drives the unsupported-placeholder gate '
    '(C4)',
    () {
      // Seeding a real photo + route (as ar_screen_test.dart's A1 does) is
      // impractical to duplicate here without pulling in the full library
      // CRUD + path_provider-fake setup that test file already owns — so,
      // per the C4 spec's documented fallback, this proves the WEAKER but
      // still load-bearing claim instead: toggling arSupportedProvider
      // between false/true toggles whether the unsupported placeholder
      // renders, with no photo/routes ever seeded (the wall genuinely has
      // none). With the override true, the screen falls through to the
      // "missing data" placeholder instead of crashing or (incorrectly)
      // still showing "iOS-only" — proving the gate is driven by the
      // provider, not hardcoded to isArSupported().
      ({AppDatabase db, ProviderContainer container}) buildContainer({
        required bool arSupported,
      }) {
        final db = AppDatabase(NativeDatabase.memory());
        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWithValue(db),
            nowMsProvider.overrideWithValue(() => 1000),
            arSupportedProvider.overrideWithValue(arSupported),
            // Self-consistency hardening: with arSupported:true, ArScreen's
            // _resetArViewState (see ar_screen.dart) may call
            // ArController.setMode, which fires a fire-and-forget
            // arChannelProvider.setMode call. Left un-overridden, that
            // resolves to createArChannel()'s REAL (non-noop) backing on
            // this native-VM test host (see ar_channel_factory_native.dart)
            // — a genuine `masi/ar` MethodChannel call with no mock
            // handler registered in this file, which becomes an orphaned,
            // never-completing Future rather than a clean, immediate no-op.
            // Overriding to ArChannel.noop() here keeps this group
            // self-consistent with what it's actually testing (the
            // arSupportedProvider gate), independent of that unrelated
            // channel side effect.
            arChannelProvider.overrideWithValue(ArChannel.noop()),
          ],
        );
        return (db: db, container: container);
      }

      testWidgets(
        'override -> false: the unsupported placeholder renders (matches '
        'this suite\'s real non-iOS host default from ar_screen_test.dart\'s '
        'A1/A1b)',
        (tester) async {
          final built = buildContainer(arSupported: false);
          final container = built.container;
          addTearDown(built.db.close);
          addTearDown(container.dispose);

          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: MaterialApp(
                theme: MasiTheme.light,
                home: const ArScreen(wallId: 'no-such-wall'),
              ),
            ),
          );
          await tester.pumpAndSettle();

          expect(
            find.byKey(const Key('ar-unsupported-placeholder')),
            findsOneWidget,
          );
        },
      );

      testWidgets(
        'override -> true: the unsupported placeholder does NOT render '
        '(falls through to the missing-data placeholder instead, since '
        'there is still no photo/routes for this wall) — proves the gate '
        'is driven by arSupportedProvider, not a hardcoded isArSupported() '
        'call',
        (tester) async {
          final built = buildContainer(arSupported: true);
          final container = built.container;
          addTearDown(built.db.close);
          addTearDown(container.dispose);

          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: MaterialApp(
                theme: MasiTheme.light,
                home: const ArScreen(wallId: 'no-such-wall'),
              ),
            ),
          );
          await tester.pumpAndSettle();

          expect(
            find.byKey(const Key('ar-unsupported-placeholder')),
            findsNothing,
          );
          expect(find.byKey(const Key('ar-missing-data')), findsOneWidget);
        },
      );
    },
  );

  group(
    'ArScreen web camera remount-on-retry (HIGH-sev fix: retry must not '
    'fake success without re-attempting getUserMedia)',
    () {
      late PathProviderPlatform originalPathProviderPlatform;
      setUp(() {
        originalPathProviderPlatform = PathProviderPlatform.instance;
        PathProviderPlatform.instance = _FakePathProviderPlatform();
      });
      tearDown(() {
        PathProviderPlatform.instance = originalPathProviderPlatform;
      });

      testWidgets(
        'web (arAutoTrackingProvider:false): the camera view ArScreen.build '
        'constructs is wrapped in a KeyedSubtree keyed on the current '
        '_webCameraAttempt count ("ar-web-camera-0" on first build) — the '
        'exact invariant _retryStartSession\'s web branch depends on to '
        'force a remount (bumping to "ar-web-camera-1", -2, ...) instead of '
        'silently reusing the old, already-failed _ArWebCameraViewState.\n'
        '\n'
        'This does NOT drive an actual failed-getUserMedia -> tap-retry -> '
        'remount round trip: this suite\'s plain `flutter test` VM host '
        'compiles `buildArCameraView` to `ar_camera_view_stub.dart` (no '
        '`dart.library.js_interop` here), an inert placeholder that never '
        'calls `onReady`/`onError` at all (see that file) — so `_startError` '
        'can never organically go non-null through a real ArScreen on this '
        'host, no matter how much DB/photo state is seeded (the real '
        '`getUserMedia()`-calling widget only exists in '
        '`ar_camera_view_web.dart`, which this project\'s test tooling never '
        'compiles or runs — there is no headless-browser widget-test host). '
        'Per this file\'s own C4-group precedent of not duplicating full '
        'seeding for paths a plain VM host cannot truly execute, this '
        'KeyedSubtree-key assertion plus a clean `flutter analyze` are the '
        'load-bearing checks for the remount fix itself.',
        (tester) async {
          final db = AppDatabase(NativeDatabase.memory());
          addTearDown(db.close);
          final container = ProviderContainer(
            overrides: [
              appDatabaseProvider.overrideWithValue(db),
              nowMsProvider.overrideWithValue(() => 1000),
              arSupportedProvider.overrideWithValue(true),
              arAutoTrackingProvider.overrideWithValue(false),
              // See buildContainer's identical override above for why this
              // is required once arSupported:true can drive a real setMode
              // call out of _resetArViewState.
              arChannelProvider.overrideWithValue(ArChannel.noop()),
            ],
          );
          addTearDown(container.dispose);

          final crud = container.read(libraryCrudRepositoryProvider);
          final area = await crud.createArea('Area');
          final sector = await crud.createSector(area.id, 'Sector');
          final wall = await crud.createWall(sector.id, 'Wall');
          late String photoId;
          await tester.runAsync(() async {
            photoId = await crud.attachPhotoToWall(
              wall.id,
              XFile('/tmp/ar-web-manual-test-photo.jpg'),
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
          });

          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: MaterialApp(
                theme: MasiTheme.light,
                home: ArScreen(wallId: wall.id),
              ),
            ),
          );
          await tester.pumpAndSettle();

          expect(
            find.byKey(const ValueKey('ar-web-camera-0')),
            findsOneWidget,
            reason:
                'ArScreen.build\'s web (!autoTracking) branch must wrap '
                'buildArCameraView(...) in a KeyedSubtree keyed on the '
                'current _webCameraAttempt count, starting at 0 — without '
                'this key, Flutter reuses the same _ArWebCameraViewState '
                'across a retry (same runtimeType, both keys null) and '
                'initState (where getUserMedia() actually runs) never '
                're-fires, so a retry after a denied permission would '
                'silently never re-attempt camera acquisition.',
          );
          expect(find.byKey(const Key('ar-web-camera')), findsOneWidget);
        },
      );
    },
  );
}
