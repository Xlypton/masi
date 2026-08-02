import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The retry cadence `SyncOrchestrator` uses after a FAILED push: exponential
/// backoff with equal jitter, a bounded interval, and deliberately UNBOUNDED
/// attempts.
///
/// Why unbounded (D-2, "just make sync bulletproof"): giving up is the one
/// outcome that loses a topo recorded offline. There is no attempt cap, no
/// terminal state and no "gave up" status anywhere in this class. What IS
/// bounded is the INTERVAL — [ceiling] — so a device that has been offline for
/// a week retries every ~5 minutes forever instead of once a fortnight. The
/// loop terminates by itself, not by exhaustion: `SyncOrchestrator._runPush`
/// stops re-arming the timer as soon as nothing is `dirty` (see
/// `SyncService.hasPendingLocalChanges`).
///
/// Two layers, split so the growth law is testable without a clock:
///  - [envelopeFor] is pure and deterministic: `base * 2^(attempt-1)`, clamped
///    to [ceiling]. Monotonic non-decreasing.
///  - [delayFor] draws the actual delay uniformly from
///    `[envelope / 2, envelope]` ("equal jitter"). Full jitter — `[0,
///    envelope]` — was rejected: it lets a late attempt fire sooner than an
///    early one, which makes "backoff grows on repeated failure" untestable
///    and, worse, hammers a struggling backend.
///
/// Injected via [syncRetryScheduleProvider], exactly like
/// `syncDebounceDurationProvider` (`sync_orchestrator.dart`) — so tests shrink
/// [base]/[ceiling] to milliseconds and seed [random], instead of waiting out
/// the production cadence.
class SyncRetrySchedule {
  SyncRetrySchedule({
    this.base = const Duration(seconds: 2),
    this.ceiling = const Duration(minutes: 5),
    Random? random,
  }) : _random = random ?? Random();

  /// Delay envelope for the FIRST retry.
  final Duration base;

  /// Hard upper bound on any delay this schedule ever returns.
  final Duration ceiling;

  final Random _random;

  /// The un-jittered delay envelope for [attempt] (1-based: 1 is the first
  /// retry after the first failure) — `base * 2^(attempt-1)`, clamped to
  /// [ceiling].
  ///
  /// Computed by an early-returning loop rather than `pow`/`<<`: [attempt] is
  /// unbounded, and `base.inMilliseconds << 60` overflows. The loop can never
  /// run more than ~ceil(log2(ceiling/base)) times (8 with the production
  /// defaults) because it returns the moment it reaches the ceiling.
  Duration envelopeFor(int attempt) {
    if (attempt <= 1) return base <= ceiling ? base : ceiling;
    final ceilingMs = ceiling.inMilliseconds;
    var ms = base.inMilliseconds;
    if (ms >= ceilingMs) return ceiling;
    for (var i = 1; i < attempt; i++) {
      ms *= 2;
      if (ms >= ceilingMs) return ceiling;
    }
    return Duration(milliseconds: ms);
  }

  /// The delay to wait before retry [attempt]: uniform in
  /// `[envelopeFor(attempt) / 2, envelopeFor(attempt)]`.
  Duration delayFor(int attempt) {
    final envelopeMs = envelopeFor(attempt).inMilliseconds;
    final half = envelopeMs ~/ 2;
    // `nextInt`'s argument is exclusive and must be positive; `envelopeMs -
    // half + 1` is >= 1 for every non-negative envelope, so this is safe even
    // for a zero-length envelope (an injected `Duration.zero` base in a test).
    return Duration(
      milliseconds: half + _random.nextInt(envelopeMs - half + 1),
    );
  }
}

/// The [SyncRetrySchedule] `SyncOrchestrator` reads its backoff from —
/// production defaults (~2s → 5min). Override in tests with millisecond
/// [SyncRetrySchedule.base]/[SyncRetrySchedule.ceiling] values and a seeded
/// `Random`, the same way `syncDebounceDurationProvider` is shrunk.
final syncRetryScheduleProvider = Provider<SyncRetrySchedule>(
  (ref) => SyncRetrySchedule(),
);
