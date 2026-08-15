import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:masi/core/db/database_provider.dart';
import 'package:masi/core/db/settings_store.dart';

/// Why the draw-mode hint is on screen, or [none] when it is not.
///
/// The two reasons say different things and are worth keeping apart, because
/// one of them is an answer to a mistake the climber has just made and the
/// other is an offer of help they did not ask for.
enum DrawHintReason {
  /// Nothing to show.
  none,

  /// First time in draw mode on this device — an unprompted nudge. Retires
  /// permanently once a route has been drawn ([DrawHint.markRouteDrawn]).
  firstTime,

  /// A drag on empty canvas just ended having added nothing at all.
  ///
  /// This is the one that matters. In draw mode `panEnabled` is false and
  /// `_updateInteraction` cancels a pending tap once movement passes the slop,
  /// so dragging across the photo — the instinctive way to "draw" a line —
  /// does *nothing*: no point, no pan, no feedback of any kind. Someone whose
  /// reflex is to stroke the line gets silence and reasonably concludes the
  /// app is broken. This fires at exactly that moment, and deliberately fires
  /// for experienced users too: it answers a specific failed attempt rather
  /// than guessing at inexperience.
  triedToDrag,
}

/// Drives the draw-mode hint. See [DrawHintReason].
class DrawHint extends Notifier<DrawHintReason> {
  /// There is deliberately NO auto-dismiss timer.
  ///
  /// The hint goes away when the climber places a point, leaves draw mode, or
  /// taps it — i.e. when it has been acted on, not when a clock says so. That
  /// is better behaviour (the advice stays visible until it has been taken)
  /// and it also keeps a periodic timer out of a widget that widget tests pump
  /// constantly, which is a recurring source of "a Timer is still pending
  /// after the widget tree was disposed" failures in this repo.
  ///
  /// The shortest gap between two drag-triggered hints.
  ///
  /// Without it, a climber fidgeting with the photo — or one drag that the
  /// framework reports as several — gets the same sentence flashed at them
  /// repeatedly, which reads as the app malfunctioning rather than helping.
  static const Duration repeatCooldown = Duration(seconds: 8);

  bool _hasDrawnRoute = false;

  /// When the drag hint last fired, or null if it never has.
  ///
  /// Nullable rather than `0`, and that is not fussiness: with a `0` sentinel
  /// the cooldown compares against the epoch, so the very first hint is
  /// suppressed for any clock reading under 8000. Real `nowMs` is epoch
  /// milliseconds so it never bit in the app — the first hint worked by
  /// accident of the clock being large — but it made the cooldown untestable
  /// at any sane timestamp, which is how it was found.
  int? _lastDragHintMs;

  @override
  DrawHintReason build() {
    _load();
    return DrawHintReason.none;
  }

  Future<void> _load() async {
    try {
      final stored = await ref
          .read(settingsStoreProvider)
          .read(SettingsStore.hasDrawnRouteKey);
      // [markRouteDrawn] may have landed while this read was in flight — a
      // climber who opens the canvas and finishes a route quickly can easily
      // beat a database round trip. This read is stale in that case, and
      // applying it would flip the flag back to false and show the beginner
      // hint to someone who has just demonstrably drawn a route. The flag only
      // ever travels false -> true, so refusing to move it backwards is the
      // whole fix.
      if (_hasDrawnRoute) return;
      _hasDrawnRoute = stored == 'true';
    } catch (_) {
      // A device whose settings table cannot be read has much louder problems
      // than a hint. Defaulting to "not yet drawn" shows the nudge one extra
      // time, which is the harmless direction.
    }
  }

  /// Whether the first-time nudge is still owed.
  bool get isFirstTimePending => !_hasDrawnRoute;

  /// Offers the unprompted first-time nudge. No-op once a route has been
  /// drawn, or when a hint is already up — a drag-triggered hint is a response
  /// to something the climber just did and must not be replaced by the
  /// generic one.
  void offerFirstTime() {
    if (_hasDrawnRoute) return;
    if (state != DrawHintReason.none) return;
    state = DrawHintReason.firstTime;
  }

  /// Reports a drag that added nothing, and shows the hint unless one was
  /// shown very recently. Returns whether it actually fired.
  bool reportFruitlessDrag(int nowMs) {
    final last = _lastDragHintMs;
    if (last != null && nowMs - last < repeatCooldown.inMilliseconds) {
      return false;
    }
    _lastDragHintMs = nowMs;
    state = DrawHintReason.triedToDrag;
    return true;
  }

  /// Takes the hint down — the climber placed a point, left draw mode, or the
  /// hint simply timed out.
  void dismiss() {
    if (state == DrawHintReason.none) return;
    state = DrawHintReason.none;
  }

  /// Records that a route has been drawn, retiring the first-time nudge for
  /// good. Idempotent, and never throws: a hint that fails to retire is worth
  /// far less than the commit it is riding on.
  Future<void> markRouteDrawn() async {
    if (_hasDrawnRoute) return;
    _hasDrawnRoute = true;
    if (state == DrawHintReason.firstTime) state = DrawHintReason.none;
    try {
      await ref
          .read(settingsStoreProvider)
          .write(SettingsStore.hasDrawnRouteKey, 'true');
    } catch (error) {
      debugPrint('drawHint: could not persist hasDrawnRoute: $error');
    }
  }
}

final drawHintProvider = NotifierProvider<DrawHint, DrawHintReason>(
  DrawHint.new,
);

/// The sentence shown for [reason], or null when nothing should be shown.
///
/// Split out as a pure function so the wording is assertable without pumping a
/// canvas, and so the two reasons cannot silently converge on one string —
/// they are answering different questions. The drag case names the gesture
/// that just failed; the first-time case does not, because nothing has failed
/// yet and telling someone what they did wrong before they did it is noise.
/// Both messages are kept SHORT deliberately — one line at phone width.
///
/// The pill is one of six things stacked in the canvas's bottom band, and the
/// route legend lifts itself clear of that band by a fixed
/// [kDrawHintHeight]. A message that wraps to two lines is taller than that
/// constant and starts covering the legend chip, which is exactly the bug this
/// note exists to stop coming back.
String? drawHintMessage(DrawHintReason reason) => switch (reason) {
  DrawHintReason.none => null,
  DrawHintReason.firstTime => 'Tap to add points',
  DrawHintReason.triedToDrag => 'Tap to draw — dragging does nothing',
};

/// The height the draw hint occupies, including the gap beneath it.
///
/// Hand-maintained rather than measured, matching `kBottomChromeClusterHeight`
/// next door: the route legend needs this at layout time to lift itself clear,
/// and measuring would mean a second layout pass on every frame of a draw.
/// Keep [drawHintMessage]'s strings short enough to stay on one line, or this
/// stops being true.
const double kDrawHintHeight = 44;
