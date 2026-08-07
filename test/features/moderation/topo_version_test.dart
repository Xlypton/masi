// Version history, client side (community editing phase 6a / C-8).
//
// The domain half here is small but it is the part a person reads: a history
// list exists to answer "is it worth looking at this one", and it answers it
// by comparing adjacent entries rather than by diffing snapshots. That makes
// two failure modes easy and both are covered below — claiming a change that
// this list cannot actually see, and describing the oldest entry as if
// somebody had just built the whole topo from nothing.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:masi/app/theme.dart';
import 'package:masi/features/account/application/auth_providers.dart';
import 'package:masi/features/moderation/application/moderation_providers.dart';
import 'package:masi/features/moderation/application/topo_version_providers.dart';
import 'package:masi/features/moderation/data/moderation_remote.dart';
import 'package:masi/features/moderation/data/topo_versions_remote.dart';
import 'package:masi/features/moderation/domain/topo_version.dart';
import 'package:masi/features/moderation/presentation/topo_history_sheet.dart';

Map<String, dynamic> _row(
  String id, {
  String name = 'Dolomitici',
  int routes = 3,
  int at = 1000,
  String? actorId = 'u1',
  String? actorName = 'Kata',
}) => {
  'id': id,
  'wallName': name,
  'routeCount': routes,
  'createdAt': at,
  'actorId': actorId,
  'actorName': actorName,
};

class _FakeVersions implements TopoVersionsRemote {
  _FakeVersions(this.rows, {this.listThrows = false});

  final List<Map<String, dynamic>> rows;
  final bool listThrows;
  final reverted = <(String, String)>[];
  Object? revertError;

  @override
  Future<List<Map<String, dynamic>>> fetchVersions(
    String wallId, {
    int limit = 30,
  }) async {
    if (listThrows) throw StateError('offline');
    return rows;
  }

  @override
  Future<int> revert({
    required String wallId,
    required String versionId,
  }) async {
    if (revertError != null) throw revertError!;
    reverted.add((wallId, versionId));
    return 4;
  }
}

class _FakeModeration implements ModerationRemote {
  _FakeModeration({this.admin = false});
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
  Future<List<Map<String, dynamic>>> fetchAbandoned({
    int inactiveDays = 90,
    int limit = 50,
  }) async => const [];

  @override
  Future<List<String>> publishedPhotoObjects(String wallId) async => const [];

  @override
  Future<int> removePublishedPhotoObjects(List<String> objectPaths) async => 0;
  @override
  Future<int?> requestWithdrawal(String wallId) async => null;
  @override
  Future<String> cancelWithdrawal(String wallId) async => 'published';
}

Future<_FakeVersions> _pumpSheet(
  WidgetTester tester, {
  required List<Map<String, dynamic>> rows,
  bool admin = false,
  bool listThrows = false,
}) async {
  final remote = _FakeVersions(rows, listThrows: listThrows);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        topoVersionsRemoteProvider.overrideWithValue(remote),
        moderationRemoteProvider.overrideWithValue(
          _FakeModeration(admin: admin),
        ),
        effectiveUidProvider.overrideWithValue('me'),
      ],
      child: MaterialApp(
        theme: MasiTheme.light,
        home: const Scaffold(body: TopoHistorySheet(wallId: 'w1')),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return remote;
}

/// Opens the sheet through the REAL `showModalBottomSheet` path, so its
/// measured size is the one a user actually gets. [_pumpSheet] mounts the
/// widget directly, which is fine for content assertions and useless for
/// anything about how the sheet sits on the display.
Future<_FakeVersions> _pumpSheetInModal(
  WidgetTester tester, {
  required List<Map<String, dynamic>> rows,
  bool admin = false,
  bool listThrows = false,
  bool settle = true,
}) async {
  final remote = _FakeVersions(rows, listThrows: listThrows);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        topoVersionsRemoteProvider.overrideWithValue(remote),
        moderationRemoteProvider.overrideWithValue(
          _FakeModeration(admin: admin),
        ),
        effectiveUidProvider.overrideWithValue('me'),
      ],
      child: MaterialApp(
        theme: MasiTheme.light,
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () => showTopoHistory(context, wallId: 'w1'),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
  return remote;
}

void main() {
  group('what a version says it changed', () {
    test('routes added since the version before it', () {
      final versions = [
        TopoVersion.fromRow(_row('v2', routes: 7)),
        TopoVersion.fromRow(_row('v1', routes: 3)),
      ];
      expect(TopoVersionChange.between(versions, 0).summary, '+4 routes');
    });

    test('routes removed', () {
      final versions = [
        TopoVersion.fromRow(_row('v2', routes: 1)),
        TopoVersion.fromRow(_row('v1', routes: 3)),
      ];
      expect(TopoVersionChange.between(versions, 0).summary, '−2 routes');
    });

    test('a rename names the OLD title, which is the part you forgot', () {
      final versions = [
        TopoVersion.fromRow(_row('v2', name: 'Bad Name')),
        TopoVersion.fromRow(_row('v1', name: 'Dolomitici')),
      ];
      expect(
        TopoVersionChange.between(versions, 0).summary,
        'renamed from "Dolomitici"',
      );
    });

    test('both at once', () {
      final versions = [
        TopoVersion.fromRow(_row('v2', name: 'B', routes: 5)),
        TopoVersion.fromRow(_row('v1', name: 'A', routes: 4)),
      ];
      expect(
        TopoVersionChange.between(versions, 0).summary,
        '+1 route · renamed from "A"',
      );
    });

    test(
      'a version that changed something INVISIBLE to this list says nothing '
      'rather than inventing a difference — a redrawn line, a corrected grade '
      'and an edited description all leave the count and the name alone',
      () {
        final versions = [
          TopoVersion.fromRow(_row('v2')),
          TopoVersion.fromRow(_row('v1')),
        ];
        final change = TopoVersionChange.between(versions, 0);
        expect(change.isEmpty, isTrue);
        expect(change.summary, isNull);
      },
    );

    test(
      'the OLDEST version reports nothing. It has no predecessor, and calling '
      'its whole contents "added" would describe the baseline snapshot as if '
      'someone had just built the topo from scratch',
      () {
        final versions = [
          TopoVersion.fromRow(_row('v2', routes: 7)),
          TopoVersion.fromRow(_row('v1', routes: 3)),
        ];
        expect(TopoVersionChange.between(versions, 1).summary, isNull);
      },
    );

    test('an out-of-range index is inert rather than throwing', () {
      expect(TopoVersionChange.between(const [], 0).summary, isNull);
      expect(
        TopoVersionChange.between([TopoVersion.fromRow(_row('v1'))], -1)
            .summary,
        isNull,
      );
    });
  });

  group('who to credit', () {
    test('a display name when there is one', () {
      expect(TopoVersion.fromRow(_row('v1')).actorLabel, 'Kata');
    });

    test(
      'never a raw uid. It is not a name, it tells the reader nothing, and it '
      'puts an identifier on screen that has no business being there',
      () {
        final v = TopoVersion.fromRow(_row('v1', actorName: null));
        expect(v.actorLabel, 'Someone');
        expect(v.actorLabel, isNot(contains('u1')));
      },
    );

    test('the baseline rows say so, rather than crediting a phantom', () {
      final v = TopoVersion.fromRow(
        _row('v1', actorId: null, actorName: null),
      );
      expect(v.actorLabel, 'Before history was kept');
    });

    test('a blank name is treated as absent, not rendered as empty', () {
      final v = TopoVersion.fromRow(_row('v1', actorName: '   '));
      expect(v.actorLabel, 'Someone');
    });
  });

  group('the sheet', () {
    testWidgets('lists versions newest-first with their change summary', (
      tester,
    ) async {
      await _pumpSheet(
        tester,
        rows: [_row('v2', routes: 7), _row('v1', routes: 3)],
      );

      expect(find.byKey(const Key('topo-version-row-v2')), findsOne);
      expect(find.byKey(const Key('topo-version-row-v1')), findsOne);
      expect(find.byKey(const Key('topo-version-change-v2')), findsOne);
      expect(find.text('+4 routes'), findsOne);
      // The oldest row carries no summary, per the domain test above.
      expect(find.byKey(const Key('topo-version-change-v1')), findsNothing);
    });

    testWidgets(
      'a NON-admin gets no restore button anywhere. The server refuses them '
      'too, but a button that always errors is a worse answer than no button',
      (tester) async {
        await _pumpSheet(tester, rows: [_row('v2'), _row('v1')]);
        expect(find.text('Restore'), findsNothing);
      },
    );

    testWidgets(
      'an admin can restore an OLD version but not the newest — the newest is '
      'the current state, so restoring it is a no-op dressed as an action',
      (tester) async {
        await _pumpSheet(
          tester,
          rows: [_row('v2'), _row('v1')],
          admin: true,
        );

        expect(find.byKey(const Key('topo-history-restore-v1')), findsOne);
        expect(find.byKey(const Key('topo-history-restore-v2')), findsNothing);
      },
    );

    testWidgets('restoring confirms first, then calls the RPC', (tester) async {
      final remote = await _pumpSheet(
        tester,
        rows: [_row('v2'), _row('v1', routes: 4)],
        admin: true,
      );

      await tester.tap(find.byKey(const Key('topo-history-restore-v1')));
      await tester.pumpAndSettle();

      expect(find.text('Restore this version?'), findsOne);
      // The two consequences an admin cannot guess: what gets thrown away, and
      // that the mistake is recoverable.
      expect(find.textContaining('Anything added since is removed'), findsOne);
      expect(find.textContaining('can be undone'), findsOne);
      expect(remote.reverted, isEmpty);

      await tester.tap(
        find.byKey(const Key('topo-history-restore-confirm-v1')),
      );
      await tester.pumpAndSettle();

      expect(remote.reverted, [('w1', 'v1')]);
      expect(find.text('Restored — 4 routes'), findsOne);
    });

    testWidgets('backing out of the confirm restores nothing', (tester) async {
      final remote = await _pumpSheet(
        tester,
        rows: [_row('v2'), _row('v1')],
        admin: true,
      );

      await tester.tap(find.byKey(const Key('topo-history-restore-v1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel').last);
      await tester.pumpAndSettle();

      expect(remote.reverted, isEmpty);
    });

    testWidgets(
      'a FAILED restore says so loudly. An admin who believes a vandalised '
      'topo has been repaired when it has not is the worst outcome this whole '
      'phase exists to prevent',
      (tester) async {
        final remote = await _pumpSheet(
          tester,
          rows: [_row('v2'), _row('v1')],
          admin: true,
        );
        remote.revertError = StateError('not authorised');

        await tester.tap(find.byKey(const Key('topo-history-restore-v1')));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('topo-history-restore-confirm-v1')),
        );
        await tester.pumpAndSettle();

        expect(find.textContaining('Could not restore'), findsOne);
      },
    );

    testWidgets(
      'a FAILED fetch shows an error, NOT an empty list. "Nothing has ever '
      'changed here" is a claim, and rendering it because the request failed '
      'states something false about the exact thing the reader came to check',
      (tester) async {
        await _pumpSheet(tester, rows: const [], listThrows: true);

        expect(find.byKey(const Key('topo-history-empty')), findsNothing);
        expect(
          find.textContaining("Couldn't load this topo's history"),
          findsOne,
        );
      },
    );

    testWidgets('a genuinely empty history explains why it is empty', (
      tester,
    ) async {
      await _pumpSheet(tester, rows: const []);
      expect(find.byKey(const Key('topo-history-empty')), findsOne);
      expect(find.textContaining('when a topo is published'), findsOne);
    });

    testWidgets(
      'the sheet SHRINKS TO ITS CONTENT rather than filling the display. '
      'It used to delegate its three states to MasiAsyncView, which puts its '
      'content in an Expanded — correct on a screen, but here it made the '
      'sheet cover the whole viewport, so there was no scrim left to tap and '
      'the sheet could not be dismissed at all. Every test in this file '
      'passed while that was true, because a widget test never tries to tap '
      'outside a sheet; a browser found it in one gesture',
      (tester) async {
        await _pumpSheetInModal(tester, rows: [_row('v2'), _row('v1')]);

        final sheet = tester.getRect(
          find.byKey(const Key('topo-history-sheet')),
        );
        final screen = tester.getRect(find.byType(MaterialApp));
        expect(
          sheet.height,
          lessThan(screen.height * 0.7),
          reason: 'two rows should not need most of the display',
        );
        expect(
          sheet.top,
          greaterThan(0),
          reason: 'there must be scrim above the sheet to tap',
        );
      },
    );

    testWidgets('a LOADING sheet is short too — not a full-screen spinner', (
      tester,
    ) async {
      await _pumpSheetInModal(tester, rows: const [], settle: false);
      // Pumped, not settled: this is the state while the fetch is in flight.
      await tester.pump(const Duration(milliseconds: 400));

      final sheet = tester.getRect(find.byKey(const Key('topo-history-sheet')));
      final screen = tester.getRect(find.byType(MaterialApp));
      expect(sheet.height, lessThan(screen.height * 0.7));
    });

    testWidgets('an ERROR sheet is short too', (tester) async {
      await _pumpSheetInModal(tester, rows: const [], listThrows: true);

      expect(find.byKey(const Key('topo-history-error')), findsOne);
      final sheet = tester.getRect(find.byKey(const Key('topo-history-sheet')));
      final screen = tester.getRect(find.byType(MaterialApp));
      expect(sheet.height, lessThan(screen.height * 0.7));
    });
  });
}
