import 'package:masi/app/claim_ownership_bootstrap.dart';
import 'package:masi/features/account/data/auth_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('handleAuthStateForClaimOwnership', () {
    test(
      'fires claim exactly once, with the new uid, on the signed-out -> '
      'signed-in edge',
      () {
        final calls = <String>[];
        Future<void> claim(String uid) async => calls.add(uid);

        handleAuthStateForClaimOwnership(
          const AsyncValue.data(AuthSessionState.signedOut()),
          AsyncValue.data(AuthSessionState.signedIn('a@b.com', uid: 'u1')),
          claim,
        );

        expect(calls, ['u1']);
      },
    );

    test(
      'fires claim when the previous state was still loading (cold-start '
      'restoring an already-signed-in session)',
      () {
        final calls = <String>[];
        Future<void> claim(String uid) async => calls.add(uid);

        handleAuthStateForClaimOwnership(
          const AsyncValue.loading(),
          AsyncValue.data(AuthSessionState.signedIn('a@b.com', uid: 'u1')),
          claim,
        );

        expect(calls, ['u1']);
      },
    );

    test(
      'fires claim when previous is null (the very first emission the '
      'listener ever sees)',
      () {
        final calls = <String>[];
        Future<void> claim(String uid) async => calls.add(uid);

        handleAuthStateForClaimOwnership(
          null,
          AsyncValue.data(AuthSessionState.signedIn('a@b.com', uid: 'u1')),
          claim,
        );

        expect(calls, ['u1']);
      },
    );

    test(
      'does NOT fire again for a same-session re-emission (already '
      'signed-in -> still signed-in, e.g. a token refresh)',
      () {
        final calls = <String>[];
        Future<void> claim(String uid) async => calls.add(uid);

        handleAuthStateForClaimOwnership(
          AsyncValue.data(AuthSessionState.signedIn('a@b.com', uid: 'u1')),
          AsyncValue.data(AuthSessionState.signedIn('a@b.com', uid: 'u1')),
          claim,
        );

        expect(
          calls,
          isEmpty,
          reason: 'the edge already fired on the earlier signed-out -> '
              'signed-in transition; a rebuild/re-emission of the same '
              'signed-in session must not re-trigger it',
        );
      },
    );

    test('does not fire on a signed-in -> signed-out transition', () {
      final calls = <String>[];
      Future<void> claim(String uid) async => calls.add(uid);

      handleAuthStateForClaimOwnership(
        AsyncValue.data(AuthSessionState.signedIn('a@b.com', uid: 'u1')),
        const AsyncValue.data(AuthSessionState.signedOut()),
        claim,
      );

      expect(calls, isEmpty);
    });

    test('does not fire on a signed-out -> signed-out transition', () {
      final calls = <String>[];
      Future<void> claim(String uid) async => calls.add(uid);

      handleAuthStateForClaimOwnership(
        const AsyncValue.data(AuthSessionState.signedOut()),
        const AsyncValue.data(AuthSessionState.signedOut()),
        claim,
      );

      expect(calls, isEmpty);
    });

    test(
      'is a guarded no-op — does not throw and does not call claim — when '
      'the auth source is uninitialized/erroring, whether transitioning '
      'from or to the error state',
      () {
        final calls = <String>[];
        Future<void> claim(String uid) async => calls.add(uid);

        expect(
          () => handleAuthStateForClaimOwnership(
            null,
            AsyncValue<AuthSessionState>.error(
              StateError('Supabase not initialized'),
              StackTrace.empty,
            ),
            claim,
          ),
          returnsNormally,
        );
        expect(calls, isEmpty);

        // An error -> signed-in edge still legitimately claims once
        // Supabase recovers/initializes and reports a real session.
        handleAuthStateForClaimOwnership(
          AsyncValue<AuthSessionState>.error(
            StateError('Supabase not initialized'),
            StackTrace.empty,
          ),
          AsyncValue.data(AuthSessionState.signedIn('a@b.com', uid: 'u1')),
          claim,
        );
        expect(calls, ['u1']);
      },
    );

    test(
      'swallows a claim failure instead of letting it escape the listener '
      '(fire-and-forget, guarded)',
      () async {
        Future<void> failingClaim(String uid) async {
          throw StateError('boom');
        }

        expect(
          () => handleAuthStateForClaimOwnership(
            const AsyncValue.data(AuthSessionState.signedOut()),
            AsyncValue.data(AuthSessionState.signedIn('a@b.com', uid: 'u1')),
            failingClaim,
          ),
          returnsNormally,
        );

        // Let the fire-and-forget future (and its internal catchError)
        // actually run to completion before the test ends, so a real
        // failure here would surface as an unhandled-async-error test
        // failure rather than being silently dropped by the test runner.
        await Future<void>.delayed(Duration.zero);
      },
    );
  });
}
