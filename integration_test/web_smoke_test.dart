// Real-app web smoke test: Area -> Sector -> Wall creation, driven headless
// in Chrome via `tool/drive_web.sh`.
//
// Runs via `bootApp(overrides: [...])`, disabling the web-only auth wall
// (`webAuthGateEnabledProvider.overrideWithValue(false)`) rather than
// plain `app.main()` — the wall (`webAuthGateEnabledProvider` defaults to
// `kIsWeb`, see `auth_providers.dart`) would otherwise redirect straight to
// the sign-in view (`/account`) before any of the Topos/Areas/Sectors/Walls
// flow below is reachable. Disabling the gate here reaches Topos home
// exactly as this flow did before the wall existed; the gate itself
// (on/off, signed-in/out) is exercised by `web_boot_stability_test.dart`.
// Run with:
//
//   tool/drive_web.sh integration_test/web_smoke_test.dart
//
// Modeled on `integration_test/smoke_test.dart` (boots the real app, taps
// `topos-organize` into Areas) and extended through Sector/Wall creation
// using the generic `CrudListScaffold` keys (see
// `lib/features/library/presentation/crud_list_scaffold.dart`):
//   `<entityKey>-add-fab` (entityKey is 'area' / 'sector' / 'wall'),
//   `crud-name-field` / `crud-name-submit` (shared add/rename dialog).
// Row navigation uses `find.text(name)` rather than the `<entityKey>-item-
// <id>` key, since the id isn't known ahead of creation.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:climbtopo/features/account/application/auth_providers.dart';
import 'package:climbtopo/main.dart' show bootApp;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('boots to Topos home, then creates Area -> Sector -> Wall', (
    tester,
  ) async {
    bootApp(
      overrides: [webAuthGateEnabledProvider.overrideWithValue(false)],
    );
    await tester.pumpAndSettle(const Duration(seconds: 2));
    await binding.takeScreenshot('01-topos-home');

    final organizeFinder = find.byKey(const Key('topos-organize'));
    if (tester.any(organizeFinder)) {
      await tester.tap(organizeFinder);
    }
    await tester.pumpAndSettle(const Duration(seconds: 2));
    await binding.takeScreenshot('02-areas');

    // --- Create an Area ---
    final areaFabFinder = find.byKey(const Key('area-add-fab'));
    if (tester.any(areaFabFinder)) {
      await tester.tap(areaFabFinder);
    } else {
      final anyFab = find.byType(FloatingActionButton);
      if (tester.any(anyFab)) {
        await tester.tap(anyFab.first);
      }
    }
    await tester.pumpAndSettle(const Duration(seconds: 1));
    await binding.takeScreenshot('03-area-dialog');

    const areaName = 'Web E2E Area';
    final areaNameField = find.byKey(const Key('crud-name-field'));
    if (tester.any(areaNameField)) {
      await tester.enterText(areaNameField, areaName);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('crud-name-submit')));
    }
    await tester.pumpAndSettle(const Duration(seconds: 2));
    await binding.takeScreenshot('04-area-created');

    // --- Drill into the new Area -> Sectors screen ---
    final areaRow = find.text(areaName);
    if (tester.any(areaRow)) {
      await tester.tap(areaRow.first);
    }
    await tester.pumpAndSettle(const Duration(seconds: 2));
    await binding.takeScreenshot('05-sectors-empty');

    // --- Create a Sector ---
    final sectorFabFinder = find.byKey(const Key('sector-add-fab'));
    if (tester.any(sectorFabFinder)) {
      await tester.tap(sectorFabFinder);
    }
    await tester.pumpAndSettle(const Duration(seconds: 1));

    const sectorName = 'Web E2E Sector';
    final sectorNameField = find.byKey(const Key('crud-name-field'));
    if (tester.any(sectorNameField)) {
      await tester.enterText(sectorNameField, sectorName);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('crud-name-submit')));
    }
    await tester.pumpAndSettle(const Duration(seconds: 2));
    await binding.takeScreenshot('06-sector-created');

    // --- Drill into the new Sector -> Walls screen ---
    final sectorRow = find.text(sectorName);
    if (tester.any(sectorRow)) {
      await tester.tap(sectorRow.first);
    }
    await tester.pumpAndSettle(const Duration(seconds: 2));
    await binding.takeScreenshot('07-walls-empty');

    // --- Create a Wall ---
    final wallFabFinder = find.byKey(const Key('wall-add-fab'));
    if (tester.any(wallFabFinder)) {
      await tester.tap(wallFabFinder);
    }
    await tester.pumpAndSettle(const Duration(seconds: 1));

    const wallName = 'Web E2E Wall';
    final wallNameField = find.byKey(const Key('crud-name-field'));
    if (tester.any(wallNameField)) {
      await tester.enterText(wallNameField, wallName);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('crud-name-submit')));
    }
    await tester.pumpAndSettle(const Duration(seconds: 2));
    await binding.takeScreenshot('08-wall-created');
  });
}
