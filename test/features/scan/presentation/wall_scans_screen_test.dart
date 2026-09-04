import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:masi/app/theme.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/features/account/application/auth_providers.dart';
import 'package:masi/features/scan/application/rock_scan_providers.dart';
import 'package:masi/features/scan/data/rock_scan_remote.dart';
import 'package:masi/features/scan/presentation/wall_scans_screen.dart';

class _FakeRemote implements RockScanRemote {
  final List<String> uploaded = [];

  @override
  Future<String> uploadVideo({
    required String uid,
    required String scanId,
    required Uint8List bytes,
  }) async {
    uploaded.add(scanId);
    return rockScanVideoObjectPath(uid, scanId);
  }

  @override
  Future<Uint8List?> downloadCloud(String objectPath) async => null;
}

void main() {
  late AppDatabase db;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    await db.into(db.areas).insert(
          AreasCompanion.insert(
            id: 'area-1',
            createdAt: 1,
            updatedAt: 1,
            name: 'Area',
          ),
        );
    await db.into(db.sectors).insert(
          SectorsCompanion.insert(
            id: 'sector-1',
            createdAt: 1,
            updatedAt: 1,
            areaId: 'area-1',
            name: 'Sector',
            sortOrder: 0,
          ),
        );
    await db.into(db.walls).insert(
          WallsCompanion.insert(
            id: 'wall-1',
            createdAt: 1,
            updatedAt: 1,
            sectorId: 'sector-1',
            name: 'Sunny Slab',
            sortOrder: 0,
          ),
        );
  });

  tearDown(() => db.close());

  Future<void> seedScan({
    required String id,
    String uploadState = 'uploaded',
    String status = 'pending',
    String? failureReason,
    String? manifestJson,
    int? sizeBytes,
    int createdAt = 100,
  }) async {
    await db.into(db.rockScans).insert(
          RockScansCompanion.insert(
            id: id,
            createdAt: createdAt,
            updatedAt: createdAt,
            wallId: 'wall-1',
            ownerId: const Value('uid-1'),
            uploadState: Value(uploadState),
            status: Value(status),
            failureReason: Value(failureReason),
            manifestJson: Value(manifestJson),
            sizeBytes: Value(sizeBytes),
          ),
        );
  }

  Future<void> pump(
    WidgetTester tester, {
    RockScanRemote? remote,
    Future<XFile?> Function(ImageSource)? pickVideo,
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // An explicit container disposed in teardown, rather than a bare
    // `ProviderScope`, matching every other screen test here. It matters:
    // this screen holds a drift stream subscription, and letting the widget
    // tree own the container leaves that subscription's timer pending past
    // the end of the test, which flutter_test reports as "A Timer is still
    // pending" and which then wedges the whole test harness.
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        nowMsProvider.overrideWithValue(() => 1000),
        currentUidProvider.overrideWithValue(() => 'uid-1'),
        rockScanRemoteProvider.overrideWithValue(remote ?? _FakeRemote()),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: MasiTheme.light,
          home: WallScansScreen(
            wallId: 'wall-1',
            pickVideo: pickVideo ?? (_) async => null,
          ),
        ),
      ),
    );
    // NOT pumpAndSettle: the in-progress phases render an indeterminate
    // CircularProgressIndicator, whose animation never ends, so settling
    // would wait forever.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('empty state invites a capture and says the topo is unaffected',
      (tester) async {
    await pump(tester);

    expect(find.text('No scans yet'), findsOneWidget);
    expect(
      find.textContaining('Your topo works exactly the same'),
      findsOneWidget,
      reason: 'a scan must never read as something the topo depends on',
    );
    expect(find.byKey(const Key('scan-capture-button')), findsOneWidget);
  });

  testWidgets('shows the wall name it is scanning', (tester) async {
    await pump(tester);
    expect(find.text('Sunny Slab'), findsOneWidget);
  });

  testWidgets('a queued scan reads as work in progress, with no ETA',
      (tester) async {
    await seedScan(id: 'scan-1');
    await pump(tester);

    expect(find.text('Building the 3D model'), findsOneWidget);
    // Nothing on the device knows the worker's queue depth, so any estimate
    // would be invented.
    expect(find.textContaining('minute'), findsNothing);
    expect(find.textContaining('%'), findsNothing);
  });

  testWidgets('a failed reconstruction shows the worker\'s own words',
      (tester) async {
    await seedScan(
      id: 'scan-1',
      status: 'failed',
      failureReason: 'Not enough overlap between frames — move more slowly.',
    );
    await pump(tester);

    expect(
      find.textContaining('Not enough overlap between frames'),
      findsOneWidget,
    );
  });

  testWidgets('a ready scan reports its point count and opens', (tester) async {
    await seedScan(
      id: 'scan-1',
      status: 'ready',
      manifestJson: '{"version":1,"pointCount":84213}',
    );
    await pump(tester);

    expect(find.text('3D model ready'), findsOneWidget);
    expect(find.textContaining('84 213'), findsOneWidget);
  });

  testWidgets('only a ready scan is tappable', (tester) async {
    await seedScan(id: 'scan-1', status: 'pending');
    await pump(tester);

    // `.first` is the tile's own InkWell; the delete IconButton contributes
    // another one deeper in the subtree.
    final tile = tester.widget<InkWell>(
      find
          .descendant(
            of: find.byKey(const Key('scan-tile-scan-1')),
            matching: find.byType(InkWell),
          )
          .first,
    );
    expect(
      tile.onTap,
      isNull,
      reason: 'tapping a processing scan and landing on an empty viewer '
          'teaches the user the viewer is broken',
    );
  });

  testWidgets('cancelling the picker creates no scan', (tester) async {
    final remote = _FakeRemote();
    await pump(tester, remote: remote, pickVideo: (_) async => null);

    await tester.tap(find.byKey(const Key('scan-capture-button')));
    await tester.pump(const Duration(milliseconds: 350));
    // The sheet is up; dismiss it by choosing a source, then the picker
    // returns null.
    await tester.tap(find.byKey(const Key('scan-source-gallery')));
    await tester.pump(const Duration(milliseconds: 350));

    expect(await db.select(db.rockScans).get(), isEmpty);
    expect(remote.uploaded, isEmpty);
  });

  testWidgets('the capture sheet says what a usable pass looks like',
      (tester) async {
    await pump(tester);

    await tester.tap(find.byKey(const Key('scan-capture-button')));
    await tester.pump(const Duration(milliseconds: 350));

    // Every controllable failure mode of the reconstruction is on this sheet.
    expect(find.textContaining('Walk slowly'), findsOneWidget);
    expect(find.textContaining('30–45 seconds'), findsOneWidget);
    expect(find.byKey(const Key('scan-source-gallery')), findsOneWidget);
  });

  testWidgets('deleting a scan removes it from the list', (tester) async {
    await seedScan(id: 'scan-1', status: 'ready');
    await pump(tester);
    expect(find.byKey(const Key('scan-tile-scan-1')), findsOneWidget);

    await tester.tap(find.byKey(const Key('scan-delete-scan-1')));
    await tester.pump(const Duration(milliseconds: 350));

    expect(find.byKey(const Key('scan-tile-scan-1')), findsNothing);
    final row = await (db.select(
      db.rockScans,
    )..where((t) => t.id.equals('scan-1'))).getSingle();
    expect(
      row.deletedAt,
      isNotNull,
      reason: 'a tombstone, so the deletion reaches the other devices',
    );
  });

  testWidgets('newest scan first', (tester) async {
    await seedScan(id: 'older', createdAt: 100, status: 'ready');
    await seedScan(id: 'newer', createdAt: 200, status: 'ready');
    await pump(tester);

    final olderY = tester.getTopLeft(find.byKey(const Key('scan-tile-older')));
    final newerY = tester.getTopLeft(find.byKey(const Key('scan-tile-newer')));
    expect(newerY.dy, lessThan(olderY.dy));
  });
}
