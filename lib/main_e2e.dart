// E2E-ONLY ENTRYPOINT — never built for production, never deployed.
//
// `flutter build web` (and `tool/build_web.sh`, and the `deploy-web` skill)
// all target the DEFAULT entrypoint `lib/main.dart`. This file is reachable
// only via an explicit `-t lib/main_e2e.dart`, so nothing here is compiled
// into, or tree-shaken from, a production bundle — it is simply never part of
// that program. `tool/build_web.sh` additionally greps the emitted bundle for
// [e2eTestEmail] and FAILS the build if it appears, so a mistargeted
// production build cannot ship this silently.
//
// WHY THIS EXISTS. The app is private and web sign-in is a hard wall
// (`webAuthGateEnabledProvider` defaults to `kIsWeb`; see `app/router.dart`'s
// `_webAuthGateRedirect`). Every real sign-in route needs something an
// automated agent cannot drive:
//   - magic link  -> requires reading an email inbox,
//   - emailed OTP -> same, and its field is iOS-web only,
//   - Google OAuth -> requires a real Google consent screen.
// So an agent driving a real browser can otherwise never get past `/account`,
// and the entire signed-in surface of the app is untestable.
//
// This entrypoint boots the REAL app — real router, real widgets, real drift
// database on OPFS, real photo pipeline — with exactly two overrides: the
// auth wall off, and [E2eSignedInAuthRepository] standing in for Supabase
// auth. Everything below the auth seam is production code.
//
// WHAT THIS DOES NOT TEST, and must never be claimed to: real Supabase
// authentication, real JWT issuance, and anything gated on server-side RLS
// (`auth.uid()` is null for the anon key, so live push/pull is rejected).
// Those need a real session and remain human-in-the-loop. This harness proves
// the app's own behavior for a signed-in user, which is where the large
// majority of the bug surface lives — not that auth itself works.
import 'dart:async';

import 'package:flutter_riverpod/misc.dart';

import 'features/account/application/auth_providers.dart';
import 'features/account/data/auth_repository.dart';
import 'main.dart' show bootApp;

/// The synthetic E2E identity's email.
///
/// `.test` is reserved by RFC 2606 and can never resolve to a real mailbox,
/// so this address cannot collide with — or accidentally be mailed by — a real
/// account. Also doubles as the marker string `tool/build_web.sh` greps for to
/// prove this entrypoint never reached a production bundle.
const String e2eTestEmail = 'e2e@masi.test';

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

/// In-memory [AuthRepository] that reports a permanently signed-in session as
/// [e2eTestEmail]/[e2eTestUid].
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

/// The override list that turns the real app into the E2E-signed-in app.
///
/// Exported so `integration_test/e2e_signed_in_test.dart` drives byte-identical
/// wiring to what the interactive browser build runs — otherwise the scripted
/// suite and the hands-on session could diverge and disagree about a bug.
List<Override> e2eOverrides() => [
  webAuthGateEnabledProvider.overrideWithValue(false),
  authRepositoryProvider.overrideWithValue(E2eSignedInAuthRepository()),
];

Future<void> main() => bootApp(overrides: e2eOverrides());
