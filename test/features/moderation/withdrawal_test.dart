// The withdrawal cooldown, client side (community editing phase 5 / C-3).
//
// The thing under test is a deliberate asymmetry in the design: the server
// NEVER writes a matured withdrawal back to the `state` column. The ten days
// are evaluated lazily inside `is_wall_public()`, so no cron can drift and the
// answer is right at every instant (COMMUNITY_IMPL.md §0.2) — but the cost is
// that a row reading `published` can mean two opposite things, and every
// client that shows it to a person has to do the arithmetic itself.
//
// `ModerationView` is that arithmetic, and these are its boundaries. They
// matter because getting one wrong is not a cosmetic bug: telling an owner
// their topo is still public when it left public view yesterday, or that it is
// gone when it is still up, are both worse than saying nothing.

import 'package:flutter_test/flutter_test.dart';
import 'package:masi/features/moderation/domain/moderation_state.dart';

/// A fixed "now" so the ten-day boundary can be crossed by arithmetic rather
/// than by waiting, and so a test cannot pass or fail depending on when it
/// runs.
final _now = DateTime.utc(2026, 8, 7, 12);

ModerationView _view({
  String state = 'published',
  Duration? requestedAgo,
  String? reason,
}) => ModerationView.fromRow(
  state: state,
  withdrawRequestedAt: requestedAgo == null
      ? null
      : _now.subtract(requestedAgo).millisecondsSinceEpoch,
  rejectionReason: reason,
  now: _now,
);

void main() {
  group('nothing running', () {
    test('a plain published topo is not withdrawing and not matured', () {
      final view = _view();
      expect(view.isWithdrawing, isFalse);
      expect(view.effectiveState, ModerationState.published);
      expect(view.deadline, isNull);
      expect(view.daysRemaining, isNull);
    });

    test(
      'hasMatured is FALSE with no withdrawal — "never asked" and "the window '
      'closed" are opposite facts and must not collapse into each other',
      () {
        // Read the other way round, every healthy published topo in the app
        // would report itself as gone.
        expect(_view().hasMatured, isFalse);
      },
    );

    test('a draft is untouched by any of this', () {
      final view = _view(state: 'draft');
      expect(view.effectiveState, ModerationState.draft);
      expect(view.isDeleteProtected, isFalse);
      expect(view.isWithdrawing, isFalse);
    });
  });

  group('while the window runs', () {
    test('a fresh request reads as withdrawing, still stored as published', () {
      final view = _view(requestedAgo: Duration.zero);
      expect(view.isWithdrawing, isTrue);
      expect(view.storedState, ModerationState.published);
      expect(
        view.effectiveState,
        ModerationState.published,
        reason: 'it IS still public — that is the entire point of the ten days',
      );
      expect(view.daysRemaining, 10);
    });

    test('the deadline is exactly ten days after the request', () {
      final view = _view(requestedAgo: const Duration(days: 3));
      // Compared as an INSTANT, not by equality: `deadline` is built from
      // `fromMillisecondsSinceEpoch`, so it comes back in the device's local
      // zone (which is what you want to show a person), and `==` on DateTime
      // is false across zones even for the same moment.
      expect(
        view.deadline!.isAtSameMomentAs(_now.add(const Duration(days: 7))),
        isTrue,
      );
      expect(view.daysRemaining, 7);
    });

    test(
      'a part-day rounds UP, so the last hours read "1 day" rather than "0 '
      'days" on a topo that is still public',
      () {
        final view = _view(
          requestedAgo: const Duration(days: 9, hours: 23),
        );
        expect(view.daysRemaining, 1);
        expect(view.isWithdrawing, isTrue);
      },
    );

    test('the topo is delete-protected for the whole window', () {
      expect(_view(requestedAgo: Duration.zero).isDeleteProtected, isTrue);
      expect(
        _view(requestedAgo: const Duration(days: 9, hours: 23))
            .isDeleteProtected,
        isTrue,
      );
    });
  });

  group('the boundary itself', () {
    test('one second before ten days: still running', () {
      final view = _view(
        requestedAgo: const Duration(days: 10) - const Duration(seconds: 1),
      );
      expect(view.hasMatured, isFalse);
      expect(view.isWithdrawing, isTrue);
      expect(view.effectiveState, ModerationState.published);
    });

    test('exactly ten days: matured — the deadline is inclusive', () {
      final view = _view(requestedAgo: const Duration(days: 10));
      expect(view.hasMatured, isTrue);
      expect(view.isWithdrawing, isFalse);
      expect(view.effectiveState, ModerationState.withdrawn);
      expect(view.daysRemaining, 0);
    });

    test(
      'the moment it matures the topo stops being protected — the cooldown is '
      'a delay, not a permanent lock',
      () {
        expect(
          _view(requestedAgo: const Duration(days: 10)).isDeleteProtected,
          isFalse,
        );
      },
    );
  });

  group('after the window', () {
    test(
      'a stored "published" with an elapsed window reads as WITHDRAWN, which '
      'is what every other observer already sees',
      () {
        final view = _view(requestedAgo: const Duration(days: 40));
        expect(view.storedState, ModerationState.published);
        expect(view.effectiveState, ModerationState.withdrawn);
      },
    );

    test('days remaining floors at zero rather than going negative', () {
      expect(_view(requestedAgo: const Duration(days: 40)).daysRemaining, 0);
    });
  });

  group('states other than published', () {
    test(
      'a withdrawal timestamp on a PENDING row does not fabricate a countdown '
      '— only a published topo has public visibility to lose',
      () {
        final view = _view(state: 'pending', requestedAgo: Duration.zero);
        expect(view.isWithdrawing, isFalse);
        expect(view.isDeleteProtected, isFalse);
        expect(view.effectiveState, ModerationState.pending);
      },
    );

    test('a rejected row keeps its reason and is freely deletable', () {
      final view = _view(state: 'rejected', reason: 'Photo is unusable');
      expect(view.effectiveState, ModerationState.rejected);
      expect(view.rejectionReason, 'Photo is unusable');
      expect(view.isDeleteProtected, isFalse);
    });

    test(
      'an unknown state from a newer server falls back to draft, so the '
      'protection is never claimed on the strength of a value we cannot read',
      () {
        final view = _view(state: 'quarantined');
        expect(view.effectiveState, ModerationState.draft);
        expect(view.isDeleteProtected, isFalse);
      },
    );

    test('a missing row is a draft, not a crash', () {
      final view = ModerationView.fromRow(state: null, now: _now);
      expect(view.effectiveState, ModerationState.draft);
      expect(view.isWithdrawing, isFalse);
    });
  });

  test(
    'the client cooldown matches the 864000000 ms the server enforces — these '
    'two numbers living in different languages is exactly how a countdown ends '
    'up disagreeing with the thing it counts down to',
    () {
      expect(kWithdrawalCooldown.inMilliseconds, 864000000);
    },
  );
}
