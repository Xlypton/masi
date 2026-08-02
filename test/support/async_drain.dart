// Shared, load-tolerant helpers for widget tests that have to advance REAL
// asynchronous work (Drift's background executor, `dart:io` file reads,
// `ui.instantiateImageCodec` decodes) from inside `testWidgets`' fake-async
// clock.
//
// ## Why this file exists
//
// Fifteen test files had grown their own byte-identical copy of a `_drain`
// helper shaped like this:
//
// ```dart
// for (var i = 0; i < 6; i++) {
//   await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
//   await tester.pump(const Duration(milliseconds: 30));
// }
// await tester.pumpAndSettle();
// ```
//
// `tester.runAsync` is the only way to hand control back to the REAL Dart
// event loop from a `testWidgets` body, so the pattern itself is right. What
// is wrong is the BUDGET: those six 20 ms sleeps grant the real event loop a
// **fixed 120 ms of wall-clock time, once**, and then the test asserts as if
// every pending real continuation had landed. That makes the assertion a bet
// on machine speed:
//
// * A single completion chain here is many real hops — Drift ships the query
//   to a background isolate and back, `File.readAsBytes` round-trips through
//   the IO thread pool, `instantiateImageCodec` hops to the raster worker,
//   and each hop's result then has to be delivered, awaited, folded into
//   Riverpod state and rebuilt. 120 ms covers all of that comfortably on an
//   idle machine and nothing like it on a busy one.
// * Wall-clock sleeps do not scale with contention in the test's favour: at
//   load 150 the *work* slows down by an order of magnitude while the sleep
//   only overshoots a little, so the budget shrinks exactly when it needs to
//   grow.
//
// Empirically this produced a direct load/failure correlation (5 failures at
// load 156, 7 at 96, 2 at 20-59, 0-1 under 30) with every single failure
// passing in isolation — a suite that cries wolf.
//
// ## What [drainAsync] does instead
//
// Phase 1 is the historical loop, unchanged, so fake-time semantics are
// bit-identical to before (the same number of `pump(fakeStep)`s, hence the
// same amount of fake time advanced — which matters, e.g. `_drainNoSettle`
// call sites deliberately observe a `SnackBar` before its 4 s fake-time
// duration expires).
//
// Phase 2 is the fix: instead of stopping at a fixed budget, it keeps handing
// the real event loop time for as long as the widget tree is still CHANGING,
// and only returns once the tree has been quiet for [quietWindow] of real
// time. Any observed change resets the window. That converts the guarantee
// from "the whole async chain must finish inside 120 ms" (a cliff) into "each
// individual hop must land within [quietWindow] of the previous one" (a
// ratchet) — an unbounded total budget, capped only by [timeout], for a
// near-unchanged idle cost, because the poll backs off exponentially and
// exits as soon as the tree settles.
//
// ## What it does NOT do
//
// Phase 2 is a robustness ratchet, not a proof: nothing in Flutter can tell a
// widget test "there is still real IO in flight", so a chain that has not
// produced its FIRST visible change yet is indistinguishable from one that has
// finished. Wherever a test asserts on a specific outcome of real async work,
// prefer the condition-based waits below ([pumpUntil], [pumpUntilFound],
// [pumpUntilGone], [pumpUntilAsync]) — those are genuinely deterministic,
// because they wait for the very thing the assertion is about and only give
// up at a deadline chosen to be far beyond any plausible scheduling delay.
// A `pumpUntil` never weakens an assertion: if the condition never comes
// true, the loop simply returns and the caller's own `expect` fails exactly
// as it would have before.
//
// ## How to test this class of fix (do NOT rely on machine load)
//
// Reproducing a load-dependent flake by loading the machine is unreliable in
// both directions: too little load and it never fires, too much and the
// toolchain stalls before the tests even run. Drive the variable directly
// instead — set [kDrainRealStep] and [kDrainQuietWindow] to `Duration.zero`,
// which is strictly harsher than any real machine, and run the suite:
//
//   * a test that still passes is synchronised by a CONDITION and is immune;
//   * a test that fails is still betting on the wall clock, and the failure
//     names the exact assertion to convert.
//
// That is a deterministic, seconds-long A/B. Measured with it on the two
// files this landed for: pristine `_drain` at zero budget = 20 failures,
// the condition-waited version at the same zero budget = 0.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// The historical fixed round count every hand-rolled `_drain` used.
const int kDrainRounds = 6;

/// The historical per-round fake-time advance every hand-rolled `_drain` used.
const Duration kDrainFakeStep = Duration(milliseconds: 30);

/// The historical per-round REAL sleep every hand-rolled `_drain` used.
const Duration kDrainRealStep = Duration(milliseconds: 20);

/// How long the widget tree must stay unchanged, in REAL time, before
/// [drainAsync] concludes that pending real async work has landed.
const Duration kDrainQuietWindow = Duration(milliseconds: 120);

/// Absolute cap on [drainAsync]'s phase 2, so a permanently-animating tree
/// can never hang a test — it just degrades to the old behaviour.
const Duration kDrainMaxWait = Duration(seconds: 20);

/// The deadline the condition-based waits below use. Deliberately generous:
/// it is a *safety valve*, not a timing assumption. On an idle machine these
/// helpers return in a few milliseconds; the only thing a long deadline buys
/// is immunity to scheduling delay on a loaded one.
const Duration kPumpUntilTimeout = Duration(seconds: 20);

/// Advances real asynchronous work (Drift's background executor, `dart:io`
/// reads, image decode, …) that would otherwise never make progress under
/// `testWidgets`' fake-async clock, then pumps to flush the resulting
/// Riverpod-triggered rebuilds and any in-flight dialog/route transitions.
///
/// [rounds]/[fakeStep]/[realStep] reproduce the historical helper exactly.
/// [settle] appends the trailing `pumpAndSettle()` (pass `false` for the
/// `_drainNoSettle` variant, which observes a `SnackBar` mid-life).
///
/// See the file header for why phase 2 exists.
Future<void> drainAsync(
  WidgetTester tester, {
  int rounds = kDrainRounds,
  bool settle = true,
  Duration fakeStep = kDrainFakeStep,
  Duration realStep = kDrainRealStep,
  Duration quietWindow = kDrainQuietWindow,
  Duration timeout = kDrainMaxWait,
}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(() => Future<void>.delayed(realStep));
    await tester.pump(fakeStep);
  }
  await _awaitTreeQuiescence(
    tester,
    quietWindow: quietWindow,
    timeout: timeout,
  );
  if (settle) {
    await tester.pumpAndSettle();
  }
}

/// Keeps yielding to the real event loop until the widget tree has been
/// structurally unchanged for [quietWindow] of REAL time (or [timeout]
/// expires). Pumps are zero-duration on purpose: this must add real time
/// WITHOUT advancing the fake clock, so it can never skip a `SnackBar`
/// duration, a debounce `Timer`, or anything else a caller's assertions
/// depend on.
Future<void> _awaitTreeQuiescence(
  WidgetTester tester, {
  required Duration quietWindow,
  required Duration timeout,
}) async {
  final elapsed = Stopwatch()..start();
  var fingerprint = _treeFingerprint(tester);
  var lastChange = Duration.zero;
  // Exponential backoff: cheap when the tree is already settled (the common
  // case), progressively more patient when it is not.
  var step = const Duration(milliseconds: 2);
  const maxStep = Duration(milliseconds: 50);

  while (elapsed.elapsed - lastChange < quietWindow &&
      elapsed.elapsed < timeout) {
    await tester.runAsync(() => Future<void>.delayed(step));
    await tester.pump();

    final next = _treeFingerprint(tester);
    if (next != fingerprint) {
      fingerprint = next;
      lastChange = elapsed.elapsed;
      step = const Duration(milliseconds: 2);
    } else if (step < maxStep) {
      step *= 2;
      if (step > maxStep) step = maxStep;
    }
  }
}

/// An order-sensitive hash of the element tree's SHAPE (widget runtime types
/// + keys) plus the text it is displaying.
///
/// Shape rather than paint state on purpose: a running fade/shimmer changes
/// what is on screen every frame but not the element tree, so it cannot keep
/// [_awaitTreeQuiescence] spinning, while everything real async work produces
/// (a list going from empty-state to rows, a dialog or SnackBar appearing, a
/// thumbnail replacing a placeholder, a route push) does change it.
int _treeFingerprint(WidgetTester tester) {
  if (tester.binding.rootElement == null) return 0;
  var hash = 17;
  for (final element in tester.allElements) {
    final widget = element.widget;
    hash = 0x1fffffff & (hash * 31 + widget.runtimeType.hashCode);
    final key = widget.key;
    if (key != null) {
      hash = 0x1fffffff & (hash * 31 + key.hashCode);
    }
    if (widget is Text) {
      hash = 0x1fffffff & (hash * 31 + (widget.data?.hashCode ?? 0));
    }
  }
  return hash;
}

/// Pumps — giving the REAL event loop time between frames — until [condition]
/// holds, or [timeout] of real time elapses.
///
/// On expiry it returns QUIETLY rather than throwing, so the caller's own
/// `expect` produces the failure (with its own `reason`/matcher diagnostics)
/// exactly as it would have without this helper. The assertion is unchanged;
/// only the "has it had a chance to happen yet?" question is answered
/// properly instead of guessed.
Future<void> pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  Duration timeout = kPumpUntilTimeout,
}) async {
  if (condition()) return;
  final elapsed = Stopwatch()..start();
  var step = const Duration(milliseconds: 2);
  const maxStep = Duration(milliseconds: 50);
  while (elapsed.elapsed < timeout) {
    await tester.runAsync(() => Future<void>.delayed(step));
    await tester.pump();
    if (condition()) return;
    if (step < maxStep) {
      step *= 2;
      if (step > maxStep) step = maxStep;
    }
  }
}

/// [pumpUntil] the widget tree contains at least one match for [finder].
Future<void> pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = kPumpUntilTimeout,
}) => pumpUntil(tester, () => finder.evaluate().isNotEmpty, timeout: timeout);

/// [pumpUntil] the widget tree contains no match for [finder].
Future<void> pumpUntilGone(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = kPumpUntilTimeout,
}) => pumpUntil(tester, () => finder.evaluate().isEmpty, timeout: timeout);

/// [pumpUntil] for conditions that are themselves asynchronous (a Drift read,
/// say). [condition] runs inside `tester.runAsync`, so its awaits actually
/// complete.
///
/// Like [pumpUntil], expiry returns quietly and leaves the verdict to the
/// caller's own `expect`.
Future<void> pumpUntilAsync(
  WidgetTester tester,
  Future<bool> Function() condition, {
  Duration timeout = kPumpUntilTimeout,
}) async {
  final elapsed = Stopwatch()..start();
  var step = const Duration(milliseconds: 2);
  const maxStep = Duration(milliseconds: 50);
  while (true) {
    var satisfied = false;
    await tester.runAsync(() async {
      satisfied = await condition();
    });
    if (satisfied) return;
    if (elapsed.elapsed >= timeout) return;
    await tester.runAsync(() => Future<void>.delayed(step));
    await tester.pump();
    if (step < maxStep) {
      step *= 2;
      if (step > maxStep) step = maxStep;
    }
  }
}
