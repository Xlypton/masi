import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:web/web.dart' as web;

/// Always `true` on web: a page always has a browsing context it can navigate.
/// See `oauth_redirect.dart`.
bool canRedirectTopLevel() => true;

/// Grace period the WATCHDOG (see [redirectTopLevel]) waits, after a
/// synchronous `location.assign`/`location.href` call raised no exception,
/// before concluding the navigation was silently refused.
///
/// A real top-level navigation tears this whole document down — destroying
/// every pending Dart/JS timer, including the one this watchdog starts — the
/// moment the browser commits to leaving. For a same-tab redirect to a
/// Google/Supabase-hosted endpoint that is, in practice, on the order of tens
/// to a few hundred ms; 2s leaves an order of magnitude of headroom. It is
/// NOT a race a genuine navigation can lose (see the doc on
/// [redirectTopLevel]): the only way this ever resolves is if this document
/// is still alive to resolve it, which is itself proof nothing navigated.
///
/// `@visibleForTesting` so a test can shrink it — 2 real seconds per test
/// would make the suite unusably slow.
@visibleForTesting
Duration watchdogGrace = const Duration(milliseconds: 2000);

/// Navigates THIS browsing context to [url] — an ordinary top-level
/// navigation, with no `noopener` and no request for a new window, which is
/// the only handoff that works in an iOS home-screen standalone web app (see
/// `oauth_redirect.dart` for why `window.open(url, '_self', 'noopener,...')`
/// does not).
///
/// Refuses an empty [url] outright, and reports `false` (never `true`) if the
/// browser rejects the navigation. Tries `location.assign` first — the
/// explicit "navigate this context" API — and falls back to the `location.href`
/// setter, which some engines gate differently, before giving up.
///
/// WATCHDOG (added after the fact that `assign`/`href` never throwing turned
/// a total sign-in lockout into an apparently dead button — an iOS home-screen
/// standalone PWA silently ignores an out-of-scope top-level navigation
/// instead of raising anything): a call that raises no exception is not yet
/// "navigated", only "not synchronously refused". This function now also
/// waits [watchdogGrace] and, if it is STILL running at the end of that wait,
/// reports `false` instead of the unconditional `true` it used to return.
///
/// Why a navigation that actually happens can never lose that race: the
/// moment the browser commits to a top-level navigation, it unloads the
/// current document — which means destroying this exact JS/Dart execution
/// context, mid-`await`, before the `Future.delayed` below ever gets to fire.
/// There is no code path in which this function both (a) is still running to
/// observe the timeout AND (b) the navigation it started has actually
/// happened — those two are mutually exclusive by construction, not by
/// timing luck. A pathologically slow-to-commit navigation could in theory
/// still be in flight when the timer fires, but even then the harm is at most
/// a momentary, cosmetic error flash: the instant that slow navigation does
/// commit, the whole page — including whatever rendered that error — is
/// torn down with it, so no persistent false failure survives.
Future<bool> redirectTopLevel(String url) async {
  if (url.isEmpty) return false;
  final location = web.window.location;
  bool navigated;
  try {
    location.assign(url);
    navigated = true;
  } catch (_) {
    try {
      location.href = url;
      navigated = true;
    } catch (_) {
      navigated = false;
    }
  }
  if (!navigated) return false;

  await Future<void>.delayed(watchdogGrace);
  // Still here => nothing tore this document down => the navigation never
  // actually happened, whatever the synchronous call claimed.
  return false;
}
