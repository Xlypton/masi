// Compile-time shape check for `bootApp`'s injectable-overrides seam
// (extracted from `main()` in `lib/main.dart` for #55's web boot-stability
// work).
//
// Deliberately does NOT call `bootApp()` here: it performs real side effects
// (`WidgetsFlutterBinding.ensureInitialized()`, a real `Supabase.initialize`
// network call, and `photoFilesProvider`'s `warmDocsPath()`, which touches
// `path_provider`) that don't belong in a plain `flutter test` unit test —
// none of those are mocked/overridable here the way a widget test's own
// `ProviderContainer` overrides would be, since `bootApp` builds its own
// container internally.
//
// What this DOES assert is the seam's shape: `bootApp` is
// `Future<void> Function({List<Override> overrides})` — i.e. it genuinely
// accepts a list of Riverpod `Override`s (the entire point of the
// refactor), not just an empty parameter list that happens to still
// compile. If a future edit narrowed/renamed/repositioned that parameter,
// this assignment would fail to compile.
//
// The actual runtime behavior of the seam (overriding `authRepositoryProvider`
// / `webAuthGateEnabledProvider` and reaching different app states) is
// exercised for real by `integration_test/web_smoke_test.dart` and
// `integration_test/web_boot_stability_test.dart` (run via
// `tool/drive_web.sh` in headless Chrome, NOT by `flutter test`), plus the
// existing non-web-specific auth-wall redirect coverage in
// `test/app/router_test.dart`.
import 'package:masi/main.dart' show bootApp;
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('bootApp exposes an injectable {List<Override> overrides} seam', () {
    final Future<void> Function({List<Override> overrides}) seam = bootApp;
    expect(seam, isNotNull);
  });
}
