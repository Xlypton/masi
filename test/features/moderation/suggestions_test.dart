// Suggested edits, metadata slice (community editing phase 7a / C-5).
//
// The load-bearing part of this file is the APPLY path, because it is the only
// place in the whole community feature where somebody else's proposal turns
// into a write against the owner's own rows.
//
// The shape that makes that safe is worth restating: non-owners have zero
// write access to any content table and are not given any. A suggestion is a
// patch in its own table; when the owner accepts, THEIR client writes THEIR
// rows and syncs normally. No new write authority, no change to the sync
// engine, no merge algorithm. These tests exist to keep it that way — in
// particular, to keep a patch from ever writing a field nobody agreed could be
// suggested.

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

Map<String, dynamic> _row(
  String id, {
  String kind = 'topo.metadata',
  Map<String, dynamic> patch = const {'name': 'Corrected Name'},
  String wall = 'w1',
  String wallName = 'Dolomitici',
  String? route,
  String? author = 'Kata',
  String? note,
  bool stale = false,
}) => {
  'id': id,
  'wallId': wall,
  'wallName': wallName,
  'routeId': route,
  'routeName': route == null ? null : 'Alma',
  'authorId': 'u1',
  'authorName': author,
  'kind': kind,
  'patch': patch,
  'note': note,
  'isStale': stale,
  'createdAt': 1000,
};

class _FakeSuggestions implements SuggestionsRemote {
  _FakeSuggestions();

  final List<Map<String, dynamic>> rows = const [];
  final filed = <(String, SuggestionKind, Map<String, Object?>)>[];
  final resolved = <(String, bool)>[];
  Object? resolveError;

  @override
  Future<List<Map<String, dynamic>>> fetchForMe({int limit = 50}) async => rows;

  @override
  Future<String> suggest({
    required String wallId,
    required SuggestionKind kind,
    required Map<String, Object?> patch,
    String? note,
    String? routeId,
  }) async {
    filed.add((wallId, kind, patch));
    return 'new';
  }

  @override
  Future<String> resolve({
    required String suggestionId,
    required bool accept,
    String? note,
  }) async {
    if (resolveError != null) throw resolveError!;
    resolved.add((suggestionId, accept));
    return accept ? 'accepted' : 'rejected';
  }
}

void main() {
  group('reading a suggestion off the wire', () {
    test('a known kind with an allowed field parses', () {
      final s = EditSuggestion.fromRow(_row('a'))!;
      expect(s.kind, SuggestionKind.topoMetadata);
      expect(s.patch, {'name': 'Corrected Name'});
      expect(s.changes.single.label, 'Topo name');
      expect(s.changes.single.value, 'Corrected Name');
    });

    test(
      'a field NOT on the whitelist is stripped. The server refuses to store '
      'one, so a stored patch carrying it means something is wrong, and the '
      'safe response is to not write it',
      () {
        final s = EditSuggestion.fromRow(
          _row('a', patch: {'name': 'Fine', 'ownerId': 'attacker'}),
        )!;
        expect(s.patch.keys, ['name']);
      },
    );

    test(
      'a patch with NOTHING applicable left is dropped entirely rather than '
      'shown as an empty suggestion the owner can "apply" to no effect',
      () {
        expect(
          EditSuggestion.fromRow(_row('a', patch: {'ownerId': 'x'})),
          isNull,
        );
      },
    );

    test('an unknown kind is dropped', () {
      expect(EditSuggestion.fromRow(_row('a', kind: 'route.geometry')), isNull);
    });

    test('grade is not a suggestible field, on either kind', () {
      expect(kSuggestableFields['topo.metadata'], isNot(contains('gradeRaw')));
      expect(kSuggestableFields['route.metadata'], isNot(contains('gradeRaw')));
      expect(
        kSuggestableFields['route.metadata'],
        isNot(contains('gradeSystem')),
        reason: 'phase 4 already handles grades with no approval step at all',
      );
    });

    test('nor is accessState, nor stars', () {
      for (final fields in kSuggestableFields.values) {
        expect(fields, isNot(contains('accessState')));
        expect(fields, isNot(contains('stars')));
      }
    });

    test('an author with no profile is credited generically, never by uid', () {
      final s = EditSuggestion.fromRow(_row('a', author: null))!;
      expect(s.authorLabel, 'Someone');
      expect(s.authorLabel, isNot(contains('u1')));
    });

    test('a route suggestion names the route as its target', () {
      final s = EditSuggestion.fromRow(
        _row('a', kind: 'route.metadata', route: 'r1', patch: {'name': 'X'}),
      )!;
      expect(s.targetLabel, 'Alma');
      expect(s.changes.single.label, 'Route name');
    });
  });

  group('applying an accepted suggestion', () {
    late AppDatabase db;
    late LibraryCrudRepository repo;
    late ProviderContainer container;
    late _FakeSuggestions remote;

    Future<String> seedWall() async {
      final wallId = await repo.createTopo('Original Name');
      return wallId;
    }

    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
      repo = LibraryCrudRepository(db, nowMs: () => 1000);
      remote = _FakeSuggestions();
      container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          nowMsProvider.overrideWithValue(() => 1000),
          libraryCrudRepositoryProvider.overrideWithValue(repo),
          suggestionsRemoteProvider.overrideWithValue(remote),
          effectiveUidProvider.overrideWithValue(null),
        ],
      );
    });

    tearDown(() async {
      container.dispose();
      await db.close();
    });

    test('a name patch writes the name and marks the row dirty', () async {
      final wallId = await seedWall();
      await repo.applyWallSuggestion(wallId, {'name': 'Corrected Name'});

      final wall = await (db.select(
        db.walls,
      )..where((t) => t.id.equals(wallId))).getSingle();
      expect(wall.name, 'Corrected Name');
      expect(
        wall.dirty,
        isTrue,
        reason: 'the sync engine has to pick the change up like any other',
      );
    });

    test('coordinates apply, including from a numeric string', () async {
      final wallId = await seedWall();
      await repo.applyWallSuggestion(wallId, {
        'latitude': 47.6512,
        'longitude': '19.0402',
      });

      final wall = await (db.select(
        db.walls,
      )..where((t) => t.id.equals(wallId))).getSingle();
      expect(wall.latitude, closeTo(47.6512, 0.0001));
      expect(wall.longitude, closeTo(19.0402, 0.0001));
    });

    test(
      'a patch touching only fields this method does not know writes NOTHING '
      '— not even a bumped updatedAt, which would push a row claiming a change '
      'that never happened',
      () async {
        final wallId = await seedWall();
        final before = await (db.select(
          db.walls,
        )..where((t) => t.id.equals(wallId))).getSingle();

        await repo.applyWallSuggestion(wallId, {'ownerId': 'attacker'});

        final after = await (db.select(
          db.walls,
        )..where((t) => t.id.equals(wallId))).getSingle();
        expect(after.name, before.name);
        expect(after.ownerId, before.ownerId);
        expect(after.updatedAt, before.updatedAt);
      },
    );

    test('an empty or whitespace name is refused rather than written', () async {
      final wallId = await seedWall();
      await repo.applyWallSuggestion(wallId, {'name': '   '});

      final wall = await (db.select(
        db.walls,
      )..where((t) => t.id.equals(wallId))).getSingle();
      expect(wall.name, 'Original Name');
    });

    test(
      'applying the SAME patch twice is a no-op the second time. That is what '
      'makes the apply-then-mark ordering safe: if the mark fails, the owner '
      'sees the suggestion again and accepting once more costs nothing',
      () async {
        final wallId = await seedWall();
        await repo.applyWallSuggestion(wallId, {'name': 'Corrected'});
        await repo.applyWallSuggestion(wallId, {'name': 'Corrected'});

        final wall = await (db.select(
          db.walls,
        )..where((t) => t.id.equals(wallId))).getSingle();
        expect(wall.name, 'Corrected');
      },
    );

    test('accept applies FIRST, then records the decision', () async {
      final wallId = await seedWall();
      final suggestion = EditSuggestion.fromRow(
        _row('s1', wall: wallId, patch: {'name': 'From A Suggestion'}),
      )!;

      await container.read(suggestionServiceProvider).accept(suggestion);

      final wall = await (db.select(
        db.walls,
      )..where((t) => t.id.equals(wallId))).getSingle();
      expect(wall.name, 'From A Suggestion');
      expect(remote.resolved, [('s1', true)]);
    });

    test(
      'if the MARK fails after the apply, the edit still stands — the owner '
      'sees the suggestion again rather than losing the fix',
      () async {
        final wallId = await seedWall();
        remote.resolveError = StateError('offline');
        final suggestion = EditSuggestion.fromRow(
          _row('s1', wall: wallId, patch: {'name': 'Landed Anyway'}),
        )!;

        await expectLater(
          container.read(suggestionServiceProvider).accept(suggestion),
          throwsA(isA<StateError>()),
        );

        final wall = await (db.select(
          db.walls,
        )..where((t) => t.id.equals(wallId))).getSingle();
        expect(wall.name, 'Landed Anyway');
        expect(remote.resolved, isEmpty);
      },
    );

    test('declining writes nothing to the topo', () async {
      final wallId = await seedWall();
      final suggestion = EditSuggestion.fromRow(
        _row('s1', wall: wallId, patch: {'name': 'Never Applied'}),
      )!;

      await container.read(suggestionServiceProvider).reject(suggestion);

      final wall = await (db.select(
        db.walls,
      )..where((t) => t.id.equals(wallId))).getSingle();
      expect(wall.name, 'Original Name');
      expect(remote.resolved, [('s1', false)]);
    });
  });
}
