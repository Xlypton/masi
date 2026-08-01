import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/account/data/auth_repository.dart';

/// Pure edge-handler backing `MasiApp`'s `ref.listen(authStateProvider, ...)`
/// last-known-uid bootstrap — the sibling of
/// `handleAuthStateForClaimOwnership` in `claim_ownership_bootstrap.dart`, and
/// deliberately shaped the same way (a pure function over the AsyncValue, unit
/// tested on its own, with the provider wiring left to the call site).
///
/// Semantics, which are the entire point of §1c:
///  - `AsyncLoading`/`AsyncError` -> **do nothing**. gotrue's refresh ticker
///    fires every 10s and, once offline near expiry, pushes an
///    `AuthRetryableFetchException` down the stream on every tick with the
///    in-memory session still valid. Those must not touch the stored uid.
///  - a session uid present -> [remember] it.
///  - signed out with [AuthSignOutCause.userInitiated] -> [forget].
///  - signed out for ANY other reason ([AuthSignOutCause.sessionExpired] —
///    L4's captive-portal hard sign-out, [AuthSignOutCause.sessionMissing], or
///    a null/unknown cause such as a cross-tab `BroadcastChannel` sign-out) ->
///    **keep** the uid. Losing it here is exactly what blackholes local
///    writes.
///
/// Unlike the claim-ownership handler this needs no `previous`: every decision
/// is a function of the current emission alone, and both actions are
/// idempotent ([remember] no-ops on an unchanged uid, [forget] on an already
/// null one), so a duplicate emission is harmless.
void handleAuthStateForLastKnownUid(
  AsyncValue<AuthSessionState> next, {
  required void Function(String uid) remember,
  required void Function() forget,
}) {
  final session = next.asData?.value;
  if (session == null) return;
  final uid = session.uid;
  if (uid != null && uid.isNotEmpty) {
    remember(uid);
    return;
  }
  if (session.signOutCause == AuthSignOutCause.userInitiated) forget();
}
