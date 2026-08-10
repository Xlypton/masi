// Tests for the topo canvas's LOADING states — the four states this screen used
// to render as either "nothing here" or "a spinner", which is what made a topo
// still on its way indistinguishable from a topo that had lost its work:
//
//  * the wall's photo is still being restored -> a canvas-shaped placeholder,
//    never `topo-empty-state`'s "No photo yet — pick one to start";
//  * the photo strip's live list is still loading -> a skeleton strip, never an
//    empty (invisible) band;
//  * the wall's name is still loading -> a placeholder bar, never the wrong
//    "Topo" fallback;
//  * a route commit / a manage action / a photo switch is in flight -> a cue on
//    the control or the object it is about.
//
// Every wait here is an explicit `tester.pump(duration)`: a revealed skeleton or
// spinner animates forever, so `pumpAndSettle()` would hang (see
// `masi_loading_gate.dart`'s and `masi_skeleton.dart`'s testing notes). And a
// Riverpod state change lands on the FOLLOWING pump, so completions are always
// delivered with a bare `pump()` before the clock is advanced — otherwise the
// gate is credited with time the app never spent loading.
import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:masi/app/theme.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/features/library/application/library_providers.dart';
import 'package:masi/features/topo/application/draw_controller.dart';
import 'package:masi/features/topo/data/photo_files.dart' show PhotoWriteFailure;
import 'package:masi/features/topo/data/photo_repository.dart';
import 'package:masi/features/topo/data/route_repository.dart';
import 'package:masi/features/topo/domain/topo_route.dart';
import 'package:masi/features/topo/presentation/photo_strip.dart';
import 'package:masi/features/topo/presentation/topo_canvas_screen.dart';
import 'package:masi/shared/presentation/masi_loading_indicator.dart';
import 'package:masi/shared/presentation/masi_skeleton.dart';

/// Holds [loadOriginal] — the screen's initial photo restore — open until the
/// test lets it finish, so the window that used to render "No photo yet" can be
/// inspected at all.
class _GatedLoadPhotoRepository extends PhotoRepository {
  _GatedLoadPhotoRepository(super.db, {required super.nowMs});

  final Completer<void> gate = Completer<void>();

  @override
  Future<PhotoRef?> loadOriginal(String wallId) async {
    await gate.future;
    return super.loadOriginal(wallId);
  }
}

/// Fails [loadOriginal] outright — the terminal case for the photo-pending
/// placeholder, which is handed a hardcoded `isLoading: true` and can therefore
/// only ever be resolved by its parent condition going false.
class _FailingLoadPhotoRepository extends PhotoRepository {
  _FailingLoadPhotoRepository(super.db, {required super.nowMs});

  @override
  Future<PhotoRef?> loadOriginal(String wallId) async =>
      throw StateError('the photo row could not be read');
}

/// Holds route WRITES open, so the commit button's pending state is observable.
class _GatedWriteRouteRepository extends RouteRepository {
  _GatedWriteRouteRepository(super.db, {required super.nowMs});

  final Completer<void> gate = Completer<void>();
  int upserts = 0;

  @override
  Future<void> upsertRoute(
    String wallId,
    String photoId,
    TopoRoute route, {
    bool markDirty = true,
  }) async {
    upserts++;
    await gate.future;
    return super.upsertRoute(wallId, photoId, route, markDirty: markDirty);
  }
}

typedef _Seeded = ({
  AppDatabase db,
  ProviderContainer container,
  String wallId,
  String photoId,
});

void main() {
  /// [extraOverrides] is deliberately untyped (`Riverpod`'s `Override` is not
  /// exported by `flutter_riverpod`): callers pass provider overrides, which
  /// `ProviderContainer` type-checks itself.
  Future<_Seeded> seedWallWithPhoto(
    WidgetTester tester, {
    List<dynamic> extraOverrides = const [],
  }) async {
    final db = AppDatabase(NativeDatabase.memory());
    final container = ProviderContainer(
      // Riverpod v3 retries failed providers on a backoff by default, which
      // would leave pending timers behind these tests' assertions.
      retry: (_, _) => null,
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        nowMsProvider.overrideWithValue(() => 1000),
        ...extraOverrides.cast(),
      ],
    );

    final crud = container.read(libraryCrudRepositoryProvider);
    final area = await crud.createArea('Area');
    final sector = await crud.createSector(area.id, 'Sector');
    final wall = await crud.createWall(sector.id, 'Kőbánya slab');
    late String photoId;
    await tester.runAsync(() async {
      photoId = await crud.attachPhotoToWall(
        wall.id,
        XFile('/tmp/canvas-loading-states-test.jpg'),
        1000,
        2000,
      );
    });

    return (db: db, container: container, wallId: wall.id, photoId: photoId);
  }

  Widget wrap(ProviderContainer container, Widget child) {
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp(theme: MasiTheme.light, home: child),
    );
  }

  testWidgets(
    'a wall whose photo is still being restored never claims "No photo yet" — '
    'it shows a canvas-shaped placeholder, and nothing at all inside the '
    'anti-flash window',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      final repo = _GatedLoadPhotoRepository(db, nowMs: () => 1000);
      final container = ProviderContainer(
        retry: (_, _) => null,
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          nowMsProvider.overrideWithValue(() => 1000),
          photoRepositoryProvider.overrideWithValue(repo),
        ],
      );
      addTearDown(db.close);
      addTearDown(container.dispose);

      final crud = container.read(libraryCrudRepositoryProvider);
      final area = await crud.createArea('Area');
      final sector = await crud.createSector(area.id, 'Sector');
      final wall = await crud.createWall(sector.id, 'Wall');
      await tester.runAsync(() async {
        await crud.attachPhotoToWall(
          wall.id,
          XFile('/tmp/canvas-loading-states-restore.jpg'),
          1000,
          2000,
        );
      });

      await tester.pumpWidget(
        wrap(
          container,
          TopoCanvasScreen(
            wallId: wall.id,
            debugInitialImageSize: const Size(1000, 2000),
          ),
        ),
      );

      // Inside MasiMotion.loadingRevealDelay: no placeholder yet...
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const Key('topo-photo-pending')), findsOneWidget);
      expect(find.byType(MasiSkeleton), findsNothing);
      // ...and, above all, no claim that this wall has no photo.
      expect(
        find.byKey(const Key('topo-empty-state')),
        findsNothing,
        reason:
            'the empty state must never stand in for a photo that is still '
            'being restored — that is the state a climber reads as lost work',
      );

      // Past it: a shaped placeholder, still not the empty state.
      await tester.pump(const Duration(milliseconds: 150));
      expect(find.byType(MasiSkeleton), findsWidgets);
      expect(find.byKey(const Key('topo-empty-state')), findsNothing);

      // Let the restore finish: the real canvas replaces the placeholder.
      repo.gate.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byKey(const Key('topo-photo-pending')), findsNothing);
      expect(find.byKey(const Key('topo-empty-state')), findsNothing);
    },
  );

  testWidgets(
    'a photo restore that FAILS still resolves the placeholder: the gate is '
    'hardcoded to isLoading:true, so a shimmer nothing can end would be worse '
    'than the empty state it replaced',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      final container = ProviderContainer(
        retry: (_, _) => null,
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          nowMsProvider.overrideWithValue(() => 1000),
          photoRepositoryProvider.overrideWithValue(
            _FailingLoadPhotoRepository(db, nowMs: () => 1000),
          ),
        ],
      );
      addTearDown(db.close);
      addTearDown(container.dispose);

      final crud = container.read(libraryCrudRepositoryProvider);
      final area = await crud.createArea('Area');
      final sector = await crud.createSector(area.id, 'Sector');
      final wall = await crud.createWall(sector.id, 'Wall');
      await tester.runAsync(() async {
        await crud.attachPhotoToWall(
          wall.id,
          XFile('/tmp/canvas-loading-states-failed-restore.jpg'),
          1000,
          2000,
        );
      });

      await tester.pumpWidget(wrap(container, TopoCanvasScreen(wallId: wall.id)));
      // Well past MasiMotion.loadingRevealDelay: whatever is on screen now is
      // the settled state, not the anti-flash window.
      await tester.pump(const Duration(milliseconds: 600));

      expect(
        find.byKey(const Key('topo-photo-pending')),
        findsNothing,
        reason:
            'the restore is over — it failed — so the placeholder must be gone; '
            'a skeleton only its parent can end must not outlive that parent',
      );
      expect(find.byType(MasiSkeleton), findsNothing);
      expect(find.byKey(const Key('topo-empty-state')), findsOneWidget);
    },
  );

  testWidgets(
    'the photo strip renders a skeleton band, not an empty one, while the '
    "wall's live photo list is still loading",
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      final controller = StreamController<List<PhotoRef>>();
      addTearDown(controller.close);
      final container = ProviderContainer(
        retry: (_, _) => null,
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          nowMsProvider.overrideWithValue(() => 1000),
          wallOriginalsProvider.overrideWith((ref, wallId) => controller.stream),
        ],
      );
      addTearDown(db.close);
      addTearDown(container.dispose);

      await tester.pumpWidget(
        wrap(
          container,
          Scaffold(
            body: PhotoStrip(
              wallId: 'wall-1',
              activePhotoId: null,
              onSelect: (_) {},
            ),
          ),
        ),
      );

      await tester.pump(const Duration(milliseconds: 100));
      expect(
        find.byKey(const Key('photo-strip-loading')),
        findsNothing,
        reason: 'a fast list read must paint no loading state at all',
      );

      await tester.pump(const Duration(milliseconds: 150));
      expect(
        find.byKey(const Key('photo-strip-loading')),
        findsOneWidget,
        reason:
            'a still-loading list is not an empty wall — it must not render as '
            'an invisible band',
      );
      expect(find.byKey(const Key('photo-strip')), findsNothing);

      // An EMPTY list, once it actually arrives, is the one state that may
      // render nothing.
      controller.add(const <PhotoRef>[]);
      await tester.pump();
      // Past MasiMotion.loadingMinVisible: the revealed skeleton is pinned for
      // the hold even after the empty list lands (that hold is what stops it
      // strobing), so this must wait it out rather than assert into it.
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byKey(const Key('photo-strip-loading')), findsNothing);
      expect(find.byKey(const Key('photo-strip')), findsNothing);
    },
  );

  testWidgets(
    "the canvas title shows a placeholder while the wall's name loads, never "
    'the wrong "Topo" fallback',
    (tester) async {
      final nameGate = Completer<String?>();
      final seeded = await seedWallWithPhoto(
        tester,
        extraOverrides: [
          wallNameProvider.overrideWith((ref, wallId) => nameGate.future),
        ],
      );
      addTearDown(seeded.db.close);
      addTearDown(seeded.container.dispose);

      await tester.pumpWidget(
        wrap(
          seeded.container,
          TopoCanvasScreen(
            wallId: seeded.wallId,
            debugInitialImageSize: const Size(1000, 2000),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 250));

      expect(
        find.text('Topo'),
        findsNothing,
        reason:
            '"Topo" is the fallback for a wall with no name, not for a name '
            'that has not arrived — printing it produces a title that silently '
            'changes under the climber',
      );
      expect(find.byType(MasiSkeleton), findsWidgets);

      nameGate.complete('Kőbánya slab');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('Kőbánya slab'), findsOneWidget);
    },
  );

  testWidgets(
    'the commit button reports its write: it disables itself immediately and '
    'shows a spinner once the write outlasts the reveal delay',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      final routeRepo = _GatedWriteRouteRepository(db, nowMs: () => 1000);
      final container = ProviderContainer(
        retry: (_, _) => null,
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          nowMsProvider.overrideWithValue(() => 1000),
          routeRepositoryProvider.overrideWithValue(routeRepo),
        ],
      );
      addTearDown(db.close);
      addTearDown(container.dispose);

      final crud = container.read(libraryCrudRepositoryProvider);
      final area = await crud.createArea('Area');
      final sector = await crud.createSector(area.id, 'Sector');
      final wall = await crud.createWall(sector.id, 'Wall');
      await tester.runAsync(() async {
        await crud.attachPhotoToWall(
          wall.id,
          XFile('/tmp/canvas-loading-states-commit.jpg'),
          1000,
          2000,
        );
      });

      await tester.pumpWidget(
        wrap(
          container,
          TopoCanvasScreen(
            wallId: wall.id,
            debugInitialImageSize: const Size(1000, 2000),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));

      // Draw a two-point route, in draw mode, so committing has something to
      // write.
      final notifier = container.read(drawControllerProvider(wall.id).notifier);
      notifier.setMode(DrawMode.draw);
      notifier.addPoint(const Offset(0.1, 0.1));
      notifier.addPoint(const Offset(0.2, 0.2));
      await tester.pump();

      final commit = find.byKey(const Key('topo-commit-button'));
      expect(commit, findsOneWidget);
      await tester.tap(commit);
      await tester.pump();

      // The disable is immediate; the spinner waits out the reveal delay.
      expect(find.byKey(MasiLoadingIndicator.spinnerKey), findsNothing);
      await tester.pump(const Duration(milliseconds: 250));
      expect(
        find.descendant(
          of: commit,
          matching: find.byKey(MasiLoadingIndicator.spinnerKey),
        ),
        findsOneWidget,
        reason: 'a route write in flight must be visible ON the commit button',
      );

      // A second tap while pending is swallowed rather than queued.
      await tester.tap(commit);
      await tester.pump();
      expect(routeRepo.upserts, 1);

      routeRepo.gate.complete();
      await tester.pump();
      // Past the minimum-visible hold, the cue clears.
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byKey(MasiLoadingIndicator.spinnerKey), findsNothing);
    },
  );

  testWidgets(
    'switching photos says so: while the new photo\'s routes are being read '
    'the canvas shows a "Loading routes…" cue instead of a bare empty topo',
    (tester) async {
      final seeded = await seedWallWithPhoto(tester);
      addTearDown(seeded.db.close);
      addTearDown(seeded.container.dispose);

      final transformationController = TransformationController();
      addTearDown(transformationController.dispose);

      await tester.pumpWidget(
        wrap(
          seeded.container,
          Scaffold(
            body: TopoCanvasBody(
              wallId: seeded.wallId,
              imagePath: '/tmp/canvas-loading-states-test.jpg',
              imageSize: const Size(1000, 2000),
              // Exactly what DrawController.beginPhotoSwitch produces: no
              // routes, no active photo, a switch in flight.
              drawState: const DrawState(isSwitchingPhoto: true),
              transformationController: transformationController,
            ),
          ),
        ),
      );

      await tester.pump(const Duration(milliseconds: 100));
      expect(
        find.byKey(const Key('topo-routes-loading')),
        findsNothing,
        reason: 'a switch that resolves instantly must show nothing',
      );

      await tester.pump(const Duration(milliseconds: 150));
      expect(find.byKey(const Key('topo-routes-loading')), findsOneWidget);
      expect(find.text('Loading routes…'), findsOneWidget);
    },
  );

  testWidgets(
    'and it clears on EVERY way a switch can end — including the failed read, '
    'the exit path that used to leave isSwitchingPhoto stuck true. The cue is '
    'handed a hardcoded isLoading:true, so this condition is the only thing '
    'that can ever end it',
    (tester) async {
      final seeded = await seedWallWithPhoto(tester);
      addTearDown(seeded.db.close);
      addTearDown(seeded.container.dispose);

      final transformationController = TransformationController();
      addTearDown(transformationController.dispose);

      Future<void> pumpWith(DrawState drawState) async {
        await tester.pumpWidget(
          wrap(
            seeded.container,
            Scaffold(
              body: TopoCanvasBody(
                wallId: seeded.wallId,
                imagePath: '/tmp/canvas-loading-states-test.jpg',
                imageSize: const Size(1000, 2000),
                drawState: drawState,
                transformationController: transformationController,
              ),
            ),
          ),
        );
      }

      await pumpWith(const DrawState(isSwitchingPhoto: true));
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byKey(const Key('topo-routes-loading')), findsOneWidget);

      // (1) The read SUCCEEDED and found nothing — still zero routes, but the
      // switch is settled, so the cue must go rather than sit over an empty
      // topo forever.
      await pumpWith(const DrawState());
      await tester.pump();
      expect(find.byKey(const Key('topo-routes-loading')), findsNothing);

      // (2) The read FAILED. `loadForWall`'s catch settles the switch exactly
      // like this — isSwitchingPhoto false, routes still empty, the failure
      // recorded — and that must clear the cue too: a "Loading routes…" pill
      // that never resolves is precisely the lie this cue exists to prevent.
      await pumpWith(const DrawState(isSwitchingPhoto: true));
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byKey(const Key('topo-routes-loading')), findsOneWidget);
      await pumpWith(
        const DrawState(
          lastLoadFailure: RouteLoadException(
            failure: PhotoWriteFailure.unknown,
            wallId: 'w',
            photoId: 'p',
            cause: 'boom',
          ),
        ),
      );
      await tester.pump();
      expect(find.byKey(const Key('topo-routes-loading')), findsNothing);
    },
  );

  testWidgets(
    'a manage action shows a busy cue on the tile it is about, for the whole '
    'window between the confirm tap and its SnackBar',
    (tester) async {
      final seeded = await seedWallWithPhoto(tester);
      addTearDown(seeded.db.close);
      addTearDown(seeded.container.dispose);

      // A second photo, so the tapped one is not already the cover (the manage
      // sheet hides "Set as cover" for the primary photo).
      late String photo2Id;
      await tester.runAsync(() async {
        photo2Id = await seeded.container
            .read(libraryCrudRepositoryProvider)
            .attachPhotoToWall(
              seeded.wallId,
              XFile('/tmp/canvas-loading-states-test-2.jpg'),
              1000,
              2000,
            );
      });

      final coverGate = Completer<void>();
      await tester.pumpWidget(
        wrap(
          seeded.container,
          Scaffold(
            body: PhotoStrip(
              wallId: seeded.wallId,
              activePhotoId: seeded.photoId,
              onSelect: (_) {},
              onSetCover: (_) => coverGate.future,
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));

      await tester.longPress(find.byKey(Key('photo-strip-item-$photo2Id')));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byKey(Key('photo-manage-setcover-$photo2Id')));
      // The sheet pops itself, then the write runs.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        find.byKey(Key('photo-strip-item-busy-$photo2Id')),
        findsOneWidget,
        reason:
            'the sheet is gone by now, so the tile is the only place left that '
            'can say the write is still running',
      );
      expect(
        find.byKey(Key('photo-strip-item-busy-${seeded.photoId}')),
        findsNothing,
        reason: 'only the photo being changed is busy',
      );

      coverGate.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byKey(Key('photo-strip-item-busy-$photo2Id')), findsNothing);
    },
  );
}
