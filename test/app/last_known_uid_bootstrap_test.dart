import 'package:masi/app/last_known_uid_bootstrap.dart';
import 'package:masi/features/account/data/auth_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late List<String> remembered;
  late int forgotten;

  setUp(() {
    remembered = [];
    forgotten = 0;
  });

  void run(AsyncValue<AuthSessionState> next) {
    handleAuthStateForLastKnownUid(
      next,
      remember: remembered.add,
      forget: () => forgotten++,
    );
  }

  test('a signed-in emission remembers the uid', () {
    run(const AsyncData(AuthSessionState.signedIn('a@b.c', uid: 'user-u1')));
    expect(remembered, ['user-u1']);
    expect(forgotten, 0);
  });

  test('an account switch remembers the new uid', () {
    run(const AsyncData(AuthSessionState.signedIn('a@b.c', uid: 'user-u1')));
    run(const AsyncData(AuthSessionState.signedIn('b@b.c', uid: 'user-u2')));
    expect(remembered, ['user-u1', 'user-u2']);
    expect(forgotten, 0);
  });

  test('AsyncLoading touches nothing', () {
    run(const AsyncLoading());
    expect(remembered, isEmpty);
    expect(forgotten, 0);
  });

  test('AsyncError touches nothing — this is the offline-refresh case', () {
    // gotrue's 10s ticker addError()s an AuthRetryableFetchException on every
    // offline refresh attempt. That must not disturb lastKnownUid at all.
    run(AsyncError(Exception('AuthRetryableFetchException'), StackTrace.empty));
    expect(remembered, isEmpty);
    expect(forgotten, 0);
  });

  test('a sessionExpired sign-out does NOT forget (L4)', () {
    run(
      const AsyncData(
        AuthSessionState.signedOut(cause: AuthSignOutCause.sessionExpired),
      ),
    );
    expect(forgotten, 0, reason: 'involuntary sign-out must keep the uid');
  });

  test('a sessionMissing sign-out does NOT forget', () {
    run(
      const AsyncData(
        AuthSessionState.signedOut(cause: AuthSignOutCause.sessionMissing),
      ),
    );
    expect(forgotten, 0);
  });

  test('a cause-less (cross-tab / unknown) sign-out does NOT forget', () {
    run(const AsyncData(AuthSessionState.signedOut()));
    expect(forgotten, 0);
  });

  test('a userInitiated sign-out DOES forget', () {
    run(
      const AsyncData(
        AuthSessionState.signedOut(cause: AuthSignOutCause.userInitiated),
      ),
    );
    expect(forgotten, 1);
    expect(remembered, isEmpty);
  });

  test('an empty uid is ignored rather than remembered', () {
    run(const AsyncData(AuthSessionState.signedIn('a@b.c', uid: '')));
    expect(remembered, isEmpty);
    expect(forgotten, 0);
  });
}
