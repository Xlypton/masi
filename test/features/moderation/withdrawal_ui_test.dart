// What the withdrawal cooldown looks like on screen (community editing
// phase 5 / C-3).
//
// The banner has two audiences and they are not the same person, which is the
// only genuinely subtle thing here. An owner needs to know where their topo
// stands in review and that they can still change their mind. A READER needs
// exactly one fact — that a topo they may be planning a trip around is on its
// way out — and is entitled to none of the rest. Getting that split wrong
// leaks a rejection reason to strangers in one direction, and in the other
// removes the warning that is the entire reason the topo stays visible for ten
// days instead of vanishing.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:masi/app/theme.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/features/moderation/presentation/moderation_banner.dart';

final _now = DateTime.utc(2026, 8, 7, 12);

WallModerationRow _row({
  String state = 'published',
  Duration? requestedAgo,
  String? reason,
}) => WallModerationRow(
  wallId: 'w1',
  state: state,
  submittedAt: 0,
  reviewedAt: null,
  reviewerId: null,
  rejectionReason: reason,
  withdrawRequestedAt: requestedAgo == null
      ? null
      : _now.subtract(requestedAgo).millisecondsSinceEpoch,
  updatedAt: 0,
);

Future<void> _pump(
  WidgetTester tester,
  WallModerationRow row, {
  required bool isOwner,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: MasiTheme.light,
      home: Scaffold(
        body: ModerationNotice(row: row, isOwner: isOwner, now: _now),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('the reader', () {
    testWidgets('is warned that a topo is being withdrawn', (tester) async {
      await _pump(
        tester,
        _row(requestedAgo: const Duration(days: 3)),
        isOwner: false,
      );

      expect(find.byKey(const Key('moderation-notice-withdrawing')), findsOne);
      expect(find.textContaining('The owner is withdrawing'), findsOne);
      expect(find.textContaining('7 days'), findsOne);
    });

    testWidgets(
      'is NOT told they can cancel — they cannot, and offering it would be a '
      'dead promise on somebody else\'s topo',
      (tester) async {
        await _pump(
          tester,
          _row(requestedAgo: const Duration(days: 3)),
          isOwner: false,
        );
        expect(find.textContaining('cancel'), findsNothing);
      },
    );

    testWidgets(
      'sees nothing at all on a healthy published topo — a banner saying '
      '"this is fine" is noise on every page in the feed',
      (tester) async {
        await _pump(tester, _row(), isOwner: false);
        expect(find.byType(Container), findsNothing);
      },
    );

    testWidgets(
      'never sees a rejection reason. RLS would not hand one over, but a '
      'widget that would render it if it arrived is one policy edit away from '
      'publishing a moderator\'s private note to strangers',
      (tester) async {
        await _pump(
          tester,
          _row(state: 'rejected', reason: 'Photo shows a private house'),
          isOwner: false,
        );
        expect(find.textContaining('private house'), findsNothing);
        expect(find.text('Not approved'), findsNothing);
      },
    );

    testWidgets('is told nothing once the window has closed', (tester) async {
      // By then the topo is out of every public query, so a reader looking at
      // a cached page has nothing actionable left to learn.
      await _pump(
        tester,
        _row(requestedAgo: const Duration(days: 40)),
        isOwner: false,
      );
      expect(find.textContaining('withdraw'), findsNothing);
    });
  });

  group('the owner', () {
    testWidgets('gets the countdown and the way out', (tester) async {
      await _pump(
        tester,
        _row(requestedAgo: const Duration(days: 8)),
        isOwner: true,
      );

      expect(find.text('Being withdrawn'), findsOne);
      expect(find.textContaining('2 days'), findsOne);
      expect(find.textContaining('You can cancel'), findsOne);
    });

    testWidgets('reads "today" on the last day rather than "0 days"', (
      tester,
    ) async {
      await _pump(
        tester,
        _row(requestedAgo: const Duration(days: 10)),
        isOwner: true,
      );
      // Ten days elapsed: this is now `withdrawn`, not a countdown.
      expect(find.text('Withdrawn'), findsOne);
      expect(find.textContaining('goes back through review'), findsOne);
    });

    testWidgets(
      'sees "Waiting for review" while pending — the acknowledgement whose '
      'absence made submitting indistinguishable from publishing',
      (tester) async {
        await _pump(tester, _row(state: 'pending'), isOwner: true);
        expect(find.byKey(const Key('moderation-notice-pending')), findsOne);
        expect(find.text('Waiting for review'), findsOne);
      },
    );

    testWidgets('sees the rejection reason, which is the whole point', (
      tester,
    ) async {
      await _pump(
        tester,
        _row(state: 'rejected', reason: 'Photo shows a private house'),
        isOwner: true,
      );
      expect(find.text('Photo shows a private house'), findsOne);
    });

    testWidgets('sees nothing on a healthy published topo', (tester) async {
      await _pump(tester, _row(), isOwner: true);
      expect(find.byType(Container), findsNothing);
    });

    testWidgets(
      'a withdrawing topo keys as `withdrawing`, not `published` — it is '
      'stored as published, and a test asking "is the warning up" must not '
      'have to match a perfectly healthy topo',
      (tester) async {
        await _pump(tester, _row(requestedAgo: Duration.zero), isOwner: true);
        expect(find.byKey(const Key('moderation-notice-withdrawing')), findsOne);
        expect(find.byKey(const Key('moderation-notice-published')), findsNothing);
      },
    );
  });
}
