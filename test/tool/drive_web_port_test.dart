// Tests `tool/drive_web.sh`'s chromedriver port hygiene by RUNNING it.
//
// This file deliberately departs from the style of its neighbours.
// `build_web_flags_test.dart` scans the shell script as a string, and says
// why: "A shell script cannot be unit-tested directly". That is the right
// trade for pinning a build flag, but it would be the wrong one here — the
// thing under test is behaviour under a condition (a port that is already
// bound), and a `contains('lsof')` assertion would pass just as happily
// against a version of the script that finds the stale process and then does
// nothing useful with it. The hazard being guarded against is precisely a
// harness that looks correct and hangs, so the guard has to be executed.
//
// So: `DRIVE_WEB_PREFLIGHT_ONLY=1` runs the script's port hygiene and
// chromedriver readiness check and then exits, without building or driving
// anything. Each case below puts a real listener on a real port and checks
// what the script actually does about it.
//
// THE HAZARD, for context: under load, chromedriver sometimes fails to launch
// Chrome and is left running with its port still bound. The old script then
// started a second chromedriver, which died instantly with "Address already
// in use" into a temp log nobody printed, while `flutter drive` connected to
// the wedged FIRST one and hung until the outer timeout. Every run after the
// first failure looked like an unexplained hang.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

String get _repoRoot => Directory.current.path;

String get _script => p.join(_repoRoot, 'tool', 'drive_web.sh');

/// Runs the script in preflight-only mode against [port].
Future<ProcessResult> _preflight(int port) => Process.run(
  _script,
  ['unused-target', '$port'],
  workingDirectory: _repoRoot,
  environment: {'DRIVE_WEB_PREFLIGHT_ONLY': '1'},
);

/// A port with nothing on it. Bound and released, so it is free *now*; good
/// enough for a local test and the only way to avoid colliding with whatever
/// else this machine is running.
Future<int> _freePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

bool get _hasChromedriver {
  final result = Process.runSync('which', [
    'chromedriver',
  ], environment: {'PATH': '/opt/homebrew/bin:${Platform.environment['PATH']}'});
  return result.exitCode == 0;
}

void main() {
  group('tool/drive_web.sh port hygiene', () {
    test('the script exists and is executable', () {
      final file = File(_script);
      expect(file.existsSync(), isTrue, reason: 'expected $_script to exist');
      final mode = file.statSync().mode;
      expect(
        mode & 0x40, // owner execute bit
        isNonZero,
        reason: '$_script must be executable',
      );
    });

    test(
      'a FREE port passes preflight',
      () async {
        final port = await _freePort();
        final result = await _preflight(port);
        expect(
          result.exitCode,
          0,
          reason: 'preflight failed on a free port.\n'
              'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
        );
        expect(result.stdout.toString(), contains('PREFLIGHT OK'));
      },
      timeout: const Timeout(Duration(minutes: 2)),
      skip: _hasChromedriver ? false : 'chromedriver not on PATH',
    );

    test(
      'a STALE chromedriver holding the port is reclaimed, not tripped over',
      () async {
        final port = await _freePort();
        final stale = await Process.start('chromedriver', [
          '--port=$port',
        ], environment: {
          'PATH': '/opt/homebrew/bin:${Platform.environment['PATH']}',
        });
        addTearDown(() => stale.kill(ProcessSignal.sigkill));

        // Wait until it really owns the port, otherwise this tests nothing.
        var bound = false;
        for (var i = 0; i < 50; i++) {
          try {
            final probe = await Socket.connect(
              InternetAddress.loopbackIPv4,
              port,
              timeout: const Duration(milliseconds: 200),
            );
            await probe.close();
            bound = true;
            break;
          } catch (_) {
            await Future<void>.delayed(const Duration(milliseconds: 200));
          }
        }
        expect(
          bound,
          isTrue,
          reason: 'the stale chromedriver never bound port $port, so the '
              'reclaim path was never exercised',
        );

        final result = await _preflight(port);
        final stdout = result.stdout.toString();
        expect(
          result.exitCode,
          0,
          reason: 'THE HAZARD: preflight did not recover from a stale '
              'chromedriver.\nstdout:\n$stdout\nstderr:\n${result.stderr}',
        );
        expect(
          stdout,
          contains('stale chromedriver detected'),
          reason: 'the script must SAY it reclaimed the port — a silent '
              'recovery is how the original bug stayed invisible',
        );
        expect(stdout, contains('PREFLIGHT OK'));

        // The wedged process is actually gone, not merely stepped around.
        expect(
          await stale.exitCode.timeout(
            const Duration(seconds: 10),
            onTimeout: () => -999,
          ),
          isNot(-999),
          reason: 'the stale chromedriver is still running; the new one is '
              'talking to something else, or the port was never reclaimed',
        );
      },
      timeout: const Timeout(Duration(minutes: 3)),
      skip: _hasChromedriver ? false : 'chromedriver not on PATH',
    );

    test(
      'a FOREIGN listener is refused, fast and with instructions — and is '
      'left alive',
      () async {
        // A plain TCP server owned by this test process. `ps -o comm=` reports
        // it as `dart`, not `chromedriver`, which is exactly the case the
        // script must not resolve by killing — doing so here would take down
        // the test runner itself.
        final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(server.close);

        final result = await _preflight(server.port);
        final stderr = result.stderr.toString();

        expect(
          result.exitCode,
          2,
          reason: 'a port held by a stranger must fail fast, not be killed '
              'and not be waited on.\nstdout:\n${result.stdout}\n'
              'stderr:\n$stderr',
        );
        expect(
          stderr,
          contains('NOT chromedriver'),
          reason: 'the error must name the actual problem',
        );
        expect(
          stderr,
          contains('tool/drive_web.sh'),
          reason: 'the error must tell the reader how to proceed (another '
              'port), since this is the message someone sees at the point '
              'where the old script just hung',
        );

        // Still ours, still listening.
        final probe = await Socket.connect(
          InternetAddress.loopbackIPv4,
          server.port,
          timeout: const Duration(seconds: 5),
        );
        await probe.close();
      },
      timeout: const Timeout(Duration(minutes: 2)),
      skip: _hasChromedriver ? false : 'chromedriver not on PATH',
    );
  });
}
