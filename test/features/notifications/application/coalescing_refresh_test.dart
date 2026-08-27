// Pins the difference between a leading-edge guard and an actual coalescer.
//
// The bug this replaces: `NotificationRealtime._nudge` held a single
// `bool _refreshInFlight` and did `if (_refreshInFlight) return;`. A realtime
// INSERT arriving after the refresh had read the server but before it
// completed was DISCARDED — so the badge, whose whole job is to appear without
// being asked for, silently lagged until the user opened a screen. The comment
// above it said "coalescing bursts", which is what it looked like it did.
//
// These tests are only possible because the logic moved out of the `Notifier`:
// `build()` needs a live `supabaseClientProvider`, so under test it returns
// early, never subscribes, and `_nudge` was unreachable.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:masi/features/notifications/application/coalescing_refresh.dart';

void main() {
  group('CoalescingRefresh', () {
    test('the first schedule runs immediately — a badge must not wait out a '
        'debounce interval before it appears', () async {
      var runs = 0;
      final refresh = CoalescingRefresh(() async => runs++);

      refresh.schedule();

      expect(runs, 1, reason: 'leading edge, synchronously');
    });

    test('a trigger arriving MID-FLIGHT produces a trailing run instead of '
        'being dropped', () async {
      var runs = 0;
      final gate = Completer<void>();
      final refresh = CoalescingRefresh(() async {
        runs++;
        await gate.future;
      });

      refresh.schedule();
      expect(runs, 1);

      // The event the old code threw away: it lands while the first refresh is
      // still awaiting the server.
      refresh.schedule();
      expect(runs, 1, reason: 'not run yet — one at a time');
      expect(refresh.hasQueued, isTrue, reason: 'but REMEMBERED. This is the '
          'whole fix; the old code returned here and forgot it.');

      gate.complete();
      await pumpEventQueue();

      expect(runs, 2);
      expect(refresh.isRunning, isFalse);
      expect(refresh.hasQueued, isFalse);
    });

    test('a burst mid-flight collapses into exactly ONE trailing run', () async {
      var runs = 0;
      final gate = Completer<void>();
      final refresh = CoalescingRefresh(() async {
        runs++;
        if (runs == 1) await gate.future;
      });

      refresh.schedule();
      for (var i = 0; i < 5; i++) {
        refresh.schedule();
      }

      gate.complete();
      await pumpEventQueue();

      expect(runs, 2,
          reason: 'somebody liking five of your topos is five events and one '
              'thing worth knowing — coalesced, not queued five deep');
    });

    test('triggers arriving during the TRAILING run queue again, so a '
        'continuous stream never loses its tail', () async {
      var runs = 0;
      final gates = [Completer<void>(), Completer<void>()];
      final refresh = CoalescingRefresh(() async {
        final index = runs++;
        if (index < gates.length) await gates[index].future;
      });

      refresh.schedule();          // run 0 starts
      refresh.schedule();          // queues run 1
      gates[0].complete();
      await pumpEventQueue();
      expect(runs, 2, reason: 'run 1 (the trailing one) is now in flight');

      refresh.schedule();          // arrives during run 1 — must queue again
      expect(refresh.hasQueued, isTrue);
      gates[1].complete();
      await pumpEventQueue();

      expect(runs, 3,
          reason: 'the trailing run can itself be coalesced into; otherwise a '
              'steady stream drops every event after the first tail');
    });

    test('a throwing run does not wedge the coalescer, and the error is '
        'reported rather than escaping into the zone', () async {
      var runs = 0;
      final errors = <Object>[];
      final refresh = CoalescingRefresh(
        () async {
          runs++;
          throw StateError('server said no');
        },
        onError: errors.add,
      );

      refresh.schedule();
      await pumpEventQueue();

      expect(errors, hasLength(1));
      expect(refresh.isRunning, isFalse,
          reason: 'a failed refresh that left the flag set would silently '
              'disable realtime notifications for the rest of the session');

      refresh.schedule();
      await pumpEventQueue();
      expect(runs, 2, reason: 'and the next nudge still works');
    });

    test('sequential schedules each run — the guard only applies in flight',
        () async {
      var runs = 0;
      final refresh = CoalescingRefresh(() async => runs++);

      refresh.schedule();
      await pumpEventQueue();
      refresh.schedule();
      await pumpEventQueue();

      expect(runs, 2);
    });
  });
}
