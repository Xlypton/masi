import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'backup_providers.dart';

/// Whether the app can currently reach its own backend, as a value the UI can
/// render — distinct from `SyncStatus`, which describes the *sync engine's*
/// last attempt rather than the network.
///
/// Three states, not two, and [unknown] is deliberately NOT collapsed into
/// either verdict: before the first probe completes there is genuinely no
/// answer, and a UI that guesses would show a wrong banner for a frame on
/// every cold start. Consumers must treat [unknown] as "say nothing yet".
///
/// The two getters exist so a consumer never has to write `!= online` (which
/// silently sweeps [unknown] in with [offline] — the exact bug this enum's
/// third state is here to prevent). Ask [isKnownOffline] to warn, ask
/// [isKnownOnline] to reassure; when both are false, render neither.
enum Reachability {
  /// No probe has completed yet. Neither reachable nor unreachable — unasked.
  unknown,

  /// The app's Supabase origin answered a request.
  online,

  /// The app's Supabase origin did not answer: no route, DNS failure,
  /// timeout, or a captive portal that never forwarded the request.
  offline,
}

/// Verdict helpers that keep [Reachability.unknown] from being mistaken for a
/// verdict. See the enum's own doc comment for why this matters.
extension ReachabilityVerdict on Reachability {
  /// True only when a probe has completed and FAILED. False while [unknown],
  /// so an offline banner cannot flash before anything has been checked.
  bool get isKnownOffline => this == Reachability.offline;

  /// True only when a probe has completed and SUCCEEDED. False while
  /// [unknown].
  bool get isKnownOnline => this == Reachability.online;
}

/// Owns the app's current [Reachability] verdict.
///
/// The probe is `ConnectivityService.isBackendReachable`
/// (`lib/features/backup/data/connectivity_service.dart`): a short-timeout
/// `GET <supabaseUrl>/auth/v1/health` that treats any HTTP response at all as
/// proof of reach and never throws. It is used in preference to
/// `ConnectivityService.currentStatus`, which is *interface* state — it
/// reports "connected" behind a captive portal, and on web is hardcoded to
/// `NetworkStatus.wifi` because a browser cannot distinguish transports.
///
/// **Probe-on-demand: nothing here schedules anything.** Callers invoke
/// [refresh] at the moments the answer is about to be rendered (screen mount,
/// a read that came back empty, pull-to-refresh). That keeps the cost at one
/// cheap request per user-visible decision rather than a background poll, and
/// an app that is never asked never makes a request at all.
/// `ConnectivityService.statusChanges` — which `SyncOrchestrator` already
/// subscribes to — is the natural future trigger for an extra [refresh], but
/// wiring it is an additive follow-up, not a change to this surface.
///
/// Riverpod v3 [Notifier] (never `StateProvider` — see CLAUDE.md), mirroring
/// `StoragePersistenceController` in
/// `lib/core/storage/storage_persistence_providers.dart`.
class ReachabilityController extends Notifier<Reachability> {
  /// De-dupes concurrent [refresh] calls onto a single in-flight probe — two
  /// screens mounting in the same frame must not fire two health requests.
  /// Assigned SYNCHRONOUSLY (before [_probe] reaches its first `await`), so
  /// even same-microtask callers collapse; cleared on completion, so a later
  /// caller gets a fresh answer rather than a stale memoised one.
  Future<Reachability>? _inFlight;

  @override
  Reachability build() => Reachability.unknown;

  /// Probes once and updates [state], returning the verdict it recorded.
  ///
  /// Never throws and never completes with an error, so a fire-and-forget
  /// call from `initState` cannot produce an unhandled async error. Safe to
  /// call from several widgets at once — they share one probe.
  ///
  /// The returned value is the same verdict [state] now holds, so an
  /// imperative caller ("the search came back empty — are we offline?") can
  /// `await` it directly instead of re-reading the provider.
  Future<Reachability> refresh() =>
      _inFlight ??= _probe().whenComplete(() => _inFlight = null);

  Future<Reachability> _probe() async {
    final connectivity = ref.read(connectivityServiceProvider);
    bool reachable;
    try {
      reachable = await connectivity.isBackendReachable();
    } catch (_) {
      // `isBackendReachable` documents that it never throws, but a fake or a
      // future implementation might, and a reachability probe must never take
      // down the screen that asked for it. Unproven reach is not reach.
      reachable = false;
    }
    final verdict = reachable ? Reachability.online : Reachability.offline;
    // The container can be torn down while a probe is outstanding (screen
    // popped, hot restart, a disposed test container); writing `state` then
    // throws. The verdict is still returned to whoever awaited it.
    if (ref.mounted) state = verdict;
    return verdict;
  }
}

/// App-wide [Reachability]: read it synchronously to render, call
/// `ref.read(reachabilityProvider.notifier).refresh()` to ask for a fresh
/// answer (typically once at widget mount).
///
/// Override [connectivityServiceProvider] in tests rather than this provider,
/// so the de-duplication and mounted-guard logic above is exercised rather
/// than bypassed.
final reachabilityProvider =
    NotifierProvider<ReachabilityController, Reachability>(
      ReachabilityController.new,
    );
