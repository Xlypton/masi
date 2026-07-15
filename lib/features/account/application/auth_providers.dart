import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/supabase_providers.dart';
import '../data/auth_repository.dart';

/// The [AuthRepository] the rest of the `account` feature talks to.
///
/// Defaults to the real [SupabaseAuthRepository] wired to the shared
/// [supabaseClientProvider]; override this in tests with a fake
/// implementation (see `test/features/account/presentation/
/// account_screen_test.dart`) so nothing ever hits the real network.
final authRepositoryProvider = Provider<AuthRepository>(
  (ref) => SupabaseAuthRepository(ref.watch(supabaseClientProvider)),
);

/// Live [AuthSessionState]: signed-out or signed-in-with-email, sourced from
/// [authRepositoryProvider]'s [AuthRepository.authStateChanges] stream.
/// Mirrors the `library_providers.dart` pattern of a thin `StreamProvider`
/// over a repository method (e.g. `toposProvider`/`watchTopos`) rather than
/// a Notifier, since there is no local mutable state to own here — every
/// emission just reflects what Supabase's `onAuthStateChange` (or a test
/// fake) reports.
final authStateProvider = StreamProvider<AuthSessionState>(
  (ref) => ref.watch(authRepositoryProvider).authStateChanges(),
);

/// A lazily-evaluated accessor for the signed-in user's uid (or `null` when
/// signed out) that the row-inserting repository providers pass as their
/// `currentUid` seam to stamp `ownerId` at create time.
///
/// Returns `null` — i.e. degrades to signed-out — if the auth backend is
/// unavailable (`Supabase.initialize` failed or never ran). That happens
/// both in production first-launch/offline (see `main()`, which
/// deliberately catches an `initialize` failure and continues, keeping this
/// local-first app fully usable without Supabase) and in widget tests that
/// override the database but not auth. In either case an absent auth layer
/// must degrade to unattributed (`ownerId == null`) rows rather than
/// crashing the create/edit path — so the read is guarded and any failure
/// maps to signed-out, mirroring `main()`'s "log and continue" stance.
///
/// The uid is read *inside* the returned closure (lazily, per INSERT) rather
/// than up front, so this provider never rebuilds on auth changes and there
/// is no provider-construction cycle with the repository providers that
/// consume it.
final currentUidProvider = Provider<String? Function()>((ref) {
  return () {
    try {
      return ref.read(authRepositoryProvider).currentSession.uid;
    } catch (_) {
      return null;
    }
  };
});
