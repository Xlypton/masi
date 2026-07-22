// Screenshot-capture test for two new web-only UI elements, driven headless
// in Chrome via `tool/drive_web.sh` (same harness as `web_smoke_test.dart`
// and `web_boot_stability_test.dart`):
//
//  1. the PWA "Add to Home Screen" install banner (`install-banner`, top of
//     the `NavShell` body — see `lib/app/install_banner.dart`), forced
//     visible via `pwaInstallStatusProvider.overrideWithValue(...)` with
//     `canPrompt: true`;
//  2. the Account screen's "Continue with Google" button
//     (`account-google-signin`, in `_SignedOutBody` — see
//     `lib/features/account/presentation/account_screen.dart`), reached by
//     tapping the Topos home AppBar's `topos-account-button`
//     (`context.push('/account')` — see `topos_screen.dart`).
//
// A SINGLE `bootApp()` call drives both screenshots in one `testWidgets`
// (the `appRouter` is a module-level singleton, so — per
// `web_boot_stability_test.dart`'s header doc — a second `bootApp()` call in
// the same headless-Chrome page would inherit stale router navigation state
// from the first).
//
// Uses a `_FakeAuthRepository` (copied from `web_boot_stability_test.dart`,
// signed-out) rather than the real Supabase-backed `authRepositoryProvider`,
// so the Account screen settles on `_SignedOutBody` deterministically
// without a real network round-trip — and, per that same file's doc, so
// `authStateProvider`'s loading spinner (a `CircularProgressIndicator`,
// whose implicit rotation animation would make `pumpAndSettle` hang forever)
// resolves to a value on the very first stream emission instead of sitting
// in `AsyncLoading` indefinitely.
//
// Run with:
//   tool/drive_web.sh integration_test/google_banner_shot_test.dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:climbtopo/features/account/application/auth_providers.dart';
import 'package:climbtopo/features/account/application/pwa_install_providers.dart';
import 'package:climbtopo/features/account/application/pwa_install_types.dart';
import 'package:climbtopo/features/account/data/auth_repository.dart';
import 'package:climbtopo/main.dart' show bootApp;

/// Minimal in-memory [AuthRepository] double — copied verbatim from
/// `web_boot_stability_test.dart`'s `_FakeAuthRepository` (see that file's
/// header doc for the full rationale). Always constructed already-resolved
/// (signed-out here), so there's no `.loadingForever()` variant to worry
/// about.
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

/// Pumps a bounded number of real frames without `pumpAndSettle` — mirroring
/// `web_boot_stability_test.dart`'s `_pumpForStability`: a bare
/// `Future.delayed` blanks the screenshot on some harnesses, and
/// `pumpAndSettle` itself is unsafe here (see this file's header doc), so a
/// fixed pump loop is the only reliable way to let a frame settle before
/// `takeScreenshot`.
Future<void> _pump(WidgetTester tester, [int times = 6]) async {
  for (var i = 0; i < times; i++) {
    await tester.pump(const Duration(milliseconds: 500));
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'PWA install banner shows on Topos home; Google sign-in button shows '
    'on the signed-out Account screen',
    (tester) async {
      bootApp(
        overrides: [
          webAuthGateEnabledProvider.overrideWithValue(false),
          authRepositoryProvider.overrideWithValue(
            _FakeAuthRepository(const AuthSessionState.signedOut()),
          ),
          pwaInstallStatusProvider.overrideWithValue(
            const PwaInstallStatus(
              isStandalone: false,
              canPrompt: true,
              platform: PwaPlatform.other,
            ),
          ),
        ],
      );
      await _pump(tester);
      await binding.takeScreenshot('01-install-banner');

      expect(
        find.byKey(const Key('install-banner')),
        findsOneWidget,
        reason:
            'PWA install banner should be visible on Topos home when '
            'canPrompt is true',
      );

      // --- Navigate to the Account sign-in screen via the AppBar button ---
      final accountButton = find.byKey(const Key('topos-account-button'));
      expect(accountButton, findsOneWidget);
      await tester.tap(accountButton);
      await _pump(tester);
      await binding.takeScreenshot('02-account-google');

      expect(
        find.byKey(const Key('account-google-signin')),
        findsOneWidget,
        reason:
            'Google sign-in button should be visible on the signed-out '
            'Account screen',
      );
    },
  );
}
