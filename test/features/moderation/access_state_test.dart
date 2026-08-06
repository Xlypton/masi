// Access & closure (community editing phase 2 / R-2).
//
// The inheritance rule is the interesting part: most-restrictive-wins up the
// Wall -> Sector -> Area chain, so closing a crag is ONE write that repaints
// every topo beneath it, and a stale "open" on one wall cannot override a
// landowner's closure of the whole area.

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:masi/app/theme.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/features/moderation/data/moderation_repository.dart';
import 'package:masi/features/moderation/domain/access_state.dart';
import 'package:masi/features/moderation/presentation/access_banner.dart';

AccessLevel _level(AccessState? state, {String? note, String label = 'x'}) =>
    AccessLevel(state: state, note: note, sourceLabel: label);

void main() {
  group('AccessState.fromWire', () {
    test('parses the four known values, and absent stays absent', () {
      expect(AccessState.fromWire('open'), AccessState.open);
      expect(AccessState.fromWire('restricted'), AccessState.restricted);
      expect(AccessState.fromWire('closed'), AccessState.closed);
      expect(AccessState.fromWire('sensitive'), AccessState.sensitive);
      expect(AccessState.fromWire(null), isNull);
      expect(AccessState.fromWire(''), isNull);
    });

    test(
      'an UNKNOWN value resolves to closed, not to null — reading a future '
      "'closed_seasonally' as \"nothing stated\" would show an open crag that "
      'somebody had marked shut',
      () {
        expect(AccessState.fromWire('closed_seasonally'), AccessState.closed);
        expect(AccessState.fromWire('CLOSED'), AccessState.closed);
        expect(AccessState.fromWire('nonsense'), AccessState.closed);
      },
    );

    test('only restricted and above warrant a banner', () {
      expect(AccessState.open.warrantsNotice, isFalse);
      expect(AccessState.restricted.warrantsNotice, isTrue);
      expect(AccessState.closed.warrantsNotice, isTrue);
      expect(AccessState.sensitive.warrantsNotice, isTrue);
    });
  });

  group('ResolvedAccess.resolve', () {
    test('nothing stated anywhere resolves to none', () {
      final resolved = ResolvedAccess.resolve([
        _level(null),
        _level(null),
        _level(null),
      ]);
      expect(resolved.state, isNull);
      expect(resolved.warrantsNotice, isFalse);
    });

    test(
      'MOST RESTRICTIVE wins, not nearest: a wall marked open under an area '
      'marked closed reads as closed',
      () {
        final resolved = ResolvedAccess.resolve([
          _level(AccessState.open, label: 'Roof Wall'),
          _level(null, label: 'Main Sector'),
          _level(AccessState.closed, note: 'Peregrines', label: 'Csobánka'),
        ]);

        expect(resolved.state, AccessState.closed);
        expect(
          resolved.note,
          'Peregrines',
          reason: 'the note that matters explains the RESTRICTION',
        );
        expect(resolved.sourceLabel, 'Csobánka');
      },
    );

    test('carries the note and source of the winning level, not of any other', () {
      final resolved = ResolvedAccess.resolve([
        _level(AccessState.restricted, note: 'wall note', label: 'Wall'),
        _level(AccessState.sensitive, note: 'area note', label: 'Area'),
      ]);

      expect(resolved.state, AccessState.sensitive);
      expect(resolved.note, 'area note');
      expect(resolved.sourceLabel, 'Area');
    });

    test('a tie goes to the level given FIRST (the most specific)', () {
      final resolved = ResolvedAccess.resolve([
        _level(AccessState.closed, note: 'wall reason', label: 'Wall'),
        _level(AccessState.closed, note: 'area reason', label: 'Area'),
      ]);

      expect(resolved.note, 'wall reason');
      expect(resolved.sourceLabel, 'Wall');
    });

    test('an empty list is none, not a crash', () {
      expect(ResolvedAccess.resolve(const []).state, isNull);
    });
  });

  group('ModerationRepository.watchAccess (real inheritance over Drift)', () {
    late AppDatabase db;
    late ModerationRepository repo;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      repo = ModerationRepository(db);
      await db.into(db.areas).insert(
        AreasCompanion.insert(
          id: 'a1',
          createdAt: 1,
          updatedAt: 1,
          name: 'Csobánka',
        ),
      );
      await db.into(db.sectors).insert(
        SectorsCompanion.insert(
          id: 's1',
          createdAt: 1,
          updatedAt: 1,
          areaId: 'a1',
          name: 'Main Sector',
          sortOrder: 0,
        ),
      );
      await db.into(db.walls).insert(
        WallsCompanion.insert(
          id: 'w1',
          createdAt: 1,
          updatedAt: 1,
          sectorId: 's1',
          name: 'Roof Wall',
          sortOrder: 0,
        ),
      );
    });
    tearDown(() => db.close());

    test('nothing set anywhere resolves to none', () async {
      expect((await repo.watchAccess('w1').first).state, isNull);
    });

    test('a closure on the AREA reaches a wall three levels down', () async {
      await (db.update(db.areas)..where((t) => t.id.equals('a1'))).write(
        const AreasCompanion(
          accessState: Value('closed'),
          accessNote: Value('Landowner request'),
        ),
      );

      final resolved = await repo.watchAccess('w1').first;
      expect(resolved.state, AccessState.closed);
      expect(resolved.note, 'Landowner request');
      expect(resolved.sourceLabel, 'Csobánka');
    });

    test('a sector restriction beats an area marked open', () async {
      await (db.update(db.areas)..where((t) => t.id.equals('a1')))
          .write(const AreasCompanion(accessState: Value('open')));
      await (db.update(db.sectors)..where((t) => t.id.equals('s1'))).write(
        const SectorsCompanion(
          accessState: Value('restricted'),
          accessNote: Value('Permit needed'),
        ),
      );

      final resolved = await repo.watchAccess('w1').first;
      expect(resolved.state, AccessState.restricted);
      expect(resolved.sourceLabel, 'Main Sector');
    });

    test('an unknown wall resolves to none rather than throwing', () async {
      expect((await repo.watchAccess('nope').first).state, isNull);
    });

    test(
      'the stream repaints when a closure is set at ANY level — that is the '
      'whole point of one write covering a crag',
      () async {
        final seen = <AccessState?>[];
        final sub = repo.watchAccess('w1').listen((a) => seen.add(a.state));
        await Future<void>.delayed(Duration.zero);

        await (db.update(db.areas)..where((t) => t.id.equals('a1')))
            .write(const AreasCompanion(accessState: Value('closed')));
        await Future<void>.delayed(Duration.zero);

        await sub.cancel();
        expect(seen, [null, AccessState.closed]);
      },
    );
  });

  group('AccessNotice', () {
    Widget wrap(ResolvedAccess access) => MaterialApp(
      theme: MasiTheme.light,
      home: Scaffold(body: AccessNotice(access: access)),
    );

    testWidgets('renders nothing when nothing is stated', (tester) async {
      await tester.pumpWidget(wrap(ResolvedAccess.none));
      expect(find.byType(Container), findsNothing);
    });

    testWidgets(
      'renders nothing for a bare "open" — a banner that is always there is '
      'a banner nobody reads',
      (tester) async {
        await tester.pumpWidget(
          wrap(const ResolvedAccess(state: AccessState.open)),
        );
        expect(find.textContaining('Open'), findsNothing);
      },
    );

    testWidgets('shows the headline, the reason, and WHERE it came from', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(
          const ResolvedAccess(
            state: AccessState.closed,
            note: 'Peregrine nesting until 31 Jul',
            sourceLabel: 'Csobánka',
          ),
        ),
      );

      expect(find.text('Closed to climbing'), findsOneWidget);
      expect(find.text('Peregrine nesting until 31 Jul'), findsOneWidget);
      expect(
        find.text('Applies to Csobánka'),
        findsOneWidget,
        reason:
            'an inherited closure must be attributable, or it reads as an '
            'unexplained flag on a topo whose owner set nothing',
      );
      expect(find.byKey(const Key('access-notice-closed')), findsOneWidget);
    });

    testWidgets('restricted renders its own softer notice', (tester) async {
      await tester.pumpWidget(
        wrap(const ResolvedAccess(state: AccessState.restricted)),
      );
      expect(find.text('Access restrictions apply'), findsOneWidget);
      expect(find.byKey(const Key('access-notice-restricted')), findsOneWidget);
    });
  });
}
