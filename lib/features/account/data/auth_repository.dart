import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'oauth_redirect.dart' as oauth_redirect;

/// Why a session ended, as this app's own narrow enum rather than gotrue's
/// [SignOutReason].
///
/// Kept app-local (mapped by [authSignOutCauseFrom]) for two reasons: test
/// doubles like `FakeAuthRepository` can emit plain values without
/// constructing real Supabase types — the same rationale that keeps
/// [AuthSessionState] free of `Session`/`User` — and [unknown] exists here
/// with no gotrue counterpart, for a `signedOut` whose reason gotrue does not
/// report (a cross-tab `BroadcastChannel` sign-out, `AuthState.fromBroadcast`).
///
/// Only [userInitiated] is allowed to clear locally-scoped ownership state
/// (see `auth_providers.dart`'s `LastKnownUid.forget`). Everything else —
/// [sessionExpired] (a captive portal answering the refresh with an HTML body,
/// classified as a non-retryable `AuthUnknownException`, which is L4's
/// trigger), [sessionMissing], [unknown] — means "the network took the session
/// away", never "the user asked to be signed out".
enum AuthSignOutCause { userInitiated, sessionExpired, sessionMissing, unknown }

/// Maps gotrue's [SignOutReason] onto [AuthSignOutCause].
///
/// `null` in -> `null` out, deliberately: gotrue sets `signOutReason` only on
/// [AuthChangeEvent.signedOut], and leaves it null even there when the event
/// arrived cross-tab via `BroadcastChannel`. A null must therefore NEVER be
/// read as "user initiated" — doing so would clear `lastKnownUid` on a
/// transient refresh failure and re-open L4.
AuthSignOutCause? authSignOutCauseFrom(SignOutReason? reason) {
  return switch (reason) {
    SignOutReason.userInitiated => AuthSignOutCause.userInitiated,
    SignOutReason.sessionExpired => AuthSignOutCause.sessionExpired,
    SignOutReason.sessionMissing => AuthSignOutCause.sessionMissing,
    null => null,
  };
}

/// Immutable snapshot of the app's auth session: signed-out when [email] is
/// null, signed-in with that address otherwise.
///
/// Deliberately doesn't carry the full Supabase [User]/[Session] — the
/// Account screen (and everything downstream of it) only ever needs the
/// signed-in/signed-out distinction plus the email to display, so keeping
/// this narrow is what lets [FakeAuthRepository]-style test doubles emit
/// plain values instead of constructing real Supabase types.
class AuthSessionState {
  const AuthSessionState.signedOut({AuthSignOutCause? cause})
    : email = null,
      uid = null,
      signOutCause = cause;

  const AuthSessionState.signedIn(String signedInEmail, {this.uid})
    : email = signedInEmail,
      signOutCause = null;

  /// The signed-in user's email, or `null` when signed out.
  final String? email;

  /// The signed-in user's Supabase Auth id (what `auth.uid()` resolves to
  /// server-side for RLS), or `null` when signed out. Added for the cloud
  /// backup engine (S4), which needs this to gate push/pull on being
  /// signed-in and to build the per-user Storage path prefix
  /// (`topo-photos/<uid>/...`).
  ///
  /// Deliberately NOT part of [operator ==]/[hashCode] — [email] already
  /// uniquely identifies a signed-in Supabase Auth account, so keeping
  /// equality scoped to [email] avoids rippling this addition through
  /// existing equality-based assertions (see `account_screen_test.dart`).
  final String? uid;

  /// Why this signed-out state came about, or `null` when unknown / when this
  /// is a signed-in state. See [AuthSignOutCause]: ONLY
  /// [AuthSignOutCause.userInitiated] may clear locally-scoped ownership
  /// state. Like [uid], deliberately NOT part of [operator ==]/[hashCode] —
  /// equality stays keyed on [email] alone so existing equality-based
  /// assertions are unaffected.
  final AuthSignOutCause? signOutCause;

  bool get isSignedIn => email != null;

  @override
  bool operator ==(Object other) =>
      other is AuthSessionState && other.email == email;

  @override
  int get hashCode => email.hashCode;

  @override
  String toString() =>
      'AuthSessionState(email: $email, uid: $uid, '
      'signOutCause: $signOutCause)';
}

/// Seam over Supabase auth so `application`/`presentation` code never talks
/// to [SupabaseClient] directly (see [SupabaseAuthRepository]) and tests can
/// override `authRepositoryProvider` with an in-memory fake instead of
/// hitting the network.
abstract class AuthRepository {
  /// Emits the current [AuthSessionState] and every subsequent change
  /// (sign-in, sign-out, token refresh that resolves to a different user,
  /// etc).
  Stream<AuthSessionState> authStateChanges();

  /// Synchronous snapshot of the current session, without waiting on
  /// [authStateChanges]. Mirrors Supabase's own synchronous
  /// `auth.currentSession` getter — used by one-shot callers (e.g. the cloud
  /// backup engine's `pushBackup`/`pullBackup`) that just need "am I signed
  /// in right now, and as whom" rather than a live subscription.
  AuthSessionState get currentSession;

  /// Sends a magic-link sign-in email to [email]. The link redirects back
  /// into the app (see [SupabaseAuthRepository.magicLinkRedirect]); this
  /// method itself only resolves once the email has been queued to send —
  /// it does NOT wait for the user to tap the link. The [authStateChanges]
  /// stream is what reports the eventual sign-in once that happens.
  ///
  /// Signups are OPEN client-side (`shouldCreateUser: true`): a brand-new
  /// [email] can create an account and sign in. If the Supabase project
  /// still has server-side `disable_signup=true`, GoTrue may reject a
  /// never-seen address with a `signup_disabled` error — the caller
  /// (`account_screen.dart`'s `_handleSendLink`) surfaces that gracefully as
  /// a fallback message rather than treating it as a hard failure.
  Future<void> sendMagicLink(String email);

  /// Starts the Google OAuth sign-in flow (hands control to the provider's
  /// consent page). Like [sendMagicLink], this only kicks off the flow — the
  /// eventual session arrives via [authStateChanges] once the OAuth redirect
  /// completes back into the app.
  ///
  /// THROWS (an [AuthException]) if control could not be handed over at all —
  /// i.e. the consent page was never reached. That case used to resolve
  /// normally, which made a total sign-in lockout look like a dead button with
  /// no error to report; callers must be able to render a failure. On web the
  /// page navigates away on success, so a normal return there is the
  /// *un*observable outcome.
  Future<void> signInWithGoogle();

  /// Verifies an emailed numeric sign-in [code] for [email] — the PWA-safe
  /// alternative to the magic link, which breaks in the iOS standalone PWA
  /// (the link opens Safari, so the session never lands back in the installed
  /// app). Resolves once the code is accepted and the session is established;
  /// [authStateChanges] then reports the sign-in.
  Future<void> verifyEmailOtp(String email, String code);

  /// Signs out the current session, if any.
  Future<void> signOut();
}

/// Real [AuthRepository], backed by the Supabase client's `auth` module.
///
/// SECURITY: this class (like the rest of the client app) only ever touches
/// the publishable/anon [SupabaseClient] from `supabase_providers.dart` —
/// never the privileged/service-role key, which must never appear here or
/// anywhere else client-side (see `supabase_config.dart`'s doc comment).
class SupabaseAuthRepository implements AuthRepository {
  /// [canRedirectTopLevel]/[redirectTopLevel] default to the real
  /// `oauth_redirect.dart` conditional backend (web: a top-level
  /// `location.assign`; native/tests: the inert stub) and exist ONLY so a unit
  /// test can exercise both branches of [signInWithGoogle] — including the
  /// refused-navigation branch — without a real browser, where the
  /// compile-time import condition can't otherwise be flipped. Same rationale
  /// as [resolveMagicLinkRedirect]'s `isWeb` seam. Production code must never
  /// pass them.
  SupabaseAuthRepository(
    this._client, {
    bool Function()? canRedirectTopLevel,
    Future<bool> Function(String url)? redirectTopLevel,
  }) : _canRedirectTopLevel =
           canRedirectTopLevel ?? oauth_redirect.canRedirectTopLevel,
       _redirectTopLevel = redirectTopLevel ?? oauth_redirect.redirectTopLevel;

  final SupabaseClient _client;

  final bool Function() _canRedirectTopLevel;
  final Future<bool> Function(String url) _redirectTopLevel;

  /// Message for the "control was never handed to the provider" failure, on
  /// either platform. Reported as an [AuthException] — the same type every
  /// other auth failure in this class surfaces (they all bubble up from
  /// gotrue) — so `account_screen.dart`'s existing `catch` renders its
  /// "Google sign-in failed" message instead of the user seeing nothing.
  static const String _oauthHandoffFailed =
      'Could not open the Google sign-in page.';

  /// Must match the `CFBundleURLTypes` scheme registered in
  /// `ios/Runner/Info.plist` and the intent-filter scheme/host registered in
  /// `android/app/src/main/AndroidManifest.xml` — otherwise the OS has
  /// nothing to hand the magic-link tap back to and the deep link falls
  /// through to a browser instead of reopening the app. Native-only — web
  /// uses [resolveMagicLinkRedirect]'s `Uri.base.origin` branch instead,
  /// since there's no OS-level scheme handler in a browser.
  static const String magicLinkRedirect =
      'io.supabase.climbtopo://login-callback/';

  /// The actual `emailRedirectTo` sent with the magic-link email —
  /// platform-specific because native and web have no shared notion of
  /// "hand control back to this app":
  ///  - native (iOS/Android): [magicLinkRedirect], the custom URL scheme
  ///    registered in `Info.plist`/`AndroidManifest.xml`.
  ///  - web: there's no scheme handler, so the redirect must be a real
  ///    `https://`/`http://` URL the browser can load — this app's own
  ///    origin (e.g. `https://climbtopo.example.com` in prod,
  ///    `http://localhost:<port>` in dev). Landing back on the site root is
  ///    sufficient: `supabase_flutter`'s `SupabaseAuth` (wired up
  ///    automatically by `Supabase.initialize`'s `detectSessionInUri: true`
  ///    default, which `main.dart` never overrides) reads the PKCE `code`
  ///    straight out of `Uri.base` at boot, completes the session via
  ///    `getSessionFromUrl`, and strips the auth query params from the
  ///    address bar afterwards — no dedicated `/auth-callback` route or
  ///    extra app code needed beyond this redirect target.
  ///
  /// NOTE for a human: the Supabase project's Auth "Redirect URLs"
  /// allowlist must include both the web dev origin (e.g.
  /// `http://localhost:<port>`) and the deployed prod origin, or Supabase
  /// rejects the redirect at send-time — console-side config, not code.
  ///
  /// [isWeb]/[origin] default to the real [kIsWeb]/[Uri.base] and only exist
  /// so a unit test can exercise the web branch without a real browser test
  /// runner, where the compile-time [kIsWeb] can't otherwise be flipped —
  /// mirrors `photo_source_sheet.dart`'s `showCameraOption` seam.
  @visibleForTesting
  static String resolveMagicLinkRedirect({bool? isWeb, Uri? origin}) {
    if (!(isWeb ?? kIsWeb)) return magicLinkRedirect;
    return (origin ?? Uri.base).origin;
  }

  @override
  Stream<AuthSessionState> authStateChanges() {
    return _client.auth.onAuthStateChange.map(
      // `state.signOutReason` is gotrue's own, non-null only on a
      // `signedOut` event it originated itself — this is what lets §1c tell a
      // deliberate sign-out apart from an involuntary one WITHOUT parsing
      // error strings.
      (state) => _toSessionState(state.session, state.signOutReason),
    );
  }

  @override
  AuthSessionState get currentSession =>
      _toSessionState(_client.auth.currentSession);

  @override
  Future<void> sendMagicLink(String email) {
    // `shouldCreateUser: true` opens signups client-side: a brand-new email
    // can create an account and sign in. The server-side `disable_signup`
    // flag is managed separately; if it's still on, GoTrue may return a
    // `signup_disabled` error for a never-seen address, which
    // `account_screen.dart` surfaces gracefully as a fallback.
    return _client.auth.signInWithOtp(
      email: email,
      emailRedirectTo: resolveMagicLinkRedirect(),
      shouldCreateUser: true,
    );
  }

  @override
  Future<void> signInWithGoogle() async {
    // Identical on both platforms, and it must stay byte-identical to what the
    // Supabase project's Auth "Redirect URLs" allowlist contains, or GoTrue
    // rejects the /authorize call.
    final redirectTo = resolveMagicLinkRedirect();

    if (_canRedirectTopLevel()) {
      // WEB. Split `signInWithOAuth` into its two halves and do the navigation
      // ourselves: `getOAuthSignInUrl` is the exact same call
      // `signInWithOAuth` makes first (it also mints the PKCE verifier and
      // stores it, so `detectSessionInUri` can complete the session on the way
      // back), but the handoff is then a plain top-level navigation instead of
      // `url_launcher_web`'s `window.open(url, '_self', 'noopener,noreferrer')`
      // — which an iOS standalone web app silently refuses while reporting
      // success. See `oauth_redirect.dart`.
      final response = await _client.auth.getOAuthSignInUrl(
        provider: OAuthProvider.google,
        redirectTo: redirectTo,
      );
      final redirected = await _redirectTopLevel(response.url);
      if (!redirected) throw const AuthException(_oauthHandoffFailed);
      return;
    }

    // NATIVE (iOS/Android) — mechanism unchanged: `signInWithOAuth` launches
    // the system browser / `ASWebAuthenticationSession` via url_launcher and
    // the `io.supabase.climbtopo://` deep link brings the session back. The
    // only change is that its `bool` result is no longer discarded: `false`
    // means url_launcher never opened anything, which the user has to be told.
    final launched = await _client.auth.signInWithOAuth(
      OAuthProvider.google,
      redirectTo: redirectTo,
    );
    if (!launched) throw const AuthException(_oauthHandoffFailed);
  }

  @override
  Future<void> verifyEmailOtp(String email, String code) {
    final normalized = code.replaceAll(RegExp(r'\s+'), '');
    return _client.auth.verifyOTP(
      email: email,
      token: normalized,
      type: OtpType.email,
    );
  }

  @override
  Future<void> signOut() => _client.auth.signOut();

  static AuthSessionState _toSessionState(
    Session? session, [
    SignOutReason? reason,
  ]) {
    final email = session?.user.email;
    return (email == null || email.isEmpty)
        ? AuthSessionState.signedOut(cause: authSignOutCauseFrom(reason))
        : AuthSessionState.signedIn(email, uid: session?.user.id);
  }
}
