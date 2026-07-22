import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/account/data/auth_repository.dart';

/// Pure edge-detector + guarded invoker backing `MasiApp`'s
/// `ref.listen(authStateProvider, ...)` claim-on-sign-in bootstrap.
///
/// Fires [claim] with the newly-signed-in uid exactly when [previous] was
/// NOT resolved to a signed-in session (i.e. it was `null` — no prior
/// emission yet — still loading, an error such as an uninitialized Supabase
/// client, or resolved data with a `null` uid/signed-out) and [next]
/// resolves to data with a non-null uid. That is the signed-out (or
/// unknown) -> signed-in edge. Every other transition — already signed in
/// staying signed in (e.g. a token refresh re-emitting the same session),
/// signed-in -> signed-out, loading/error -> loading/error, etc. — is a
/// no-op, so a rebuild or a benign re-emission never re-fires the claim for
/// a session that already had its shot.
///
/// Reading `next`/`previous` only through [AsyncValue.asData] means an
/// unavailable/erroring auth source (Supabase never initialized, a stream
/// error) degrades to `null` here rather than throwing — this must never
/// crash the app, since Masi is local-first and fully usable with sync
/// unavailable (see `main()`'s identical "log and continue" stance around
/// `Supabase.initialize`).
///
/// [claim] itself is invoked fire-and-forget (its `Future` is not awaited by
/// the caller, since `ref.listen` callbacks are synchronous) and any failure
/// is caught and logged rather than rethrown — a failed backfill just means
/// the next sign-in gets another chance, not a crashed listener.
void handleAuthStateForClaimOwnership(
  AsyncValue<AuthSessionState>? previous,
  AsyncValue<AuthSessionState> next,
  Future<void> Function(String uid) claim,
) {
  final previousUid = previous?.asData?.value.uid;
  final nextUid = next.asData?.value.uid;
  if (previousUid == null && nextUid != null) {
    unawaited(
      claim(nextUid).catchError((Object e, StackTrace st) {
        debugPrint('claimOwnership on sign-in failed: $e\n$st');
      }),
    );
  }
}
