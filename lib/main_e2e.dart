// E2E-ONLY ENTRYPOINT — never built for production, never deployed.
//
// `flutter build web` (and `tool/build_web.sh`, and the `deploy-web` skill)
// all target the DEFAULT entrypoint `lib/main.dart`. This file is reachable
// only via an explicit `-t lib/main_e2e.dart`, so nothing here is compiled
// into, or tree-shaken from, a production bundle — it is simply never part of
// that program. `tool/build_web.sh` additionally greps the emitted bundle for
// [e2eEntrypointMarker] (and [e2eTestEmail]) and FAILS the build if either
// appears, so a mistargeted production build cannot ship this silently.
//
// WHY THIS EXISTS. The app is private and web sign-in is a hard wall
// (`webAuthGateEnabledProvider` defaults to `kIsWeb`; see `app/router.dart`'s
// `_webAuthGateRedirect`). Every sign-in route the app OFFERS needs something
// an automated agent cannot drive:
//   - magic link  -> requires reading an email inbox,
//   - emailed OTP -> same, and its field is iOS-web only,
//   - Google OAuth -> requires a real Google consent screen.
// So an agent driving a real browser can otherwise never get past `/account`,
// and the entire signed-in surface of the app is untestable.
//
// ============================ THE TWO MODES ============================
//
// This entrypoint has TWO modes, selected by whether `E2E_EMAIL`/`E2E_PASSWORD`
// were supplied as `--dart-define`s. Both boot the REAL app — real router, real
// widgets, real drift database on OPFS, real photo pipeline. They differ only
// in who the app thinks it is, and in whether the server agrees.
//
// ---- FAKE mode (no dart-defines) — [e2eOverrides] --------------------------
// Two overrides: the auth wall off, and [E2eSignedInAuthRepository] standing in
// for Supabase auth as [e2eTestEmail]/[e2eTestUid]. Everything below the auth
// seam is production code.
//
//   PROVES: the app's own behavior for a signed-in user — routing, layout,
//   local drift/OPFS reads and writes, photo rendering, every screen that does
//   not need the server to answer.
//   DOES NOT PROVE, and must never be claimed to: real Supabase authentication,
//   JWT issuance, or anything gated on server-side RLS. `auth.uid()` is null
//   under the bare anon key, so live push/pull is rejected and the console
//   fills with 401s. That rejection is also what makes this mode SAFE: it
//   cannot write to the live dev backend at all.
//
// ---- REAL mode (`--dart-define=E2E_EMAIL=… --dart-define=E2E_PASSWORD=…`) ---
// NO overrides. `Supabase.initialize` runs first, then a real
// `signInWithPassword` against the real anon key, and only then does `bootApp`
// run — with the production `SupabaseAuthRepository` and the production auth
// wall both fully live. The session carries a real JWT.
//
//   PROVES: everything FAKE mode proves, PLUS real authentication, real RLS,
//   real sync push/pull, and every server-gated community/moderation flow —
//   the review queue, reports, suggestions, trust levels, version history.
//   DOES NOT PROVE: the sign-in ROUTES the product actually ships (magic link,
//   emailed OTP, Google OAuth). Password grant is an E2E-only door; no button
//   in the app reaches it. It also does not prove anything about a browser's
//   OAuth redirect handling.
//
// Accounts are provisioned by `tool/e2e_accounts.sh ensure` — real, confirmed
// users under the RFC 2606 `.test` TLD (`e2e-owner@masi.test`,
// `e2e-reader@masi.test`, `e2e-admin@masi.test`) on the SAME live dev project
// the app uses. Isolation is by OWNERSHIP, not by database: every row these
// accounts create is `ownerId`-scoped to an E2E uid, and `tool/e2e_reset.sh`
// deletes exactly that set and nothing else.
//
// ---- A NOTE ON UIDS AND THE LOCAL LIBRARY ---------------------------------
// `effectiveUidProvider` is THE single "who am I, for LOCAL data" door: it
// feeds every owner-scoped drift query AND `PhotoFiles`' per-user path prefix.
// The two modes therefore see DIFFERENT LOCAL LIBRARIES on the same browser
// profile — fake-mode rows are owned by [e2eTestUid], real-mode rows by the
// Supabase uid of whichever account signed in. That is correct (it is the same
// isolation a real account switch gets), but it means a topo created in one
// mode is invisible in the other, and switching modes is not a way to inspect
// what the other mode wrote.
import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/misc.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show Supabase;

import 'core/config/supabase_init_provider.dart' show initializeSupabase;
import 'features/account/application/auth_providers.dart';
import 'features/account/data/auth_repository.dart';
import 'main.dart' show bootApp;

/// The synthetic E2E identity's email, used by FAKE mode.
///
/// `.test` is reserved by RFC 2606 and can never resolve to a real mailbox,
/// so this address cannot collide with — or accidentally be mailed by — a real
/// account. Also one of the two marker strings `tool/build_web.sh` greps for to
/// prove this entrypoint never reached a production bundle.
const String e2eTestEmail = 'e2e@masi.test';

/// Unconditional build-gate marker.
///
/// [e2eTestEmail] alone is NOT a sufficient gate any more: in REAL mode nothing
/// references [E2eSignedInAuthRepository], so a tree-shaking compiler is free
/// to drop that constant from the bundle entirely — and the gate would then
/// pass on a bundle that does bypass the product's sign-in. This marker is
/// printed by [e2eBoot] on every boot in BOTH modes, so it can never be shaken
/// out. `tool/build_web.sh` greps for it.
const String e2eEntrypointMarker = 'masi-e2e-entrypoint-do-not-deploy';

/// The synthetic E2E identity's uid — what `auth.uid()` would resolve to.
///
/// Fixed rather than random because it is an OWNERSHIP key, not a nonce:
/// `effectiveUidProvider` (the single "who am I, for LOCAL data" door) feeds
/// every owner-scoped query, and `PhotoFiles` builds per-user path prefixes
/// from it. A uid that changed per run would orphan the previous run's local
/// library and photos behind an owner filter that no longer matches, so
/// nothing would ever persist across runs and no cross-run regression (the
/// interesting kind) would be observable.
///
/// Shaped as a valid v4 UUID so it is indistinguishable from a real Supabase
/// uid to every consumer that parses one.
const String e2eTestUid = '00000000-0000-4000-8000-000000000e2e';

/// The three dedicated E2E accounts, provisioned by `tool/e2e_accounts.sh`.
///
/// Public constants, not defines: an address is not a secret, and having them
/// in the source is what lets ONE build switch identity at runtime
/// ([e2eSignInAs]) instead of needing a separate `--dart-define` build per
/// role. Only the shared password is a define.
const String e2eOwnerEmail = 'e2e-owner@masi.test';

/// Files reports and suggestions against [e2eOwnerEmail]'s published topo.
const String e2eReaderEmail = 'e2e-reader@masi.test';

/// Present in `public.admins`, so `is_admin()` is true and the review queue,
/// the reports tab and `review_topo`/`resolve_report`/`revert_topo` all answer.
const String e2eAdminEmail = 'e2e-admin@masi.test';

/// The real E2E account this build boots as.
///
/// Supplied as `--dart-define=E2E_EMAIL=…`; defaults to [e2eOwnerEmail] when
/// only the password was given, which is the common case. Get the flags from
/// `tool/e2e_accounts.sh env owner|reader|admin`.
const String e2eRealEmail = String.fromEnvironment(
  'E2E_EMAIL',
  defaultValue: e2eOwnerEmail,
);

/// The real E2E account's password, or `''` when REAL mode was not requested.
///
/// Supplied as `--dart-define=E2E_PASSWORD=…`, sourced from
/// `~/.config/masi-e2e-password`. It is a throwaway credential for three
/// `.test` accounts on a dev project and is never committed — but it IS baked
/// into whatever bundle you build with it, which is one more reason such a
/// bundle only ever goes to `build/web_e2e` and is never deployed.
const String e2eRealPassword = String.fromEnvironment('E2E_PASSWORD');

/// Whether REAL mode was requested.
///
/// Keyed on the PASSWORD alone, because that is the only define that carries
/// information the build cannot otherwise have — [e2eRealEmail] has a sensible
/// default. Supplying `E2E_EMAIL` without `E2E_PASSWORD` therefore stays in
/// FAKE mode rather than half-booting a real session it cannot complete.
bool get e2eRealSessionRequested =>
    e2eRealEmail.isNotEmpty && e2eRealPassword.isNotEmpty;

/// Signs the running app in as [email], one of the three E2E accounts, using
/// the password this build was compiled with. REAL mode only.
///
/// Exists so a scripted run can cross an OWNERSHIP BOUNDARY — file a report as
/// the reader against the owner's topo, then approve it as the admin — inside a
/// single build. `--dart-define` is compile-time, so without this every role
/// would need its own full rebuild.
///
/// This is a REAL account switch, not a shim: gotrue issues a new JWT, and
/// `effectiveUidProvider` therefore starts resolving to a different uid, which
/// re-scopes every owner-filtered local drift query and `PhotoFiles`' path
/// prefix. That is exactly what a user switching accounts on one browser
/// experiences — including that the previous role's local library goes out of
/// view. Await this and let the app settle before asserting anything.
///
/// Throws in FAKE mode rather than silently doing nothing: a test that asks to
/// become the admin and quietly stays the fake user would then assert against
/// the wrong identity and report a pass.
Future<void> e2eSignInAs(String email) async {
  if (!e2eRealSessionRequested) {
    throw StateError(
      'e2eSignInAs($email) needs REAL mode — rebuild with '
      '--dart-define=E2E_PASSWORD=… (tool/e2e_accounts.sh env)',
    );
  }
  await Supabase.instance.client.auth.signOut();
  await Supabase.instance.client.auth.signInWithPassword(
    email: email,
    password: e2eRealPassword,
  );
}

/// The email this run is signed in as, whichever mode is active.
///
/// Assertions about the session should use this rather than [e2eTestEmail], so
/// one test file works unchanged in both modes.
String get e2eActiveEmail =>
    e2eRealSessionRequested ? e2eRealEmail : e2eTestEmail;

/// In-memory [AuthRepository] that reports a permanently signed-in session as
/// [e2eTestEmail]/[e2eTestUid]. FAKE mode only.
///
/// Mirrors the `_FakeAuthRepository` copies in `web_boot_stability_test.dart`
/// and `google_banner_shot_test.dart`, but signed-IN rather than signed-out,
/// and shared rather than copy-pasted a third time.
///
/// [signOut] genuinely flips to signed-out (with
/// [AuthSignOutCause.userInitiated], the only cause permitted to clear
/// `LastKnownUid`) so the sign-out path is exercisable rather than inert.
class E2eSignedInAuthRepository implements AuthRepository {
  E2eSignedInAuthRepository() {
    _controller.add(_current);
  }

  AuthSessionState _current = const AuthSessionState.signedIn(
    e2eTestEmail,
    uid: e2eTestUid,
  );

  final StreamController<AuthSessionState> _controller =
      StreamController<AuthSessionState>.broadcast();

  @override
  Stream<AuthSessionState> authStateChanges() async* {
    yield _current;
    yield* _controller.stream;
  }

  @override
  AuthSessionState get currentSession => _current;

  /// No-op: there is no mailbox to send to, and pretending to send would make
  /// a broken send look successful in a test.
  @override
  Future<void> sendMagicLink(String email) async {}

  @override
  Future<void> signInWithGoogle() async {}

  @override
  Future<void> verifyEmailOtp(String email, String code) async {}

  @override
  Future<void> signOut() async {
    _current = const AuthSessionState.signedOut(
      cause: AuthSignOutCause.userInitiated,
    );
    _controller.add(_current);
  }
}

/// The override list that turns the real app into the FAKE-mode E2E app.
///
/// Exported so `integration_test/e2e_*_test.dart` drive byte-identical wiring
/// to what the interactive browser build runs — otherwise the scripted suite
/// and the hands-on session could diverge and disagree about a bug.
///
/// REAL mode deliberately returns `const []` from [e2eBootOverrides]: overriding
/// nothing is the point, because the auth wall and the real `AuthRepository`
/// are two of the things being tested.
List<Override> e2eOverrides() => [
  webAuthGateEnabledProvider.overrideWithValue(false),
  authRepositoryProvider.overrideWithValue(E2eSignedInAuthRepository()),
];

/// The overrides for whichever mode this build selected.
List<Override> e2eBootOverrides() =>
    e2eRealSessionRequested ? const <Override>[] : e2eOverrides();

/// Boots the app in whichever mode this build selected.
///
/// The single entry point for BOTH `main()` below and every
/// `integration_test/e2e_*_test.dart`, so a hand-driven browser session and a
/// scripted run can never disagree about how the app was started.
///
/// REAL mode does its sign-in BEFORE `bootApp`, not after, because
/// `MasiApp.build()` constructs `authStateProvider` on its very first build:
/// booting first and signing in second would render one frame of the signed-OUT
/// app, which the production auth wall would immediately redirect to
/// `/account`, and the test would then be racing a redirect it did not cause.
///
/// `initializeSupabase()` is safe to call here even though `bootApp` calls it
/// too — it is documented re-callable (`Supabase.initialize` returns the
/// existing singleton once `_isInitialized` is set), so boot's own call becomes
/// a no-op rather than a second init.
///
/// A FAILED real sign-in deliberately does NOT fall back to the fake identity.
/// Falling back would turn "the server rejected us" into a green run against a
/// fake session — precisely the false pass this whole mode exists to remove.
/// Instead the app boots with no overrides at all, so the production auth wall
/// bounces to `/account` and the failure is visible on the very first
/// screenshot.
Future<void> e2eBoot() async {
  // Printed unconditionally, in both modes, so [e2eEntrypointMarker] can never
  // be tree-shaken out of the bundle the build gate greps.
  debugPrint(
    'masi/e2e: $e2eEntrypointMarker '
    '(mode=${e2eRealSessionRequested ? 'real-session' : 'fake-session'})',
  );
  if (!e2eRealSessionRequested) {
    debugPrint(
      'masi/e2e: FAKE session as $e2eTestEmail — no JWT, so every '
      'server-gated call will 401. That is expected in this mode.',
    );
    return bootApp(overrides: e2eOverrides());
  }

  try {
    await initializeSupabase();
    final response = await Supabase.instance.client.auth.signInWithPassword(
      email: e2eRealEmail,
      password: e2eRealPassword,
    );
    debugPrint(
      'masi/e2e: REAL session as $e2eRealEmail (uid=${response.user?.id}) — '
      'RLS applies, sync push/pull is live, writes land in the dev backend.',
    );
  } catch (error, stackTrace) {
    // Loud, and NOT recovered from with a fake identity. See the doc above.
    debugPrint(
      'masi/e2e: REAL sign-in FAILED for $e2eRealEmail: $error\n$stackTrace\n'
      'masi/e2e: booting SIGNED OUT — the auth wall will bounce to /account. '
      'Do not report any flow as verified from this run.',
    );
  }
  return bootApp();
}

Future<void> main() => e2eBoot();
