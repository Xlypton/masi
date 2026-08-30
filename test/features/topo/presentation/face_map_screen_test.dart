import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:masi/app/theme.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/features/topo/presentation/face_map_screen.dart';

/// The plan view, full screen.
///
/// It is a screen because the card it replaced could not be both things a
/// plan has to be: big enough to recognise a face from a photograph, and
/// absent while you read the routes. Mounted permanently at 153pt above the
/// legend it was neither.
///
/// The contract worth pinning is that it WRITES NOTHING. It pops the id of the
/// face the reader chose and the canvas switches to it, which keeps every path
/// that changes the shown photo running through one method.
void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  const wallId = 'wall-1';

  Future<void> seedWall({required int photos, bool withGps = true}) async {
    await db.into(db.areas).insert(
      AreasCompanion.insert(
        id: 'area-1',
        createdAt: 1000,
        updatedAt: 1000,
        name: 'Area',
      ),
    );
    await db.into(db.sectors).insert(
      SectorsCompanion.insert(
        id: 'sector-1',
        createdAt: 1000,
        updatedAt: 1000,
        areaId: 'area-1',
        name: 'Sector',
        sortOrder: 0,
      ),
    );
    await db.into(db.walls).insert(
      WallsCompanion.insert(
        id: wallId,
        createdAt: 1000,
        updatedAt: 1000,
        sectorId: 'sector-1',
        name: 'Dolomitici',
        sortOrder: 0,
      ),
    );
    for (var i = 0; i < photos; i++) {
      await db.into(db.photos).insert(
        PhotosCompanion.insert(
          id: 'photo-$i',
          createdAt: 1000 + i,
          updatedAt: 1000 + i,
          wallId: wallId,
          localPath: '/tmp/photo-$i.jpg',
          kind: 'original',
          width: 100,
          height: 200,
          sortOrder: Value(i),
          isPrimary: Value(i == 0),
          captureLatitude: Value(withGps ? 47.0 + i * 0.0005 : null),
          captureLongitude: Value(withGps ? 12.0 + i * 0.0005 : null),
          captureAccuracyMeters: Value(withGps ? 4 : null),
          captureBearingDegrees: Value(withGps ? i * 90.0 : null),
        ),
      );
    }
  }

  /// An EXPLICIT container disposed in `addTearDown`, never a plain
  /// `ProviderScope` inside the pumped tree. This screen watches three drift
  /// stream providers, and tearing a scope down inside the test body cancels
  /// their subscriptions in the fake-async zone — a cancellation that posts a
  /// zero-duration timer and fails every test here with "a Timer is still
  /// pending", which says nothing about what the test was checking. Disposing
  /// the container afterwards puts that teardown outside the zone.
  ProviderContainer makeContainer() => ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(db),
      nowMsProvider.overrideWithValue(() => 1000),
    ],
  );

  Future<void> pumpMap(
    WidgetTester tester,
    ProviderContainer container, {
    String? initialPhotoId = 'photo-0',
    bool readOnly = false,
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: MasiTheme.light,
          home: FaceMapScreen(
            wallId: wallId,
            initialPhotoId: initialPhotoId,
            readOnly: readOnly,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('every photo of the rock is on the plan, as a picture', (
    tester,
  ) async {
    await seedWall(photos: 4);
    final container = makeContainer();
    addTearDown(container.dispose);
    await pumpMap(tester, container);

    expect(find.text('Dolomitici'), findsOneWidget);
    expect(find.text('4 photos around this rock'), findsOneWidget);
    for (var i = 0; i < 4; i++) {
      expect(find.byKey(Key('face-map-face-photo-$i')), findsOneWidget);
    }
  });

  testWidgets('tapping a camera moves the current-photo bar to it, and Open '
      'hands that choice back', (tester) async {
    await seedWall(photos: 4);
    final container = makeContainer();
    addTearDown(container.dispose);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    String? popped;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: MasiTheme.light,
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () async {
                    popped = await Navigator.of(context).push<String>(
                      MaterialPageRoute<String>(
                        builder: (_) => const FaceMapScreen(
                          wallId: wallId,
                          initialPhotoId: 'photo-0',
                        ),
                      ),
                    );
                  },
                  child: const Text('open map'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open map'));
    await tester.pumpAndSettle();

    expect(find.text('Photo 1'), findsOneWidget);

    await tester.tap(find.byKey(const Key('face-map-face-photo-2')));
    await tester.pumpAndSettle();
    expect(
      find.text('Photo 3'),
      findsOneWidget,
      reason: 'the bar follows the camera you tapped',
    );

    await tester.tap(find.byKey(const Key('face-map-open')));
    await tester.pumpAndSettle();
    expect(
      popped,
      'photo-2',
      reason: 'the screen writes nothing — it hands the choice back',
    );
  });

  testWidgets('a read-only rock offers no way into the editor', (tester) async {
    await seedWall(photos: 3);
    final container = makeContainer();
    addTearDown(container.dispose);
    await pumpMap(tester, container, readOnly: true);

    expect(find.byKey(const Key('face-map-edit')), findsNothing);
  });

  testWidgets('a rock nobody has traced says so, rather than drawing an '
      'empty box', (tester) async {
    // No photos: `wallLayoutProvider` answers `LayoutResult.empty`, whose
    // baseline is degenerate. That is also the shape the screen sees for one
    // frame on a cold open, before the photo rows arrive — a real state, and
    // the one where an empty plan box would look like a broken screen.
    //
    // One photo would NOT reach it: the engine synthesises a capture-order
    // strip rather than handing back a degenerate line, which is deliberate
    // (see `baseline_synthesis.dart`) and worth not asserting against.
    await seedWall(photos: 0, withGps: false);
    final container = makeContainer();
    addTearDown(container.dispose);
    await pumpMap(tester, container);

    expect(find.byKey(const Key('face-map-empty')), findsOneWidget);
    expect(find.byKey(const Key('face-map-plan')), findsNothing);
  });
}
