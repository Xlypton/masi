// The hazard surface (phase 4 / R-1).
//
// The assertion this file exists for: the topo owner gets a Resolve control
// and NO delete control, on somebody else's report, on their own topo. That
// asymmetry is C-12 made visible, and it is the kind of thing a well-meaning
// later refactor ("owners should be able to tidy their topo") would quietly
// undo.

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:masi/app/theme.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/features/account/application/auth_providers.dart';
import 'package:masi/features/moderation/data/community_facts_repository.dart';
import 'package:masi/features/moderation/domain/community_facts.dart';
import 'package:masi/features/moderation/presentation/hazard_banner.dart';
import 'package:masi/features/moderation/presentation/hazard_list_sheet.dart';
import 'package:masi/features/moderation/presentation/hazard_reporter.dart';

Widget _wrap(Widget child, {required List<Override> overrides}) =>
    ProviderScope(
      overrides: overrides,
      child: MaterialApp(theme: MasiTheme.light, home: Scaffold(body: child)),
    );

Map<String, dynamic> _hazardRow({
  String id = 'h1',
  String severity = 'caution',
  String authorId = 'reporter',
  int? resolvedAt,
}) => {
  'id': id,
  'wallId': 'w1',
  'routeId': null,
  'authorId': authorId,
  'severity': severity,
  'body': 'Loose flake at the third clip',
  'resolvedAt': resolvedAt,
  'resolvedBy': null,
  'createdAt': 1000,
};

void main() {
  group('HazardNotice', () {
    testWidgets('renders nothing when there is no outstanding hazard', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          const HazardNotice(
            summary: HazardSummary(
              worst: null,
              unresolvedCount: 0,
              resolvedCount: 3,
            ),
          ),
          overrides: const [],
        ),
      );

      // Nothing at all, not a quiet "0 hazards" row: three reports that were
      // all dealt with is not something to interrupt a reader about.
      for (final severity in HazardSeverity.values) {
        expect(find.byKey(Key('hazard-notice-${severity.wire}')), findsNothing);
      }
    });

    testWidgets('a danger reads as a danger', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const HazardNotice(
            summary: HazardSummary(
              worst: HazardSeverity.danger,
              unresolvedCount: 1,
              resolvedCount: 0,
            ),
          ),
          overrides: const [],
        ),
      );

      expect(find.byKey(const Key('hazard-notice-danger')), findsOneWidget);
      expect(find.text('Danger reported'), findsOneWidget);
    });

    testWidgets('a milder report does not shout', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const HazardNotice(
            summary: HazardSummary(
              worst: HazardSeverity.note,
              unresolvedCount: 2,
              resolvedCount: 0,
            ),
          ),
          overrides: const [],
        ),
      );

      expect(find.byKey(const Key('hazard-notice-note')), findsOneWidget);
      expect(find.text('2 hazards reported'), findsOneWidget);
    });
  });

  group('showHazardReporter', () {
    Future<HazardDraft?> drive(
      WidgetTester tester,
      Future<void> Function(WidgetTester tester) interact,
    ) async {
      HazardDraft? result;
      var returned = false;

      await tester.pumpWidget(
        _wrap(
          Builder(
            builder: (context) => TextButton(
              key: const Key('open'),
              onPressed: () async {
                result = await showHazardReporter(
                  context,
                  targetLabel: 'Kavics',
                );
                returned = true;
              },
              child: const Text('open'),
            ),
          ),
          overrides: const [],
        ),
      );

      await tester.tap(find.byKey(const Key('open')));
      await tester.pumpAndSettle();
      await interact(tester);
      await tester.pumpAndSettle();

      expect(returned, isTrue, reason: 'the reporter should have resolved');
      return result;
    }

    testWidgets('offers all three severities', (tester) async {
      await drive(tester, (t) async {
        expect(find.byKey(const Key('hazard-danger')), findsOneWidget);
        expect(find.byKey(const Key('hazard-caution')), findsOneWidget);
        expect(find.byKey(const Key('hazard-note')), findsOneWidget);
        await t.tap(find.text('Cancel'));
      });
    });

    testWidgets('carries the severity and the description through', (
      tester,
    ) async {
      final draft = await drive(tester, (t) async {
        await t.tap(find.byKey(const Key('hazard-danger')));
        await t.pumpAndSettle();
        await t.enterText(
          find.byKey(const Key('hazard-body-field')),
          'Bolt 2 spins',
        );
        await t.pumpAndSettle();
        await t.tap(find.byKey(const Key('hazard-body-submit')));
      });

      expect(draft!.severity, HazardSeverity.danger);
      expect(draft.body, 'Bolt 2 spins');
    });

    testWidgets(
      'backing out of the description abandons the report — a bare severity '
      'nobody explained is not filed',
      (tester) async {
        final draft = await drive(tester, (t) async {
          await t.tap(find.byKey(const Key('hazard-caution')));
          await t.pumpAndSettle();
          await t.tap(find.text('Cancel'));
        });

        expect(draft, isNull);
      },
    );

    testWidgets('dismissing the severity sheet returns null', (tester) async {
      expect(await drive(tester, (t) => t.tap(find.text('Cancel'))), isNull);
    });
  });

  group('HazardListSheet', () {
    late AppDatabase db;
    late CommunityFactsRepository repo;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      repo = CommunityFactsRepository(db);
    });
    tearDown(() => db.close());

    Future<void> pump(
      WidgetTester tester, {
      required String? uid,
      required String? wallOwnerId,
    }) async {
      await tester.pumpWidget(
        _wrap(
          HazardListSheet(wallId: 'w1', wallOwnerId: wallOwnerId),
          overrides: [
            appDatabaseProvider.overrideWithValue(db),
            effectiveUidProvider.overrideWithValue(uid),
          ],
        ),
      );
      await tester.pumpAndSettle();
    }

    /// Tears the tree down INSIDE the test body.
    ///
    /// Drift's `StreamQueryStore` schedules a timer when its last listener
    /// cancels, and Riverpod only cancels when the `ProviderScope` unmounts.
    /// Left to the end of the test that lands after flutter_test has already
    /// checked its invariants, which fails with "a Timer is still pending even
    /// after the widget tree was disposed" — a teardown artefact, not a
    /// product bug. Unmounting here gives the timer a frame to drain.
    Future<void> unmount(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 50));
    }

    testWidgets('says so plainly when nothing is reported', (tester) async {
      await pump(tester, uid: 'someone', wallOwnerId: 'owner');
      expect(find.byKey(const Key('hazard-list-empty')), findsOneWidget);
      await unmount(tester);
    });

    testWidgets(
      'the topo owner gets a Resolve control on somebody else\'s report — but '
      'there is NO delete control anywhere on this sheet (C-12)',
      (tester) async {
        await repo.upsertFromRemote({
          'hazards': [_hazardRow(authorId: 'reporter')],
        });

        await pump(tester, uid: 'owner', wallOwnerId: 'owner');

        expect(find.byKey(const Key('hazard-row-h1')), findsOneWidget);
        expect(find.byKey(const Key('hazard-resolve-h1')), findsOneWidget);
        expect(find.text('Resolve'), findsOneWidget);
        expect(
          find.text('Delete'),
          findsNothing,
          reason: 'the owner must never be able to erase a hazard report',
        );
        await unmount(tester);
      },
    );

    testWidgets('the reporter can withdraw their own report', (tester) async {
      await repo.upsertFromRemote({
        'hazards': [_hazardRow(authorId: 'reporter')],
      });

      await pump(tester, uid: 'reporter', wallOwnerId: 'owner');
      expect(find.byKey(const Key('hazard-resolve-h1')), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('an unrelated reader gets no resolve control at all', (
      tester,
    ) async {
      await repo.upsertFromRemote({
        'hazards': [_hazardRow(authorId: 'reporter')],
      });

      await pump(tester, uid: 'stranger', wallOwnerId: 'owner');

      expect(find.byKey(const Key('hazard-row-h1')), findsOneWidget);
      expect(find.byKey(const Key('hazard-resolve-h1')), findsNothing);
      await unmount(tester);
    });

    testWidgets('a signed-out reader can still READ the hazards', (
      tester,
    ) async {
      await repo.upsertFromRemote({
        'hazards': [_hazardRow(severity: 'danger')],
      });

      await pump(tester, uid: null, wallOwnerId: 'owner');

      expect(find.byKey(const Key('hazard-row-h1')), findsOneWidget);
      expect(find.text('DANGER'), findsOneWidget);
      expect(find.byKey(const Key('hazard-resolve-h1')), findsNothing);
      await unmount(tester);
    });

    testWidgets(
      'a resolved report stays visible and offers Reopen — never hidden, so '
      '"reported and dealt with" stays distinguishable from "never reported"',
      (tester) async {
        await repo.upsertFromRemote({
          'hazards': [_hazardRow(resolvedAt: 5000)],
        });

        await pump(tester, uid: 'owner', wallOwnerId: 'owner');

        expect(find.byKey(const Key('hazard-row-h1')), findsOneWidget);
        expect(find.text('CAUTION · resolved'), findsOneWidget);
        expect(find.text('Reopen'), findsOneWidget);
        expect(find.text('Loose flake at the third clip'), findsOneWidget);
        await unmount(tester);
      },
    );

    testWidgets('live hazards sort above resolved ones', (tester) async {
      await repo.upsertFromRemote({
        'hazards': [
          _hazardRow(id: 'old', severity: 'danger', resolvedAt: 5000),
          _hazardRow(id: 'live', severity: 'note'),
        ],
      });

      await pump(tester, uid: 'stranger', wallOwnerId: 'owner');

      final live = tester.getTopLeft(find.byKey(const Key('hazard-row-live')));
      final old = tester.getTopLeft(find.byKey(const Key('hazard-row-old')));
      expect(live.dy, lessThan(old.dy));
      await unmount(tester);
    });
  });
}
