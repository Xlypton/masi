// Browser-executed coverage for the offline-shell diagnostic seam.
//
// This is the ONLY place `lib/core/diagnostics/shell_info_web.dart` ever runs:
// the facade selects it only when `dart.library.js_interop` is available, so
// `flutter test` (Dart VM) always gets the inert stub and can never catch a
// wrong interop type — a `getRegistration()` promise typed wrong, or a
// `caches.keys()` read that throws. Same reasoning, and same shape, as
// `web_storage_persistence_test.dart` next door. Run it with:
//
//   tool/drive_web.sh integration_test/web_shell_info_test.dart
//
// Deliberately dependency-light: it does not boot the whole app (no router, no
// Supabase, no drift), it drives the seam directly.
//
// `flutter drive -d web-server` does NOT relay the browser's `debugPrint` to
// the terminal, so what the browser actually reported is pushed out through
// `binding.reportData` — the driver persists it to
// `build/integration_response_data.json`, which is the record of what a real
// browser said.
//
// WHAT THIS CANNOT PIN: whether a worker is registered, controlling, or which
// version it is. The drive harness's origin is not production's, the worker
// registers on `load` and may not have activated by the time a test runs, and
// headless Chrome may refuse registration outright. Asserting any of those
// would be asserting the harness, not the seam. What IS pinned is the thing
// that can actually be wrong: that the browser path RAN (rather than the stub),
// that it produced a coherent answer, and that it never throws.
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:masi/core/diagnostics/build_info.dart';
import 'package:masi/core/diagnostics/shell_info.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final observed = <String, Object?>{};
  void record(Map<String, Object?> entries) {
    observed.addAll(entries);
    binding.reportData = Map<String, Object?>.from(observed);
  }

  group('web service-worker diagnostic seam', () {
    testWidgets('readShellInfo runs the BROWSER backend, not the stub', (
      tester,
    ) async {
      final info = await readShellInfo();

      record({
        'shell_supported': info.supported,
        'shell_registered': info.registered,
        'shell_controlling': info.controlling,
        'shell_update_pending': info.updatePending,
        'shell_version': info.version,
        'shell_extra_versions': info.extraVersions,
        'shell_summary': info.summary,
        'shell_clipboard_tokens': info.clipboardTokens,
      });

      // The single assertion that proves the conditional import resolved to
      // `shell_info_web.dart`: the stub hard-codes `supported: false`, and
      // every browser this harness can run in has `navigator.serviceWorker`.
      // A `false` here means the seam silently fell back to the stub in the
      // web build — which would make this row lie "not applicable" on every
      // real web report.
      expect(
        info.supported,
        isTrue,
        reason:
            'navigator.serviceWorker exists in every browser this runs in; '
            'false means the inert stub was compiled into the web bundle',
      );
    });

    testWidgets('the answer is internally coherent, never half-filled', (
      tester,
    ) async {
      final info = await readShellInfo();

      // A version can only come from a shell cache, which only a registered
      // worker creates. Reporting one without a registration would mean the
      // cache scan and the registration read disagree — the exact kind of
      // half-answer that sends a support reader chasing a ghost.
      if (!info.registered) {
        expect(info.controlling, isFalse);
        expect(info.updatePending, isFalse);
      }
      // Whatever the state, the rendered summary is never empty and never
      // leaks a Dart object's toString into a support row.
      expect(info.summary, isNotEmpty);
      expect(info.summary, isNot(contains('Instance of')));
      expect(info.clipboardTokens, isNot(contains('\n')));
    });

    testWidgets('repeated probes are stable and never throw', (tester) async {
      // The Account screen's Refresh button re-runs this on demand, so a
      // second call must be as safe as the first — no cached promise to
      // re-await, no listener to double-register.
      final first = await readShellInfo();
      final second = await readShellInfo();

      record({
        'shell_second_summary': second.summary,
        'shell_stable': first.summary == second.summary,
      });

      expect(second.supported, first.supported);
      expect(second.registered, first.registered);
    });

    testWidgets('BuildInfo resolves the web runtime, not a native platform', (
      tester,
    ) async {
      record({
        'build_runtime_token': BuildInfo.runtimeToken,
        'build_runtime_label': BuildInfo.runtimeLabel,
        'build_mode': BuildInfo.modeLabel,
        'build_app_version': BuildInfo.appVersion,
        'build_channel': BuildInfo.channel,
        'build_commit': BuildInfo.gitSha,
        'build_time_raw': BuildInfo.buildTimeRaw,
        'build_is_stamped': BuildInfo.isStamped,
      });

      // `kIsWeb`/`kIsWasm` are compile-time constants that only resolve
      // correctly in a real web compile — the VM test suite can only ever see
      // the native branch, so this is the one place the web labels are real.
      expect(BuildInfo.runtimeToken, anyOf('web-wasm', 'web-js'));
      expect(BuildInfo.runtimeToken, isNot(contains(' ')));
      expect(BuildInfo.runtimeLabel, startsWith('web'));
      expect(BuildInfo.modeLabel, isIn(['debug', 'profile', 'release']));
    });
  });
}
