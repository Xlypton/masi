import 'dart:async';

/// Runs an async refresh at most once at a time, collapsing everything that
/// arrives mid-flight into exactly ONE trailing re-run.
///
/// ## Why this exists as its own type
///
/// `NotificationRealtime._nudge` used to hold this state inline as a single
/// `bool _refreshInFlight`, and that shape is a LEADING-EDGE guard, not a
/// coalescer: a trigger arriving while a refresh was in flight was
/// **discarded**. Its own comment said "coalescing bursts", which is what the
/// code looked like it did.
///
/// The difference is not academic. The realtime nudge is a Postgres INSERT
/// event, and the refresh it starts reads the server once. An insert that
/// lands after that read but before the refresh completes is therefore
/// invisible until something else triggers a pull — so the badge, whose entire
/// job is to appear without being asked for, silently lags by however long it
/// takes the user to open the screen.
///
/// Pulling it out of the `Notifier` is what makes it testable at all.
/// `NotificationRealtime.build()` needs a live `supabaseClientProvider`; under
/// test it returns early and never subscribes, so `_nudge` was unreachable and
/// the behaviour could only be verified by reading it.
///
/// ## Semantics
///
/// * The first [schedule] runs immediately (leading edge — a badge must not
///   wait out a debounce interval before appearing).
/// * Any number of [schedule] calls during that run collapse into ONE further
///   run afterwards. Five likes in a row are five events and one thing worth
///   knowing.
/// * The trailing run can itself be coalesced into, so a continuous stream
///   settles into back-to-back runs rather than an unbounded queue.
/// * A throwing run does not wedge the coalescer: the in-flight flag is
///   cleared in a `whenComplete`, and errors go to [onError] rather than
///   escaping into the zone.
class CoalescingRefresh {
  CoalescingRefresh(this._run, {void Function(Object error)? onError})
    : _onError = onError;

  final Future<void> Function() _run;
  final void Function(Object error)? _onError;

  bool _inFlight = false;
  bool _queued = false;

  /// Whether a run is currently in flight.
  bool get isRunning => _inFlight;

  /// Whether a trailing run is owed once the current one finishes.
  bool get hasQueued => _queued;

  /// Request a refresh now, or as soon as the one in flight finishes.
  void schedule() {
    if (_inFlight) {
      // The whole fix: remember it. This used to be a bare `return`.
      _queued = true;
      return;
    }
    _start();
  }

  void _start() {
    _inFlight = true;
    unawaited(
      _run()
          .catchError((Object error) {
            // A nudge that cannot be serviced is not worth surfacing: the
            // screen's own refresh will try again and the mirror still holds
            // everything from the last successful pull. Reported, not thrown —
            // this runs detached, so an escaping error would land in the zone.
            _onError?.call(error);
          })
          .whenComplete(() {
            _inFlight = false;
            if (!_queued) return;
            _queued = false;
            // Tail-call rather than recursion into `schedule()`: `_queued` is
            // already cleared, so this starts exactly one more run and any
            // triggers arriving during IT queue again from scratch. No
            // unbounded growth, and no lost trailing edge.
            _start();
          }),
    );
  }
}
