// The grade-opinion and verification surface (phase 4 / R-1).
//
// What matters here: the consensus renders BESIDE the author's grade and never
// instead of it, it stays silent below three opinions, and the bounded picker
// still reaches the ends of the ladder — a window that shrank at the top would
// make the hardest grades unstatable.

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:masi/app/theme.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/core/grades/grade_system.dart';
import 'package:masi/features/moderation/data/community_facts_repository.dart';
import 'package:masi/features/moderation/presentation/grade_consensus_view.dart';
import 'package:masi/features/moderation/presentation/verification_tile.dart';

Widget _wrap(Widget child, {List<Override> overrides = const []}) =>
    ProviderScope(
      overrides: overrides,
      child: MaterialApp(theme: MasiTheme.light, home: Scaffold(body: child)),
    );

Map<String, dynamic> _opinion(String id, String raw) => {
  'id': id,
  'routeId': 'r1',
  'authorId': 'a-$id',
  'gradeSystem': 'french',
  'gradeRaw': raw,
  'gradeSortKey': gradeSortKey(GradeSystem.french, raw),
  'createdAt': 1000,
};

void main() {
  group('gradeOpinionOptions', () {
    test('windows around the author grade rather than listing the ladder', () {
      final options = gradeOpinionOptions(GradeSystem.french, '6a');

      expect(options, contains('6a'));
      expect(options.length, lessThan(gradeOptions(GradeSystem.french).length));
      expect(
        options.length,
        kGradeOpinionWindow * 2 + 1,
        reason: 'a full window either side of the anchor',
      );
    });

    test(
      'the window shrinks at the ends rather than running off them — the '
      'hardest and softest grades stay statable, and neither end throws',
      () {
        final ladder = gradeOptions(GradeSystem.french);

        final atTop = gradeOpinionOptions(GradeSystem.french, ladder.last);
        expect(atTop, contains(ladder.last));
        expect(atTop.length, kGradeOpinionWindow + 1);

        final atBottom = gradeOpinionOptions(GradeSystem.french, ladder.first);
        expect(atBottom, contains(ladder.first));
        expect(atBottom.length, kGradeOpinionWindow + 1);
      },
    );

    test('an ungraded route falls back to the whole ladder', () {
      expect(
        gradeOpinionOptions(GradeSystem.french, null),
        gradeOptions(GradeSystem.french),
      );
    });

    test('an unparseable author grade falls back to the whole ladder', () {
      expect(
        gradeOpinionOptions(GradeSystem.french, '5.11a'),
        gradeOptions(GradeSystem.french),
      );
    });

    test('works on the UIAA ladder too', () {
      final options = gradeOpinionOptions(GradeSystem.uiaa, 'VI+');
      expect(options, contains('VI+'));
      expect(options.length, lessThan(gradeOptions(GradeSystem.uiaa).length));
    });
  });

  group('GradeConsensusChip', () {
    late AppDatabase db;
    late CommunityFactsRepository repo;

    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
      repo = CommunityFactsRepository(db);
    });
    tearDown(() => db.close());

    Future<void> pump(WidgetTester tester, {String? authorGrade}) async {
      await tester.pumpWidget(
        _wrap(
          GradeConsensusChip(
            routeId: 'r1',
            system: GradeSystem.french,
            authorGrade: authorGrade,
          ),
          overrides: [appDatabaseProvider.overrideWithValue(db)],
        ),
      );
      await tester.pumpAndSettle();
    }

    /// See `hazard_ui_test.dart` — drift's stream teardown leaves a timer
    /// pending if the tree is only disposed once the test has ended.
    Future<void> unmount(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 50));
    }

    testWidgets('renders nothing with no opinions at all', (tester) async {
      await pump(tester, authorGrade: '6a');
      expect(find.byKey(const Key('grade-consensus-r1')), findsNothing);
      await unmount(tester);
    });

    testWidgets(
      'stays silent at two opinions — one passer-by must not appear to '
      'overrule the first ascensionist',
      (tester) async {
        await repo.upsertFromRemote({
          'opinions': [_opinion('o1', '7a'), _opinion('o2', '7a')],
        });

        await pump(tester, authorGrade: '6a');
        expect(find.byKey(const Key('grade-consensus-r1')), findsNothing);
        await unmount(tester);
      },
    );

    testWidgets('shows the median and the count at three', (tester) async {
      await repo.upsertFromRemote({
        'opinions': [
          _opinion('o1', '6b'),
          _opinion('o2', '6b'),
          _opinion('o3', '6b+'),
        ],
      });

      await pump(tester, authorGrade: '6b');

      expect(find.byKey(const Key('grade-consensus-r1')), findsOneWidget);
      expect(find.text('6b · 3'), findsOneWidget);
      await unmount(tester);
    });

    testWidgets(
      'renders on the author\'s ladder even when the opinions came in on a '
      'different one',
      (tester) async {
        await repo.upsertFromRemote({
          'opinions': [
            for (var i = 0; i < 3; i++)
              {
                'id': 'u$i',
                'routeId': 'r1',
                'authorId': 'a$i',
                'gradeSystem': 'uiaa',
                'gradeRaw': 'VII-',
                'gradeSortKey': gradeSortKey(GradeSystem.uiaa, 'VII-'),
                'createdAt': 1,
              },
          ],
        });

        await pump(tester, authorGrade: '6a');

        expect(find.byKey(const Key('grade-consensus-r1')), findsOneWidget);
        await unmount(tester);
      },
    );

    testWidgets('an ungraded route still gets a consensus', (tester) async {
      await repo.upsertFromRemote({
        'opinions': [
          _opinion('o1', '7a'),
          _opinion('o2', '7a'),
          _opinion('o3', '7a'),
        ],
      });

      await pump(tester);

      expect(find.text('7a · 3'), findsOneWidget);
      await unmount(tester);
    });
  });

  group('VerificationTile', () {
    late AppDatabase db;
    late CommunityFactsRepository repo;

    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
      repo = CommunityFactsRepository(db);
    });
    tearDown(() => db.close());

    Future<void> pump(WidgetTester tester) async {
      await tester.pumpWidget(
        _wrap(
          const VerificationTile(wallId: 'w1'),
          overrides: [appDatabaseProvider.overrideWithValue(db)],
        ),
      );
      await tester.pumpAndSettle();
    }

    Future<void> unmount(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 50));
    }

    Map<String, dynamic> verification(String id, bool accurate) => {
      'id': id,
      'wallId': 'w1',
      'authorId': 'a-$id',
      'accurate': accurate,
      'note': null,
      'createdAt': 1,
    };

    testWidgets(
      'prompts when nothing is confirmed — always shown, unlike the banners, '
      'because an unconfirmed topo is where the prompt matters most',
      (tester) async {
        await pump(tester);

        expect(find.byKey(const Key('verification-tile-w1')), findsOneWidget);
        expect(find.text('Nobody has confirmed this topo yet.'), findsOneWidget);
        expect(find.byKey(const Key('verify-accurate-w1')), findsOneWidget);
        expect(find.byKey(const Key('verify-inaccurate-w1')), findsOneWidget);
        await unmount(tester);
      },
    );

    testWidgets('counts confirmations as a fact, not a score', (tester) async {
      await repo.upsertFromRemote({
        'verifications': [
          verification('v1', true),
          verification('v2', true),
          verification('v3', true),
        ],
      });

      await pump(tester);
      expect(find.text('3 climbers confirm this topo.'), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('singular reads correctly', (tester) async {
      await repo.upsertFromRemote({
        'verifications': [verification('v1', true)],
      });

      await pump(tester);
      expect(find.text('1 climber confirms this topo.'), findsOneWidget);
      await unmount(tester);
    });

    testWidgets(
      'a single dissent is surfaced however outvoted — one credible "the line '
      'is on the wrong crack" is worth reading',
      (tester) async {
        await repo.upsertFromRemote({
          'verifications': [
            for (var i = 0; i < 8; i++) verification('ok$i', true),
            verification('no', false),
          ],
        });

        await pump(tester);
        expect(
          find.text('8 climbers confirm this topo · 1 says it does not match.'),
          findsOneWidget,
        );
        await unmount(tester);
      },
    );
  });
}
