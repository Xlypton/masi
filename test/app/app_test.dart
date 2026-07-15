import 'dart:async';

import 'package:climbtopo/app/app.dart';
import 'package:climbtopo/app/router.dart';
import 'package:climbtopo/core/db/app_database.dart';
import 'package:climbtopo/core/db/database_provider.dart';
import 'package:climbtopo/features/account/application/auth_providers.dart';
import 'package:climbtopo/features/account/data/auth_repository.dart';
import 'package:climbtopo/features/backup/application/sync_orchestrator.dart';
import 'package:climbtopo/features/library/presentation/topos_screen.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Mirrors `router_test.dart`'s `_makeContainer`: a fresh in-memory database
/// so `ToposScreen` (the `/` route) has something real to watch, without
/// touching the real filesystem/sqlite. `authStateProvider` is also
/// overridden to a known signed-out stream — the real
/// `authRepositoryProvider` reaches `Supabase.instance.client`, which throws
/// when `Supabase.initialize` never ran (true in this test process),
/// surfacing as an `AsyncError` that would otherwise route `AccountScreen`
/// to its (unrelated, out-of-scope) error-state body instead of the normal
/// signed-out one this test actually wants to drive.
ProviderContainer _makeContainer() {
  final db = AppDatabase(NativeDatabase.memory());
  final container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(db),
      nowMsProvider.overrideWithValue(() => 1000),
      authStateProvider.overrideWith(
        (ref) => Stream.value(const AuthSessionState.signedOut()),
      ),
      // `ClimbTopoApp` permanently `ref.watch`es `syncOrchestratorProvider`
      // (see its doc comment), so ANY real table write in a test that
      // mounts it — e.g. this file's claim-on-sign-in row update below —
      // now schedules a real debounced-push `Timer`. Left at the real 2s
      // production default, that `Timer` would still be pending when
      // `testWidgets` tears down the widget tree, tripping Flutter test's
      // "A Timer is still pending" invariant. A few milliseconds is easily
      // covered by `_drain`'s pump cycles below, so the timer always fires
      // (and stops being "pending") well before any test here ends.
      syncDebounceDurationProvider.overrideWithValue(
        const Duration(milliseconds: 5),
      ),
    ],
  );
  addTearDown(db.close);
  addTearDown(container.dispose);
  return container;
}

/// Mirrors `router_test.dart`'s `_drain`: advances real Drift async work
/// interleaved with fake-clock pumps to get past the initial
/// `CircularProgressIndicator`.
Future<void> _drain(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 30));
  }
  await tester.pumpAndSettle();
}

void main() {
  // `appRouter` is a module-level singleton (see `router_test.dart`'s
  // identical caveat) whose location persists across tests in this file.
  setUp(() => appRouter.go('/'));

  group('ClimbTopoApp global tap-to-dismiss keyboard (#20)', () {
    testWidgets(
      'MaterialApp.router wraps its routed content in a translucent '
      'GestureDetector whose onTap unfocuses the current focus',
      (tester) async {
        final container = _makeContainer();

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const ClimbTopoApp(),
          ),
        );
        await _drain(tester);

        expect(find.byType(ToposScreen), findsOneWidget);

        final gestureDetectorFinder = find.byWidgetPredicate(
          (widget) =>
              widget is GestureDetector &&
              widget.behavior == HitTestBehavior.translucent &&
              widget.onTap != null,
        );
        expect(
          gestureDetectorFinder,
          findsOneWidget,
          reason:
              "MaterialApp.router's builder must wrap child in a "
              'translucent tap-to-dismiss GestureDetector',
        );
        // It must actually sit ABOVE the routed content (an ancestor), not
        // just exist somewhere unrelated in the tree.
        expect(
          find.ancestor(
            of: find.byType(ToposScreen),
            matching: gestureDetectorFinder,
          ),
          findsOneWidget,
        );

        // Now prove it actually dismisses the keyboard: navigate to the
        // Account screen (which has a real text field), focus that field,
        // then tap empty space elsewhere on screen and confirm focus drops.
        await tester.tap(find.byKey(const Key('topos-account-button')));
        await _drain(tester);

        expect(find.byKey(const Key('account-email-field')), findsOneWidget);
        await tester.tap(find.byKey(const Key('account-email-field')));
        await tester.pump();
        expect(
          tester.testTextInput.hasAnyClients,
          isTrue,
          reason: 'tapping the field must focus it and show the keyboard',
        );

        // Tap a point well above the field (still inside the signed-out
        // card, on the non-interactive title text / blank padding) so the
        // tap resolves to the outer GestureDetector rather than the field
        // itself re-focusing.
        final fieldTopLeft = tester.getTopLeft(
          find.byKey(const Key('account-email-field')),
        );
        await tester.tapAt(Offset(fieldTopLeft.dx, fieldTopLeft.dy - 40));
        await tester.pump();

        expect(
          tester.testTextInput.hasAnyClients,
          isFalse,
          reason: 'tapping empty space must dismiss the keyboard',
        );
      },
    );
  });

  group('ClimbTopoApp claim-on-sign-in bootstrap (C3)', () {
    testWidgets(
      'a real signed-out -> signed-in auth-state transition claims a '
      'previously-unowned local row for the new uid, exactly once',
      (tester) async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        await db
            .into(db.areas)
            .insert(
              AreasCompanion.insert(
                id: 'area-unowned',
                createdAt: 1000,
                updatedAt: 1000,
                name: 'Unowned Area',
              ),
            );

        // A single-subscription controller: `authStateProvider` subscribes
        // once and stays subscribed, so this supports any number of `add()`
        // calls before or after that single `listen()` — same reasoning as
        // `FakeAuthRepository` in `account_screen_test.dart`.
        final authController = StreamController<AuthSessionState>();
        addTearDown(authController.close);
        authController.add(const AuthSessionState.signedOut());

        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWithValue(db),
            nowMsProvider.overrideWithValue(() => 2000),
            authStateProvider.overrideWith((ref) => authController.stream),
            // See `_makeContainer`'s identical override above: the
            // claimOwnership row UPDATE below is a real table write, which
            // (now that `ClimbTopoApp` permanently watches
            // `syncOrchestratorProvider`) schedules a real debounced-push
            // `Timer` — keep it short so `_drain` lets it fire before this
            // test ends, instead of tripping the "Timer still pending"
            // widget-test invariant with the real 2s production default.
            syncDebounceDurationProvider.overrideWithValue(
              const Duration(milliseconds: 5),
            ),
          ],
        );
        addTearDown(container.dispose);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const ClimbTopoApp(),
          ),
        );
        await _drain(tester);

        // Still signed-out: the row must remain unclaimed.
        var row = await (db.select(
          db.areas,
        )..where((t) => t.id.equals('area-unowned'))).getSingle();
        expect(row.ownerId, isNull);

        // Fire the signed-out -> signed-in edge.
        authController.add(
          const AuthSessionState.signedIn('a@b.com', uid: 'u1'),
        );
        await _drain(tester);

        row = await (db.select(
          db.areas,
        )..where((t) => t.id.equals('area-unowned'))).getSingle();
        expect(row.ownerId, 'u1');
        expect(row.dirty, isTrue);
        expect(row.updatedAt, 2000);

        // A second emission of the SAME signed-in session (e.g. a token
        // refresh) must not re-claim / re-touch the now-owned row again —
        // flip `nowMs` forward and confirm `updatedAt` does NOT move again.
        authController.add(
          const AuthSessionState.signedIn('a@b.com', uid: 'u1'),
        );
        await _drain(tester);

        row = await (db.select(
          db.areas,
        )..where((t) => t.id.equals('area-unowned'))).getSingle();
        expect(
          row.updatedAt,
          2000,
          reason: 'the claim must fire only once, on the actual '
              'signed-out -> signed-in edge, not on every re-emission',
        );
      },
    );
  });
}
