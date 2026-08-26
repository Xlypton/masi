import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'shell_info.dart';
import 'shell_info_types.dart';

/// The shape of the `shell_info.dart` seam, named so it can be overridden.
typedef ShellInfoReader = Future<ShellInfo> Function();

/// The seam the Account screen's build-diagnostics row reads through.
///
/// Defaults to the real platform delegate (web: `navigator.serviceWorker` +
/// `caches`; native/tests: the inert stub that answers
/// [ShellInfo.notApplicable]). Overridable in widget tests so a shell state
/// that only a browser can produce — an update waiting, two surviving shell
/// caches — can still be asserted on, exactly like
/// `storagePersistenceServiceProvider` next door.
final shellInfoReaderProvider = Provider<ShellInfoReader>(
  (ref) => readShellInfo,
);

/// The offline shell's current state, re-read on demand.
///
/// A [FutureProvider] rather than a [Notifier] because there is no state to
/// own: every value here is a fresh read of the browser's own bookkeeping, and
/// the Account screen's existing "Refresh" button re-runs it with a plain
/// `ref.invalidate`. Deliberately NOT polled — nothing here changes without a
/// deploy or a reload, and a diagnostic that runs on a timer is a diagnostic
/// that costs battery on every screen it is not being read from.
final shellInfoProvider = FutureProvider<ShellInfo>(
  (ref) => ref.read(shellInfoReaderProvider)(),
);
