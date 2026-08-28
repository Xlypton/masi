import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart' hide Baseline;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:masi/app/theme.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/features/topo/domain/face_layout/baseline.dart';
import 'package:masi/features/topo/presentation/layout_editor_screen.dart';

/// The layout editor. What is worth pinning here is the contract the design
/// states in words: a guessed line says so and can be accepted, and accepting
/// it is a real edit rather than a dismissal.
void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  const wallId = 'wall-1';

  Future<void> seed({int photos = 3, bool withGps = false}) async {
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
        name: 'Kirchl Wall',
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
          captureLatitude: Value(withGps ? 47.0 + i * 0.0005 : null),
          captureLongitude: Value(withGps ? 12.0 + i * 0.0005 : null),
          captureAccuracyMeters: Value(withGps ? 4 : null),
        ),
      );
    }
  }

  ProviderContainer makeContainer() => ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(db),
      nowMsProvider.overrideWithValue(() => 1000),
    ],
  );

  Widget wrap(ProviderContainer container) => UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: MasiTheme.light,
      home: const LayoutEditorScreen(wallId: wallId),
    ),
  );

  testWidgets('a guessed line says so, and the notice can be dismissed '
      'without blocking anything', (tester) async {
    await seed();
    final container = makeContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(wrap(container));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('layout-confidence-banner')), findsOneWidget);
    expect(find.byKey(const Key('layout-canvas')), findsOneWidget);

    await tester.tap(find.byKey(const Key('layout-banner-dismiss')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('layout-confidence-banner')), findsNothing);
    expect(
      find.byKey(const Key('layout-canvas')),
      findsOneWidget,
      reason: 'dismissing a hint must never take the editor with it',
    );
  });

  testWidgets('Accept promotes the guess to an authored line, and the notice '
      'goes with it', (tester) async {
    await seed(withGps: true);
    final container = makeContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(wrap(container));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('layout-confidence-banner')), findsOneWidget);

    // The editor is a scrolling column; on the default test surface the
    // action row sits below the fold.
    await tester.ensureVisible(find.byKey(const Key('layout-accept')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('layout-accept')));
    await tester.pumpAndSettle();

    final wall = await (db.select(db.walls)
          ..where((t) => t.id.equals(wallId)))
        .getSingle();
    expect(
      wall.baselineJson,
      isNotNull,
      reason: 'accepting is an edit — it stops the line being re-guessed, and '
          'silently changing, the next time a photo is added',
    );
    expect(Baseline.decode(wall.baselineJson), isNotNull);
    expect(wall.dirty, isTrue, reason: 'the stroke has to reach the cloud');

    // Once authored, the line is no longer a guess.
    expect(find.byKey(const Key('layout-confidence-banner')), findsNothing);
  });

  testWidgets('a wall with no photos explains itself instead of rendering an '
      'empty canvas', (tester) async {
    await seed(photos: 0);
    final container = makeContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(wrap(container));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('layout-canvas')), findsNothing);
    expect(find.textContaining('Add a photo'), findsOneWidget);
  });

  testWidgets('the capture-order rail lists every face and selecting one '
      'reports how it was placed', (tester) async {
    await seed();
    final container = makeContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(wrap(container));
    await tester.pumpAndSettle();

    for (var i = 0; i < 3; i++) {
      expect(find.byKey(Key('layout-order-photo-$i')), findsOneWidget);
    }

    await tester.tap(find.byKey(const Key('layout-order-photo-1')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('layout-selected-placement')),
      findsOneWidget,
    );
    expect(find.text('Placed in capture order'), findsOneWidget);
    expect(
      find.byKey(const Key('layout-unpin')),
      findsNothing,
      reason: 'nothing has been dragged, so there is no pin to remove',
    );
  });
}
