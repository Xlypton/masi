import 'package:masi/app/theme.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/features/ar/application/ar_channel.dart';
import 'package:masi/features/ar/application/ar_controller.dart';
import 'package:masi/features/ar/presentation/ar_screen.dart';
import 'package:masi/features/library/application/library_providers.dart';
import 'package:masi/features/topo/data/route_repository.dart';
import 'package:masi/features/topo/domain/topo_route.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// Stands in for the real `path_provider` platform channel plugin (no mock
/// registered in this suite's plain `flutter test` host). Needed here because
/// this file mounts a real [ArScreen] with a persisted photo — see
/// `ar_screen_test.dart`'s identically-named fake for the full rationale (an
/// unmocked `getApplicationDocumentsPath()` call made from inside
/// `ArScreen._load`'s async lifecycle never settles under `pumpAndSettle`).
class _FakePathProviderPlatform extends PathProviderPlatform {
  @override
  Future<String?> getApplicationDocumentsPath() async =>
      '/tmp/ar_screen_start_session_test_docs';
}

/// A fake [ArChannel] whose [start] resolves to a fixed, distinctive
/// `rockQuadPercent` rather than [ArChannel.noop]'s always-`null` result —
/// this is exactly what distinguishes this test from every other rockQuad
/// test in this suite: every OTHER test seeds `rockQuadPercent` directly via
/// `ArController.setRockQuadPercent` and never actually round-trips through
/// `channel.start()` -> `_ArScreenState._startSession`'s forwarding line.
///
/// Constructed via `super.noop()` — [ArChannel.noop]'s own constructor sets
/// the private `_noop` flag every OTHER public method
/// (`alignments`/`stop`/`setMode`/`rescan`/`lockManual`/`unlockManual`)
/// checks first (`if (_noop) return ...`) — so leaving all of them
/// un-overridden here already gives the exact same safe no-op behavior
/// `ArChannel.noop()` itself provides, with no need to duplicate that logic.
/// Only [start] needs overriding, since it's the one call this test needs to
/// return something other than `null`.
class _FakeArChannel extends ArChannel {
  _FakeArChannel(this.result) : super.noop();

  final List<Offset> result;

  /// Set by [stop] when called. Lets this test assert that
  /// `_ArScreenState.dispose()` actually invokes `channel.stop()` (releasing
  /// the native camera/tracking session) rather than silently skipping it —
  /// see the dispose-time bug this test's final block documents/asserts.
  bool stopCalled = false;

  @override
  Future<List<Offset>?> start({
    required String referenceImagePath,
    required int refWidth,
    required int refHeight,
    required String routesJson,
  }) async => result;

  @override
  Future<void> stop() {
    stopCalled = true;
    return super.stop();
  }
}

/// Covers the one end-to-end forwarding gap no other AR test closes:
/// `_ArScreenState._startSession`'s
/// `ref.read(arControllerProvider.notifier).setRockQuadPercent(rockQuad)`
/// line, where `rockQuad` is exactly whatever `channel.start(...)` returned.
///
/// `ArChannel.start`'s wire-parsing (`_parseRockQuadPercent`),
/// `ArController.setRockQuadPercent`'s state update, and the
/// `arState.rockQuadPercent` render seam in `ArAlignmentStage.build` are each
/// tested in isolation elsewhere (`ar_channel_test.dart`,
/// `ar_controller_test.dart`, and `ar_screen_test.dart`'s "B2:
/// rockQuadPercent as the fromQuad SOURCE quad" group, respectively) — but
/// none of them drive a real `_startSession` call and assert its `start()`
/// result actually lands in the controller. This test reaches `_startSession`
/// for real, by mounting a genuine `UiKitView` (native/auto-tracking branch)
/// and letting its `onPlatformViewCreated` callback fire — the same gate
/// `_maybeStartSession`'s doc describes as the only legitimate way
/// `_startSession` is ever invoked.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const fakeRockQuad = <Offset>[
    Offset(0.1, 0.2),
    Offset(0.9, 0.2),
    Offset(0.9, 0.8),
    Offset(0.1, 0.8),
  ];

  late PathProviderPlatform originalPathProviderPlatform;
  setUp(() {
    originalPathProviderPlatform = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _FakePathProviderPlatform();
    // A real UiKitView's `_createNewUiKitView` awaits
    // `SystemChannels.platform_views`'s 'create' method call before ever
    // invoking `onPlatformViewCreated` (see the framework's
    // `platform_view.dart`) — and `_maybeStartSession`/`_startSession` are
    // ONLY ever reached from that callback (see `ar_screen.dart`'s doc).
    // With no handler registered at all, that 'create' call throws
    // MissingPluginException and onPlatformViewCreated never fires, so
    // this test would never reach the very line under test. Returning
    // `null` unconditionally mirrors the Flutter SDK's own
    // `FakeIosPlatformViewsController`'s happy-path 'create' response
    // (`packages/flutter/test/services/fake_platform_views.dart`) — there's
    // no real native view to track here, just enough to let the awaited
    // Future resolve so the framework fires the created-callback.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          SystemChannels.platform_views,
          (call) async => null,
        );
  });
  tearDown(() {
    PathProviderPlatform.instance = originalPathProviderPlatform;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform_views, null);
  });

  testWidgets(
    "_startSession forwards channel.start()'s rockQuad result into "
    'arControllerProvider.rockQuadPercent -- deleting that forwarding line '
    '(the setRockQuadPercent(rockQuad) call in ar_screen.dart) must fail '
    'this test',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final fakeChannel = _FakeArChannel(fakeRockQuad);
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          nowMsProvider.overrideWithValue(() => 1000),
          arSupportedProvider.overrideWithValue(true),
          // true (the native/auto-tracking branch): ArScreen.build only ever
          // constructs a real UiKitView -- and thus only ever wires
          // onPlatformViewCreated -> _maybeStartSession -- when this is
          // true. With this false (the web branch, per ar_web_manual_test
          // .dart's C4 group), _startSession is never invoked at all: the
          // web camera surface's own onReady callback marks the session
          // active directly, bypassing _startSession/channel.start()
          // entirely (see ar_screen.dart's build doc).
          arAutoTrackingProvider.overrideWithValue(true),
          arChannelProvider.overrideWithValue(fakeChannel),
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
          XFile('/tmp/ar-start-session-test-photo.jpg'),
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
            // visible defaults to true -- _maybeStartSession's
            // hasVisibleRoute gate needs at least one visible route or it
            // bails before ever calling _startSession.
          ),
        );
      });

      expect(
        container.read(arControllerProvider).rockQuadPercent,
        isNull,
        reason: 'sanity: nothing set yet before the session ever starts',
      );

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
        find.byType(UiKitView),
        findsOneWidget,
        reason:
            'sanity: arSupportedProvider:true + arAutoTrackingProvider:true '
            'must take the native branch, or onPlatformViewCreated (and '
            'thus _startSession) is never reached at all',
      );
      expect(
        container.read(arControllerProvider).rockQuadPercent,
        fakeRockQuad,
        reason:
            "_startSession must forward channel.start()'s returned rockQuad "
            'straight into arControllerProvider via setRockQuadPercent -- '
            'this must be non-null and equal to fakeRockQuad, never left at '
            'its initial null',
      );

      // Explicitly unmount (mirrors the same pattern `ar_screen_test.dart`'s
      // Fix 1/B3 tests already use to simulate a real Navigator.pop) so this
      // test controls exactly when `_ArScreenState.dispose()` runs, rather
      // than leaving it to the framework's own implicit end-of-test teardown.
      //
      // This is the FIRST test in the whole AR suite to actually drive
      // `_startSession` to completion (every other ArScreen-mounting test
      // takes either the unsupported-placeholder branch or the
      // web/KeyedSubtree branch, where `_sessionStarted` never flips true —
      // see this file's class doc and `ar_web_manual_test.dart`'s C4 group),
      // so it's also the first to exercise `dispose()`'s
      // `if (_sessionStarted) { ... }` branch at all.
      //
      // FORMERLY a pre-existing bug lived here: Flutter's
      // `StatefulElement.unmount()` calls `super.unmount()` (which marks the
      // element `defunct`) BEFORE calling `state.dispose()`, and Riverpod
      // 3.3.2's `WidgetRef.read` starts with an unconditional
      // `_assertNotDisposed()` check against exactly that flag (see
      // `flutter_riverpod`'s `consumer.dart`) — so a `ref.read` called
      // directly in `dispose()`'s body threw a `StateError` on every real
      // dispose of an AR screen that ever started a session, silently
      // aborting `channel.stop()`/`markActive(false)` (caught and reported by
      // `FlutterError`, hence never surfacing as an app crash on-device).
      // Fixed in `ar_screen.dart` by caching the channel/controller-notifier
      // in State fields (assigned in `initState`, where `ref.read` is safe)
      // and reading those cached fields in `dispose()` instead — exactly the
      // fix Riverpod's own assertion message advises. This test now asserts
      // both halves of that fix: dispose no longer throws, and the teardown
      // it used to skip (`channel.stop()`) actually runs.
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(
        tester.takeException(),
        isNull,
        reason:
            'dispose() must not throw — the cached-field fix means no '
            '`ref.read` ever runs in the dispose body',
      );
      expect(
        fakeChannel.stopCalled,
        isTrue,
        reason:
            "dispose() must actually call the cached channel's stop() to "
            'release the native camera/tracking session — this is the '
            'load-bearing teardown the pre-existing bug used to skip',
      );
    },
  );
}
