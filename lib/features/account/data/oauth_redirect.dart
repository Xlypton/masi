// Facade for the OAuth top-level-redirect seam: how this build hands control
// over to a provider's consent page (Google) and back.
//
// Redirecting the CURRENT browsing context is a web-only concept, so — like
// `pwa_install.dart` / `is_safari.dart`, and unlike the three-way
// native/web/stub splits elsewhere (e.g.
// `lib/features/topo/data/photo_files.dart`) — this is a two-way split:
//  - native (iOS/Android/desktop) AND plain-Dart tests: the inert stub,
//    picked whenever `dart.library.js_interop` is unavailable. There OAuth is
//    started by `supabase_flutter`'s `signInWithOAuth` (url_launcher -> system
//    browser / `ASWebAuthenticationSession`), with the
//    `io.supabase.climbtopo://` deep link bringing the session back — the
//    right mechanism on native, and deliberately left untouched.
//  - web: a real top-level navigation (see `oauth_redirect_web.dart`).
//
// Why web can't just use `signInWithOAuth`: its web path ends in
// `url_launcher_web`'s `window.open(url, '_self', 'noopener,noreferrer')`.
// Passing `noopener` as a window FEATURE makes that a request for a *new*
// browsing context rather than a reuse of the named one; an iOS home-screen
// standalone web app (`"display": "standalone"` in `web/manifest.json`) has no
// tab UI to satisfy that with and silently refuses. Worse,
// `url_launcher_web.openNewWindow` hardcodes `return true` and never inspects
// `window.open`'s result — its own doc comment says it cannot, because of
// `noopener` — so the refusal is indistinguishable from success: no throw, no
// error UI, and a Google button that looks simply dead. A plain
// `location.assign` has neither problem.
export 'oauth_redirect_stub.dart'
    if (dart.library.js_interop) 'oauth_redirect_web.dart';
