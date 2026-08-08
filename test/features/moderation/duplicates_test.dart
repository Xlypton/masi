// Duplicate topos: detect, name, link (community editing phase 8b / C-6).
//
// The one property that must hold across every test in this file: **nothing
// here can remove a topo.** §C-6 opens by ruling out resolution by deletion and
// by refusing the second submission, so a client that could block a publish or
// hide a listing would be enforcing the opposite of the decision. The warning
// sheet is a prompt with a live confirm button; linking two topos leaves both
// published.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:masi/app/theme.dart';
import 'package:masi/features/account/application/auth_providers.dart';
import 'package:masi/features/moderation/application/duplicate_providers.dart';
import 'package:masi/features/moderation/application/moderation_providers.dart';
import 'package:masi/features/moderation/application/report_providers.dart';
import 'package:masi/features/moderation/data/duplicates_remote.dart';
import 'package:masi/features/moderation/data/moderation_remote.dart';
import 'package:masi/features/moderation/data/reports_remote.dart';
import 'package:masi/features/moderation/domain/content_report.dart';
import 'package:masi/features/moderation/domain/nearby_topo.dart';
import 'package:masi/features/moderation/presentation/admin_queue_screen.dart';
import 'package:masi/features/moderation/presentation/duplicate_warning_sheet.dart';
import 'package:masi/features/moderation/presentation/report_reporter.dart';

NearbyTopo _nearby(String id, {double distanceM = 30, String? name}) =>
    NearbyTopo(
      wallId: id,
      name: name ?? 'Topo $id',
      distanceM: distanceM,
      ownerName: 'Kata',
      routeCount: 3,
    );

class _FakeDuplicates implements DuplicatesRemote {
  _FakeDuplicates({this.linkThrows = false});

  final bool linkThrows;
  final linked = <({String duplicateId, String canonicalId})>[];
  final unlinked = <String>[];
  List<Map<String, dynamic>> alternates = const [];

  @override
  Future<List<Map<String, dynamic>>> nearby({
    required double latitude,
    required double longitude,
    double radiusM = 50,
    String? excludeWallId,
  }) async => const [];

  @override
  Future<List<Map<String, dynamic>>> alternatesFor(Set<String> wallIds) async =>
      alternates;

  @override
  Future<String> link({
    required String duplicateId,
    required String canonicalId,
    String? note,
  }) async {
    if (linkThrows) throw StateError('not authorised');
    linked.add((duplicateId: duplicateId, canonicalId: canonicalId));
    return canonicalId;
  }

  @override
  Future<void> unlink(String wallId) async => unlinked.add(wallId);
}

class _FakeReports implements ReportsRemote {
  _FakeReports(this.rows);

  final List<Map<String, dynamic>> rows;
  final resolved = <({String id, bool uphold})>[];
  final filed =
      <({String wallId, ReportReason reason, String? duplicateOfId})>[];

  @override
  Future<List<Map<String, dynamic>>> fetchReports({int limit = 50}) async =>
      rows;

  @override
  Future<String> report({
    required String wallId,
    required ReportReason reason,
    String? body,
    String? routeId,
    String? duplicateOfId,
  }) async {
    filed.add((wallId: wallId, reason: reason, duplicateOfId: duplicateOfId));
    return 'new-report';
  }

  @override
  Future<String> resolve({
    required String reportId,
    required bool uphold,
    String? note,
  }) async {
    resolved.add((id: reportId, uphold: uphold));
    return uphold ? 'upheld' : 'dismissed';
  }
}

/// Admin, with an empty submissions queue — the reports tab is what these
/// tests are about.
class _FakeModeration implements ModerationRemote {
  @override
  Future<bool> isAdmin() async => true;
  @override
  Future<List<Map<String, dynamic>>> fetchQueue({int limit = 50}) async =>
      const [];
  @override
  Future<List<Map<String, dynamic>>> fetchWallModeration(
    Set<String> wallIds,
  ) async => const [];
  @override
  Future<String> reviewTopo({
    required String wallId,
    required bool approve,
    String? reason,
  }) async => 'published';
  @override
  Future<void> removeTopo({required String wallId, String? reason}) async {}

  @override
  Future<List<Map<String, dynamic>>> fetchAbandoned({
    int inactiveDays = 90,
    int limit = 50,
  }) async => const [];

  @override
  Future<List<String>> publishedPhotoObjects(String wallId) async => const [];

  @override
  Future<Map<String, dynamic>?> deletionRequestFor(String wallId) async => null;
  @override
  Future<String> requestDeletion(String wallId, {String? reason}) async => '';
  @override
  Future<List<Map<String, dynamic>>> fetchDeletionRequests({int limit = 50}) async =>
      const [];
  @override
  Future<String> reviewDeletion({
    required String requestId,
    required bool approve,
    String? note,
  }) async => approve ? 'approved' : 'rejected';
  @override
  Future<List<Map<String, dynamic>>> fetchMaterialChanges({
    int limit = 50,
  }) async => const [];
  @override
  Future<void> resolveMaterialChange(String noticeId) async {}
  @override
  Future<int> removePublishedPhotoObjects(List<String> objectPaths) async => 0;
  @override
  Future<int?> requestWithdrawal(String wallId) async => null;
  @override
  Future<String> cancelWithdrawal(String wallId) async => 'published';
}

Map<String, dynamic> _reportRow({
  String reason = 'duplicate',
  String? duplicateOfId = 'wall-b',
  String? duplicateOfName = 'Beta',
  bool alreadyLinked = false,
}) => {
  'id': 'r1',
  'wallId': 'wall-a',
  'wallName': 'Alpha',
  'reason': reason,
  'createdAt': 1000,
  'reporterName': 'Kata',
  'duplicateOfId': duplicateOfId,
  'duplicateOfName': duplicateOfName,
  'alreadyLinked': alreadyLinked,
};

void main() {
  group('NearbyTopo', () {
    test('a row with no id or no distance is skipped, never defaulted', () {
      expect(NearbyTopo.fromRow({'name': 'x', 'distanceM': 3}), isNull);
      expect(NearbyTopo.fromRow({'wallId': 'a', 'name': 'x'}), isNull);
    });

    test(
      'distance is rounded to what a phone GPS can actually support — "18 m" '
      'and "23 m" are the same claim, and both mean "probably the same rock"',
      () {
        expect(_nearby('a', distanceM: 0.4).distanceLabel, 'same spot');
        expect(_nearby('a', distanceM: 22.6).distanceLabel, '23 m away');
        expect(_nearby('a', distanceM: 1450).distanceLabel, '1.4 km away');
      },
    );

    test('an unnamed topo gets a label rather than an empty row', () {
      final topo = NearbyTopo.fromRow({
        'wallId': 'a',
        'distanceM': 10,
        'name': '  ',
      });
      expect(topo!.name, 'Untitled topo');
      expect(topo.ownerLabel, 'Another climber');
    });
  });

  group('the pre-submit warning', () {
    testWidgets(
      'is a PROMPT, not a gate: the confirm button is live and returns true. '
      'A client that could block a second topo would enforce the opposite of '
      '§C-6, which says the second submission is often the better one',
      (tester) async {
        bool? result;
        await tester.pumpWidget(
          MaterialApp(
            theme: MasiTheme.light,
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () async => result = await showDuplicateWarning(
                  context,
                  nearby: [_nearby('a'), _nearby('b', distanceM: 44)],
                  topoName: 'Mine',
                  trusted: false,
                ),
                child: const Text('go'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('go'));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('duplicate-warning-sheet')), findsOneWidget);
        expect(find.text('2 topos already exist here'), findsOneWidget);
        expect(find.byKey(const Key('duplicate-warning-row-a')), findsOneWidget);
        expect(find.byKey(const Key('duplicate-warning-row-b')), findsOneWidget);

        await tester.tap(find.byKey(const Key('duplicate-warning-continue')));
        await tester.pumpAndSettle();
        expect(result, isTrue);
      },
    );

    testWidgets('backing out returns false', (tester) async {
      bool? result;
      await tester.pumpWidget(
        MaterialApp(
          theme: MasiTheme.light,
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async => result = await showDuplicateWarning(
                context,
                nearby: [_nearby('a')],
                topoName: 'Mine',
                trusted: true,
              ),
              child: const Text('go'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(find.text('A topo already exists here'), findsOneWidget);

      await tester.tap(find.byKey(const Key('duplicate-warning-cancel')));
      await tester.pumpAndSettle();
      expect(result, isFalse);
    });
  });

  group('naming which topo it duplicates', () {
    Future<ReportDraft?> run(
      WidgetTester tester, {
      required List<NearbyTopo> candidates,
      required String reasonKey,
      String? targetKey,
      bool dismissTarget = false,
    }) async {
      ReportDraft? draft;
      await tester.pumpWidget(
        MaterialApp(
          theme: MasiTheme.light,
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async => draft = await showReportReporter(
                context,
                targetLabel: 'Alpha',
                duplicateCandidates: candidates,
              ),
              child: const Text('go'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key(reasonKey)));
      await tester.pumpAndSettle();

      if (dismissTarget) {
        // The sheet's own Cancel row.
        await tester.tap(find.text('Cancel').last);
        await tester.pumpAndSettle();
        return draft;
      }
      if (targetKey != null) {
        await tester.tap(find.byKey(Key(targetKey)));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.byKey(const Key('report-body-submit')));
      await tester.pumpAndSettle();
      return draft;
    }

    testWidgets('picking a nearby topo puts its id on the draft', (
      tester,
    ) async {
      final draft = await run(
        tester,
        candidates: [_nearby('wall-b')],
        reasonKey: 'report-reason-duplicate',
        targetKey: 'report-duplicate-target-wall-b',
      );
      expect(draft!.reason, ReportReason.duplicate);
      expect(draft.duplicateOfId, 'wall-b');
    });

    testWidgets(
      '"Something else" still files the report, with no topo named. A '
      'duplicate across a boulder field, or one with no coordinates, is still '
      'a real complaint — it is just one an admin has to research',
      (tester) async {
        final draft = await run(
          tester,
          candidates: [_nearby('wall-b')],
          reasonKey: 'report-reason-duplicate',
          targetKey: 'report-duplicate-target-other',
        );
        expect(draft, isNotNull);
        expect(draft!.duplicateOfId, isNull);
      },
    );

    testWidgets(
      'dismissing the "which one" sheet ABANDONS the report rather than '
      'filing it unnamed — they were asked a question and backed out of it',
      (tester) async {
        final draft = await run(
          tester,
          candidates: [_nearby('wall-b')],
          reasonKey: 'report-reason-duplicate',
          dismissTarget: true,
        );
        expect(draft, isNull);
      },
    );

    testWidgets('no candidates means the step is skipped entirely', (
      tester,
    ) async {
      final draft = await run(
        tester,
        candidates: const [],
        reasonKey: 'report-reason-duplicate',
      );
      expect(draft, isNotNull);
      expect(draft!.duplicateOfId, isNull);
    });

    testWidgets(
      'no other reason is ever asked which topo it duplicates — the server '
      'refuses the combination outright',
      (tester) async {
        final draft = await run(
          tester,
          candidates: [_nearby('wall-b')],
          reasonKey: 'report-reason-unsafe',
        );
        expect(draft!.reason, ReportReason.unsafe);
        expect(draft.duplicateOfId, isNull);
        expect(
          find.byKey(const Key('report-duplicate-target-sheet')),
          findsNothing,
        );
      },
    );
  });

  group('the admin resolution', () {
    Widget wrap(ProviderContainer container) => UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        theme: MasiTheme.light,
        routerConfig: GoRouter(
          initialLocation: '/',
          routes: [
            GoRoute(path: '/', builder: (_, _) => const AdminQueueScreen()),
            GoRoute(path: '/walls/:wallId', builder: (_, _) => const SizedBox()),
          ],
        ),
      ),
    );

    ProviderContainer container(
      _FakeReports reports,
      _FakeDuplicates duplicates,
    ) => ProviderContainer(
      overrides: [
        reportsRemoteProvider.overrideWithValue(reports),
        duplicatesRemoteProvider.overrideWithValue(duplicates),
        moderationRemoteProvider.overrideWithValue(_FakeModeration()),
        // `isAdminProvider` is keyed on the uid and returns false without one,
        // so the admin surface would fail closed and the tabs would never
        // render.
        effectiveUidProvider.overrideWithValue('admin-uid'),
      ],
    );

    testWidgets(
      'linking records the pair AND upholds the report in one gesture. Two '
      'buttons is how a queue fills with linked pairs whose reports are still '
      'open',
      (tester) async {
        final reports = _FakeReports([_reportRow()]);
        final duplicates = _FakeDuplicates();
        final c = container(reports, duplicates);
        addTearDown(c.dispose);

        await tester.pumpWidget(wrap(c));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('admin-tab-reports')));
        await tester.pumpAndSettle();

        expect(find.text('Same as: Beta'), findsOneWidget);
        await tester.tap(find.byKey(const Key('admin-report-link-r1')));
        await tester.pumpAndSettle();

        // The REPORTED topo becomes the alternate: "this is the same boulder
        // as X" makes X the one that was already here.
        expect(duplicates.linked, hasLength(1));
        expect(duplicates.linked.single.duplicateId, 'wall-a');
        expect(duplicates.linked.single.canonicalId, 'wall-b');
        expect(reports.resolved.single, (id: 'r1', uphold: true));
      },
    );

    testWidgets(
      'a report naming nothing offers no link — an admin cannot resolve what '
      'the reporter did not say',
      (tester) async {
        final reports = _FakeReports([
          _reportRow(duplicateOfId: null, duplicateOfName: null),
        ]);
        final c = container(reports, _FakeDuplicates());
        addTearDown(c.dispose);

        await tester.pumpWidget(wrap(c));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('admin-tab-reports')));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('admin-report-link-r1')), findsNothing);
        expect(find.byKey(const Key('admin-report-uphold-r1')), findsOneWidget);
      },
    );

    testWidgets(
      'an ALREADY-linked pair offers no link either, and says so. A button '
      'that appears to act and does nothing is how a moderation queue stops '
      'meaning anything',
      (tester) async {
        final reports = _FakeReports([_reportRow(alreadyLinked: true)]);
        final c = container(reports, _FakeDuplicates());
        addTearDown(c.dispose);

        await tester.pumpWidget(wrap(c));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('admin-tab-reports')));
        await tester.pumpAndSettle();

        expect(find.text('Already linked to Beta'), findsOneWidget);
        expect(find.byKey(const Key('admin-report-link-r1')), findsNothing);
      },
    );

    testWidgets(
      'a failed link does NOT uphold the report. Recording a verdict for a '
      'link that never happened would leave the queue saying the duplicate '
      'was dealt with',
      (tester) async {
        final reports = _FakeReports([_reportRow()]);
        final duplicates = _FakeDuplicates(linkThrows: true);
        final c = container(reports, duplicates);
        addTearDown(c.dispose);

        await tester.pumpWidget(wrap(c));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('admin-tab-reports')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('admin-report-link-r1')));
        await tester.pumpAndSettle();

        expect(reports.resolved, isEmpty);
        expect(find.text("Couldn't link those two"), findsOneWidget);
      },
    );

    testWidgets('a non-duplicate report is unaffected by any of this', (
      tester,
    ) async {
      final reports = _FakeReports([
        _reportRow(
          reason: 'unsafe',
          duplicateOfId: null,
          duplicateOfName: null,
        ),
      ]);
      final c = container(reports, _FakeDuplicates());
      addTearDown(c.dispose);

      await tester.pumpWidget(wrap(c));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('admin-tab-reports')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('admin-report-link-r1')), findsNothing);
      expect(
        find.byKey(const Key('admin-report-duplicate-of-r1')),
        findsNothing,
      );
    });
  });

  group('ContentReport', () {
    test('canLink needs a duplicate reason, a named topo, and no link yet', () {
      ContentReport parse(Map<String, dynamic> row) =>
          ContentReport.fromRow(row)!;
      expect(parse(_reportRow()).canLink, isTrue);
      expect(parse(_reportRow(alreadyLinked: true)).canLink, isFalse);
      expect(parse(_reportRow(duplicateOfId: null)).canLink, isFalse);
      expect(parse(_reportRow(reason: 'inaccurate')).canLink, isFalse);
    });
  });
}
