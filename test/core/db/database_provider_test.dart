import 'dart:async';
import 'dart:io';

import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/connection/query_timeout.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/core/db/storage_durability_provider.dart';
import 'package:masi/features/library/application/library_providers.dart';
import 'package:drift/drift.dart'
    show
        BatchedStatements,
        LazyDatabase,
        QueryExecutor,
        QueryExecutorUser,
        SqlDialect,
        TransactionExecutor;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// Stands in for the real `path_provider` platform channel plugin — see
/// `test/features/ar/presentation/ar_screen_test.dart`'s identical fake for
/// why this is needed (a plain `flutter test` host has no `path_provider`
/// platform implementation registered).
class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this.docsPath);

  final String docsPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => docsPath;
}

/// An [AppDatabase] whose executor resolves fine and then fails the moment a
/// statement actually needs it — precisely drift-on-web's shape, where the
/// real sqlite open lives behind a `LazyDatabase` INSIDE the worker
/// (`drift-2.34.2/lib/src/web/wasm_setup/shared.dart:284`) and so cannot fail
/// until the first query.
///
/// A closed `NativeDatabase.memory()` does NOT work as a stand-in here: drift
/// simply opens a fresh in-memory database on the next statement, so every
/// query keeps succeeding.
AppDatabase _brokenDatabase() => AppDatabase(
  LazyDatabase(() async => throw StateError('no storage backend')),
);

/// The bound the query-timeout tests below inject. Small enough to keep the
/// suite fast, on a REAL clock (these are plain `test()`s, so `Future.timeout`
/// uses the real one).
const Duration kTestQueryBound = Duration(milliseconds: 100);

/// A [QueryExecutor] whose asynchronous methods NEVER complete — the Dart-side
/// stand-in for a wedged OPFS worker, and the one shape `_brokenDatabase()`
/// above cannot express (it THROWS, which already worked; the bug being fixed
/// is a future that stays pending for the lifetime of the page).
class _HangingExecutor extends QueryExecutor {
  final Completer<Never> _never = Completer<Never>();

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
  TransactionExecutor beginTransaction() => throw UnimplementedError();

  @override
  QueryExecutor beginExclusive() => throw UnimplementedError();

  @override
  Future<void> close() => _hang();
}

/// The verdict production actually measures on the deployed site, per
/// `connection_web.dart` — an OPFS backend that nevertheless reports one
/// missing browser feature. Used as the "already measured" state that a stall
/// verdict must not destroy.
const StorageDurability _measuredInProduction = StorageDurability(
  backend: StorageBackend.opfsLocks,
  missingFeatures: {StorageMissingFeature.dedicatedWorkersInSharedWorkers},
);

/// Regression coverage for the cold-cache device bug: `photoRepositoryProvider`
/// and `libraryCrudRepositoryProvider` used to each construct their OWN
/// `PhotoFiles()` (`?? PhotoFiles()`), so warming one repository's docs-path
/// cache never helped the other, and neither was ever warmed at app startup
/// — leaving `Photos.localPath`'s bare relative form (`photos/<id>.jpg`)
/// unresolved on a device's first cold launch (`File(...)` then resolves
/// against the process CWD, not the app documents directory -> missing
/// images).
///
/// Both providers now read the single shared `photoFilesProvider` (see
/// `database_provider.dart`), and `main.dart` awaits that ONE instance's
/// `warmDocsPath()` before `runApp`. This file proves the sharing half of
/// the fix: warming `photoFilesProvider` directly — mirroring exactly what
/// `main.dart` does — is visible to BOTH repositories' photo-path
/// resolution, even though neither repository ever calls `warmDocsPath` on
/// its own.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late String mockedDocsPath;
  final originalPathProviderPlatform = PathProviderPlatform.instance;

  setUp(() {
    mockedDocsPath = Directory.systemTemp
        .createTempSync('database_provider_test_')
        .path;
    PathProviderPlatform.instance = _FakePathProviderPlatform(mockedDocsPath);
  });

  tearDown(() {
    PathProviderPlatform.instance = originalPathProviderPlatform;
    final dir = Directory(mockedDocsPath);
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test('container.read(photoFilesProvider) returns the same PhotoFiles '
      'instance on every read (a single shared cache, not a fresh instance '
      'per read)', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final first = container.read(photoFilesProvider);
    final second = container.read(photoFilesProvider);

    expect(identical(first, second), isTrue);
  });

  test('photoRepositoryProvider and libraryCrudRepositoryProvider are backed '
      'by the SAME photoFilesProvider instance: warming ONLY the shared '
      'PhotoFiles (as main.dart does before runApp) makes BOTH repositories '
      "resolve a stored relative localPath to an absolute path, proving "
      'neither one carries its own separate, unwarmed PhotoFiles()', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        nowMsProvider.overrideWithValue(() => 1000),
      ],
    );
    addTearDown(container.dispose);

    // Mirrors main.dart's startup sequence exactly: only the shared
    // photoFilesProvider instance is ever warmed, directly — neither
    // repository's own warmDocsPath is ever invoked below.
    await container.read(photoFilesProvider).warmDocsPath();

    final crud = container.read(libraryCrudRepositoryProvider);
    final area = await crud.createArea('Area');
    final sector = await crud.createSector(area.id, 'Sector');
    final wall = await crud.createWall(sector.id, 'Wall');
    // A missing source path -> PhotoFiles.importPhoto's best-effort
    // branch returns the relative destination form directly without
    // touching the docs dir, giving a clean "stored relative, never
    // resolved" row to resolve from below.
    final photoId = await crud.attachPhotoToWall(
      wall.id,
      XFile('/does/not/exist.jpg'),
      100,
      200,
    );
    final expectedAbsolute = p.join(mockedDocsPath, 'photos', '$photoId.jpg');

    // libraryCrudRepositoryProvider's own resolution.
    final crudResolved = await crud.photoLocalPath(photoId);
    expect(crudResolved, expectedAbsolute);

    // photoRepositoryProvider's resolution of the SAME row, via a
    // completely different repository instance — this only resolves to
    // an absolute path if it shares photoFilesProvider's already-warmed
    // cache instead of carrying its own cold PhotoFiles().
    final photoRepo = container.read(photoRepositoryProvider);
    final original = await photoRepo.loadOriginal(wall.id);

    expect(original, isNotNull);
    expect(original!.localPath, expectedAbsolute);
  });

  // `WasmDatabase.open`'s verdict is reported BEFORE the database has done any
  // real work: drift hands back a `resolvedExecutor` whose actual sqlite open
  // is itself deferred behind a `LazyDatabase` inside the worker
  // (`drift-2.34.2/lib/src/web/wasm_setup/shared.dart:284`), and native's
  // `openConnection` reports synchronously around an unopened `LazyDatabase`.
  // So a green `opfsShared`/`opfsLocks`/`nativeFile` verdict is NOT evidence
  // that storage works — only a completed query is. Without this probe a
  // worker that reports green and then dies on the first query leaves
  // `topos_screen` with creation ENABLED and no warning banner, which is
  // exactly the L1 silent-data-loss shape the storage verdict exists to end.
  group('verifyDatabaseUsable', () {
    test(
      'a database that cannot answer a query is reported as unavailable, even '
      'though the connection layer never complained',
      () async {
        final container = ProviderContainer(
          overrides: [appDatabaseProvider.overrideWithValue(_brokenDatabase())],
        );
        addTearDown(container.dispose);

        expect(container.read(storageDurabilityProvider).isProbing, isTrue);

        await verifyDatabaseUsable(container);

        final verdict = container.read(storageDurabilityProvider);
        expect(verdict.unavailable, isTrue);
        expect(verdict.isEphemeral, isTrue);
        expect(verdict.unavailableReason, isNotNull);
      },
    );

    test('never rethrows — boot must not be taken down by the probe', () async {
      final container = ProviderContainer(
        overrides: [appDatabaseProvider.overrideWithValue(_brokenDatabase())],
      );
      addTearDown(container.dispose);

      await expectLater(verifyDatabaseUsable(container), completes);
    });

    test('a healthy database leaves the verdict exactly as it was', () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final container = ProviderContainer(
        overrides: [appDatabaseProvider.overrideWithValue(db)],
      );
      addTearDown(container.dispose);
      container.read(storageDurabilityProvider.notifier).report(
            const StorageDurability(backend: StorageBackend.opfsShared),
          );

      await verifyDatabaseUsable(container);

      expect(
        container.read(storageDurabilityProvider).backend,
        StorageBackend.opfsShared,
      );
      expect(container.read(storageDurabilityProvider).unavailable, isFalse);
    });
  });

  // Task #54 — the per-operation database bound, wired.
  //
  // Read the honest scope first: NOTHING here cures a hang. sqlite3's OPFS VFS
  // blocks on `Atomics.wait(int32View, _responseIndex, -1)` with no timeout
  // inside a web worker, and a Dart-side timeout does not release drift's
  // `_openingLock`. What is asserted below is only that our side stops waiting
  // silently, that the failure is NAMED, and that it reaches the machinery that
  // already exists to explain it.
  group('databaseQueryTimeoutProvider', () {
    test(
      'assertion 1 — is NULL under flutter test, because kIsWeb is permanently '
      'false there. This negative is the ONLY way the platform gate is '
      'observable at all; that it ENGAGES on web can only be shown in a real '
      'browser (integration_test/web_query_timeout_test.dart)',
      () {
        final container = ProviderContainer();
        addTearDown(container.dispose);

        expect(
          container.read(databaseQueryTimeoutProvider),
          isNull,
          reason: 'a non-null bound here would mean every flutter test — and '
              'every iOS/Android build — had silently acquired an executor '
              'identity change and a timeout it has no use for',
        );
      },
    );

    test(
      'assertion 2 — a database that never ANSWERS (not one that throws) is '
      'reported as unavailable, with the bound named in the reason',
      () async {
        // As faithful as `flutter test` allows: the bound is taken FROM
        // `databaseQueryTimeoutProvider`, exactly as `appDatabaseProvider`
        // does, and only the executor is substituted — `openConnection()`
        // resolves the native seam here and opens a real, healthy sqlite file
        // that could never stall.
        final container = ProviderContainer(
          overrides: [
            databaseQueryTimeoutProvider.overrideWithValue(kTestQueryBound),
            appDatabaseProvider.overrideWith(
              (ref) => AppDatabase(
                bindQueryTimeout(
                  _HangingExecutor(),
                  timeout: ref.watch(databaseQueryTimeoutProvider),
                ),
              ),
            ),
          ],
        );
        addTearDown(container.dispose);

        await verifyDatabaseUsable(container);

        final verdict = container.read(storageDurabilityProvider);
        expect(verdict.unavailable, isTrue);
        expect(
          verdict.isEphemeral,
          isTrue,
          reason: 'the create-topo interlock blocks on exactly this — writes '
              'into a wedged worker will not land',
        );
        expect(
          verdict.unavailableReason,
          contains('TimeoutException'),
          reason: 'MasiAsyncView(showErrorDetail: true) and the release '
              '`masi/storage:` log line both render this string; "it did not '
              'answer" has to be IN it',
        );
        // `100ms`, not `0s` — `describeQueryBound`'s sub-second branch. Its
        // other branch (`30s`) is covered by assertion 3 below.
        expect(verdict.unavailableReason, contains('within 100ms'));
      },
    );
  });

  group('StorageStallReporter', () {
    /// A container already holding the verdict production actually measures.
    (ProviderContainer, StorageStallReporter) reporterOver(
      StorageDurability initial,
    ) {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(storageDurabilityProvider.notifier).report(initial);
      return (
        container,
        StorageStallReporter(
          current: () => container.read(storageDurabilityProvider),
          report: container.read(storageDurabilityProvider.notifier).report,
          timeout: kDatabaseQueryTimeout,
        ),
      );
    }

    test(
      'assertion 3 — the stall verdict carries measuredBackend and '
      'missingFeatures FORWARD. This re-guards the regression commit 340ba7b '
      'fixed: plain StorageDurability.unavailable() hard-zeroes both fields, '
      'and they are the ONLY field-diagnosable facts this app ever learns '
      "about a browser's storage — a real field report came back with no "
      '`· missing: …` segment for exactly that reason',
      () {
        final (container, reporter) = reporterOver(_measuredInProduction);

        reporter.onStall();

        final verdict = container.read(storageDurabilityProvider);
        expect(verdict.unavailable, isTrue);
        expect(
          verdict.measuredBackend,
          StorageBackend.opfsLocks,
          reason: 'zeroed => StorageDurability.unavailable() crept back in',
        );
        expect(verdict.missingFeatures, {
          StorageMissingFeature.dedicatedWorkersInSharedWorkers,
        });
        expect(
          verdict.backend,
          isNull,
          reason: '`backend` means "in effect NOW", and a database that cannot '
              'be reached has no backend in effect',
        );
        expect(verdict.unavailableReason, contains('30s'));
      },
    );

    test(
      'assertion 4 — that one verdict lights up BOTH existing notices: the '
      'retry banner (storageRetryNotice) on every tab, and the create-topo '
      'interlock copy (storageBlockedNotice). No new UI was invented for this',
      () {
        final (container, reporter) = reporterOver(_measuredInProduction);

        reporter.onStall();
        final verdict = container.read(storageDurabilityProvider);

        expect(storageRetryNotice(verdict), isNotNull);
        expect(storageBlockedNotice(verdict), isNotNull);
        expect(
          verdict.unavailableCause,
          StorageUnavailableCause.failed,
          reason: 'a schemaDowngrade cause would suppress the retry notice and '
              'tell the user their intact library needs a newer app',
        );
      },
    );

    test(
      'assertion 5 — a success RESTORES the displaced verdict, so a merely-slow '
      'database is not permanently branded broken',
      () {
        final (container, reporter) = reporterOver(_measuredInProduction);

        reporter.onStall();
        expect(container.read(storageDurabilityProvider).unavailable, isTrue);

        reporter.onRecovered();

        expect(
          container.read(storageDurabilityProvider),
          _measuredInProduction,
          reason: 'the exact verdict the connection layer had measured, back '
              'again — not a fresh `probing`, which would hide a real problem',
        );
      },
    );

    test(
      'assertion 6 — a THIRD verdict published BETWEEN the stall and the '
      'success SURVIVES: a later verdict is a newer fact. Revert the '
      '`current() != published` guard and the restore becomes unconditional, '
      'resurrecting a stale verdict over a fresher one',
      () {
        final (container, reporter) = reporterOver(_measuredInProduction);

        reporter.onStall();
        // e.g. boot's storage deadline, or a storage retry, landing its own
        // verdict while the query is still stalled.
        const fresher = StorageDurability(backend: StorageBackend.inMemory);
        container.read(storageDurabilityProvider.notifier).report(fresher);

        reporter.onRecovered();

        expect(container.read(storageDurabilityProvider), fresher);
      },
    );

    test(
      'onRecovered without a preceding stall does nothing at all — the healthy '
      'path must not publish verdicts',
      () {
        final (container, reporter) = reporterOver(_measuredInProduction);

        reporter.onRecovered();

        expect(container.read(storageDurabilityProvider), _measuredInProduction);
      },
    );

    test(
      'a stall with nowhere to report (the container is gone) is logged and '
      'dropped, never thrown — this fires from a microtask, where an '
      'unhandled error is nobody\'s to catch',
      () {
        final reporter = StorageStallReporter(
          current: () => throw StateError('the provider container is gone'),
          report: (_) => fail('nothing can be reported with no verdict to read'),
          timeout: kDatabaseQueryTimeout,
        );

        expect(reporter.onStall, returnsNormally);
        expect(reporter.onRecovered, returnsNormally);
      },
    );
  });
}
