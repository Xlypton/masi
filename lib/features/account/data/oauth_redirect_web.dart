import 'package:web/web.dart' as web;

/// Always `true` on web: a page always has a browsing context it can navigate.
/// See `oauth_redirect.dart`.
bool canRedirectTopLevel() => true;

/// Navigates THIS browsing context to [url] — an ordinary top-level
/// navigation, with no `noopener` and no request for a new window, which is
/// the only handoff that works in an iOS home-screen standalone web app (see
/// `oauth_redirect.dart` for why `window.open(url, '_self', 'noopener,...')`
/// does not).
///
/// Returns `true` once the navigation has been asked for. The browser tears
/// this document down asynchronously, so the caller normally never observes
/// the result — but `false`/`throw` paths matter enormously: a caller that
/// cannot tell "navigated" from "refused" is exactly what turned a total
/// sign-in lockout into an apparently dead button.
///
/// Refuses an empty [url] outright, and reports `false` (never `true`) if the
/// browser rejects the navigation. Tries `location.assign` first — the
/// explicit "navigate this context" API — and falls back to the `location.href`
/// setter, which some engines gate differently, before giving up.
Future<bool> redirectTopLevel(String url) async {
  if (url.isEmpty) return false;
  final location = web.window.location;
  try {
    location.assign(url);
    return true;
  } catch (_) {
    try {
      location.href = url;
      return true;
    } catch (_) {
      return false;
    }
  }
}
