// Shared fixture for the WRITE-ORDER durability matrix.
//
//   tool/drive_web_write_order.sh
//     -> integration_test/web_write_order_seed_test.dart      (run 1)
//     -> integration_test/web_write_order_verify_test.dart    (run 2)
//
// -------------------------------------------------------------------------
// WHY THIS EXISTS, GIVEN THE PHOTO PAIR ALREADY DOES
// -------------------------------------------------------------------------
// `web_photo_offline_{seed,verify}_test.dart` measured one thing: a photo
// attached offline loses its `Photos` row across a browser restart while the
// `Wall` row written moments earlier survives, and the pixels in the separate
// `climbtopo-photos` IndexedDB survive too.
//
// That result has TWO readings, and they have wildly different blast radii:
//
//   * PHOTO-SPECIFIC — something about the `Photos` row (or the large
//     IndexedDB byte write that precedes it) is not durable. Bad, bounded.
//   * LAST-WRITE-LOST — the drift database loses whatever was written most
//     recently, and the photo row was merely last in that sequence. Then the
//     real casualty is ROUTES: the thing a climber draws last, at the crag,
//     offline, immediately before pocketing the phone.
//
// The photo pair cannot tell those apart, because it only ever writes one
// row after the wall. This pair writes a NUMBERED SEQUENCE and reports which
// members of it came back, so the shape of the loss is a measurement rather
// than an inference:
//
//   wall -> photo -> route 01 -> route 02 -> ... -> route N
//
//   all present                 -> not reproducible in this ordering
//   only route N missing        -> LAST-WRITE-LOST
//   only routes N-k..N missing  -> a bounded tail is lost; k is the number
//   only the photo missing      -> PHOTO-SPECIFIC
//   everything after wall gone  -> only the first transaction ever persists
//
// The photo is written BEFORE the routes on purpose. If the loss were
// photo-specific, the photo is no longer last and must still vanish; if it
// is positional, the photo now sits mid-sequence and must survive while the
// tail does not. One ordering discriminates both ways.
//
// Deliberately NOT named `*_test.dart`: it holds no tests and `flutter test`
// must not pick it up.
import 'package:flutter/painting.dart' show Offset;
import 'package:masi/features/topo/domain/topo_route.dart';

/// Identifies one chained seed+verify pair, so a stale row left in a warm
/// Chrome profile by an earlier pair can never satisfy a later one.
const String kOrderRunStamp = String.fromEnvironment(
  'MASI_ORDER_RUN',
  defaultValue: 'unstamped',
);

/// How many route rows the seed writes after the photo.
///
/// Each is its own `RouteRepository.upsertRoute` call — i.e. its own SELECT
/// + INSERT pair against drift, not one batched transaction — because that
/// is what the drawing UI actually does, one route at a time.
const int kOrderRouteCount = int.fromEnvironment(
  'MASI_ORDER_ROUTES',
  defaultValue: 10,
);

/// Seconds run 1 holds the page open after its LAST write before the browser
/// dies. Same knob as the photo pair's `MASI_PHOTO_SETTLE`, and the same
/// reason: it turns "the row vanished" into a measurement with an axis.
const int kOrderSettleSeconds = int.fromEnvironment(
  'MASI_ORDER_SETTLE',
  defaultValue: 15,
);

/// How run 1's page dies.
///
///  * `kill` (default) — the test returns and `flutter drive` tears the whole
///    Chrome process down. No `pagehide`, no `unload`, no chance for anything
///    to run on the way out. This is a CRASH, harsher than anything a user
///    does.
///  * `unload` — the page navigates itself to `about:blank` as its last act.
///    The document is destroyed the same way closing the tab destroys it:
///    `pagehide` and `unload` fire, the client's `MessagePort`s to drift's
///    SharedWorker go away, and the browser process stays alive and idle
///    afterwards so any teardown work has time to finish. This is the
///    GRACEFUL close, and it is the whole reason this knob exists — "does an
///    ordinary tab close save the row?" separates "bad, but only on a crash"
///    from "the app loses work in normal use".
///
///    The Dart isolate dies with the document, so the test never returns and
///    `flutter drive` reports a failure. That is expected and the runner
///    script tolerates it: run 2 finds everything BY NAME and needs nothing
///    from run 1's report.
const String kOrderTeardown = String.fromEnvironment(
  'MASI_ORDER_TEARDOWN',
  defaultValue: 'kill',
);

/// Reverts the post-commit durability flush for this run only, by overriding
/// `appDatabaseProvider` with an `AppDatabase(..., flushAfterCommit: false)`.
///
/// The fix in `AppDatabase.transaction` makes a committed transaction durable
/// immediately, which is exactly what makes the graceful-close question
/// unmeasurable on fixed code: there would be nothing pending to lose. Turning
/// the fix off for a run restores the ORIGINAL behaviour faithfully — same
/// binary, same browser, same harness — so `unload` measures the browser, not
/// the patch.
const bool kOrderDisableCommitFlush = bool.fromEnvironment(
  'MASI_ORDER_NO_FLUSH',
);

/// The wall id run 1 created, threaded to run 2 by the shell script.
const String kOrderExpectedWallId = String.fromEnvironment('MASI_ORDER_WALL');

/// The photo id run 1 attached, threaded to run 2 by the shell script.
///
/// Empty when run 1's photo row could not be created at all. Run 2 falls
/// back to "no photo id" and reports the routes it can still find, so a
/// failure to attach never masquerades as a durability finding.
const String kOrderExpectedPhotoId = String.fromEnvironment(
  'MASI_ORDER_PHOTO',
);

String get orderWallName => 'Order Wall $kOrderRunStamp';

/// The name of the LAST thing run 1 writes: a second topo, created through
/// `LibraryCrudRepository.createTopo` — i.e. a drift `transaction(...)`.
///
/// The routes before it go through `RouteRepository.upsertRoute`, which is a
/// bare auto-commit INSERT. This one is not, and that difference is the
/// hypothesis under test: drift's `_WasmDelegate` flushes the IndexedDB
/// mirror after an auto-commit statement but NOT after a COMMIT
/// (drift-2.34.2/lib/wasm.dart:365-367 vs
/// `_StatementBasedTransactionExecutor.send`, engines.dart:275-281). If that
/// is the mechanism, this wall — a perfectly ordinary "climber makes a new
/// topo, then pockets the phone" — must be the one thing that does not come
/// back, while every route does.
String get orderTailWallName => 'Tail Wall $kOrderRunStamp';

/// Every route gets a name derived from its position, so run 2 can say
/// exactly WHICH members of the sequence came back rather than only how
/// many.
String orderRouteName(int number) =>
    'M${number.toString().padLeft(2, '0')}-$kOrderRunStamp';

/// The photo filename, and hence the IndexedDB key (`photos/<id>.jpg`).
String get orderPhotoFileName => 'order-$kOrderRunStamp.jpg';

/// A route with real geometry, so the row carries a realistic `pointsJson`
/// payload rather than an empty list — a few hundred bytes each, which is
/// what a hand-drawn line actually costs.
TopoRoute buildOrderRoute(int number) {
  final base = number * 0.03;
  return TopoRoute(
    id: number,
    number: number,
    name: orderRouteName(number),
    colorIndex: number % 8,
    points: <Offset>[
      for (var i = 0; i < 24; i++)
        Offset(0.1 + base + i * 0.002, 0.9 - i * 0.03),
    ],
  );
}
