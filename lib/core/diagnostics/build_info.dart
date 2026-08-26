import 'package:flutter/foundation.dart'
    show
        defaultTargetPlatform,
        kIsWasm,
        kIsWeb,
        kProfileMode,
        kReleaseMode,
        visibleForTesting;

/// The compile-time build stamp — which build of Masi is this, cut from which
/// commit, and when — plus the runtime facts (renderer, build mode, platform)
/// that decide how to read it.
///
/// Every field is a `String.fromEnvironment` const rather than a runtime
/// lookup, for the reason the old `kMasiAppVersion` already spelled out: this
/// project has no `package_info_plus` dependency, and all of these values are
/// known at build time anyway. `tool/build_web.sh` passes the matching
/// `--dart-define`s; **a build that does not pass them degrades to an honest
/// `'unknown'`, never to a plausible-looking default.** That distinction is
/// the whole point of a support diagnostic — a stamp that quietly invents
/// "built just now, from main" for an unstamped build is worse than no stamp,
/// because it is believed.
///
/// The one exception is [appVersion], which keeps its `pubspec.yaml`-mirroring
/// fallback: unlike a commit or a build time, the version really is knowable
/// without the define, and it is the value a `package_info` lookup would have
/// returned.
///
/// WHY THIS EXISTS AT ALL: on web, the running bundle and the deployed bundle
/// routinely disagree — a stale service worker keeps serving the previous
/// build from its precache, and the app then looks exactly like a build where
/// the fix simply did not work (see `CLAUDE.md`'s "a stale service worker
/// serves the PREVIOUS build and you will debug a ghost"). The FIRST question
/// of any web bug report is therefore "which build are you actually running?",
/// and until this existed neither the user nor a support reader could answer
/// it. Pair it with `shell_info.dart`, which reports the service worker's own
/// shell version — together they distinguish "the deploy did not land" from
/// "the deploy landed and the fix is wrong".
abstract final class BuildInfo {
  /// The token every unstamped field renders as. A single shared literal so
  /// the diagnostics UI and the clipboard blob can never disagree about what
  /// "we were not told" looks like.
  static const String unknown = 'unknown';

  /// `pubspec.yaml`'s `version:` — `<semver>+<build number>`.
  ///
  /// KEEP THE FALLBACK IN SYNC with `pubspec.yaml` for builds that pass no
  /// define (a plain `flutter run`, `flutter build ios`, `flutter test`).
  /// `tool/build_web.sh` reads the real line out of `pubspec.yaml` and passes
  /// it, so on a web build this literal never matters.
  static const String appVersion = String.fromEnvironment(
    'APP_VERSION',
    defaultValue: '1.0.0+1',
  );

  /// The short commit this build was cut from, with a `-dirty` suffix when the
  /// working tree had uncommitted changes at build time.
  ///
  /// The dirty marker matters more than it looks: it is the difference between
  /// "this bug is reproducible from a commit anyone can check out" and "this
  /// bug only exists in one working tree", and a report that cannot tell them
  /// apart sends the reader looking for a diff that was never pushed.
  static const String gitSha = String.fromEnvironment(
    'GIT_SHA',
    defaultValue: unknown,
  );

  /// The branch the build was cut from. Now that more than one agent works
  /// this repo and `main` is a shared base (see `CLAUDE.md`), "which branch is
  /// deployed?" is a real question with a non-obvious answer.
  static const String gitBranch = String.fromEnvironment(
    'GIT_BRANCH',
    defaultValue: unknown,
  );

  /// The build time as the define carried it — an ISO-8601 instant, expected
  /// in UTC. Empty when unstamped. Read [buildTime] instead of parsing this;
  /// it exists as a separate field only so a malformed value can be shown
  /// verbatim rather than silently becoming "unknown".
  static const String buildTimeRaw = String.fromEnvironment('BUILD_TIME');

  /// How this build was produced — `web-wasm`, `web-js`, or whatever a future
  /// build script stamps. Deliberately a free-form string set by the build
  /// script rather than inferred here: [runtimeLabel] already reports what the
  /// running engine actually is, and the interesting failure is precisely when
  /// those two disagree.
  static const String channel = String.fromEnvironment(
    'BUILD_CHANNEL',
    defaultValue: unknown,
  );

  /// [buildTimeRaw] parsed to a UTC instant, or `null` when the define was
  /// absent or unparseable.
  static DateTime? get buildTime => parseBuildTime(buildTimeRaw);

  /// Whether this build carries a real build time. A `false` here is itself
  /// worth reporting: it means the bundle did not come out of
  /// `tool/build_web.sh`, which narrows a "the deploy did nothing" report a
  /// long way on its own.
  static bool get isStamped => buildTime != null;

  /// What is executing RIGHT NOW, as opposed to what [channel] claims was
  /// built: `web (wasm)` / `web (js)` on web — the dart2wasm/skwasm build and
  /// the dart2js/canvaskit build take genuinely different renderer and plugin
  /// paths, so a bug that reproduces on one and not the other is a different
  /// bug — and the target platform's own name on native.
  static String get runtimeLabel {
    if (kIsWeb) return kIsWasm ? 'web (wasm)' : 'web (js)';
    return defaultTargetPlatform.name;
  }

  /// [runtimeLabel] with no spaces in it — `web-wasm` / `web-js` / the
  /// platform name.
  ///
  /// A separate accessor rather than a `replaceAll` at the call site because
  /// the two have genuinely different contracts: [runtimeLabel] is read by a
  /// person on a screen, this one goes into the single-line `key=value`
  /// clipboard blob, where a space would end the token early and silently turn
  /// `runtime=web (wasm)` into a `runtime=web` followed by a garbage token.
  static String get runtimeToken {
    if (kIsWeb) return kIsWasm ? 'web-wasm' : 'web-js';
    return defaultTargetPlatform.name;
  }

  /// `debug` / `profile` / `release`. Assertions, timings and tree-shaking all
  /// differ, so a performance or "impossible state" report means something
  /// different in each.
  ///
  /// Written as release/profile-then-fall-through rather than the more obvious
  /// `kDebugMode` first, because `test/core/db/connection_seam_source_test.dart`
  /// asserts that `lib/` contains ZERO `kDebugMode` USES. That guard exists
  /// because a diagnostic hidden behind `if (kDebugMode)` is invisible in the
  /// release web build — which is the only build real reports come from, and
  /// is exactly how a total-data-loss bug once stayed invisible. This value
  /// GATES nothing (it reports which mode is running, in every mode), so it is
  /// not the thing that guard is protecting against — but the guard is a
  /// substring check, and the three constants are mutually exclusive and
  /// exhaustive, so this formulation is exactly equivalent and needs no
  /// exception carved into the guard.
  static String get modeLabel {
    if (kReleaseMode) return 'release';
    if (kProfileMode) return 'profile';
    return 'debug';
  }

  /// `<sha> on <branch>`, degrading to whichever half is known, or [unknown]
  /// when neither is.
  static String get commitLabel {
    final hasSha = gitSha != unknown && gitSha.isNotEmpty;
    final hasBranch = gitBranch != unknown && gitBranch.isNotEmpty;
    if (hasSha && hasBranch) return '$gitSha on $gitBranch';
    if (hasSha) return gitSha;
    if (hasBranch) return 'unknown commit on $gitBranch';
    return unknown;
  }
}

/// [raw] parsed as a UTC instant, or `null` for the empty/unstamped/malformed
/// cases.
///
/// Normalised to UTC on the way out, NOT left in whatever offset the build
/// machine wrote: two reports from two timezones have to be comparable by
/// eye, and the stamp's only job is to place a build on a single timeline.
@visibleForTesting
DateTime? parseBuildTime(String raw) {
  if (raw.isEmpty) return null;
  return DateTime.tryParse(raw)?.toUtc();
}

/// The "Built" row's value: an absolute UTC stamp plus how long ago that was,
/// e.g. `2026-08-26 14:03 UTC · 2h ago`.
///
/// Both halves, deliberately. The absolute stamp is what a reader compares
/// against a deploy log; the relative age is what makes "this is not the build
/// you deployed ten minutes ago" obvious at a glance without doing arithmetic
/// in one's head.
///
/// [now] is injectable so this is testable without a clock; it defaults to
/// [DateTime.now].
String formatBuildStamp(DateTime? buildTime, {DateTime? now}) {
  if (buildTime == null) return 'unknown (build not stamped)';
  final at = _formatUtcMinute(buildTime);
  final age = formatBuildAge(buildTime, now: now);
  return '$at · $age';
}

/// `2026-08-26 14:03 UTC` — minute precision, because a build time is compared
/// against a deploy log, never used to order two events.
String _formatUtcMinute(DateTime time) {
  final utc = time.toUtc();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${utc.year}-${two(utc.month)}-${two(utc.day)} '
      '${two(utc.hour)}:${two(utc.minute)} UTC';
}

/// How long ago [buildTime] was, coarsely — `just now`, `42m ago`, `3h ago`,
/// `9d ago`.
///
/// A build time in the FUTURE renders as `clock skew` rather than a negative
/// age or a wrapped-around "just now". That case is not hypothetical and it is
/// not noise: a device whose clock is wrong is a live explanation for expired
/// JWTs, rejected sync pushes and last-writer-wins resolving the wrong way
/// (`shouldPushLww` compares `updatedAt` stamps), so surfacing it here is
/// worth more than a tidy-looking number.
String formatBuildAge(DateTime buildTime, {DateTime? now}) {
  final diff = (now ?? DateTime.now()).toUtc().difference(buildTime.toUtc());
  // A minute of slack before calling it skew: build machines and clients are
  // never synchronised to the second, and a fresh deploy legitimately lands a
  // few seconds "in the future" from a client's point of view.
  if (diff.inSeconds < -60) return 'clock skew';
  if (diff.inSeconds < 60) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  return '${diff.inDays}d ago';
}
