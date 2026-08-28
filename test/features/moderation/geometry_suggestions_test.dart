// Geometry suggestions (community editing phase 7b / C-5b).
//
// Phase 7a's tests guard the apply path for metadata. These guard the two
// things geometry adds that a typo fix has no equivalent of.
//
// The first is IDENTITY. Points are percent-space fractions of ONE image, and
// `TopoRoute.id` is an int the loader reassigns 1..n on every read. So a
// proposal that loses its photo, or that names a route by the local int, is
// not a degraded suggestion — it is a line drawn on the wrong picture, or a
// different route's shape replaced. Both look completely normal right up until
// the owner accepts.
//
// The second is that ACCEPTING IS DESTRUCTIVE in a way accepting a name is
// not. A metadata patch that arrives half-decoded writes a wrong string; a
// geometry patch that arrives half-decoded replaces a climbing line. Most of
// what follows is about refusing rather than degrading.


import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/features/account/application/auth_providers.dart';
import 'package:masi/features/library/application/library_providers.dart';
import 'package:masi/features/library/data/library_crud_repository.dart';
import 'package:masi/features/moderation/application/suggestion_providers.dart';
import 'package:masi/features/moderation/data/suggestions_remote.dart';
import 'package:masi/features/moderation/domain/edit_suggestion.dart';
import 'package:masi/features/moderation/domain/geometry_proposal.dart';
import 'package:masi/features/topo/data/route_mapper.dart';
import 'package:masi/features/topo/domain/topo_route.dart';

Map<String, dynamic> _geometryRow({
  String id = 'g1',
  Map<String, dynamic>? patch,
  String? photoId = 'photo-1',
  String? routeId,
}) => {
  'id': id,
  'wallId': 'wall-1',
  'wallName': 'Dolomitici',
  'routeId': routeId,
  'routeName': routeId == null ? null : 'Alma',
  'photoId': photoId,
  'authorId': 'u1',
  'authorName': 'Kata',
  'kind': 'route.geometry',
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

class _FakeSuggestions implements SuggestionsRemote {
  final filed = <({String wallId, String? routeId, String? photoId})>[];
  final resolved = <(String, bool)>[];

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
    filed.add((wallId: wallId, routeId: routeId, photoId: photoId));
    return 'new';
  }

  @override
  Future<String> resolve({
    required String suggestionId,
    required bool accept,
    String? note,
  }) async {
    resolved.add((suggestionId, accept));
    return accept ? 'accepted' : 'rejected';
  }
}

void main() {
  group('a proposal on the wire', () {
    test('round-trips through the patch it is stored as', () {
      const original = GeometryProposal(
        points: [Offset(0.1, 0.2), Offset(0.3, 0.4), Offset(0.5, 0.95)],
      );
      final back = GeometryProposal.fromPatch(original.toPatch())!;
      expect(back.points, original.points);
    });

    test('one point is not a line, and is refused rather than drawn', () {
      expect(
        GeometryProposal.fromPatch({
          'points': [
            {'x': 0.5, 'y': 0.5},
          ],
        }),
        isNull,
      );
    });

    test(
      'a point off the photo refuses the WHOLE proposal, not just that point. '
      'Dropping it would silently reshape the line into one nobody drew',
      () {
        expect(
          GeometryProposal.fromPatch({
            'points': [
              {'x': 0.5, 'y': 0.5},
              {'x': 1.4, 'y': 0.5},
            ],
          }),
          isNull,
        );
      },
    );

    test('a line past the point cap is refused, matching the server', () {
      expect(
        GeometryProposal.fromPatch({
          'points': [
            for (var i = 0; i <= kMaxProposedPoints; i++) {'x': 0.5, 'y': 0.5},
          ],
        }),
        isNull,
      );
    });

    test(
      'NO symbols key means null, not an empty list. That distinction is what '
      'stops accepting a corrected LINE from wiping the bolts on the route',
      () {
        final proposal = GeometryProposal.fromPatch({
          'points': [
            {'x': 0.1, 'y': 0.1},
            {'x': 0.2, 'y': 0.2},
          ],
        })!;
        expect(proposal.symbols, isNull);
      },
    );

    test('an explicitly empty symbols list stays an empty list', () {
      final proposal = GeometryProposal.fromPatch({
        'points': [
          {'x': 0.1, 'y': 0.1},
          {'x': 0.2, 'y': 0.2},
        ],
        'symbols': <Object?>[],
      })!;
      expect(proposal.symbols, isEmpty);
      expect(proposal.symbols, isNotNull);
    });

    test(
      'an unknown marker TYPE is dropped while the rest survive — the same '
      'thing route_mapper does for stored routes, and for the same reason: it '
      'is what lets a topo outlive a marker type the app has removed',
      () {
        final proposal = GeometryProposal.fromPatch({
          'points': [
            {'x': 0.1, 'y': 0.1},
            {'x': 0.2, 'y': 0.2},
          ],
          'symbols': [
            {'type': 'rest', 'x': 0.1, 'y': 0.1},
            {'type': 'anchor', 'x': 0.2, 'y': 0.2},
          ],
        })!;
        expect(proposal.symbols, hasLength(1));
        expect(proposal.symbols!.single.type, SymbolType.anchor);
      },
    );

    test('a marker with unreadable coordinates refuses the proposal', () {
      expect(
        GeometryProposal.fromPatch({
          'points': [
            {'x': 0.1, 'y': 0.1},
            {'x': 0.2, 'y': 0.2},
          ],
          'symbols': [
            {'type': 'anchor', 'x': 'over there', 'y': 0.2},
          ],
        }),
        isNull,
      );
    });

    test('a proposal with only one point is not drawable', () {
      const one = GeometryProposal(points: [Offset(0.5, 0.5)]);
      expect(one.isDrawable, isFalse);
    });
  });

  group('reading a geometry suggestion off the wire', () {
    test('parses, and carries the photo it was drawn on', () {
      final s = EditSuggestion.fromRow(_geometryRow())!;
      expect(s.kind, SuggestionKind.routeGeometry);
      expect(s.photoId, 'photo-1');
      expect(s.geometry!.points, hasLength(2));
    });

    test(
      'reports NO textual changes. "points: [Offset(0.4, 0.1), …]" renders the '
      'patch faithfully and tells the owner nothing they can decide on — the '
      'inbox draws it instead (C-5b, requirement 3)',
      () {
        final s = EditSuggestion.fromRow(_geometryRow())!;
        expect(s.changes, isEmpty);
      },
    );

    test('a geometry row with NO photo is dropped, not shown unpositioned', () {
      expect(EditSuggestion.fromRow(_geometryRow(photoId: null)), isNull);
    });

    test('a geometry row whose line will not decode is dropped', () {
      expect(
        EditSuggestion.fromRow(
          _geometryRow(
            patch: {
              'points': [
                {'x': 0.5, 'y': 0.5},
              ],
            },
          ),
        ),
        isNull,
      );
    });

    test('a field off the whitelist is stripped before it can be applied', () {
      final s = EditSuggestion.fromRow(
        _geometryRow(
          patch: {
            'points': [
              {'x': 0.1, 'y': 0.1},
              {'x': 0.2, 'y': 0.2},
            ],
            'ownerId': 'attacker',
          },
        ),
      )!;
      expect(s.patch.keys, ['points']);
    });

    test('no route named means a line the topo does not have', () {
      expect(EditSuggestion.fromRow(_geometryRow())!.isNewLine, isTrue);
      expect(
        EditSuggestion.fromRow(_geometryRow(routeId: 'route-1'))!.isNewLine,
        isFalse,
      );
    });

    test('a metadata suggestion still reports its changes as text', () {
      final s = EditSuggestion.fromRow({
        ..._geometryRow(),
        'kind': 'topo.metadata',
        'patch': {'name': 'Corrected'},
      })!;
      expect(s.changes.single.value, 'Corrected');
    });
  });

  group('applying an accepted line', () {
    late AppDatabase db;
    late LibraryCrudRepository repo;
    late ProviderContainer container;
    late _FakeSuggestions remote;

    const wallId = 'wall-1';
    const photoId = 'photo-1';
    const otherPhotoId = 'photo-2';
    const routeId = 'route-1';

    Future<void> seed() async {
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
              id: wallId,
              createdAt: 100,
              updatedAt: 100,
              sectorId: 'sector-1',
              name: 'Wall',
              sortOrder: 0,
            ),
          );
      for (final id in [photoId, otherPhotoId]) {
        await db
            .into(db.photos)
            .insert(
              PhotosCompanion.insert(
                id: id,
                createdAt: 100,
                updatedAt: 100,
                wallId: wallId,
                localPath: '/tmp/$id.jpg',
                kind: 'original',
                width: 800,
                height: 600,
              ),
            );
      }
      await db
          .into(db.routes)
          .insert(
            RoutesCompanion.insert(
              id: routeId,
              createdAt: 100,
              updatedAt: 100,
              wallId: wallId,
              photoId: photoId,
              number: 1,
              colorIndex: 0,
              pointsJson: '[{"x":0.1,"y":0.1},{"x":0.2,"y":0.9}]',
              symbolsJson: '[{"type":"anchor","x":0.2,"y":0.9}]',
              sortOrder: 1,
            ),
          );
    }

    Future<Route> routeRow(String id) =>
        (db.select(db.routes)..where((t) => t.id.equals(id))).getSingle();

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      repo = LibraryCrudRepository(db, nowMs: () => 5000);
      remote = _FakeSuggestions();
      container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          nowMsProvider.overrideWithValue(() => 5000),
          libraryCrudRepositoryProvider.overrideWithValue(repo),
          suggestionsRemoteProvider.overrideWithValue(remote),
          effectiveUidProvider.overrideWithValue(null),
        ],
      );
      await seed();
    });

    tearDown(() async {
      container.dispose();
      await db.close();
    });

    test('replacing a line writes the points and marks the row dirty', () async {
      await repo.applyRouteGeometry(
        wallId: wallId,
        photoId: photoId,
        routeId: routeId,
        points: const [Offset(0.5, 0.1), Offset(0.6, 0.9)],
      );

      final row = await routeRow(routeId);
      expect(decodePoints(row.pointsJson), const [
        Offset(0.5, 0.1),
        Offset(0.6, 0.9),
      ]);
      expect(row.dirty, isTrue);
      expect(row.updatedAt, 5000);
    });

    test(
      'a proposal that says nothing about markers LEAVES THEM ALONE. This is '
      'the destructive default: collapsing "no markers proposed" to an empty '
      'list would delete every bolt on the route as a side effect of fixing '
      'its shape, with nobody having asked for that or reviewed it',
      () async {
        await repo.applyRouteGeometry(
          wallId: wallId,
          photoId: photoId,
          routeId: routeId,
          points: const [Offset(0.5, 0.1), Offset(0.6, 0.9)],
        );

        final row = await routeRow(routeId);
        expect(decodeSymbols(row.symbolsJson), hasLength(1));
        expect(decodeSymbols(row.symbolsJson).single.type, SymbolType.anchor);
      },
    );

    test('markers that ARE proposed replace the existing ones', () async {
      await repo.applyRouteGeometry(
        wallId: wallId,
        photoId: photoId,
        routeId: routeId,
        points: const [Offset(0.5, 0.1), Offset(0.6, 0.9)],
        symbols: const [
          TopoSymbol(type: SymbolType.bolt, position: Offset(0.55, 0.5)),
        ],
      );

      final symbols = decodeSymbols((await routeRow(routeId)).symbolsJson);
      expect(symbols.single.type, SymbolType.bolt);
    });

    test('fewer than two points writes nothing at all', () async {
      final before = await routeRow(routeId);
      await repo.applyRouteGeometry(
        wallId: wallId,
        photoId: photoId,
        routeId: routeId,
        points: const [Offset(0.5, 0.1)],
      );

      final after = await routeRow(routeId);
      expect(after.pointsJson, before.pointsJson);
      expect(after.updatedAt, before.updatedAt);
    });

    test(
      'a route named against the WRONG photo is not written. Percent-space '
      'points normalised to one image mean something else entirely on '
      'another, so this would move a route onto a picture it was never drawn '
      'against',
      () async {
        final before = await routeRow(routeId);
        await repo.applyRouteGeometry(
          wallId: wallId,
          photoId: otherPhotoId,
          routeId: routeId,
          points: const [Offset(0.5, 0.1), Offset(0.6, 0.9)],
        );

        final after = await routeRow(routeId);
        expect(after.pointsJson, before.pointsJson);
      },
    );

    test('a NEW line inserts, numbered after this photo\'s last route', () async {
      await repo.applyRouteGeometry(
        wallId: wallId,
        photoId: photoId,
        points: const [Offset(0.7, 0.1), Offset(0.8, 0.9)],
      );

      final rows =
          await (db.select(db.routes)
                ..where((t) => t.photoId.equals(photoId)))
              .get();
      expect(rows, hasLength(2));
      final added = rows.firstWhere((r) => r.id != routeId);
      expect(added.number, 2);
      expect(added.wallId, wallId);
      expect(added.dirty, isTrue);
      expect(decodeSymbols(added.symbolsJson), isEmpty);
    });

    test(
      'numbering is PER WALL, so a line added to the second photo takes the '
      'next free number on the wall rather than colliding with the first '
      "photo's route 1",
      () async {
        await repo.applyRouteGeometry(
          wallId: wallId,
          photoId: otherPhotoId,
          points: const [Offset(0.7, 0.1), Offset(0.8, 0.9)],
        );

        final rows =
            await (db.select(db.routes)
                  ..where((t) => t.photoId.equals(otherPhotoId)))
                .get();
        expect(
          rows.single.number,
          2,
          reason: 'the wall already has a route 1, on the other photo',
        );
      },
    );

    test('accept applies the line FIRST, then records the decision', () async {
      final suggestion = EditSuggestion.fromRow(
        _geometryRow(
          routeId: routeId,
          patch: {
            'points': [
              {'x': 0.5, 'y': 0.1},
              {'x': 0.6, 'y': 0.9},
            ],
          },
        ),
      )!;

      await container.read(suggestionServiceProvider).accept(suggestion);

      expect(decodePoints((await routeRow(routeId)).pointsJson), const [
        Offset(0.5, 0.1),
        Offset(0.6, 0.9),
      ]);
      expect(remote.resolved, [('g1', true)]);
    });

    test('declining a line writes nothing to the topo', () async {
      final before = await routeRow(routeId);
      final suggestion = EditSuggestion.fromRow(
        _geometryRow(routeId: routeId),
      )!;

      await container.read(suggestionServiceProvider).reject(suggestion);

      expect((await routeRow(routeId)).pointsJson, before.pointsJson);
      expect(remote.resolved, [('g1', false)]);
    });

    test('filing a line sends the photo it was drawn on', () async {
      await container
          .read(suggestionServiceProvider)
          .suggest(
            wallId: wallId,
            kind: SuggestionKind.routeGeometry,
            patch: const GeometryProposal(
              points: [Offset(0.1, 0.1), Offset(0.2, 0.2)],
            ).toPatch(),
            routeId: routeId,
            photoId: photoId,
          );

      expect(remote.filed.single.photoId, photoId);
      expect(
        remote.filed.single.routeId,
        routeId,
        reason: 'the DATABASE uuid, never the reassigned TopoRoute.id',
      );
    });
  });
}
