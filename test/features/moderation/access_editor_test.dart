// The access editor (community editing phase 2 / R-2) — the write half of
// access/closure, without which the banner has nothing to display.
//
// The distinction the tests care most about: backing out returns null, while
// choosing "Clear" returns an AccessEdit whose state is null. Conflating them
// would make cancelling silently erase somebody's closure.

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:masi/app/theme.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/features/library/data/library_crud_repository.dart';
import 'package:masi/features/moderation/data/moderation_repository.dart';
import 'package:masi/features/moderation/domain/access_state.dart';
import 'package:masi/features/moderation/presentation/access_editor.dart';

/// Pumps a button that opens the editor and records what it resolved to.
Future<AccessEdit?> _drive(
  WidgetTester tester,
  Future<void> Function(WidgetTester tester) interact, {
  AccessState? current,
  String? currentNote,
}) async {
  AccessEdit? result;
  var returned = false;

  await tester.pumpWidget(
    MaterialApp(
      theme: MasiTheme.light,
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              key: const Key('open'),
              onPressed: () async {
                result = await showAccessEditor(
                  context,
                  targetLabel: 'Csobánka',
                  current: current,
                  currentNote: currentNote,
                );
                returned = true;
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );

  await tester.tap(find.byKey(const Key('open')));
  await tester.pumpAndSettle();
  await interact(tester);
  await tester.pumpAndSettle();

  expect(returned, isTrue, reason: 'the editor should have resolved by now');
  return result;
}

void main() {
  group('showAccessEditor', () {
    testWidgets('offers every state, and Clear only when one is already set', (
      tester,
    ) async {
      await _drive(tester, (t) async {
        expect(find.byKey(const Key('access-open')), findsOneWidget);
        expect(find.byKey(const Key('access-restricted')), findsOneWidget);
        expect(find.byKey(const Key('access-closed')), findsOneWidget);
        expect(find.byKey(const Key('access-sensitive')), findsOneWidget);
        expect(
          find.byKey(const Key('access-clear')),
          findsNothing,
          reason: 'nothing to clear when nothing is stated',
        );
        await t.tap(find.byKey(const Key('access-open')));
      });
    });

    testWidgets('"Open" needs no reason and resolves immediately', (
      tester,
    ) async {
      final edit = await _drive(tester, (t) async {
        await t.tap(find.byKey(const Key('access-open')));
      });

      expect(edit!.state, AccessState.open);
      expect(edit.note, isNull);
    });

    testWidgets('a restriction asks WHY, and carries the answer through', (
      tester,
    ) async {
      final edit = await _drive(tester, (t) async {
        await t.tap(find.byKey(const Key('access-closed')));
        await t.pumpAndSettle();
        expect(find.byKey(const Key('access-note-field')), findsOneWidget);
        await t.enterText(
          find.byKey(const Key('access-note-field')),
          'Peregrine nesting until 31 Jul',
        );
        await t.pumpAndSettle();
        await t.tap(find.byKey(const Key('access-note-submit')));
      });

      expect(edit!.state, AccessState.closed);
      expect(edit.note, 'Peregrine nesting until 31 Jul');
    });

    testWidgets(
      'backing out of the WHY step abandons the edit — a restriction nobody '
      'explained is not recorded',
      (tester) async {
        final edit = await _drive(tester, (t) async {
          await t.tap(find.byKey(const Key('access-closed')));
          await t.pumpAndSettle();
          await t.tap(find.text('Cancel'));
        });

        expect(edit, isNull);
      },
    );

    testWidgets(
      'Clear returns an edit with a NULL state — distinct from backing out, '
      'which returns null and must never erase an existing closure',
      (tester) async {
        final cleared = await _drive(
          tester,
          (t) async => t.tap(find.byKey(const Key('access-clear'))),
          current: AccessState.closed,
          currentNote: 'old reason',
        );

        expect(cleared, isNotNull, reason: 'Clear is a decision, not a cancel');
        expect(cleared!.state, isNull);
        expect(cleared.note, isNull);
      },
    );

    testWidgets('dismissing the first sheet returns null', (tester) async {
      final edit = await _drive(
        tester,
        (t) async => t.tap(find.text('Cancel')),
      );
      expect(edit, isNull);
    });

    testWidgets('pre-fills the existing reason when re-editing', (
      tester,
    ) async {
      await _drive(
        tester,
        (t) async {
          await t.tap(find.byKey(const Key('access-restricted')));
          await t.pumpAndSettle();
          expect(find.text('Permit from the farm'), findsOneWidget);
          await t.tap(find.byKey(const Key('access-note-submit')));
        },
        current: AccessState.restricted,
        currentNote: 'Permit from the farm',
      );
    });
  });

  group('LibraryCrudRepository access writes', () {
    late AppDatabase db;
    late LibraryCrudRepository repo;
    late ModerationRepository moderation;

    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
      repo = LibraryCrudRepository(db, nowMs: () => 5000);
      moderation = ModerationRepository(db);
    });
    tearDown(() => db.close());

    test('an area closure reaches a wall beneath it, and marks it dirty', () async {
      final area = await repo.createArea('Csobánka');
      final sector = await repo.createSector(area.id, 'Main');
      final wall = await repo.createWall(sector.id, 'Roof');

      await repo.setAreaAccess(area.id, 'closed', 'Landowner request');

      final resolved = await moderation.watchAccess(wall.id).first;
      expect(resolved.state, AccessState.closed);
      expect(resolved.note, 'Landowner request');
      expect(resolved.sourceLabel, 'Csobánka');

      final row = await (db.select(db.areas)
            ..where((t) => t.id.equals(area.id)))
          .getSingle();
      expect(row.dirty, isTrue, reason: 'the write must be pushed');
      expect(row.updatedAt, 5000);
    });

    test('a wall-level restriction does not override a harsher area one', () async {
      final area = await repo.createArea('Csobánka');
      final sector = await repo.createSector(area.id, 'Main');
      final wall = await repo.createWall(sector.id, 'Roof');

      await repo.setAreaAccess(area.id, 'closed', 'Landowner request');
      await repo.setWallAccess(wall.id, 'open', null);

      expect(
        (await moderation.watchAccess(wall.id).first).state,
        AccessState.closed,
        reason: 'one stale wall must not reopen a closed crag',
      );
    });

    test('clearing sets both columns back to null', () async {
      final area = await repo.createArea('Csobánka');
      final sector = await repo.createSector(area.id, 'Main');
      final wall = await repo.createWall(sector.id, 'Roof');

      await repo.setSectorAccess(sector.id, 'restricted', 'Permit');
      expect(
        (await moderation.watchAccess(wall.id).first).state,
        AccessState.restricted,
      );

      await repo.setSectorAccess(sector.id, null, null);
      expect((await moderation.watchAccess(wall.id).first).state, isNull);
    });
  });
}
