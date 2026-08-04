import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Source-level tripwire for UF-6's boot half.
///
/// `bootApp` cannot be CALLED from a plain `flutter test` — it performs real
/// side effects (`WidgetsFlutterBinding.ensureInitialized()`, `path_provider`,
/// `runApp`), which is exactly why `main_boot_app_seam_test.dart` only checks
/// the seam's shape. So the behaviour is asserted where it is observable
/// (`test/core/config/supabase_init_provider_test.dart` and
/// `test/features/backup/application/sync_orchestrator_cloud_init_test.dart`),
/// and the WIRING that connects boot to it is asserted here, the same way
/// `connection_seam_source_test.dart` guards the `dart:io` seam by reading
/// `lib/` source.
///
/// What it protects: `main.dart` used to call `Supabase.initialize` inside a
/// bare `try`/`catch` whose whole response to a failure was one `debugPrint`.
/// Continuing was right — this app is local-first — but forgetting was not:
/// every cloud provider then degraded to a signed-out no-op that reported
/// SUCCESS, so the app told the user it was synced while their library existed
/// on one device. Reintroducing that inline call, or dropping the
/// `cloudInitProvider` hand-off, would silently restore the bug.
void main() {
  final mainSource = File('lib/main.dart').readAsStringSync();

  /// [mainSource] with `//`-comment lines dropped. Needed because `main.dart`
  /// documents `Supabase.initialize` at length (why it must be awaited before
  /// the first frame, and so on) and that prose must stay — only real CODE
  /// calling it is the regression.
  final mainCode = mainSource
      .split('\n')
      .where((line) => !line.trimLeft().startsWith('//'))
      .join('\n');

  test('boot routes Supabase init through cloudInitProvider', () {
    expect(
      mainSource,
      contains('cloudInitProvider.notifier'),
      reason: 'boot must record the init outcome somewhere the sync layer can '
          'read it, or a failure is invisible again',
    );
    expect(
      mainSource,
      contains("import 'core/config/supabase_init_provider.dart'"),
    );
  });

  test('main.dart no longer calls Supabase.initialize itself', () {
    expect(
      mainCode,
      isNot(contains('Supabase.initialize(')),
      reason: 'there must be exactly ONE init call site '
          '(CloudInitController.initialize) so boot and every retry share the '
          'same arguments and the same error handling — two call sites is how '
          'they drift',
    );
  });

  test('the init future is still awaited before the first frame', () {
    // Non-negotiable regardless of the above: `MasiApp.build` synchronously
    // reads `Supabase.instance.client` via `authStateProvider`, which throws a
    // LateInitializationError if init has not COMPLETED. A fire-and-forget
    // init would crash the first frame on every platform.
    expect(mainSource, contains('_initSupabase(container)'));
    expect(mainSource, contains('await awaitBootWork('));
  });
}
