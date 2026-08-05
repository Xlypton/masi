import 'dart:async';

import 'package:drift/drift.dart';

/// How long ONE database operation — an open, a statement, a commit — may take
/// before it is treated as a failure rather than as slowness.
///
/// 30 seconds. Deliberately NOT a new number: it is the allowance this repo
/// already committed to for literally this work. `kStorageRetryTimeout`
/// (`storage_retry_provider.dart`) is 30s and covers exactly what [ensureOpen]
/// covers here — a fresh `openConnection` plus one `SELECT 1`, which on web
/// means `WasmDatabase.open` (itself bounded at `kStorageOpenTimeout`, 20s)
/// plus all the first-query work that open defers into the worker
/// (`WasmSqlite3.loadFromUrl`, VFS setup, and on a first run the v1->v9
/// migration). Its doc already records the reason a tighter bound is wrong:
/// it "would call 'broken' on a cold low-end Android that boot would have
/// called merely slow, which is the one thing these timeouts must never do".
///
/// Ladder, on purpose:
/// `kStorageOpenTimeout (20s) < kDatabaseQueryTimeout (30s) ==
/// kBootStorageDeadline (30s) == kStorageRetryTimeout (30s)`.
/// The 20s floor means that when the OPEN is the thing that wedged, its own
/// specific reason gets published first. The three-way tie at 30s is benign:
/// all three publish the same verdict SHAPE, and "a later verdict is a newer
/// fact" resolves any ordering.
///
/// ONE constant, not two. There is no in-repo measurement of a post-open
/// individual statement (searched `docs/`, `WEB_PERF_AUDIT.md`,
/// `WEB_PORT_BRIEF.md`, and every `Duration(seconds:` in `lib/`), so a second,
/// tighter statement-specific bound is deliberately REFUSED — it would be a
/// guess dressed up as a derivation, and its failure mode is the prohibited
/// one above. The one statement whose cost genuinely scales with library size
/// is `AppDatabase._postCommitFlushStatement`'s `SELECT 1`, because on the
/// IndexedDB backends its flush drains sqlite3's whole pending write queue
/// (`sqlite3-3.5.0/lib/src/wasm/vfs/indexed_db.dart:606-608`), and that has
/// never been measured on a large library. Splitting this constant is a
/// decision for after the field telemetry (`masi/storage:`) exists, not before.
const Duration kDatabaseQueryTimeout = Duration(seconds: 30);

/// Renders a bound for a human: `30s` for the production one, `100ms` for an
/// injected test one.
///
/// `'${timeout.inSeconds}s'` alone reads "within 0s" for any sub-second bound,
/// which is a confusing thing to find in a diagnostic — and these strings reach
/// real users through `MasiAsyncView(showErrorDetail: true)` and the release
/// `masi/storage:` log line.
String describeQueryBound(Duration bound) => bound.inSeconds >= 1
    ? '${bound.inSeconds}s'
    : '${bound.inMilliseconds}ms';

/// Bounds every asynchronous database operation drift routes through a
/// [QueryInterceptor], turning "this future never completes" into a named
/// [TimeoutException].
///
/// -------------------------------------------------------------------------
/// WHAT THIS BUYS, AND WHAT IT CATEGORICALLY DOES NOT
/// -------------------------------------------------------------------------
/// It does NOT cure a hang. `sqlite3`'s OPFS VFS blocks on
/// `Atomics.wait(int32View, _responseIndex, -1)`
/// (`sqlite3-3.5.0/lib/src/wasm/vfs/async_opfs/sync_channel.dart:62`) with no
/// timeout — the neighbouring `waitForRequest` uses `Atomics.waitWithTimeout`,
/// this one does not — so a dead VFS server worker blocks the database worker
/// forever and it cannot even process a `close()`. Worse, drift's
/// `DelegatedDatabase.ensureOpen`
/// (`drift-2.34.2/lib/src/runtime/executor/helpers/engines.dart:492-521`) runs
/// inside `_openingLock.synchronized(...)`, and a Dart-side timeout does not
/// release that lock: after the first stall every later `ensureOpen` queues
/// behind a block that never finishes. Only a page reload discards a wedged
/// worker.
///
/// What it DOES buy: the UI stops waiting silently, the failure is named, the
/// existing storage banner and create-topo interlock light up, and the user is
/// offered the one recovery that works. Any claim beyond that is false.
///
/// -------------------------------------------------------------------------
/// WHY THE EXECUTOR AND NOT THE 17 STREAMS
/// -------------------------------------------------------------------------
/// drift's `QueryStream.fetchAndEmitData`
/// (`stream_queries.dart:328-360`) wraps BOTH of its unbounded awaits — the
/// `doWhenOpened` at `:338` and the `runCancellable` fetch at `:342` — in ONE
/// try/catch whose only action is `addError` to every listener (`:355`).
/// So bounding the EXECUTOR turns "never emits" into "emits an error, stays
/// subscribed, recovers on the next table update" for every `watch()`-backed
/// provider at once, with no per-call-site work — and it satisfies the
/// non-negotiable constraint (an error state, NEVER an empty list)
/// structurally rather than by convention.
///
/// `.timeout()` on the *Stream* would have been actively wrong: it re-arms per
/// event and CLOSES the stream when it fires, turning a stall into "this list
/// will never update again" — strictly worse than the hang.
///
/// One-shot futures need nothing extra: the throw propagates through
/// `FutureProvider` to `AsyncError` and `MasiAsyncView`'s error state, and
/// imperative gestures already `try/catch` into a SnackBar.
class QueryTimeoutInterceptor extends QueryInterceptor {
  QueryTimeoutInterceptor({
    required this.timeout,
    this.onStall,
    this.onRecovered,
  });

  /// The bound applied to each individual operation.
  final Duration timeout;

  /// Called on the FIRST operation to exceed [timeout] after a healthy period
  /// — not once per timed-out operation.
  ///
  /// The de-duplication is load-bearing, not tidiness: `database_provider.dart`
  /// SNAPSHOTS the current storage verdict when this fires so that
  /// [onRecovered] can restore it. A second `onStall` during the same stall
  /// would snapshot the stall verdict itself and make recovery restore the
  /// failure.
  final void Function()? onStall;

  /// Called on the first SUCCESSFUL operation after [onStall] fired, exactly
  /// once, and never on an executor that has never stalled.
  ///
  /// Only a success clears the stall. An operation that fails FAST with a real
  /// error (a constraint violation, a syntax error) does prove the database
  /// answered, but treating it as recovery would mean publishing "storage is
  /// fine" off the back of an error, and the next healthy read costs nothing
  /// to wait for.
  final void Function()? onRecovered;

  /// Whether an [ensureOpen] has ALREADY exceeded [timeout] on this executor.
  ///
  /// Latched, and latched for [ensureOpen] ONLY. Because drift holds
  /// `_openingLock` across the open, every post-stall `ensureOpen` would cost
  /// another full [timeout] with a guaranteed-identical outcome, so once it has
  /// timed out here it fails immediately instead.
  ///
  /// Statement timeouts deliberately do NOT latch: one slow statement is not
  /// proof the connection is dead, and latching there would permanently poison
  /// a merely-slow database. The latch also cannot outlive a recovery attempt —
  /// `storage_retry_provider.dart`'s `ref.invalidate(appDatabaseProvider)`
  /// builds a whole new executor, and therefore a new interceptor with a fresh
  /// latch.
  bool get openTimedOut => _openTimedOut;
  bool _openTimedOut = false;

  bool _stalled = false;

  TimeoutException _timedOut(String operation) => TimeoutException(
    'the local database did not answer $operation within '
    '${describeQueryBound(timeout)}',
    timeout,
  );

  void _noteStall() {
    if (_stalled) return;
    _stalled = true;
    onStall?.call();
  }

  /// The healthy path, whose entire cost is this one branch.
  void _noteSuccess() {
    if (!_stalled) return;
    _stalled = false;
    onRecovered?.call();
  }

  /// [onBoundExceeded] runs when — and only when — THIS bound fires, before
  /// the [TimeoutException] is thrown. It exists for the [ensureOpen] latch:
  /// the timeout is imposed OUTSIDE [run] by `Future.timeout`, so a `catch`
  /// inside [run] can never observe it.
  Future<T> _bound<T>(
    String operation,
    Future<T> Function() run, {
    void Function()? onBoundExceeded,
  }) async {
    var timedOut = false;
    try {
      final value = await run().timeout(
        timeout,
        onTimeout: () {
          timedOut = true;
          onBoundExceeded?.call();
          throw _timedOut(operation);
        },
      );
      _noteSuccess();
      return value;
    } catch (_) {
      // Only OUR bound counts as a stall. A `TimeoutException` thrown from
      // somewhere underneath us (or any other error) is a database that
      // answered, and must not be reported as storage not responding.
      if (timedOut) _noteStall();
      rethrow;
    }
  }

  @override
  Future<bool> ensureOpen(QueryExecutor executor, QueryExecutorUser user) {
    if (_openTimedOut) {
      // No-op when the stall was never cleared, which is the normal case; it
      // re-reports only if a statement had somehow succeeded in between.
      _noteStall();
      return Future<bool>.error(
        TimeoutException(
          'the local database stopped responding: an earlier attempt to open '
          'it did not answer within ${describeQueryBound(timeout)}. Reloading '
          'the app is the only way to clear this.',
          timeout,
        ),
        StackTrace.current,
      );
    }
    return _bound(
      'when opening',
      () => executor.ensureOpen(user),
      // The latch is set ONLY from here, so it stays specific to the open.
      onBoundExceeded: () => _openTimedOut = true,
    );
  }

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) => _bound('a read', () => executor.runSelect(statement, args));

  @override
  Future<int> runInsert(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) => _bound('an insert', () => executor.runInsert(statement, args));

  @override
  Future<int> runUpdate(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) => _bound('an update', () => executor.runUpdate(statement, args));

  @override
  Future<int> runDelete(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) => _bound('a delete', () => executor.runDelete(statement, args));

  @override
  Future<void> runCustom(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) => _bound('a statement', () => executor.runCustom(statement, args));

  @override
  Future<void> runBatched(
    QueryExecutor executor,
    BatchedStatements statements,
  ) => _bound('a batch of statements', () => executor.runBatched(statements));

  /// Bounded, with a cost that is accepted with eyes open — write it down
  /// rather than discovering it in the field.
  ///
  /// `_StatementBasedTransactionExecutor.send()` is
  /// `await runCustom(COMMIT); _release();`
  /// (`drift-2.34.2/.../helpers/engines.dart:274-280`). If this bound fires,
  /// `_release()` has NOT run. drift's `transaction()` then calls
  /// `rollbackAfterException` (`connection_user.dart:531,543`), and
  /// `rollback()`'s `finally { _release(); }` is what actually frees the lock.
  /// So on a SPURIOUS timeout of a healthy-but-slow commit the data may
  /// already be committed, the ROLLBACK fails with "no transaction is active",
  /// a `CouldNotRollBackException` reaches the caller — and because
  /// `LibraryCrudRepository.createTopo` mints a fresh uuid, a user retry can
  /// produce a DUPLICATE TOPO.
  ///
  /// Accepted, for three reasons: the alternative is the bug being fixed (a
  /// "New topo" spinner that never resolves at all); on the real wedge path
  /// the retry's own INSERT stalls too, so no duplicate can materialise; and
  /// [kDatabaseQueryTimeout] is sized so that a spurious fire on a commit is
  /// not a realistic event.
  @override
  Future<void> commitTransaction(TransactionExecutor inner) =>
      _bound('when committing', () => inner.send());

  @override
  Future<void> rollbackTransaction(TransactionExecutor inner) =>
      _bound('when rolling back', () => inner.rollback());

  // `close` is deliberately NOT overridden, so drift's default
  // `inner.close()` passes through UNBOUNDED.
  //
  // `appDatabaseProvider`'s `ref.onDispose(() => db.close())` DROPS the
  // returned future, so a bounded-and-throwing `close` becomes an unhandled
  // async error at every teardown — including the storage-retry
  // `ref.invalidate` path, i.e. exactly when things are already going wrong.
  // A hanging `close` is currently harmless; a throwing one is not.
  //
  // `beginTransaction`, `beginExclusive`, `dialect` and
  // `transactionCanBeNested` are synchronous and have nothing to bound.
}

/// Wraps [executor] so every asynchronous database operation is bounded by
/// [timeout], or returns it UNCHANGED when [timeout] is `null`.
///
/// A `null` [timeout] is the native path: both wedge modes this exists for are
/// web-only (the OPFS `Atomics.wait`, and drift's worker-side `LazyDatabase` at
/// `wasm_setup/shared.dart:284`). On native a stall is a file lock or a corrupt
/// database, which a Dart timeout neither fixes nor diagnoses — so the choice
/// there is between an executor-identity change across ~160 call sites on the
/// primary shipped platform for zero known benefit, or nothing. Nothing wins,
/// and returning the executor untouched makes that a provable identity rather
/// than a promise.
///
/// THE SHARP TRAP THIS FUNCTION EXISTS TO AVOID. `openConnection()`'s declared
/// return type is `QueryExecutor`, but on web it actually returns a
/// `DatabaseConnection` (`connection_web.dart`'s
/// `DatabaseConnection.delayed(...)`) whose `streamQueries` is a
/// `DelayedStreamQueryStore`. drift ships TWO `interceptWith` extensions —
/// `ApplyInterceptor` on `QueryExecutor` and `ApplyInterceptorConnection` on
/// `DatabaseConnection` — and **extension resolution is by STATIC type**. So a
/// plain `executor.interceptWith(interceptor)` here would resolve to the
/// `QueryExecutor` one, return an `_InterceptedExecutor`, and hand THAT to
/// `AppDatabase`, whose `DatabaseConnectionUser` constructor then does
/// `executor is DatabaseConnection ? executor : DatabaseConnection(executor)`
/// (`connection_user.dart:46-48`) — quietly building a FRESH stream-query
/// store and **discarding the real one, which kills cross-tab `watch()`
/// invalidation with no error anywhere**. It is the same failure
/// `openConnection`'s own doc warns about for returning a bare
/// `LazyDatabase`.
///
/// Hence the explicit, by-name extension application below: it branches on the
/// RUNTIME type and preserves `streamQueries` by object identity.
/// `test/core/db/query_timeout_test.dart` pins that identity.
QueryExecutor bindQueryTimeout(
  QueryExecutor executor, {
  required Duration? timeout,
  void Function()? onStall,
  void Function()? onRecovered,
}) {
  if (timeout == null) return executor;
  final interceptor = QueryTimeoutInterceptor(
    timeout: timeout,
    onStall: onStall,
    onRecovered: onRecovered,
  );
  return executor is DatabaseConnection
      ? ApplyInterceptorConnection(executor).interceptWith(interceptor)
      : ApplyInterceptor(executor).interceptWith(interceptor);
}
