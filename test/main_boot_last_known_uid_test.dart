// Boot-wiring coverage for §1c's `lastKnownUid` COLD-BOOT restore, which
// could only land here: §1c-A built `LastKnownUid.hydrate()` and routed every
// uid door through `effectiveUidProvider`, but the one call that restores the
// persisted uid across an app restart lives in `lib/main.dart`'s `bootApp`,
// which belongs to §1b task 4.
//
// Without it, `lastKnownUid` is written on every session-bearing auth
// emission but never read back, so the offline-restart half of audit item L4
// stays open: after a captive-portal hard sign-out plus a restart, the live
// uid is null, every `_ownOrUnowned` guard collapses to `ownerId IS NULL`, and
// the user's whole library is invisible and unwritable while reporting
// success.
//
// Like `test/main_boot_app_seam_test.dart` and
// `test/main_boot_storage_persistence_test.dart`, this deliberately does NOT
// call `bootApp()` — it performs real side effects (a real
// `Supabase.initialize`, `path_provider`) and builds its own container with no
// way to observe it. The two halves below cover the wiring instead:
//  1. behaviour — the exact expression `bootApp` awaits, driven against a
//     fresh container over a database a previous run already wrote to;
//  2. placement — that the expression really is inside `bootApp`'s
//     pre-first-frame `Future.wait`, i.e. that no provider can observe a
//     spuriously-null uid on the first frame. Reading the source for a
//     structural guard mirrors `test/ios_info_plist_test.dart`.
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// Riverpod v3 does NOT export `Override` from its barrel — same reason
// `test/main_boot_app_seam_test.dart` imports `misc.dart`.
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/features/account/application/auth_providers.dart';
import 'package:path/path.dart' as p;

void main() {
  test(
    'a uid persisted by a previous run is restored at boot, with no network '
    'and no auth session at all — L4 offline restart',
    () async {
      // ONE database across both runs: the local store is what survives a
      // cold restart. `overrideWithValue` replaces the provider body, so
      // disposing a container does not close it.
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);

      List<Override> overrides() => [
        appDatabaseProvider.overrideWithValue(db),
        nowMsProvider.overrideWithValue(() => 1000),
      ];

      // --- previous run: a real session recorded its uid locally ---
      final previousRun = ProviderContainer(overrides: overrides());
      await previousRun
          .read(lastKnownUidProvider.notifier)
          .remember('user-u1');
      // Cold restart: every provider (and the in-memory uid) is gone.
      previousRun.dispose();

      // --- this run's boot. Deliberately NO `authRepositoryProvider`
      // override, so `supabaseClientProvider` throws on its `late`
      // `Supabase.instance` exactly as it does when auth is unavailable —
      // the "captive portal / no network" shape. ---
      final booted = ProviderContainer(overrides: overrides());
      addTearDown(booted.dispose);

      expect(
        booted.read(lastKnownUidProvider),
        isNull,
        reason: 'a fresh container knows nothing until boot hydrates it',
      );

      // Exactly the entry `bootApp` adds to the `Future.wait` it awaits
      // before `runApp`.
      await Future.wait([
        booted.read(lastKnownUidProvider.notifier).hydrate(),
      ]);

      expect(booted.read(lastKnownUidProvider), 'user-u1');
      expect(
        booted.read(effectiveUidProvider),
        'user-u1',
        reason: 'THE L4 assertion: local data ownership must survive a cold '
            'restart with no reachable auth backend, or the library silently '
            'empties and every subsequent edit is written to a different '
            'owner',
      );
      expect(booted.read(hasKnownLocalSessionProvider), isTrue);
    },
  );

  test(
    'bootApp hydrates lastKnownUid inside the Future.wait it awaits BEFORE '
    'runApp, so the first frame never sees a null uid',
    () {
      final lines = File(
        p.join(Directory.current.path, 'lib', 'main.dart'),
      ).readAsLinesSync();

      int lineOf(String needle) =>
          lines.indexWhere((line) => line.contains(needle));

      // The pre-frame work is no longer awaited DIRECTLY: it is handed to
      // `awaitBootWork`, which is what is awaited. That indirection is the
      // ship-blocker fix — awaiting it bare hangs boot forever when drift's
      // unbounded web open never answers (see
      // `test/main_boot_timeout_test.dart`). The ordering this test exists to
      // pin is unchanged and is checked as a full chain: hydrate sits inside a
      // `BootTask` in the list passed to the awaited boot gate, which precedes
      // runApp.
      //
      // The list used to be a bare `Future.wait([...])`, which the gate could
      // only observe as one yes/no — so a stalled Supabase init was reported as
      // dead local storage. Each future is now a NAMED `BootTask` carrying
      // whether a stall in it is evidence about storage, hence the needle.
      final gateLine = lineOf('await awaitBootWork(');
      final waitLine = lineOf('BootTask(');
      // Anchored on the CALL, not the bare token: `bootApp`'s own doc comment
      // legitimately names `LastKnownUid.hydrate()` to explain why the entry
      // is awaited, and a looser needle matches that comment instead. Same
      // class of false positive the repo's `dart:io` gate hit (fixed in
      // `14332a1` by anchoring on import/export directives).
      final hydrateLine = lineOf('.notifier).hydrate()');
      final runAppLine = lineOf('runApp(');

      expect(
        gateLine,
        isNonNegative,
        reason: 'boot no longer goes through the bounded awaitBootWork gate',
      );
      expect(waitLine, isNonNegative, reason: 'no BootTask list found');
      expect(
        hydrateLine,
        isNonNegative,
        reason: 'lib/main.dart does not hydrate lastKnownUid at all',
      );
      expect(runAppLine, isNonNegative, reason: 'no runApp call found');

      expect(
        gateLine < waitLine &&
            waitLine < hydrateLine &&
            hydrateLine < runAppLine,
        isTrue,
        reason: 'the hydrate call must sit inside the BootTask list (first '
            'entry at line $waitLine) passed to the awaited awaitBootWork '
            '(line $gateLine), '
            'and therefore before runApp (line $runAppLine); found hydrate at '
            'line $hydrateLine',
      );
    },
  );
}
