/// The one exception `AppDatabase`'s migration strategy raises itself.
library;

/// Thrown when an OLDER app shell opens a NEWER local database.
///
/// Audit item L7. drift dispatches `MigrationStrategy.onUpgrade` for any
/// version CHANGE, not just an increase — `OpeningDetails.hadUpgrade` is
/// `!wasCreated && versionBefore != versionNow` (drift 2.34.2,
/// `src/runtime/query_builder/migration.dart:647`), and
/// `DatabaseConnectionUser.beforeOpen` branches on exactly that
/// (`src/runtime/api/db_base.dart:131-137`). Every branch in `AppDatabase`'s
/// `onUpgrade` is `if (from < N)`, so a downgrade runs none of them, returns
/// normally, and then `DelegatedDatabase._runMigrations` stamps the OLDER
/// number into `PRAGMA user_version`
/// (`src/runtime/executor/helpers/engines.dart:558-563`). The database now
/// claims to be a version it is not; the next current-shell load re-runs the
/// intervening `if (from < N)` branches against objects that already exist and
/// throws, and the user's library is behind a database that will not open.
///
/// Throwing from `onUpgrade` is what prevents that: the throw propagates out
/// of `beforeOpen` at `engines.dart:557`, so the `setSchemaVersion` call on
/// line 562 never runs and `user_version` is left exactly as it was. No rows
/// are read, written, or dropped on this path — the failure is total and
/// non-destructive, which is the only acceptable outcome for a data-loss path.
/// drift then remembers the failure (`_migrationError`, `engines.dart:505-507`)
/// and rethrows it from every later query on that connection, so there is no
/// retry that can slip past into a half-migrated database.
///
/// On web this becomes reachable in Stage 2: the service worker is
/// network-first with `skipWaiting`, so one load can pair a cached older
/// `main.dart.wasm` with a local database a newer build already migrated. On
/// native it is effectively unreachable (the binary and its schema ship
/// together) but the guard is free and correct there too.
///
/// **This message is user-visible, not just log output.** `verifyDatabaseUsable`
/// (`database_provider.dart`) turns the refusal into
/// `StorageDurability.unavailable`, which raises the storage banner and
/// disables both create-topo affordances; and the topos list's `error:` branch
/// renders `Something went wrong: $error` verbatim
/// (`features/library/presentation/topos_screen.dart:354`). So [toString] leads
/// with what the reader should DO and keeps the diagnostic pair (and the
/// greppable type name) in a trailing parenthetical for the `masi/storage:`
/// console line.
///
/// The remedy is genuinely "reload", but only while online: `web/sw.js` is
/// network-first with a 4s timeout and a CACHE FALLBACK, so an offline reload
/// re-serves the very same stale shell and lands right back here. Hence the
/// explicit "reconnect first" clause — without it the advice quietly fails for
/// the offline user, who is the one this whole stage exists for.
class SchemaDowngradeException implements Exception {
  const SchemaDowngradeException({
    required this.storedVersion,
    required this.appVersion,
  });

  /// `PRAGMA user_version` as found on disk — what the data was last written
  /// by.
  final int storedVersion;

  /// `AppDatabase.schemaVersion` of the shell that just tried to open it.
  final int appVersion;

  @override
  String toString() =>
      'This version of the app is older than your saved data, so it refused '
      'to open your library rather than damage it. Nothing has been changed '
      'or deleted. Reload to pick up the current version of the app — if you '
      'are offline, reconnect first, because the reload has to fetch it. '
      '(SchemaDowngradeException: local database schema version '
      '$storedVersion, this build understands version $appVersion)';
}
