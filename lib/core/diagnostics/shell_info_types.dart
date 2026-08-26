import 'package:flutter/foundation.dart' show immutable;

/// What the browser's service worker — the offline shell in `web/sw.js` — is
/// doing for THIS page right now.
///
/// Value type only, so both backends of the `shell_info.dart` seam can import
/// it without importing the facade (which would be a cycle) — the same shape
/// `storage_persistence_types.dart` already uses.
@immutable
class ShellInfo {
  const ShellInfo({
    this.supported = false,
    this.registered = false,
    this.controlling = false,
    this.updatePending = false,
    this.version,
    this.extraVersions = const <String>[],
  });

  /// Nothing to report: this platform has no service worker concept at all
  /// (every native build, and `flutter test`). Distinct from a web build where
  /// registration was BLOCKED — see [supported].
  static const ShellInfo notApplicable = ShellInfo();

  /// Whether `navigator.serviceWorker` exists. `false` on native (via the
  /// stub) and also on a browser that hides the API — private browsing in some
  /// engines, and some enterprise policies, block it outright. `web/index.html`
  /// treats that as "no offline shell, never a broken app", and so does this.
  final bool supported;

  /// Whether a worker is registered for this scope at all. `false` with
  /// [supported] `true` is the interesting combination: the browser can run a
  /// service worker and this origin has none, so there is no offline shell and
  /// every load is a network load.
  final bool registered;

  /// Whether an ACTIVE worker is serving this page's fetches.
  ///
  /// This is the one that answers "am I looking at a cached build?". A first
  /// visit is uncontrolled by design (the worker installs during that load and
  /// only takes over afterwards), so an uncontrolled page is not a fault — but
  /// a controlled page is a page whose assets may have come from a precache
  /// rather than from the server, which is exactly the ghost-debugging case
  /// `BuildInfo` exists to make visible.
  final bool controlling;

  /// Whether a NEWER worker is installed/installing and waiting to take over.
  ///
  /// The single most actionable fact on this screen: it means the deploy DID
  /// land, this tab is still running the old build, and one reload fixes it.
  /// Without it, "the fix isn't there" and "the fix is one reload away" look
  /// identical from inside the app.
  final bool updatePending;

  /// The active shell's build version — `sw.js`'s stamped `SHELL_VERSION`,
  /// recovered from the `masi-shell-<version>` cache name it opens. `null`
  /// when there is no worker, no Cache Storage, or no Masi shell cache yet.
  ///
  /// Content-derived per build (see `tool/gen_sw_manifest.dart`), so comparing
  /// it between two reports answers "same build?" exactly, in a way a semver
  /// that only changes when someone remembers to bump it cannot.
  final String? version;

  /// Any OTHER `masi-shell-*` cache versions present besides [version].
  ///
  /// Normally empty: `sw.js`'s `activate` sweeps every cache that is not the
  /// current one. A non-empty list therefore means an activation did not
  /// complete — a worker installed but never took over, or a tab is still
  /// holding the previous one open — which is precisely the state that serves
  /// a stale build.
  final List<String> extraVersions;

  /// The one-line summary rendered in the diagnostics row and stamped into the
  /// clipboard blob. Ordered most-actionable-first, so the row never has to be
  /// read to the end to learn the bad news.
  String get summary {
    if (!supported) return 'not applicable';
    if (!registered) return 'not registered (no offline shell)';
    final label = version ?? 'active, version unknown';
    final flags = <String>[
      if (!controlling) 'not controlling this page',
      if (updatePending) 'update ready — reload to apply',
      if (extraVersions.isNotEmpty) 'stale caches: ${extraVersions.join(', ')}',
    ];
    return flags.isEmpty ? label : '$label (${flags.join('; ')})';
  }

  /// The same facts as [summary], as `key=value` tokens for the single-line
  /// clipboard blob. Kept next to [summary] so the two can never drift apart
  /// about what a given state is called.
  String get clipboardTokens =>
      'shellVersion=${version ?? 'unknown'} '
      'shellRegistered=$registered '
      'shellControlling=$controlling '
      'shellUpdatePending=$updatePending '
      'shellStaleCaches=${extraVersions.join(',')}';
}
