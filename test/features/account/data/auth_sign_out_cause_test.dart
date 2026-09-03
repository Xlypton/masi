import 'package:masi/features/account/data/auth_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show SignOutReason;

void main() {
  group('authSignOutCauseFrom', () {
    test('maps every real gotrue SignOutReason case', () {
      expect(
        authSignOutCauseFrom(SignOutReason.userInitiated),
        AuthSignOutCause.userInitiated,
      );
      expect(
        authSignOutCauseFrom(SignOutReason.sessionExpired),
        AuthSignOutCause.sessionExpired,
      );
      expect(
        authSignOutCauseFrom(SignOutReason.sessionMissing),
        AuthSignOutCause.sessionMissing,
      );
    });

    test('covers the whole enum — a new gotrue case must not slip through', () {
      // If gotrue adds a case, this fails and forces an explicit decision
      // rather than silently mapping it to `unknown`.
      expect(SignOutReason.values, hasLength(3));
      for (final reason in SignOutReason.values) {
        expect(authSignOutCauseFrom(reason), isNotNull);
      }
    });

    test('a null reason is NOT user-initiated', () {
      // A cross-tab `signedOut` (fromBroadcast) and every non-signedOut event
      // carry a null reason. Treating null as user-initiated would clear
      // lastKnownUid on a mere token-refresh failure and re-open L4.
      expect(authSignOutCauseFrom(null), isNull);
      expect(authSignOutCauseFrom(null), isNot(AuthSignOutCause.userInitiated));
    });
  });

  group('AuthSessionState.signOutCause', () {
    test('defaults to null on the existing zero-arg signedOut ctor', () {
      const state = AuthSessionState.signedOut();
      expect(state.signOutCause, isNull);
      expect(state.isSignedIn, isFalse);
    });

    test('carries the cause when supplied', () {
      const state = AuthSessionState.signedOut(
        cause: AuthSignOutCause.userInitiated,
      );
      expect(state.signOutCause, AuthSignOutCause.userInitiated);
    });

    test('a signed-in state never carries a cause', () {
      const state = AuthSessionState.signedIn('a@b.c', uid: 'u1');
      expect(state.signOutCause, isNull);
    });

    test('equality stays email-only (unchanged contract)', () {
      // Existing assertions across account_screen_test.dart etc. rely on this.
      expect(
        const AuthSessionState.signedOut(cause: AuthSignOutCause.userInitiated),
        const AuthSessionState.signedOut(
          cause: AuthSignOutCause.sessionExpired,
        ),
      );
    });
  });
}
