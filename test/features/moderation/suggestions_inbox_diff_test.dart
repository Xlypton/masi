// The owner's side of a geometry suggestion (community editing phase 7b /
// C-5b, requirement 3).
//
// "A visual diff, not a JSON diff" is the requirement, and the failure it
// exists to prevent is specific: an owner shown `points: [Offset(0.4, 0.1), …]`
// has an Apply button and no way to decide, so they either accept blind or
// leave it in the pile forever. Both outcomes are worse than not offering the
// feature.
//
// So these tests are mostly about what happens when the picture ISN'T there.
// A row that renders a proposal it cannot draw, with a working Apply button,
// is the phase-7a row's behaviour and is exactly the bug.

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:masi/app/theme.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/features/account/application/auth_providers.dart';
import 'package:masi/features/moderation/application/suggestion_providers.dart';
import 'package:masi/features/moderation/data/suggestions_remote.dart';
import 'package:masi/features/moderation/domain/edit_suggestion.dart';
import 'package:masi/features/moderation/presentation/suggestions_inbox_screen.dart';
import 'package:masi/features/moderation/presentation/topo_line_view.dart';
import 'package:masi/shared/presentation/masi_pending_button.dart';

const _wallId = 'wall-1';
const _photoId = 'photo-1';
const _routeId = 'route-1';

Map<String, dynamic> _row({
  String kind = 'route.geometry',
  String? photoId = _photoId,
  String? routeId,
  Map<String, dynamic>? patch,
}) => {
  'id': 'g1',
  'wallId': _wallId,
  'wallName': 'Dolomitici',
  'routeId': routeId,
  'routeName': routeId == null ? null : 'Alma',
  'photoId': photoId,
  'authorId': 'u1',
  'authorName': 'Kata',
  'kind': kind,
  'patch':
      patch ??
      {
        'points': [
          {'x': 0.4, 'y': 0.1},
          {'x': 0.45, 'y': 0.9},
        ],
      },
  'note': null,
  'isStale': false,
  'createdAt': 1000,
};

class _StubRemote implements SuggestionsRemote {
  _StubRemote(this.rows);
  final List<Map<String, dynamic>> rows;

  @override
  Future<List<Map<String, dynamic>>> fetchForMe({int limit = 50}) async => rows;

  @override
  Future<String> suggest({
    required String wallId,
    required SuggestionKind kind,
    required Map<String, Object?> patch,
    String? note,
    String? routeId,
    String? photoId,
  }) async => 'new';

  @override
  Future<String> resolve({
    required String suggestionId,
    required bool accept,
    String? note,
  }) async => 'accepted';
}

Future<void> _seed(AppDatabase db, {bool withPhoto = true}) async {
  await db.into(db.areas).insert(
    AreasCompanion.insert(
      id: 'area-1',
      createdAt: 100,
      updatedAt: 100,
      name: 'Area',
    ),
  );
  await db.into(db.sectors).insert(
    SectorsCompanion.insert(
      id: 'sector-1',
      createdAt: 100,
      updatedAt: 100,
      areaId: 'area-1',
      name: 'Sector',
      sortOrder: 0,
    ),
  );
  await db.into(db.walls).insert(
    WallsCompanion.insert(
      id: _wallId,
      createdAt: 100,
      updatedAt: 100,
      sectorId: 'sector-1',
      name: 'Dolomitici',
      sortOrder: 0,
    ),
  );
  if (!withPhoto) return;
  await db.into(db.photos).insert(
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
  await db.into(db.routes).insert(
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

Widget _wrap(ProviderContainer container) => UncontrolledProviderScope(
  container: container,
  child: MaterialApp.router(
    theme: MasiTheme.light,
    routerConfig: GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(path: '/', builder: (_, _) => const SuggestionsInboxScreen()),
        GoRoute(path: '/walls/:wallId', builder: (_, _) => const SizedBox()),
      ],
    ),
  ),
);

void main() {
  late AppDatabase db;

  ProviderContainer container(List<Map<String, dynamic>> rows) =>
      ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          nowMsProvider.overrideWithValue(() => 5000),
          suggestionsRemoteProvider.overrideWithValue(_StubRemote(rows)),
          effectiveUidProvider.overrideWithValue('owner-uid'),
        ],
      );

  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  testWidgets('a proposed line is DRAWN over the topo, not printed', (
    tester,
  ) async {
    await tester.runAsync(() => _seed(db));
    final c = container([_row()]);
    addTearDown(c.dispose);

    await tester.pumpWidget(_wrap(c));
    await tester.pumpAndSettle();

    final diff = tester.widget<TopoLineView>(
      find.byKey(const Key('suggestion-diff-g1')),
    );
    expect(diff.proposedPoints, hasLength(2));
    expect(diff.photo.id, _photoId);
    expect(
      diff.routes,
      hasLength(1),
      reason: 'the line already there is the thing being compared against',
    );
  });

  testWidgets(
    'no coordinates are printed anywhere. Rendering the patch faithfully as '
    'text is the failure this requirement exists to prevent',
    (tester) async {
      await tester.runAsync(() => _seed(db));
      final c = container([_row()]);
      addTearDown(c.dispose);

      await tester.pumpWidget(_wrap(c));
      await tester.pumpAndSettle();

      // `findRichText` is not optional here: the metadata row renders its
      // changes as `Text.rich` spans, which a plain text finder cannot see —
      // so without it this assertion would pass against a row that WAS
      // printing coordinates.
      expect(find.textContaining('0.4', findRichText: true), findsNothing);
      expect(find.textContaining('Offset', findRichText: true), findsNothing);
      expect(find.textContaining('points', findRichText: true), findsNothing);
    },
  );

  testWidgets(
    'a correction DROPS the line it replaces from the underlay — resolved '
    'from the database uuid back to the local number, never the other way '
    'round, which is the C-5b requirement-2 bug',
    (tester) async {
      await tester.runAsync(() => _seed(db));
      final c = container([_row(routeId: _routeId)]);
      addTearDown(c.dispose);

      await tester.pumpWidget(_wrap(c));
      await tester.pumpAndSettle();

      final diff = tester.widget<TopoLineView>(
        find.byKey(const Key('suggestion-diff-g1')),
      );
      expect(diff.replacedRouteNumber, 1);
    },
  );

  testWidgets(
    'a proposal whose photo is gone says so AND disables Apply. A line nobody '
    'can see is a line nobody can judge, and an enabled button over a blank '
    'box invites approving something unseen',
    (tester) async {
      await tester.runAsync(() => _seed(db, withPhoto: false));
      final c = container([_row()]);
      addTearDown(c.dispose);

      await tester.pumpWidget(_wrap(c));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('suggestion-diff-missing-g1')),
        findsOneWidget,
      );
      final apply = tester.widget<MasiPendingButton>(
        find.byKey(const Key('suggestion-accept-g1')),
      );
      expect(apply.onPressed, isNull);
    },
  );

  testWidgets('a metadata suggestion still reads as text, with no canvas', (
    tester,
  ) async {
    await tester.runAsync(() => _seed(db));
    final c = container([
      _row(kind: 'topo.metadata', photoId: null, patch: {'name': 'Corrected'}),
    ]);
    addTearDown(c.dispose);

    await tester.pumpWidget(_wrap(c));
    await tester.pumpAndSettle();

    // `textContaining`, because the row renders "Topo name: Corrected" as one
    // RichText of two differently-styled spans.
    expect(
      find.textContaining('Corrected', findRichText: true),
      findsOneWidget,
    );
    expect(find.byType(TopoLineView), findsNothing);
    final apply = tester.widget<MasiPendingButton>(
      find.byKey(const Key('suggestion-accept-g1')),
    );
    expect(
      apply.onPressed,
      isNotNull,
      reason: 'the geometry gate must not disable metadata suggestions',
    );
  });
}
