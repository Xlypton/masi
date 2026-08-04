// The post-commit durability flush: `AppDatabase.transaction`'s override.
//
// -------------------------------------------------------------------------
// WHAT IS BEING PROTECTED
// -------------------------------------------------------------------------
// On the web, drift's `sharedIndexedDb` backend does NOT persist a committed
// transaction. Measured, not inferred: `tool/drive_web_write_order.sh` wrote
// `wall -> photo -> 10 routes -> one more topo` into a real headless Chrome
// with the network severed, killed the browser and reopened the same profile
// in a new process. Every route came back; the topo written AFTER them did
// not. The routes go through `RouteRepository.upsertRoute` (a bare
// auto-commit INSERT, which drift flushes); the topo goes through
// `LibraryCrudRepository.createTopo` (a `transaction`, which it does not).
// The full drift/sqlite3 line-by-line trace lives on `commitNeedsExplicitFlush`
// in `lib/core/db/connection/connection_web.dart`.
//
// -------------------------------------------------------------------------
// WHY THIS TEST RUNS ON NATIVE AT ALL
// -------------------------------------------------------------------------
// `flutter test` always resolves the `dart:io` half of the connection seam,
// where `commitNeedsExplicitFlush` is `false` — so the production default
// here is "do nothing", and a test that only used the default would assert
// nothing. `AppDatabase`'s `@visibleForTesting flushAfterCommit` flips the
// flag so the REAL override — the same depth counter, the same ordering, the
// same rollback path — runs against an in-memory `NativeDatabase`.
//
// What this test cannot cover is that a flush actually reaches IndexedDB;
// only a browser can show that, and
// `integration_test/web_write_order_{seed,verify}_test.dart` is where it is
// shown. What IS covered here is every way the override could be wrong
// without a browser noticing: firing on nested transactions, not firing at
// all, firing before the COMMIT, or firing after a rollback.
//
// -------------------------------------------------------------------------
// WHICH BACKEND THIS GUARDS (and which it does not)
// -------------------------------------------------------------------------
// The loss above is an IndexedDB-VFS property, not a "web" property. Measured
// 2026-08-04 with `tool/drive_web_write_order.sh`, three runs, each reporting
// the backend it opened: `sharedIndexedDb` + fix disabled lost the trailing
// transaction (`ONLY_TRAILING_TRANSACTION_LOST`), while a cross-origin-isolated
// origin (`COI=1`, backend `opfsLocks` — what production runs) lost NOTHING
// either with the fix or without it. OPFS's `xSync` really syncs; IndexedDB's
// is a documented noop. The full table and the drift/sqlite3 line references
// are on `commitNeedsExplicitFlush`.
//
// So this override is insurance for the IndexedDB backends — which are still
// live in production (pre-COOP/COEP installs are pinned to IndexedDB, and a
// Safari without `SharedWorker` can only be offered `opfsLocks` or
// `unsafeIndexedDb`) — and an inert extra statement on OPFS. That is why the
// flag it reads is platform-wide rather than per-backend, and why these
// assertions are about the override's MECHANICS: on the backend that needs it,
// getting the depth counting or the ordering wrong is silent data loss.
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/connection/connection.dart'
    show commitNeedsExplicitFlush;

/// Records the events this test reasons about, in the order they happen.
///
/// Note what it does NOT see: drift issues a transaction's own `BEGIN` and
/// `COMMIT` through `_StatementBasedTransactionExecutor.runCustom`, whose
/// `impl` is the delegate itself (`engines.dart:258-259`) — the interceptor
/// is never in that path. Measured: intercepting only the statement methods
/// records `[SELECT 1]` and nothing else for a transaction that definitely
/// committed. So the commit boundary is captured from the
/// [commitTransaction]/[rollbackTransaction] hooks, which drift DOES route
/// through the interceptor (`interceptor.dart:200-216`), and the flush is
/// captured from `runCustom`. That pair is exactly what the ordering
/// assertions need.
class _Recorder extends QueryInterceptor {
  static const String commitMark = '<commit>';
  static const String rollbackMark = '<rollback>';
  static const String beginMark = '<begin>';

  final List<String> events = <String>[];

  void _note(String event) => events.add(event.trim());

  int get flushes => events.where((e) => e == 'SELECT 1').length;
  int get commits => events.where((e) => e == commitMark).length;

  @override
  TransactionExecutor beginTransaction(QueryExecutor parent) {
    _note(beginMark);
    return parent.beginTransaction();
  }

  @override
  Future<void> commitTransaction(TransactionExecutor inner) async {
    await inner.send();
    // Noted AFTER the send resolves, so its index in [events] is the moment
    // the COMMIT finished — which is what the flush must come after.
    _note(commitMark);
  }

  @override
  Future<void> rollbackTransaction(TransactionExecutor inner) async {
    await inner.rollback();
    _note(rollbackMark);
  }

  @override
  Future<void> runCustom(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    _note(statement);
    return executor.runCustom(statement, args);
  }

  @override
  Future<int> runInsert(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    _note(statement);
    return executor.runInsert(statement, args);
  }

  @override
  Future<int> runUpdate(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    _note(statement);
    return executor.runUpdate(statement, args);
  }

  @override
  Future<int> runDelete(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    _note(statement);
    return executor.runDelete(statement, args);
  }

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    _note(statement);
    return executor.runSelect(statement, args);
  }
}

/// Wraps [_Recorder] so the post-commit flush statement itself can be made
/// to fail on demand, without disturbing the ordering/counting mechanics
/// [_Recorder] already covers for every other test in this file.
///
/// Exists for the "flush failure propagates" test below — a residual-risk
/// guard from a 2026-08-04 durability audit of the IndexedDB VFS
/// (`docs/superpowers/specs/2026-07-30-web-offline-reliability-design.md`'s
/// follow-up, task #35). That audit found two things inside
/// `sqlite3`'s/`drift`'s pub sources that this repo cannot patch:
///
///  * `_IndexedDbTransaction`'s constructor wires `onabort` to the exact same
///    handler as `oncomplete`
///    (`sqlite3-3.5.0/lib/src/wasm/vfs/indexed_db.dart:128-133`) — an
///    out-of-band transaction abort (unrelated to any request throwing) is
///    reported as a plain successful completion. This is UNFIXABLE from this
///    layer: every observation point we have (a SQL read, this very flush's
///    `SELECT 1`) is serviced by the same conflated signal and the same
///    in-memory mirror (`IndexedDbFileSystem._memory`) that made the false
///    promise in the first place, so there is no independent channel here to
///    check against. `navigator.storage.estimate()` was considered as an
///    out-of-band signal and rejected — browsers document its usage figures
///    as non-real-time, so it would trade a real bug for a guard that only
///    looks like one. Opening a second, independent connection to the same
///    IndexedDB-backed database to force a genuine re-read was also
///    considered and rejected: sqlite3's WASM VFS assumes single-writer
///    ownership per database name, so a concurrent second connection risks
///    corrupting the one connection this app actually depends on — a worse
///    outcome than the bug it would be checking for.
///  * `_IndexedDbFile.xWrite` submits a work item and discards the `Future`
///    `_submitWork` returns (`indexed_db.dart:711-737`) — true as written,
///    but that specific per-item `Completer` is unconditionally resolved
///    with `.complete()` inside `_startWorkingIfNeeded`'s `whenComplete`
///    callback regardless of whether the batch actually succeeded
///    (`indexed_db.dart:541-547`), so it can never carry a real failure even
///    if awaited. The channel that DOES carry a real failure is the
///    *outer* per-batch future from `_performWrites`/`_startWorkingIfNeeded`,
///    which is exactly what drift's own `_WasmDelegate._flush()`
///    (`drift-2.34.2/lib/wasm.dart:358-368`) and this repo's
///    `AppDatabase.transaction` override both already await and propagate.
///
/// So the one guard that belongs at this layer isn't a new detector — it's
/// making sure the existing propagation never regresses into a silent
/// swallow (e.g. a future "robustness" try/catch around the flush). This
/// interceptor simulates that outer-channel failure so the test below can
/// pin the correct behaviour.
class _ThrowOnFlushInterceptor extends QueryInterceptor {
  _ThrowOnFlushInterceptor(this._inner);

  final _Recorder _inner;

  @override
  TransactionExecutor beginTransaction(QueryExecutor parent) =>
      _inner.beginTransaction(parent);

  @override
  Future<void> commitTransaction(TransactionExecutor inner) =>
      _inner.commitTransaction(inner);

  @override
  Future<void> rollbackTransaction(TransactionExecutor inner) =>
      _inner.rollbackTransaction(inner);

  @override
  Future<void> runCustom(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    // Matches `_Recorder.flushes`' own literal below — see
    // `AppDatabase._postCommitFlushStatement` in `app_database.dart`.
    if (statement.trim() == 'SELECT 1') {
      throw StateError('simulated flush failure');
    }
    return _inner.runCustom(executor, statement, args);
  }

  @override
  Future<int> runInsert(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) => _inner.runInsert(executor, statement, args);

  @override
  Future<int> runUpdate(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) => _inner.runUpdate(executor, statement, args);

  @override
  Future<int> runDelete(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) => _inner.runDelete(executor, statement, args);

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) => _inner.runSelect(executor, statement, args);
}

void main() {
  // Every test opens its own AppDatabase over its own in-memory executor;
  // drift's "multiple databases" warning is about SHARING one executor, which
  // never happens here, and its stack traces drown the real output.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late _Recorder recorder;

  AppDatabase open({required bool flushAfterCommit}) {
    recorder = _Recorder();
    return AppDatabase(
      NativeDatabase.memory().interceptWith(recorder),
      flushAfterCommit: flushAfterCommit,
    );
  }

  /// Drift opens lazily, so the schema bootstrap lands in the recorder on the
  /// first real query. Do it up front and clear, so each test's assertions
  /// describe only what its own transaction did.
  Future<void> warmUp(AppDatabase db) async {
    await db.customSelect('SELECT 1 AS ok').get();
    recorder.events.clear();
  }

  test('the drift/sqlite3 versions this workaround was measured against', () {
    // The post-commit flush is a WORKAROUND for behaviour inside two
    // packages, not for anything in this repo, and it is invisible to every
    // other test: if drift starts flushing on commit by itself the extra
    // statement becomes harmless dead weight, but if drift changes WHERE it
    // flushes — say, only after statements that actually modified rows — the
    // workaround stops working and nothing here would notice. A bumped
    // version must therefore be a deliberate act with a re-measurement
    // attached, not a `flutter pub upgrade` side effect.
    //
    // To re-verify after a bump:
    //   1. re-read `_runWithArgs` in `drift/lib/wasm.dart` — is the flush
    //      still gated on `!isInTransaction`?
    //   2. re-read `_StatementBasedTransactionExecutor.send` in
    //      `drift/lib/src/runtime/executor/helpers/engines.dart` — does
    //      `_release()` still happen AFTER the COMMIT statement?
    //   3. re-read `IndexedDbFileSystem` in
    //      `sqlite3/lib/src/wasm/vfs/indexed_db.dart` — is there still no
    //      implicit writer when `writeAutomatically` is false?
    //   4. run `NO_FLUSH=1 tool/drive_web_write_order.sh` (must LOSE the tail
    //      topo) and then plain `tool/drive_web_write_order.sh` (must not).
    final lock = File('pubspec.lock').readAsStringSync();
    String versionOf(String package) {
      final match = RegExp(
        '^  $package:\$.*?^    version: "([^"]+)"',
        multiLine: true,
        dotAll: true,
      ).firstMatch(lock);
      // `isNotNull` is ambiguous here: drift exports one too. Compare
      // explicitly rather than importing either under a prefix.
      expect(match != null, isTrue, reason: 'no $package entry in pubspec.lock');
      return match!.group(1)!;
    }

    expect(
      versionOf('drift'),
      '2.34.2',
      reason: 'drift moved. Re-verify the four steps in this test\'s comment '
          'before accepting the bump — `AppDatabase.transaction`\'s flush and '
          'the whole rationale on `commitNeedsExplicitFlush` are pinned to '
          'drift 2.34.2 source.',
    );
    expect(
      versionOf('sqlite3'),
      '3.5.0',
      reason: 'sqlite3 moved. Re-verify that `IndexedDbFileSystem` still has '
          'no implicit writer when drift opens it with '
          '`writeAutomatically: false`.',
    );
  });

  test('the platform default is OFF for the dart:io seam', () {
    // If this ever flips, every `flutter test` in the repo silently starts
    // issuing an extra statement per transaction, and the web-only intent of
    // the workaround has been lost.
    expect(commitNeedsExplicitFlush, isFalse);
  });

  test('a top-level transaction flushes exactly once, AFTER the commit',
      () async {
    final db = open(flushAfterCommit: true);
    await warmUp(db);

    await db.transaction(() async {
      await db.into(db.appSettings).insert(
            AppSettingsCompanion.insert(settingKey: 'k', updatedAt: 1),
          );
    });

    expect(recorder.flushes, 1);
    final order = recorder.events;
    final commit = order.indexOf(_Recorder.commitMark);
    final flush = order.indexOf('SELECT 1');
    expect(commit, isNonNegative, reason: 'no COMMIT was recorded: $order');
    expect(
      flush,
      greaterThan(commit),
      reason: 'the flush must come AFTER the commit — before it, drift still '
          'has `isInTransaction == true` and skips `_flush()` entirely '
          '(drift/lib/wasm.dart:362-368), so the statement would be wasted '
          'and the data would still be lost. Order was: $order',
    );

    await db.close();
  });

  test('a NESTED transaction does not flush; only the outermost does',
      () async {
    final db = open(flushAfterCommit: true);
    await warmUp(db);

    await db.transaction(() async {
      await db.into(db.appSettings).insert(
            AppSettingsCompanion.insert(settingKey: 'outer', updatedAt: 1),
          );
      await db.transaction(() async {
        await db.into(db.appSettings).insert(
              AppSettingsCompanion.insert(settingKey: 'inner', updatedAt: 2),
            );
      });
    });

    expect(
      recorder.flushes,
      1,
      reason: 'a nested transaction is a SAVEPOINT — drift keeps '
          '`isInTransaction` set through its release '
          '(engines.dart:300-302 clears it only at depth 0), so a statement '
          'issued there flushes nothing and is pure overhead. Events: '
          '${recorder.events}',
    );

    await db.close();
  });

  test('a rolled-back transaction does not flush', () async {
    final db = open(flushAfterCommit: true);
    await warmUp(db);

    await expectLater(
      db.transaction(() async {
        await db.into(db.appSettings).insert(
              AppSettingsCompanion.insert(settingKey: 'doomed', updatedAt: 1),
            );
        throw StateError('abort');
      }),
      throwsA(isA<StateError>()),
    );

    expect(
      recorder.flushes,
      0,
      reason: 'nothing was committed, so there is nothing to make durable',
    );
    expect(
      recorder.events,
      contains(_Recorder.rollbackMark),
      reason: 'drift did not roll the transaction back at all',
    );

    await db.close();
  });

  test('the original exception survives a rollback (the flush cannot mask it)',
      () async {
    final db = open(flushAfterCommit: true);
    await warmUp(db);

    await expectLater(
      db.transaction(() async => throw StateError('the real cause')),
      throwsA(
        isA<StateError>().having((e) => e.message, 'message', 'the real cause'),
      ),
    );

    await db.close();
  });

  test('with the flag off, not one extra statement is issued', () async {
    final db = open(flushAfterCommit: false);
    await warmUp(db);

    await db.transaction(() async {
      await db.into(db.appSettings).insert(
            AppSettingsCompanion.insert(settingKey: 'k', updatedAt: 1),
          );
    });

    expect(
      recorder.flushes,
      0,
      reason: 'native writes through sqlite to a real file; an extra '
          'statement per transaction there is pure cost',
    );

    await db.close();
  });

  test('sequential transactions each flush, and the data is all readable',
      () async {
    final db = open(flushAfterCommit: true);
    await warmUp(db);

    for (var i = 0; i < 3; i++) {
      await db.transaction(() async {
        await db.into(db.appSettings).insert(
              AppSettingsCompanion.insert(settingKey: 'k$i', updatedAt: i),
            );
      });
    }

    expect(recorder.flushes, 3);
    final rows = await db.select(db.appSettings).get();
    expect(rows.map((r) => r.settingKey), containsAll(<String>['k0', 'k1', 'k2']));

    await db.close();
  });

  test('the flush does not run inside the transaction it follows', () async {
    // A regression guard for the deadlock the interceptor-based version of
    // this fix would have risked: if the statement were issued while the
    // committing transaction still held drift's executor lock, this would
    // hang rather than fail.
    final db = open(flushAfterCommit: true);
    await warmUp(db);

    await db
        .transaction(() async {
          await db.into(db.appSettings).insert(
                AppSettingsCompanion.insert(settingKey: 'k', updatedAt: 1),
              );
        })
        .timeout(
          const Duration(seconds: 10),
          onTimeout: () => fail(
            'the post-commit flush deadlocked against the executor lock',
          ),
        );

    await db.close();
  });

  test(
    'a flush failure propagates out of transaction() rather than being '
    'swallowed as success',
    () async {
      // Task #35 (IndexedDB VFS durability audit) residual-risk guard — see
      // `_ThrowOnFlushInterceptor`'s doc for what this stands in for and why
      // the underlying bugs it represents can't be fixed from this layer.
      // What CAN be guarded from here is that this override never itself
      // becomes the silent-loss bug: if the post-commit statement throws for
      // any reason, `transaction()` must propagate that, not report the
      // transaction as done. This is already `AppDatabase.transaction`'s
      // documented behaviour ("the flush is AWAITED and its failure
      // PROPAGATES") — this test pins it down so a later change (e.g. a
      // well-meaning `try/catch` around the flush "to be safe") gets caught
      // instead of quietly reopening the exact hole the flush exists to
      // close.
      final recorder = _Recorder();
      final failing = _ThrowOnFlushInterceptor(recorder);
      final db = AppDatabase(
        NativeDatabase.memory().interceptWith(failing),
        flushAfterCommit: true,
      );
      await db.customSelect('SELECT 1 AS ok').get();
      recorder.events.clear();

      await expectLater(
        db.transaction(() async {
          await db.into(db.appSettings).insert(
                AppSettingsCompanion.insert(settingKey: 'k', updatedAt: 1),
              );
        }),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'simulated flush failure',
          ),
        ),
        reason: 'a flush error must propagate out of transaction(), exactly '
            'like a failed INSERT already does — reporting success here '
            'would be the same silent-loss bug the flush exists to prevent, '
            'just moved one level up',
      );

      await db.close();
    },
  );
}
