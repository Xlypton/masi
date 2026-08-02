import 'dart:io';

import 'package:drift/drift.dart' show LazyDatabase;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/core/db/schema_downgrade.dart';
import 'package:masi/core/db/storage_durability_provider.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as raw;

/// Audit item L7 — "a stale shell rewrites `user_version` backwards".
///
/// drift dispatches `onUpgrade` for ANY version change, not just an increase:
/// `OpeningDetails.hadUpgrade => !wasCreated && versionBefore != versionNow`
/// (drift 2.34.2, `src/runtime/query_builder/migration.dart:647`), and
/// `DatabaseConnectionUser.beforeOpen` branches on exactly that
/// (`src/runtime/api/db_base.dart:131-137`). Every branch in
/// `AppDatabase.migration`'s `onUpgrade` is `if (from < N)`, so opening a v9
/// database with an older shell runs NO branch — and then
/// `DelegatedDatabase._runMigrations`
/// (`src/runtime/executor/helpers/engines.dart:556-563`) stamps
/// `user_version = 8` onto a v9 file, because `setSchemaVersion` is called on
/// line 562 only AFTER `beforeOpen` returns normally on line 557. The next
/// current-shell load then re-runs the intervening `if (from < 9)` branches
/// against objects that already exist, with the user's library behind it.
///
/// This was low-likelihood while `web/_headers` served everything `no-cache`.
/// The Stage 2 service worker is network-first with `skipWaiting`, which makes
/// a genuinely stale shell possible for the first time — one load can pair a
/// cached older `main.dart.wasm` with a local database a newer build already
/// migrated. That is why the guard ships alongside it.
///
/// Runs on the Dart VM against a real on-disk `NativeDatabase`, because the
/// bug is about a value PERSISTED across two separate opens — an in-memory
/// database cannot express it. The guard itself lives in `lib/core/db/`, so
/// native gets the identical protection.

/// An [AppDatabase] pinned to an arbitrary [schemaVersion] — used here at one
/// version BEHIND the real one, the exact shape of a browser holding a cached
/// shell from the previous deploy.
///
/// The version is injected rather than hardcoded to 8 so this file keeps
/// testing "exactly one version behind" after the next schema bump, instead of
/// quietly becoming a two-versions-behind test.
class _PinnedVersionDatabase extends AppDatabase {
  _PinnedVersionDatabase(super.e, this.schemaVersion);

  @override
  final int schemaVersion;
}

/// `PRAGMA user_version` read from the file WITHOUT going through drift.
///
/// This must not be an `AppDatabase` open. Pre-guard, a downgrade leaves the
/// file stamped v8 while its tables are v9 — and re-opening that with the real
/// `AppDatabase` would run the `from < 9` branch, whose `m.createTable` emits
/// `CREATE TABLE IF NOT EXISTS` (drift 2.34.2,
/// `src/runtime/query_builder/migration.dart:319`), succeed as a no-op, and
/// stamp `user_version` back to 9. A drift-based probe would therefore report
/// 9 in both the guarded and the unguarded case and prove nothing at all.
/// `package:sqlite3` is a dev dependency (`pubspec.yaml:100`), so a test may
/// read the byte of interest directly and read-only.
int _userVersion(File file) {
  final db = raw.sqlite3.open(file.path, mode: raw.OpenMode.readOnly);
  try {
    return db.select('PRAGMA user_version').first.values.first! as int;
  } finally {
    db.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late File dbFile;

  /// The live [AppDatabase.schemaVersion], read once from a throwaway that is
  /// closed again immediately. `NativeDatabase.memory()` sits behind drift's
  /// `LazyDatabase`, so this never actually opens sqlite; closing it keeps
  /// drift's "created the database class multiple times" warning quiet for the
  /// real instances below.
  late final int currentVersion;
  late final int olderShellVersion;

  setUpAll(() async {
    final probe = AppDatabase(NativeDatabase.memory());
    currentVersion = probe.schemaVersion;
    olderShellVersion = currentVersion - 1;
    await probe.close();
  });

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('masi_schema_downgrade');
    dbFile = File(p.join(tempDir.path, 'app.sqlite'));
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  /// Creates the database at the CURRENT schema version with one identifiable
  /// row in it, so "did we lose data" is answerable and not just "did the
  /// pragma move".
  Future<int> seedCurrentVersionDatabase(String areaId) async {
    final current = AppDatabase(NativeDatabase(dbFile));
    await current.into(current.areas).insert(
          AreasCompanion.insert(
            id: areaId,
            name: 'Downgrade probe',
            createdAt: 1,
            updatedAt: 1,
          ),
        );
    final version = current.schemaVersion;
    await current.close();
    return version;
  }

  test(
    'an older shell opening a newer database throws instead of downgrading it',
    () async {
      final createdAtVersion = await seedCurrentVersionDatabase(
        'downgrade-probe-area',
      );
      expect(_userVersion(dbFile), createdAtVersion);

      // Open the SAME file with a shell that only understands the previous
      // version.
      final older = _PinnedVersionDatabase(
        NativeDatabase(dbFile),
        olderShellVersion,
      );
      Object? thrown;
      try {
        await older.select(older.areas).get();
      } catch (error) {
        thrown = error;
      }
      await older.close();

      // THE assertion, checked FIRST because it is the property that matters:
      // pre-guard this reads `createdAtVersion - 1`, i.e. the older shell has
      // already renumbered a database whose tables it does not understand.
      expect(
        _userVersion(dbFile),
        createdAtVersion,
        reason: 'user_version must be untouched — engines.dart:562 only calls '
            'setSchemaVersion AFTER beforeOpen returns on line 557, so the '
            'throw is what protects it',
      );

      expect(
        thrown,
        isA<SchemaDowngradeException>(),
        reason: 'the older shell must refuse the database, not silently '
            'renumber it. Got: $thrown',
      );
      final downgrade = thrown! as SchemaDowngradeException;
      expect(downgrade.storedVersion, createdAtVersion);
      expect(downgrade.appVersion, createdAtVersion - 1);
    },
  );

  test('the data survives a refused downgrade', () async {
    await seedCurrentVersionDatabase('survivor');

    final older = _PinnedVersionDatabase(
      NativeDatabase(dbFile),
      olderShellVersion,
    );
    await expectLater(
      older.select(older.areas).get(),
      throwsA(isA<SchemaDowngradeException>()),
    );
    await older.close();

    final reopened = AppDatabase(NativeDatabase(dbFile));
    addTearDown(reopened.close);
    final areas = await reopened.select(reopened.areas).get();
    expect(areas.map((a) => a.id), contains('survivor'));
  });

  test('every query keeps being refused, not just the first', () async {
    await seedCurrentVersionDatabase('sticky');

    final older = _PinnedVersionDatabase(
      NativeDatabase(dbFile),
      olderShellVersion,
    );
    addTearDown(older.close);

    // drift caches a failed migration in `_migrationError` and rethrows it
    // from every later `ensureOpen` (`engines.dart:505-507`), so the refusal
    // is a permanent property of the connection rather than a one-shot that a
    // retry could slip past into a half-migrated database.
    await expectLater(
      older.select(older.areas).get(),
      throwsA(isA<SchemaDowngradeException>()),
    );
    await expectLater(
      older.customSelect('SELECT 1').get(),
      throwsA(isA<SchemaDowngradeException>()),
    );
  });

  test('a real upgrade still runs — the guard only blocks the other direction',
      () async {
    // Create the file with the OLDER shell, so it is genuinely stamped one
    // version behind, then open it with the current one. That is `from < to`,
    // the legitimate direction, and it must migrate and re-stamp as usual.
    final older = _PinnedVersionDatabase(
      NativeDatabase(dbFile),
      olderShellVersion,
    );
    await older.customSelect('SELECT 1').get();
    final olderVersion = older.schemaVersion;
    await older.close();
    expect(_userVersion(dbFile), olderVersion);

    final current = AppDatabase(NativeDatabase(dbFile));
    addTearDown(current.close);
    expect(await current.customSelect('SELECT 1').get(), hasLength(1));
    expect(_userVersion(dbFile), current.schemaVersion);
  });

  test('SchemaDowngradeException names both versions in its message', () {
    const exception = SchemaDowngradeException(
      storedVersion: 9,
      appVersion: 8,
    );
    // Both numbers, in phrases that say which is which — a bare `contains('9')`
    // would be satisfied by any stray digit and would prove nothing.
    expect('$exception', contains('schema version 9'));
    expect('$exception', contains('understands version 8'));
    // The topos screen's `error:` branch renders `Something went wrong:
    // $error` verbatim (`topos_screen.dart:354`), so this string is read by a
    // climber at a crag, not only by a log grepper. It has to say what to DO,
    // and the fix for an old shell against a newer database is to reload into
    // the current shell.
    expect('$exception', contains('Reload to pick up the current version'));
    // …and that reload only works online: `web/sw.js` is network-first with a
    // 4s timeout and a cache fallback, so an offline reload re-serves the same
    // stale shell. Advice that silently fails for the offline user would be
    // worse than none, this stage being about offline in the first place.
    expect('$exception', contains('reconnect first'));
    // …while still carrying the greppable type name for the `masi/storage:`
    // release log line, which is the only handle on a field report.
    expect('$exception', contains('SchemaDowngradeException'));
  });

  test(
    'a refused downgrade surfaces as StorageDurability.unavailable, so the '
    'storage banner explains it and the create-topo interlock engages',
    () async {
      await seedCurrentVersionDatabase('interlocked');

      final older = _PinnedVersionDatabase(
        NativeDatabase(dbFile),
        olderShellVersion,
      );
      addTearDown(older.close);
      final container = ProviderContainer(
        overrides: [appDatabaseProvider.overrideWithValue(older)],
      );
      addTearDown(container.dispose);

      expect(container.read(storageDurabilityProvider).isProbing, isTrue);

      // Exactly what `bootApp` awaits before the first frame
      // (`lib/main.dart`), so this is the production path, not a stand-in.
      await verifyDatabaseUsable(container);

      final verdict = container.read(storageDurabilityProvider);
      expect(verdict.unavailable, isTrue);
      expect(
        verdict.isProbing,
        isFalse,
        reason: 'an unanswerable database is a verdict, not an absence of one',
      );
      expect(
        verdict.isEphemeral,
        isTrue,
        reason: "this is what disables BOTH create-topo affordances in "
            'topos_screen — nothing may be written into a database we are '
            'refusing to open',
      );
      expect(verdict.unavailableReason, contains('SchemaDowngradeException'));
      expect(verdict.unavailableReason, contains('Reload'));
      // Typed, not sniffed from the reason string: the storage banner has to
      // tell this case apart from "storage is broken" to avoid telling a user
      // with an intact library that their topos cannot be saved. A substring
      // check would rot the first time the message is reworded.
      expect(
        verdict.unavailableCause,
        StorageUnavailableCause.schemaDowngrade,
      );
    },
  );

  test(
    'an ordinary unusable database is NOT classified as a schema downgrade',
    () async {
      // Guards the discriminator against the lazy implementation that marks
      // every failure a downgrade and shows "your topos are safe" over a
      // genuinely broken storage backend.
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(
            AppDatabase(LazyDatabase(() async => throw StateError('no disk'))),
          ),
        ],
      );
      addTearDown(container.dispose);

      await verifyDatabaseUsable(container);

      final verdict = container.read(storageDurabilityProvider);
      expect(verdict.unavailable, isTrue);
      expect(verdict.unavailableCause, StorageUnavailableCause.failed);
    },
  );
}
