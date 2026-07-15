import 'package:supabase_flutter/supabase_flutter.dart';

/// Immutable snapshot of the app's auth session: signed-out when [email] is
/// null, signed-in with that address otherwise.
///
/// Deliberately doesn't carry the full Supabase [User]/[Session] — the
/// Account screen (and everything downstream of it) only ever needs the
/// signed-in/signed-out distinction plus the email to display, so keeping
/// this narrow is what lets [FakeAuthRepository]-style test doubles emit
/// plain values instead of constructing real Supabase types.
class AuthSessionState {
  const AuthSessionState.signedOut() : email = null, uid = null;

  const AuthSessionState.signedIn(String signedInEmail, {this.uid})
    : email = signedInEmail;

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

  bool get isSignedIn => email != null;

  @override
  bool operator ==(Object other) =>
      other is AuthSessionState && other.email == email;

  @override
  int get hashCode => email.hashCode;

  @override
  String toString() => 'AuthSessionState(email: $email, uid: $uid)';
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
  Future<void> sendMagicLink(String email);

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
  SupabaseAuthRepository(this._client);

  final SupabaseClient _client;

  /// Must match the `CFBundleURLTypes` scheme registered in
  /// `ios/Runner/Info.plist` and the intent-filter scheme/host registered in
  /// `android/app/src/main/AndroidManifest.xml` — otherwise the OS has
  /// nothing to hand the magic-link tap back to and the deep link falls
  /// through to a browser instead of reopening the app.
  static const String magicLinkRedirect =
      'io.supabase.climbtopo://login-callback/';

  @override
  Stream<AuthSessionState> authStateChanges() {
    return _client.auth.onAuthStateChange.map(
      (state) => _toSessionState(state.session),
    );
  }

  @override
  AuthSessionState get currentSession =>
      _toSessionState(_client.auth.currentSession);

  @override
  Future<void> sendMagicLink(String email) {
    return _client.auth.signInWithOtp(
      email: email,
      emailRedirectTo: magicLinkRedirect,
    );
  }

  @override
  Future<void> signOut() => _client.auth.signOut();

  static AuthSessionState _toSessionState(Session? session) {
    final email = session?.user.email;
    return (email == null || email.isEmpty)
        ? const AuthSessionState.signedOut()
        : AuthSessionState.signedIn(email, uid: session?.user.id);
  }
}
