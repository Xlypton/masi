// The bound on an individual database operation (task #54).
//
// -------------------------------------------------------------------------
// WHAT IS BEING PROTECTED
// -------------------------------------------------------------------------
// Nothing in this file cures a hang, and no assertion here should be read as
// claiming it does. `sqlite3`'s OPFS VFS blocks on
// `Atomics.wait(int32View, _responseIndex, -1)` (`async_opfs/sync_channel.dart:62`,
// no timeout) inside a web worker, and drift's `DelegatedDatabase.ensureOpen`
// holds `_openingLock` across the open, which a Dart-side timeout does not
// release. Only a page reload discards a wedged worker.
//
// What IS being protected is the observable consequence: that a database which
// never answers produces a NAMED ERROR rather than silence, that a `watch()`
// stream surfaces that error instead of quietly never emitting, and — the one
// non-negotiable — that it NEVER emits an empty list, which every screen would
// render as "you have no topos".
//
// Everything below runs on a REAL clock with a small injected bound (100ms),
// deliberately not under `fakeAsync`/`testWidgets`: `Future.timeout`'s Timer
// fires on the fake clock there, so the assertions would be about the harness
// rather than about the bound.
import 'dart:async';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/connection/query_timeout.dart';
import 'package:masi/core/db/connection/storage_durability.dart'
    show kStorageOpenTimeout;
import 'package:masi/core/db/storage_retry_provider.dart'
    show kStorageRetryTimeout;
import 'package:masi/main.dart' show kBootStorageDeadline;

/// The bound used everywhere below. Small enough that the whole file runs in
/// well under a second on a real clock, large enough that a healthy in-memory
/// `NativeDatabase` statement never trips it.
const Duration kBound = Duration(milliseconds: 100);

/// A [QueryExecutor] whose asynchronous methods NEVER complete — the Dart-side
/// stand-in for a wedged OPFS worker.
///
/// Deliberately not a "throws" fake: throwing is the case that already worked.
/// The bug being fixed is a future that stays pending for the lifetime of the
/// page, which only a never-completing `Completer` reproduces.
class _HangingExecutor extends QueryExecutor {
  final Completer<Never> _never = Completer<Never>();

  int closeCalls = 0;

  Future<T> _hang<T>() => _never.future;

  @override
  SqlDialect get dialect => SqlDialect.sqlite;

  @override
  Future<bool> ensureOpen(QueryExecutorUser user) => _hang();

  @override
  Future<List<Map<String, Object?>>> runSelect(
    String statement,
    List<Object?> args,
  ) => _hang();

  @override
  Future<int> runInsert(String statement, List<Object?> args) => _hang();

  @override
  Future<int> runUpdate(String statement, List<Object?> args) => _hang();

  @override
  Future<int> runDelete(String statement, List<Object?> args) => _hang();

  @override
  Future<void> runCustom(String statement, [List<Object?>? args]) => _hang();

  @override
  Future<void> runBatched(BatchedStatements statements) => _hang();

  @override
  TransactionExecutor beginTransaction() =>
      throw UnimplementedError('not needed by these tests');

  @override
  QueryExecutor beginExclusive() =>
      throw UnimplementedError('not needed by these tests');

  @override
  Future<void> close() {
    closeCalls++;
    return _hang();
  }
}

/// A [QueryExecutor] that can be switched between healthy and hanging, so a
/// stall and its recovery can be driven against ONE executor instance (the
/// latch and the `onStall`/`onRecovered` pair are per-executor state).
class _ToggleableExecutor extends _HangingExecutor {
  bool hang = false;

  int opens = 0;
  int selects = 0;

  @override
  Future<bool> ensureOpen(QueryExecutorUser user) {
    opens++;
    return hang ? super.ensureOpen(user) : Future<bool>.value(true);
  }

  @override
  Future<List<Map<String, Object?>>> runSelect(
    String statement,
    List<Object?> args,
  ) {
    selects++;
    return hang
        ? super.runSelect(statement, args)
        : Future<List<Map<String, Object?>>>.value(const []);
  }
}

/// Makes a REAL `NativeDatabase`'s `runSelect` hang on demand, leaving every
/// other operation (the open, the migration, inserts) working normally.
///
/// This is what lets assertions 3/4/5 be about a real `AppDatabase` with real
/// rows in it rather than about a synthetic executor: `bindQueryTimeout` is
/// applied OUTSIDE this, so the bound sees a genuine never-completing select
/// from a genuine drift stream.
class _HangSelects extends QueryInterceptor {
  bool hang = false;

  final Completer<Never> _never = Completer<Never>();

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) => hang ? _never.future : executor.runSelect(statement, args);
}

void main() {
  // Every test opens its own AppDatabase over its own executor; drift's
  // "multiple databases" warning is about SHARING one executor, which never
  // happens here, and its stack traces drown the real output.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('the bound fires', () {
    test(
      'assertion 1 — a bounded runSelect errors within the bound instead of '
      'hanging forever (revert the bound: this never completes)',
      () async {
        final executor = bindQueryTimeout(
          _HangingExecutor(),
          timeout: kBound,
        );

        final stopwatch = Stopwatch()..start();
        await expectLater(
          executor.runSelect('SELECT 1', const []),
          throwsA(isA<TimeoutException>()),
        );
        stopwatch.stop();

        expect(
          stopwatch.elapsed,
          lessThan(kBound * 20),
          reason: 'the bound must be what ended the wait, not the test '
              'timeout',
        );
      },
    );

    test(
      'assertion 2 — a bounded ensureOpen errors within the bound',
      () async {
        final executor = bindQueryTimeout(
          _HangingExecutor(),
          timeout: kBound,
        );

        await expectLater(
          executor.ensureOpen(_NoopUser()),
          throwsA(isA<TimeoutException>()),
        );
      },
    );

    test(
      'the TimeoutException names both the operation and the bound, so '
      'MasiAsyncView(showErrorDetail: true) renders something diagnostic',
      () async {
        final executor = bindQueryTimeout(
          _HangingExecutor(),
          timeout: kBound,
        );

        await expectLater(
          executor.runInsert('INSERT INTO x VALUES (1)', const []),
          throwsA(
            isA<TimeoutException>()
                .having((e) => e.message, 'message', contains('an insert'))
                .having((e) => e.duration, 'duration', kBound),
          ),
        );
      },
    );
  });

  group('a stalled watch() stream', () {
    /// An [AppDatabase] over a real in-memory sqlite file whose selects can be
    /// made to hang, already seeded with one area and warmed (so the schema
    /// bootstrap is not part of what any assertion observes).
    Future<(AppDatabase, _HangSelects)> seededDatabase() async {
      final hang = _HangSelects();
      final db = AppDatabase(
        bindQueryTimeout(
          NativeDatabase.memory().interceptWith(hang),
          timeout: kBound,
        ),
      );
      await db
          .into(db.areas)
          .insert(
            AreasCompanion.insert(
              id: 'area-1',
              name: 'Seeded',
              createdAt: 1,
              updatedAt: 1,
            ),
          );
      return (db, hang);
    }

    test(
      'assertion 3 — THE MONEY ASSERTION. A stalled select makes '
      'select(areas).watch() emit exactly one ERROR and zero data events: no '
      'empty list, of any kind, ever reaches a screen',
      () async {
        final (db, hang) = await seededDatabase();
        addTearDown(db.close);

        final events = <Object?>[];
        final errors = <Object>[];
        hang.hang = true;

        final sub = db
            .select(db.areas)
            .watch()
            .listen(events.add, onError: (Object e) => errors.add(e));
        addTearDown(sub.cancel);

        await Future<void>.delayed(kBound * 6);

        expect(
          errors,
          hasLength(1),
          reason: 'drift QueryStream.fetchAndEmitData addErrors to every '
              'listener; one stalled fetch is one error',
        );
        expect(errors.single, isA<TimeoutException>());
        expect(
          events,
          isEmpty,
          reason: 'THE NON-NEGOTIABLE: not one data event, and in particular '
              'not an empty <Area>[] — every list screen renders that as '
              '"you have nothing", which is the silent-data-loss shape this '
              'whole task exists to end. Got: $events',
        );
        // Said twice on purpose: `isEmpty` above would also pass if the stream
        // had emitted nothing because the harness was broken. Assertion 4 is
        // the control for that; this pins the specific forbidden value.
        expect(events, isNot(contains(isA<List<Object?>>())));
      },
    );

    test(
      'assertion 4 — NEGATIVE CONTROL for assertion 3: with hanging disabled '
      'the very same harness emits the seeded rows. Without this, assertion 3 '
      'only proves the harness is broken',
      () async {
        final (db, hang) = await seededDatabase();
        addTearDown(db.close);

        final events = <List<Area>>[];
        final errors = <Object>[];
        hang.hang = false;

        final sub = db
            .select(db.areas)
            .watch()
            .listen(events.add, onError: (Object e) => errors.add(e));
        addTearDown(sub.cancel);

        await Future<void>.delayed(kBound * 6);

        expect(errors, isEmpty);
        expect(events, isNotEmpty);
        expect(events.last.map((a) => a.id), ['area-1']);
      },
    );

    test(
      'assertion 5 — error, then RECOVERY: the stream stays subscribed and '
      'emits data on the next table update once the database answers again. '
      'This is the guard against anyone switching to Stream.timeout, which '
      'CLOSES the stream and would turn a stall into "this list will never '
      'update again"',
      () async {
        final (db, hang) = await seededDatabase();
        addTearDown(db.close);

        final events = <List<Area>>[];
        final errors = <Object>[];
        hang.hang = true;

        final sub = db
            .select(db.areas)
            .watch()
            .listen(events.add, onError: (Object e) => errors.add(e));
        addTearDown(sub.cancel);

        await Future<void>.delayed(kBound * 6);
        expect(errors, hasLength(1), reason: 'the stall must error first');
        expect(events, isEmpty);

        // The database answers again, and something changes the table.
        hang.hang = false;
        await db
            .into(db.areas)
            .insert(
              AreasCompanion.insert(
                id: 'area-2',
                name: 'After the stall',
                createdAt: 2,
                updatedAt: 2,
              ),
            );
        await Future<void>.delayed(kBound * 6);

        expect(
          events,
          isNotEmpty,
          reason: 'the subscription was still alive and re-fetched; a closed '
              'stream would never emit again. Errors so far: $errors',
        );
        expect(events.last.map((a) => a.id), containsAll(['area-1', 'area-2']));
      },
    );
  });

  group('close is deliberately NOT bounded', () {
    test(
      'assertion 6 — close() on a hanging executor does not error after the '
      'bound. appDatabaseProvider DROPS close()\'s future '
      '(ref.onDispose(() => db.close())), so a bounded-and-throwing close '
      'would be an unhandled async error at every teardown, including the '
      'storage-retry invalidate path (revert: bound `close` and this fails)',
      () async {
        final hanging = _HangingExecutor();
        final executor = bindQueryTimeout(hanging, timeout: kBound);

        Object? error;
        var completed = false;
        // Deliberately not awaited — exactly what `appDatabaseProvider`'s
        // `ref.onDispose(() => db.close())` does with this future.
        unawaited(
          executor.close().then<void>(
            (_) => completed = true,
            onError: (Object e, StackTrace _) => error = e,
          ),
        );

        await Future<void>.delayed(kBound * 6);

        expect(hanging.closeCalls, 1, reason: 'close must still be forwarded');
        // `isNull` is ambiguous here — drift exports one too. Compare
        // explicitly rather than importing either under a prefix (same fix as
        // `post_commit_flush_test.dart`).
        expect(
          error == null,
          isTrue,
          reason: 'a hanging close is harmless today; a THROWING one is not. '
              'Got: $error',
        );
        expect(completed, isFalse, reason: 'it is still pending, unbounded');
      },
    );
  });

  group('the DatabaseConnection trap', () {
    test(
      'assertion 7 — THE SHARPEST GUARD. bindQueryTimeout over a '
      'DatabaseConnection returns a DatabaseConnection whose streamQueries is '
      'the SAME OBJECT. Extension resolution is by STATIC type, and '
      'openConnection() is declared to return QueryExecutor, so a naive '
      '`executor.interceptWith(...)` picks the QueryExecutor extension, hands '
      'AppDatabase a bare _InterceptedExecutor, and DatabaseConnectionUser '
      'then builds a FRESH stream store — silently discarding web\'s '
      'BroadcastStreamQueryStore and killing cross-tab watch() invalidation '
      'with no error anywhere',
      () {
        final inner = NativeDatabase.memory();
        final connection = DatabaseConnection(inner);
        addTearDown(connection.close);

        // Typed as QueryExecutor on purpose: this is production's static type,
        // and it is the whole reason the trap exists.
        final QueryExecutor asExecutor = connection;
        final wrapped = bindQueryTimeout(asExecutor, timeout: kBound);

        expect(
          wrapped,
          isA<DatabaseConnection>(),
          reason: 'a bare QueryExecutor here loses the stream store',
        );
        final wrappedConnection = wrapped as DatabaseConnection;
        expect(
          wrappedConnection.streamQueries,
          same(connection.streamQueries),
          reason: 'object identity, not equality: drift preserves the store by '
              'passing the very same instance through withExecutor(), and any '
              'other value means a second store now exists and table updates '
              'reach only one of them',
        );
        expect(
          wrappedConnection.executor,
          isNot(same(inner)),
          reason: 'the executor itself must actually be wrapped',
        );
      },
    );

    test(
      'a null timeout returns the executor UNCHANGED (the native path is a '
      'provable identity, not a promise)',
      () {
        final inner = NativeDatabase.memory();
        addTearDown(inner.close);

        expect(bindQueryTimeout(inner, timeout: null), same(inner));
      },
    );
  });

  group('the ensureOpen latch', () {
    test(
      'assertion 8 — a SECOND ensureOpen after a stall fails in UNDER the '
      'bound. drift holds _openingLock across the open and a Dart timeout does '
      'not release it, so every post-stall open would otherwise cost another '
      'full bound for a guaranteed-identical outcome',
      () async {
        final inner = _ToggleableExecutor()..hang = true;
        final executor = bindQueryTimeout(inner, timeout: kBound);

        await expectLater(
          executor.ensureOpen(_NoopUser()),
          throwsA(isA<TimeoutException>()),
        );
        expect(inner.opens, 1);

        final stopwatch = Stopwatch()..start();
        await expectLater(
          executor.ensureOpen(_NoopUser()),
          throwsA(isA<TimeoutException>()),
        );
        stopwatch.stop();

        expect(
          stopwatch.elapsed,
          lessThan(kBound),
          reason: 'the latch must answer immediately, not re-wait the bound. '
              'Took ${stopwatch.elapsed}',
        );
        expect(
          inner.opens,
          1,
          reason: 'the latched call must not even reach the wedged executor',
        );
      },
    );

    test(
      'assertion 9 — statement timeouts do NOT latch: a healthy runSelect '
      'after a stalled one succeeds. Latching on statements would permanently '
      'poison a merely-slow database',
      () async {
        final inner = _ToggleableExecutor()..hang = true;
        final executor = bindQueryTimeout(inner, timeout: kBound);

        await expectLater(
          executor.runSelect('SELECT 1', const []),
          throwsA(isA<TimeoutException>()),
        );

        inner.hang = false;
        await expectLater(executor.runSelect('SELECT 1', const []), completes);
        // And the open is still allowed too — nothing was latched.
        await expectLater(executor.ensureOpen(_NoopUser()), completion(isTrue));
      },
    );
  });

  group('onStall / onRecovered', () {
    test(
      'assertion 10 — onStall fires once per STALL (not once per timed-out '
      'operation), onRecovered exactly once on the first success after it, '
      'and neither ever fires on an executor that has not stalled',
      () async {
        var stalls = 0;
        var recoveries = 0;
        final inner = _ToggleableExecutor()..hang = true;
        final executor = bindQueryTimeout(
          inner,
          timeout: kBound,
          onStall: () => stalls++,
          onRecovered: () => recoveries++,
        );

        await expectLater(
          executor.runSelect('SELECT 1', const []),
          throwsA(isA<TimeoutException>()),
        );
        await expectLater(
          executor.runSelect('SELECT 2', const []),
          throwsA(isA<TimeoutException>()),
        );

        expect(
          stalls,
          1,
          reason: 'the de-duplication is load-bearing: database_provider.dart '
              'SNAPSHOTS the storage verdict on onStall so onRecovered can '
              'restore it, and a second onStall would snapshot the stall '
              'verdict itself',
        );
        expect(recoveries, 0);

        inner.hang = false;
        await executor.runSelect('SELECT 3', const []);
        expect(recoveries, 1);

        await executor.runSelect('SELECT 4', const []);
        expect(recoveries, 1, reason: 'exactly once, not once per success');

        // A never-stalled executor.
        var otherStalls = 0;
        var otherRecoveries = 0;
        final healthy = bindQueryTimeout(
          _ToggleableExecutor(),
          timeout: kBound,
          onStall: () => otherStalls++,
          onRecovered: () => otherRecoveries++,
        );
        await healthy.ensureOpen(_NoopUser());
        await healthy.runSelect('SELECT 1', const []);
        expect(otherStalls, 0);
        expect(otherRecoveries, 0);
      },
    );

    test(
      'a real (non-timeout) error is NOT reported as a stall — the database '
      'answered',
      () async {
        var stalls = 0;
        final db = AppDatabase(
          bindQueryTimeout(
            NativeDatabase.memory(),
            timeout: kBound,
            onStall: () => stalls++,
          ),
        );
        addTearDown(db.close);

        await expectLater(
          db.customSelect('SELECT * FROM no_such_table').get(),
          throwsA(anything),
        );

        expect(stalls, 0);
      },
    );
  });

  group('the wrapper does not disturb what already works', () {
    // ASSERTION 11 — REGRESSION GUARD, not proof the timeout works.
    //
    // `post_commit_flush_test.dart` covers the post-commit durability flush's
    // mechanics (depth counting, nesting, rollback, and the flush landing
    // AFTER the COMMIT) against a bare executor. Wrapping the executor puts
    // drift's `_InterceptedTransactionExecutor` between `AppDatabase` and the
    // database — a class this repo takes entirely on trust — so those same
    // scenarios are re-run HERE through `bindQueryTimeout`. If the wrapper
    // broke transaction depth or commit ordering, silent web data loss would
    // be the symptom and nothing else in the suite would notice.
    late List<String> events;

    AppDatabase open() {
      events = <String>[];
      return AppDatabase(
        bindQueryTimeout(
          NativeDatabase.memory().interceptWith(_Recorder(events)),
          timeout: kBound * 100, // 10s: real statements must never trip it here
        ),
        flushAfterCommit: true,
      );
    }

    Future<void> warmUp(AppDatabase db) async {
      await db.customSelect('SELECT 1 AS ok').get();
      events.clear();
    }

    test(
      'assertion 11a — a top-level transaction still flushes exactly once, '
      'AFTER the commit (regression guard on drift\'s '
      '_InterceptedTransactionExecutor)',
      () async {
        final db = open();
        addTearDown(db.close);
        await warmUp(db);

        await db.transaction(() async {
          await db
              .into(db.appSettings)
              .insert(AppSettingsCompanion.insert(settingKey: 'k', updatedAt: 1));
        });

        expect(events.where((e) => e == 'SELECT 1').length, 1);
        final commit = events.indexOf(_Recorder.commitMark);
        expect(commit, isNonNegative, reason: 'no COMMIT recorded: $events');
        expect(
          events.indexOf('SELECT 1'),
          greaterThan(commit),
          reason: 'before the commit drift still has isInTransaction == true '
              'and skips _flush() entirely. Order was: $events',
        );
      },
    );

    test(
      'assertion 11b — a NESTED transaction still does not flush; only the '
      'outermost does (regression guard)',
      () async {
        final db = open();
        addTearDown(db.close);
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

        expect(events.where((e) => e == 'SELECT 1').length, 1);
      },
    );

    test(
      'assertion 11c — a rolled-back transaction still does not flush, still '
      'rolls back, and the original exception still survives (regression '
      'guard)',
      () async {
        final db = open();
        addTearDown(db.close);
        await warmUp(db);

        await expectLater(
          db.transaction(() async {
            await db.into(db.appSettings).insert(
              AppSettingsCompanion.insert(settingKey: 'doomed', updatedAt: 1),
            );
            throw StateError('the real cause');
          }),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              'the real cause',
            ),
          ),
        );

        expect(events.where((e) => e == 'SELECT 1').length, 0);
        expect(events, contains(_Recorder.rollbackMark));
      },
    );
  });

  group('the constant', () {
    test(
      'assertion 12 — REGRESSION GUARD / coupling check. Proves the ORDERING '
      'of the timeout ladder only, and nothing about whether any value is '
      'right: kStorageOpenTimeout < kDatabaseQueryTimeout, and the query bound '
      'ties with boot and retry',
      () {
        expect(
          kStorageOpenTimeout,
          lessThan(kDatabaseQueryTimeout),
          reason: 'when the OPEN is what wedged, its own specific reason must '
              'be published before a generic query-bound verdict can fire',
        );
        expect(
          kDatabaseQueryTimeout,
          kBootStorageDeadline,
          reason: 'the three-way tie is deliberate and benign — same verdict '
              'shape, and "a later verdict is a newer fact" resolves the '
              'ordering',
        );
        expect(kDatabaseQueryTimeout, kStorageRetryTimeout);
      },
    );

    test(
      'assertion 13 — TAUTOLOGICAL, a regression guard only. It restates the '
      'constant and proves nothing about whether 30s is the right number: '
      'that is derived from this repo\'s own recorded reasoning '
      '(kStorageRetryTimeout) and has never been measured. Only field '
      'telemetry (the release `masi/storage:` log line) can validate it',
      () {
        expect(kDatabaseQueryTimeout, const Duration(seconds: 30));
      },
    );
  });
}

/// Minimal [QueryExecutorUser]; nothing here ever reaches a migration.
class _NoopUser implements QueryExecutorUser {
  @override
  int get schemaVersion => 1;

  @override
  Future<void> beforeOpen(QueryExecutor executor, OpeningDetails details) async {}
}

/// Records statements and the commit/rollback boundary, in order — the same
/// shape as `post_commit_flush_test.dart`'s recorder, kept local so that file
/// and this one cannot drift into each other.
///
/// Note what it cannot see: drift issues a transaction's own BEGIN/COMMIT
/// through `_StatementBasedTransactionExecutor.runCustom`, whose `impl` is the
/// delegate itself, so the interceptor is never in that path. The commit
/// boundary is therefore captured from `commitTransaction`/`rollbackTransaction`.
class _Recorder extends QueryInterceptor {
  _Recorder(this.events);

  static const String commitMark = '<commit>';
  static const String rollbackMark = '<rollback>';

  final List<String> events;

  @override
  Future<void> commitTransaction(TransactionExecutor inner) async {
    await inner.send();
    events.add(commitMark);
  }

  @override
  Future<void> rollbackTransaction(TransactionExecutor inner) async {
    await inner.rollback();
    events.add(rollbackMark);
  }

  @override
  Future<void> runCustom(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    events.add(statement.trim());
    return executor.runCustom(statement, args);
  }

  @override
  Future<int> runInsert(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    events.add(statement.trim());
    return executor.runInsert(statement, args);
  }

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    events.add(statement.trim());
    return executor.runSelect(statement, args);
  }
}
