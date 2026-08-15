// "Am I allowed to edit this wall's committed routes?" — the predicate the
// codebase did not previously compute anywhere.
//
// The stakes run BOTH ways and that is what most of this file is about. Too
// strict and an owner is locked out of the topos they drew (every row created
// before a first sign-in carries a null `ownerId`, so "unowned" is normally
// the user's own work); too loose and someone else's committed lines are
// silently rewritable on a wall that only arrived here via a sync pull. The
// predicate therefore has to match `LibraryCrudRepository._ownOrUnowned`
// exactly — own OR unowned — and the arms below are that table, both halves
// of it.
//
// The provider group runs against a REAL in-memory AppDatabase rather than a
// fake repository, because the thing worth proving is that a wall row's
// `ownerId` reaches the predicate at all — and that a read which finds
// nothing, or fails outright, resolves to "editable" rather than to an
// accusation.

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart' show appDatabaseProvider;
import 'package:masi/features/account/application/auth_providers.dart'
    show effectiveUidProvider;
import 'package:masi/features/topo/application/wall_route_edit_permission.dart';

const _me = 'uid-me';
const _someoneElse = 'uid-them';
const _wallId = 'wall-1';

void main() {
  group('mayEditWallRoutes', () {
    test('my own wall', () {
      expect(mayEditWallRoutes(ownerId: _me, uid: _me), isTrue);
    });

    test('somebody else\'s wall', () {
      expect(mayEditWallRoutes(ownerId: _someoneElse, uid: _me), isFalse);
    });

    test(
      'an UNOWNED wall is mine to edit — rows drawn before a first sign-in '
      'carry a null ownerId until claimOwnership stamps them, so refusing '
      'here would lock people out of their own topos',
      () {
        expect(mayEditWallRoutes(ownerId: null, uid: _me), isTrue);
        expect(mayEditWallRoutes(ownerId: null, uid: null), isTrue);
      },
    );

    test(
      'with no identity at all, an OWNED wall is not mine — matching '
      '_ownOrUnowned\'s collapse to "ownerId IS NULL" when currentUid is null',
      () {
        expect(mayEditWallRoutes(ownerId: _someoneElse, uid: null), isFalse);
        // Not even a row stamped with a uid that once was ours: with no known
        // session there is nothing to compare against.
        expect(mayEditWallRoutes(ownerId: _me, uid: null), isFalse);
      },
    );
  });

  group('canEditWallRoutesProvider', () {
    late AppDatabase db;

    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
    });

    tearDown(() async {
      await db.close();
    });

    /// Inserts the area -> sector -> wall chain the FK constraints require
    /// (`PRAGMA foreign_keys = ON`, see `app_database.dart`'s `beforeOpen`),
    /// with the wall owned by [ownerId].
    Future<void> seedWall({required String? ownerId, int now = 1000}) async {
      await db
          .into(db.areas)
          .insert(
            AreasCompanion.insert(
              id: 'area-1',
              createdAt: now,
              updatedAt: now,
              name: 'Area',
              ownerId: Value(ownerId),
            ),
          );
      await db
          .into(db.sectors)
          .insert(
            SectorsCompanion.insert(
              id: 'sector-1',
              createdAt: now,
              updatedAt: now,
              areaId: 'area-1',
              name: 'Sector',
              sortOrder: 0,
              ownerId: Value(ownerId),
            ),
          );
      await db
          .into(db.walls)
          .insert(
            WallsCompanion.insert(
              id: _wallId,
              createdAt: now,
              updatedAt: now,
              sectorId: 'sector-1',
              name: 'Wall',
              sortOrder: 0,
              ownerId: Value(ownerId),
            ),
          );
    }

    ProviderContainer containerFor(String? uid) {
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          effectiveUidProvider.overrideWithValue(uid),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    /// The provider's first real answer. `container.read` alone would only
    /// ever see `AsyncLoading`, since the underlying query is a round-trip,
    /// so this listens and then awaits `.future`.
    Future<bool> firstAnswer(ProviderContainer container) {
      final subscription = container.listen(
        canEditWallRoutesProvider(_wallId),
        (previous, next) {},
      );
      addTearDown(subscription.close);
      return container.read(canEditWallRoutesProvider(_wallId).future);
    }

    test('my own wall resolves to editable', () async {
      await seedWall(ownerId: _me);
      expect(await firstAnswer(containerFor(_me)), isTrue);
    });

    test('a wall owned by someone else resolves to NOT editable', () async {
      await seedWall(ownerId: _someoneElse);
      expect(await firstAnswer(containerFor(_me)), isFalse);
    });

    test('an unowned wall resolves to editable', () async {
      await seedWall(ownerId: null);
      expect(await firstAnswer(containerFor(_me)), isTrue);
    });

    test(
      'a wall that is not in the local database at all resolves to EDITABLE — '
      'a missing row is not evidence of foreign ownership, and refusing would '
      'be a false accusation about a wall whose edits have nowhere to land',
      () async {
        expect(await firstAnswer(containerFor(_me)), isTrue);
      },
    );

    test(
      'recomputes when the IDENTITY changes — signing in is what turns a '
      "device's unowned rows into somebody's, and a frozen answer would "
      'outlive the fact it was computed from',
      () async {
        // The wall belongs to someone else all along. Signed out, that is
        // already visible; the point is that the answer is recomputed for a
        // NEW identity rather than cached from the old one.
        await seedWall(ownerId: _someoneElse);
        expect(await firstAnswer(containerFor(null)), isFalse);
        expect(
          await firstAnswer(containerFor(_someoneElse)),
          isTrue,
          reason:
              'the very same wall row, read as the identity that owns it — '
              'only the uid changed',
        );
      },
    );

    test(
      'a read that FAILS answers "editable" rather than accusing — an errored '
      'query is not evidence of foreign ownership, and Riverpod would '
      'otherwise retry it on a timer that outlives a widget test',
      () async {
        await seedWall(ownerId: _someoneElse);
        await db.close();

        expect(await firstAnswer(containerFor(_me)), isTrue);
      },
    );
  });
}
