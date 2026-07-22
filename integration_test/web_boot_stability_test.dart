// Real-app web boot-stability + auth-wall e2e. Proves two things about a
// REAL app boot in headless Chrome: (a) the app actually boots on web and
// reaches a stable UI, and (b) the web-only auth wall
// (`webAuthGateEnabledProvider` / `_webAuthGateRedirect`, see
// `auth_providers.dart` / `router.dart`) engages for a signed-out user and
// STAYS engaged — no redirect loop, no churn — across a multi-second pump.
// Driven headless in Chrome via
// `tool/drive_web.sh integration_test/web_boot_stability_test.dart`
// (NOT run by `flutter test` — this needs the real browser/IndexedDB stack,
// same harness as `web_smoke_test.dart`).
//
// Deliberately single-scenario (signed-out + gate ON, the production web
// default). This file used to also carry "signed-in + gate ON" and "gate
// OFF" scenarios as separate `testWidgets`, but both failed for a harness
// reason unrelated to the redirect logic itself: `appRouter`
// (`lib/app/router.dart`) is a module-level singleton, so its `GoRouter`
// navigation state persists across multiple `bootApp()` calls made in the
// SAME headless-Chrome page/isolate. Scenario 1 leaves the router parked at
// `/account`; `_webAuthGateRedirect`'s early-return
// (`if matchedLocation == '/account' return null`) then keeps every
// subsequent scenario in that same test run stuck on `/account` regardless
// of the fake auth state or gate override — a multi-boot-per-page test
// artifact only. Production calls `bootApp()` exactly once per page load,
// so this never happens for real users. The per-auth-state ROUTING this
// file used to assert (signed-in → Topos home, gate-off → Topos home even
// signed out) is already thoroughly unit-tested against `appRouter`'s
// redirect logic directly in `test/app/router_test.dart`'s "web auth wall"
// group, which doesn't have the multi-boot problem because it drives the
// router in isolation rather than via repeated real `bootApp()` calls.
//
// Background (#55): the random-reload bug had two independent causes — a
// stale cached service worker (fixed via `web/_headers` Cache-Control) and
// this app's `main()` having no way to inject test overrides at all, so no
// web integration test could previously reach past the new auth wall to
// prove it wasn't ALSO contributing redirect churn. `bootApp()` (extracted
// from `main()` in `lib/main.dart`) is the fix: it takes a `List<Override>`
// straight through to the `ProviderContainer`, so this test can fake auth
// and force the gate on/off without a real Supabase session or a real web
// build flag.
//
// The fake `AuthRepository` mirrors `test/app/router_test.dart`'s
// `_FakeAuthRepository` (itself modeled on `account_screen_test.dart`'s),
// trimmed to just what `_webAuthGateRedirect` reads (`authStateChanges`).
// Deliberately does NOT override `appDatabaseProvider` — like
// `web_smoke_test.dart`, this runs against the real web (drift/OPFS via
// IndexedDB) connection, since `NativeDatabase.memory()`
// (`package:drift/native.dart`) is `dart:ffi`-based and does not compile for
// web at all; no photos are ever seeded or decoded, so there's nothing here
// that needs a fresh/isolated DB per scenario beyond what a fresh headless
// Chrome profile already gives each `drive_web.sh` run.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:masi/features/account/application/auth_providers.dart';
import 'package:masi/features/account/data/auth_repository.dart';
import 'package:masi/main.dart' show bootApp;

/// Minimal in-memory [AuthRepository] double — see this file's header doc.
/// Only ever constructed with a resolved (signed-in or signed-out) state, so
/// unlike `router_test.dart`'s version this skips the `.loadingForever()` /
/// `.erroring()` variants (those are `_webAuthGateRedirect` unit-level edge
/// cases already covered there; this file is about real-app boot stability,
/// not exhaustively re-covering the redirect's branch logic).
class _FakeAuthRepository implements AuthRepository {
  _FakeAuthRepository(AuthSessionState initial) : _current = initial {
    _controller.add(initial);
  }

  final _controller = StreamController<AuthSessionState>();
  final AuthSessionState _current;

  @override
  AuthSessionState get currentSession => _current;

  @override
  Stream<AuthSessionState> authStateChanges() => _controller.stream;

  @override
  Future<void> sendMagicLink(String email) async {}

  @override
  Future<void> signInWithGoogle() async {}

  @override
  Future<void> verifyEmailOtp(String email, String code) async {}

  @override
  Future<void> signOut() async {}
}

/// Pumps for a few real seconds without `pumpAndSettle` (which would hang
/// forever against a live `StreamProvider` subscription that never
/// completes) — this is the "does it stay put" half of each scenario: a
/// redirect loop or repeated rebuild would flip the screen away from
/// whatever [tester] last settled on, so re-checking the same finder after
/// this is what actually proves stability rather than a single snapshot.
Future<void> _pumpForStability(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(seconds: 1));
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('web boot stability + auth wall', () {
    testWidgets(
      'signed-out + gate ON (web default): real app boots, shows the '
      'sign-in view, and stays there under sustained pumping — no '
      'redirect loop, no churn',
      (tester) async {
        bootApp(
          overrides: [
            authRepositoryProvider.overrideWithValue(
              _FakeAuthRepository(const AuthSessionState.signedOut()),
            ),
            // Gate left at its default (`kIsWeb`) — true for this web
            // build — so this scenario also proves the PRODUCTION default,
            // not just an explicit override.
          ],
        );
        await tester.pumpAndSettle(const Duration(seconds: 2));
        await binding.takeScreenshot('01-signed-out-gate-on-sign-in-view');

        expect(find.byKey(const Key('account-email-field')), findsOneWidget);
        expect(find.byKey(const Key('nav-tab-topos')), findsNothing);

        await _pumpForStability(tester);
        await binding.takeScreenshot('02-signed-out-gate-on-still-stable');

        expect(
          find.byKey(const Key('account-email-field')),
          findsOneWidget,
          reason: 'must still be on the sign-in view after several seconds '
              '— no bounce/loop',
        );
        expect(find.byKey(const Key('nav-tab-topos')), findsNothing);
      },
    );
  });
}
