import 'package:flutter_test/flutter_test.dart';
import 'package:masi/core/diagnostics/shell_info.dart';
import 'package:masi/core/diagnostics/shell_info_types.dart';

/// [ShellInfo]'s rendering contract, plus the seam's native/test behaviour.
///
/// The BROWSER half (`shell_info_web.dart`) cannot run here — it imports
/// `dart:js_interop` — so what is pinned here is everything downstream of it:
/// that each state renders a distinct, actionable sentence, and that the
/// platform with no service worker concept says "not applicable" rather than
/// reporting a missing or broken shell.
void main() {
  group('readShellInfo on a platform with no service worker', () {
    test('answers notApplicable rather than "no shell" or an error', () async {
      final info = await readShellInfo();
      expect(info.supported, isFalse);
      expect(info.registered, isFalse);
      expect(info.controlling, isFalse);
      expect(info.updatePending, isFalse);
      expect(info.version, isNull);
      expect(info.summary, 'not applicable');
    });
  });

  group('ShellInfo.summary', () {
    test(
      'an unsupported platform never reads as a FAILED shell — there is a '
      'real difference between "no such concept" and "it should be here and '
      'is not"',
      () {
        expect(ShellInfo.notApplicable.summary, 'not applicable');
        expect(
          const ShellInfo(supported: true).summary,
          'not registered (no offline shell)',
        );
      },
    );

    test('a healthy shell is just its version, with no noise around it', () {
      const info = ShellInfo(
        supported: true,
        registered: true,
        controlling: true,
        version: 'a1b2c3d4',
      );
      expect(info.summary, 'a1b2c3d4');
    });

    test(
      'a waiting update is called out as one reload away — the difference '
      'between "the fix is not there" and "the fix is not applied yet"',
      () {
        const info = ShellInfo(
          supported: true,
          registered: true,
          controlling: true,
          updatePending: true,
          version: 'a1b2c3d4',
        );
        expect(info.summary, contains('update ready'));
        expect(info.summary, contains('reload'));
      },
    );

    test('an uncontrolled page says so — its assets came off the network', () {
      const info = ShellInfo(
        supported: true,
        registered: true,
        version: 'a1b2c3d4',
      );
      expect(info.summary, contains('not controlling this page'));
    });

    test(
      'surviving shell caches are named. sw.js sweeps every cache but the '
      'current one on activate, so a leftover means an activation did not '
      'complete — which IS the state that serves a stale build',
      () {
        const info = ShellInfo(
          supported: true,
          registered: true,
          controlling: true,
          extraVersions: ['0000dead', '1111beef'],
        );
        expect(info.summary, contains('stale caches: 0000dead, 1111beef'));
        // No unambiguous version to report, so it says that instead of
        // guessing one of the leftovers.
        expect(info.summary, contains('active, version unknown'));
      },
    );
  });

  group('ShellInfo.clipboardTokens', () {
    test('every token is single-valued and space-separated', () {
      const info = ShellInfo(
        supported: true,
        registered: true,
        controlling: true,
        updatePending: true,
        version: 'a1b2c3d4',
        extraVersions: ['0000dead'],
      );
      expect(info.clipboardTokens, contains('shellVersion=a1b2c3d4'));
      expect(info.clipboardTokens, contains('shellRegistered=true'));
      expect(info.clipboardTokens, contains('shellControlling=true'));
      expect(info.clipboardTokens, contains('shellUpdatePending=true'));
      expect(info.clipboardTokens, contains('shellStaleCaches=0000dead'));
      expect(info.clipboardTokens, isNot(contains('\n')));
    });

    test('an unknown version is the word, never an empty token', () {
      expect(
        ShellInfo.notApplicable.clipboardTokens,
        contains('shellVersion=unknown'),
      );
    });

    test(
      'several stale caches are comma-joined, never space-joined — a space '
      'would break the key=value shape of the one-line blob',
      () {
        const info = ShellInfo(extraVersions: ['a', 'b', 'c']);
        expect(info.clipboardTokens, contains('shellStaleCaches=a,b,c'));
      },
    );
  });
}
