// Shared drivers for the signed-in E2E flows.
//
// Extracted from `e2e_signed_in_test.dart` when the suite grew a second and
// third file: three copies of `settle`/`tapOrFail` drifting apart is how two
// runs of "the same" flow start disagreeing about a bug.
//
// THE ONE THING THAT IS DIFFERENT HERE from an ordinary widget test: some of
// these flows wait on a REAL network round trip to Supabase. `tester.pump()`
// advances the frame clock, not the wall clock, so a fixed pump budget can
// expire before a request has physically come back. [waitFor] is the primitive
// for anything server-dependent — it interleaves real `Future.delayed`s with
// pumps and fails with a NAMED reason on timeout, which is the difference
// between "the feature is broken" and "the test was impatient".
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Shimmer-safe replacement for `pumpAndSettle`.
///
/// `MasiShimmer` (and any perpetual animation) never reaches a settled frame,
/// so `pumpAndSettle` against a screen using one hangs until its timeout —
/// a documented trap in `docs/DEV_SETUP.md` §10. Pumping a fixed budget of
/// frames is immune to that and still lets async work land.
Future<void> settle(
  WidgetTester tester, {
  int frames = 40,
  Duration step = const Duration(milliseconds: 100),
}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(step);
  }
}

/// Pumps AND yields real wall-clock time, for anything waiting on the network.
///
/// [settle] alone is not enough against a live backend: it advances the frame
/// clock without necessarily letting a real socket finish, so a Supabase call
/// that takes 400ms can lose a race against 40 synthetic frames.
Future<void> settleNetwork(
  WidgetTester tester, {
  Duration budget = const Duration(seconds: 6),
  Duration step = const Duration(milliseconds: 150),
}) async {
  final deadline = DateTime.now().add(budget);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(step);
    await Future<void>.delayed(step);
  }
}

/// Pumps until [finder] matches, or fails with [what] after [timeout].
///
/// The only correct way to assert on something the SERVER has to produce (a
/// pulled topo, a filed report appearing in the admin queue, a suggestion
/// landing in the owner's inbox). A bare `expect` after a fixed pump budget
/// turns every slow round trip into a red build.
Future<void> waitFor(
  WidgetTester tester,
  Finder finder,
  String what, {
  Duration timeout = const Duration(seconds: 25),
  Duration step = const Duration(milliseconds: 200),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (finder.evaluate().isNotEmpty) return;
    await tester.pump(step);
    await Future<void>.delayed(step);
  }
  fail('timed out after ${timeout.inSeconds}s waiting for $what');
}

/// Taps [finder], failing with [what] if it never appeared.
Future<void> tapOrFail(
  WidgetTester tester,
  Finder finder,
  String what, {
  Duration timeout = const Duration(seconds: 25),
}) async {
  await waitFor(tester, finder, what, timeout: timeout);
  await tester.tap(finder.first, warnIfMissed: false);
  await settle(tester);
}

/// Every `Key('<prefix>…')` string currently mounted, in tree order.
///
/// Needed because server-generated ids are not knowable from the test source:
/// a suggestion's key is `suggestion-accept-<uuid>` where the uuid was minted
/// by `suggest_edit` seconds earlier. Scanning for the prefix is how a test
/// acts on "the suggestion that just appeared" without inventing an id.
///
/// `Key('x')` constructs a `ValueKey<String>`, which is what makes this a
/// simple type test rather than a string-parse of `toString()`.
List<String> keysWithPrefix(WidgetTester tester, String prefix) {
  final found = <String>[];
  for (final element
      in find
          .byWidgetPredicate(
            (widget) =>
                widget.key is ValueKey<String> &&
                (widget.key! as ValueKey<String>).value.startsWith(prefix),
          )
          .evaluate()) {
    final value = (element.widget.key! as ValueKey<String>).value;
    if (!found.contains(value)) found.add(value);
  }
  return found;
}

/// The id half of the first `Key('<prefix><id>')` currently mounted, or `null`.
String? firstIdWithPrefix(WidgetTester tester, String prefix) {
  final keys = keysWithPrefix(tester, prefix);
  return keys.isEmpty ? null : keys.first.substring(prefix.length);
}
