// Reporting published content (community editing phase 6b / C-7).
//
// Two things here are worth more than the rest of the file.
//
// The first is that "unsafe" is not just another category (C-12). This is
// climbing: a missing loose-block warning or a line drawn past a runout can
// hurt someone, so an unsafe report is escalated rather than left to wait
// behind twelve duplicate-listing complaints. The server sorts it to the
// front; the client has to actually SURFACE that, or the sorting is decorative
// and the admin never opens the tab.
//
// The second is who can see a report. It is readable by its author and by
// admins, and pointedly NOT by the topo's owner, because several of the
// reasons are accusations about the owner and handing the accused the
// reporter's identity is how a community learns that reporting invites
// retaliation. The client half of that is simply that the reporter's name
// appears in exactly one place, and it is behind the admin gate.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:masi/app/theme.dart';
import 'package:masi/features/account/application/auth_providers.dart';
import 'package:masi/features/moderation/application/moderation_providers.dart';
import 'package:masi/features/moderation/application/report_providers.dart';
import 'package:masi/features/moderation/data/moderation_remote.dart';
import 'package:masi/features/moderation/data/reports_remote.dart';
import 'package:masi/features/moderation/domain/content_report.dart';
import 'package:masi/features/moderation/presentation/admin_queue_screen.dart';

Map<String, dynamic> _row(
  String id, {
  String reason = 'inaccurate',
  String wall = 'Dolomitici',
  String? route,
  String? body,
  String? reporter = 'Kata',
  int at = 1000,
}) => {
  'id': id,
  'wallId': 'w-$id',
  'wallName': wall,
  'routeId': route == null ? null : 'r-$id',
  'routeName': route,
  'reporterId': 'u1',
  'reporterName': reporter,
  'reason': reason,
  'body': body,
  'urgent': reason == 'unsafe',
  'createdAt': at,
};

class _FakeReports implements ReportsRemote {
  _FakeReports(this.rows, {this.throws = false});

  final List<Map<String, dynamic>> rows;
  final bool throws;
  final filed = <(String, ReportReason, String?)>[];
  final resolved = <(String, bool)>[];
  Object? resolveError;

  @override
  Future<List<Map<String, dynamic>>> fetchReports({int limit = 50}) async {
    if (throws) throw StateError('not authorised');
    return rows;
  }

  @override
  Future<String> report({
    required String wallId,
    required ReportReason reason,
    String? body,
    String? routeId,
    String? duplicateOfId,
  }) async {
    filed.add((wallId, reason, body));
    return 'new-report';
  }

  @override
  Future<String> resolve({
    required String reportId,
    required bool uphold,
    String? note,
  }) async {
    if (resolveError != null) throw resolveError!;
    resolved.add((reportId, uphold));
    return uphold ? 'upheld' : 'dismissed';
  }
}

class _FakeModeration implements ModerationRemote {
  _FakeModeration({this.admin = true});
  final bool admin;

  @override
  Future<bool> isAdmin() async => admin;
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
  Future<int?> requestWithdrawal(String wallId) async => null;
  @override
  Future<String> cancelWithdrawal(String wallId) async => 'published';
}

Future<_FakeReports> _pumpQueue(
  WidgetTester tester, {
  required List<Map<String, dynamic>> rows,
  bool admin = true,
  bool throws = false,
}) async {
  final remote = _FakeReports(rows, throws: throws);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        reportsRemoteProvider.overrideWithValue(remote),
        moderationRemoteProvider.overrideWithValue(
          _FakeModeration(admin: admin),
        ),
        effectiveUidProvider.overrideWithValue('me'),
      ],
      child: MaterialApp.router(
        theme: MasiTheme.light,
        routerConfig: GoRouter(
          initialLocation: '/',
          routes: [
            GoRoute(
              path: '/',
              builder: (context, state) => const AdminQueueScreen(),
            ),
            GoRoute(
              path: '/walls/:wallId',
              builder: (context, state) => const SizedBox(),
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return remote;
}

void main() {
  group('parsing a report', () {
    test('the wire value for notYours is snake_case, not the enum name', () {
      expect(ReportReason.notYours.wire, 'not_yours');
      expect(ReportReason.fromWire('not_yours'), ReportReason.notYours);
    });

    test('every reason round-trips through the wire', () {
      for (final reason in ReportReason.values) {
        expect(
          ReportReason.fromWire(reason.wire),
          reason,
          reason: '${reason.name} did not survive the round trip',
        );
      }
    });

    test('only unsafe is urgent', () {
      expect(
        ReportReason.values.where((r) => r.isUrgent).toList(),
        [ReportReason.unsafe],
      );
    });

    test(
      'a reason this client does not know is DROPPED, not shown unlabelled. '
      'An unlabelled row in a moderation queue invites a decision made on no '
      'information',
      () {
        expect(ContentReport.fromRow(_row('a', reason: 'witchcraft')), isNull);
      },
    );

    test('a row missing its id or wall is dropped rather than half-built', () {
      expect(ContentReport.fromRow({'reason': 'unsafe'}), isNull);
      expect(
        ContentReport.fromRow({'id': 'a', 'reason': 'unsafe'}),
        isNull,
      );
    });

    test('a named route is what was reported; otherwise the topo is', () {
      expect(
        ContentReport.fromRow(_row('a', route: 'Left Arete'))!.targetLabel,
        'Left Arete',
      );
      expect(ContentReport.fromRow(_row('a'))!.targetLabel, 'Dolomitici');
    });

    test('a reporter with no profile is "Someone", never a raw uid', () {
      final report = ContentReport.fromRow(_row('a', reporter: null))!;
      expect(report.reporterLabel, 'Someone');
      expect(report.reporterLabel, isNot(contains('u1')));
    });

    test('a blank body is treated as absent rather than rendered empty', () {
      expect(ContentReport.fromRow(_row('a', body: '   '))!.body, isNull);
    });
  });

  group('the admin queue', () {
    testWidgets('lists open reports with their reason and target', (
      tester,
    ) async {
      await _pumpQueue(tester, rows: [_row('a', body: 'grade is way off')]);

      await tester.tap(find.byKey(const Key('admin-tab-reports')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('admin-report-row-a')), findsOne);
      expect(find.text('Inaccurate'), findsOne);
      expect(find.text('Dolomitici'), findsOne);
      expect(find.text('grade is way off'), findsOne);
    });

    testWidgets(
      'an UNSAFE report is marked ON THE TAB, so an admin who never opens it '
      'still learns it is there. Sorting it to the front of a list nobody '
      'looks at would be escalation in name only (C-12)',
      (tester) async {
        await _pumpQueue(
          tester,
          rows: [_row('a', reason: 'unsafe'), _row('b')],
        );

        expect(find.text('Reports (2) !'), findsOne);
      },
    );

    testWidgets('an ordinary report count carries no urgency marker', (
      tester,
    ) async {
      await _pumpQueue(tester, rows: [_row('a'), _row('b')]);
      expect(find.text('Reports (2)'), findsOne);
      expect(find.text('Reports (2) !'), findsNothing);
    });

    testWidgets('an empty queue says so without a count', (tester) async {
      await _pumpQueue(tester, rows: const []);
      expect(find.text('Reports'), findsOne);

      await tester.tap(find.byKey(const Key('admin-tab-reports')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('admin-reports-empty')), findsOne);
    });

    testWidgets('upholding calls the RPC and says which way it went', (
      tester,
    ) async {
      final remote = await _pumpQueue(tester, rows: [_row('a')]);

      await tester.tap(find.byKey(const Key('admin-tab-reports')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('admin-report-uphold-a')));
      await tester.pumpAndSettle();

      expect(remote.resolved, [('a', true)]);
      expect(find.text('Report upheld'), findsOne);
    });

    testWidgets(
      'dismissing is recorded as its own verdict rather than as "closed" — '
      'phase 8 needs consistently-frivolous reporters as much as it needs '
      'consistently-right ones',
      (tester) async {
        final remote = await _pumpQueue(tester, rows: [_row('a')]);

        await tester.tap(find.byKey(const Key('admin-tab-reports')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('admin-report-dismiss-a')));
        await tester.pumpAndSettle();

        expect(remote.resolved, [('a', false)]);
        expect(find.text('Report dismissed'), findsOne);
      },
    );

    testWidgets('a failed resolution says so rather than looking inert', (
      tester,
    ) async {
      final remote = await _pumpQueue(tester, rows: [_row('a')]);
      remote.resolveError = StateError('session expired');

      await tester.tap(find.byKey(const Key('admin-tab-reports')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('admin-report-uphold-a')));
      await tester.pumpAndSettle();

      expect(find.text("Couldn't record that decision"), findsOne);
    });

    testWidgets(
      'a FAILED fetch shows an error, not an empty queue. "Nothing reported" '
      'when the truth is "we could not ask" is the one message a moderation '
      'surface must never send',
      (tester) async {
        await _pumpQueue(tester, rows: const [], throws: true);

        await tester.tap(find.byKey(const Key('admin-tab-reports')));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('admin-reports-empty')), findsNothing);
        expect(find.textContaining("Couldn't load reports"), findsOne);
      },
    );

    testWidgets(
      'a NON-admin sees the refusal and no tabs at all — not an empty '
      'Reports tab, which would leak that the surface exists and works',
      (tester) async {
        await _pumpQueue(tester, rows: [_row('a')], admin: false);

        expect(find.byKey(const Key('admin-queue-forbidden')), findsOne);
        expect(find.byKey(const Key('admin-tab-reports')), findsNothing);
      },
    );
  });
}
