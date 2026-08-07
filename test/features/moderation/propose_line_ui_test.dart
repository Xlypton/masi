// The propose-mode canvas (community editing phase 7b / C-5b, requirement 4).
//
// The thing worth testing here is not that taps become points. It is that this
// screen CANNOT WRITE TO THE TOPO. Phase 7a's rule — non-owners have no write
// access to any content table — is what keeps the sync engine simple, and a
// drawing surface pointed at somebody else's topo is the most plausible place
// in the whole plan to lose it by accident. So the first test in this file
// draws a whole line and then asserts the routes table is untouched.
//
// After that: the target chip, because "correcting route 3" and "adding a
// line" are identical gestures with completely different consequences, and the
// screen has to say which one is happening before it happens.

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:masi/app/theme.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/features/account/application/auth_providers.dart';
import 'package:masi/features/moderation/application/suggestion_providers.dart';
import 'package:masi/features/moderation/data/suggestions_remote.dart';
import 'package:masi/features/moderation/domain/edit_suggestion.dart';
import 'package:masi/features/moderation/presentation/propose_line_screen.dart';
import 'package:masi/features/moderation/presentation/topo_line_view.dart';

class _RecordingRemote implements SuggestionsRemote {
  final filed =
      <({String wallId, String? routeId, String? photoId, Map<String, Object?> patch})>[];

  @override
  Future<List<Map<String, dynamic>>> fetchForMe({int limit = 50}) async =>
      const [];

  @override
  Future<String> suggest({
    required String wallId,
    required SuggestionKind kind,
    required Map<String, Object?> patch,
    String? note,
    String? routeId,
    String? photoId,
  }) async {
    filed.add((
      wallId: wallId,
      routeId: routeId,
      photoId: photoId,
      patch: patch,
    ));
    return 'new';
  }

  @override
  Future<String> resolve({
    required String suggestionId,
    required bool accept,
    String? note,
  }) async => 'accepted';
}

const _wallId = 'wall-1';
const _photoId = 'photo-1';
const _routeId = 'route-1';

Future<void> _seed(AppDatabase db, {bool withPhoto = true}) async {
  await db
      .into(db.areas)
      .insert(
        AreasCompanion.insert(
          id: 'area-1',
          createdAt: 100,
          updatedAt: 100,
          name: 'Area',
        ),
      );
  await db
      .into(db.sectors)
      .insert(
        SectorsCompanion.insert(
          id: 'sector-1',
          createdAt: 100,
          updatedAt: 100,
          areaId: 'area-1',
          name: 'Sector',
          sortOrder: 0,
        ),
      );
  await db
      .into(db.walls)
      .insert(
        WallsCompanion.insert(
          id: _wallId,
          createdAt: 100,
          updatedAt: 100,
          sectorId: 'sector-1',
          name: 'Dolomitici',
          sortOrder: 0,
          visibility: const Value('shared'),
        ),
      );
  if (!withPhoto) return;
  await db
      .into(db.photos)
      .insert(
        PhotosCompanion.insert(
          id: _photoId,
          createdAt: 100,
          updatedAt: 100,
          wallId: _wallId,
          localPath: '/tmp/does-not-exist.jpg',
          kind: 'original',
          width: 400,
          height: 800,
        ),
      );
  await db
      .into(db.routes)
      .insert(
        RoutesCompanion.insert(
          id: _routeId,
          createdAt: 100,
          updatedAt: 100,
          wallId: _wallId,
          photoId: _photoId,
          number: 1,
          colorIndex: 0,
          pointsJson: '[{"x":0.1,"y":0.1},{"x":0.2,"y":0.9}]',
          symbolsJson: '[]',
          sortOrder: 1,
          name: const Value('Alma'),
        ),
      );
}

ProviderContainer _container(AppDatabase db, SuggestionsRemote remote) =>
    ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        nowMsProvider.overrideWithValue(() => 5000),
        suggestionsRemoteProvider.overrideWithValue(remote),
        effectiveUidProvider.overrideWithValue('reader-uid'),
      ],
    );

Widget _wrap(ProviderContainer container) => UncontrolledProviderScope(
  container: container,
  child: MaterialApp(
    theme: MasiTheme.light,
    home: const ProposeLineScreen(wallId: _wallId, topoName: 'Dolomitici'),
  ),
);

/// Taps the canvas at a fraction of its box.
Future<void> _tapCanvas(WidgetTester tester, double fx, double fy) async {
  final box = tester.getRect(find.byKey(const Key('propose-line-canvas')));
  await tester.tapAt(
    Offset(box.left + box.width * fx, box.top + box.height * fy),
  );
  await tester.pump();
}

void main() {
  late AppDatabase db;
  late _RecordingRemote remote;
  late ProviderContainer container;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    remote = _RecordingRemote();
    container = _container(db, remote);
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  testWidgets(
    'drawing a whole line writes NOTHING to the routes table. This screen '
    'produces a suggestion row and nothing else — a non-owner has no write '
    'access to any content table, and a drawing surface is the likeliest '
    'place in the plan to lose that by accident',
    (tester) async {
      await tester.runAsync(() => _seed(db));
      await tester.pumpWidget(_wrap(container));
      await tester.pumpAndSettle();

      await _tapCanvas(tester, 0.5, 0.2);
      await _tapCanvas(tester, 0.55, 0.5);
      await _tapCanvas(tester, 0.6, 0.8);

      final routes = await db.select(db.routes).get();
      expect(routes, hasLength(1));
      expect(routes.single.pointsJson, '[{"x":0.1,"y":0.1},{"x":0.2,"y":0.9}]');
      expect(routes.single.dirty, isFalse);
    },
  );

  testWidgets('Send stays disabled until there is an actual line', (
    tester,
  ) async {
    await tester.runAsync(() => _seed(db));
    await tester.pumpWidget(_wrap(container));
    await tester.pumpAndSettle();

    ElevatedButton send() =>
        tester.widget<ElevatedButton>(find.byType(ElevatedButton).first);

    expect(send().onPressed, isNull);

    await _tapCanvas(tester, 0.5, 0.2);
    expect(
      send().onPressed,
      isNull,
      reason: 'one point is a tap, not a line — the server refuses it too',
    );

    await _tapCanvas(tester, 0.5, 0.8);
    expect(send().onPressed, isNotNull);
  });

  testWidgets('undo removes the last point, clear removes all of them', (
    tester,
  ) async {
    await tester.runAsync(() => _seed(db));
    await tester.pumpWidget(_wrap(container));
    await tester.pumpAndSettle();

    await _tapCanvas(tester, 0.5, 0.2);
    await _tapCanvas(tester, 0.5, 0.5);
    await _tapCanvas(tester, 0.5, 0.8);
    expect(_proposedPoints(tester), hasLength(3));

    await tester.tap(find.byKey(const Key('propose-line-undo')));
    await tester.pump();
    expect(_proposedPoints(tester), hasLength(2));

    await tester.tap(find.byKey(const Key('propose-line-clear')));
    await tester.pump();
    expect(_proposedPoints(tester), isEmpty);
  });

  testWidgets(
    'picking a route to fix DROPS it from the underlay, so what is on screen '
    'is what accepting would produce rather than two lines to tell apart',
    (tester) async {
      await tester.runAsync(() => _seed(db));
      await tester.pumpWidget(_wrap(container));
      await tester.pumpAndSettle();

      expect(_canvas(tester).replacedRouteNumber, isNull);
      expect(_canvas(tester).routes, hasLength(1));

      await tester.tap(find.byKey(const Key('propose-line-target-1')));
      await tester.pump();

      expect(_canvas(tester).replacedRouteNumber, 1);
    },
  );

  testWidgets(
    'sending a correction names the route by its DATABASE uuid, never by the '
    'int the loader reassigns 1..n on every read (C-5b, requirement 2)',
    (tester) async {
      await tester.runAsync(() => _seed(db));
      await tester.pumpWidget(_wrap(container));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('propose-line-target-1')));
      await tester.pump();
      await _tapCanvas(tester, 0.5, 0.2);
      await _tapCanvas(tester, 0.5, 0.8);

      await tester.enterText(
        find.byKey(const Key('propose-line-note-field')),
        'the second half traverses right',
      );
      await tester.tap(find.byKey(const Key('propose-line-send')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(remote.filed, hasLength(1));
      expect(remote.filed.single.routeId, _routeId);
      expect(remote.filed.single.photoId, _photoId);
      expect(remote.filed.single.patch['points'], hasLength(2));
    },
  );

  testWidgets('a new line is filed with no route named at all', (tester) async {
    await tester.runAsync(() => _seed(db));
    await tester.pumpWidget(_wrap(container));
    await tester.pumpAndSettle();

    await _tapCanvas(tester, 0.5, 0.2);
    await _tapCanvas(tester, 0.5, 0.8);
    await tester.tap(find.byKey(const Key('propose-line-send')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(remote.filed.single.routeId, isNull);
  });

  testWidgets(
    'a topo with no photo says so instead of showing an empty canvas — there '
    'is nothing to draw on, which is a real state rather than a failure',
    (tester) async {
      await tester.runAsync(() => _seed(db, withPhoto: false));
      await tester.pumpWidget(_wrap(container));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('propose-line-no-photo')), findsOneWidget);
      expect(find.byKey(const Key('propose-line-canvas')), findsNothing);
    },
  );
}

TopoLineView _canvas(WidgetTester tester) =>
    tester.widget<TopoLineView>(find.byKey(const Key('propose-line-canvas')));

List<Offset> _proposedPoints(WidgetTester tester) =>
    _canvas(tester).proposedPoints;
