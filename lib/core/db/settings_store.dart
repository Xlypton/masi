import 'package:drift/drift.dart';

import 'app_database.dart';

/// Tiny async key/value facade over the local-only `AppSettings` drift table
/// (see `tables.dart`). Deliberately minimal — three methods, `String` values
/// only — because its single purpose is small device-scoped state that must
/// survive a sign-out and an app restart on BOTH web and native without
/// introducing a second persistence mechanism.
///
/// Every method is best-effort from the caller's point of view in the sense
/// that it does no validation beyond the table's own PK constraint; callers
/// that must never fail boot (see `LastKnownUid.hydrate`) guard their own
/// call sites.
class SettingsStore {
  SettingsStore(this._db, {required this.nowMs});

  final AppDatabase _db;
  final int Function() nowMs;

  /// Key under which the last uid that held a real session on this device is
  /// stored. See `auth_providers.dart`'s `LastKnownUid` for the lifecycle:
  /// written on every session-bearing auth emission, cleared ONLY on a
  /// user-initiated sign-out.
  static const String lastKnownUidKey = 'lastKnownUid';

  Future<String?> read(String key) async {
    final row = await (_db.select(_db.appSettings)
          ..where((t) => t.settingKey.equals(key)))
        .getSingleOrNull();
    return row?.settingValue;
  }

  Future<void> write(String key, String value) {
    return _db
        .into(_db.appSettings)
        .insertOnConflictUpdate(
          AppSettingsCompanion.insert(
            settingKey: key,
            settingValue: Value(value),
            updatedAt: nowMs(),
          ),
        );
  }

  Future<void> remove(String key) {
    return (_db.delete(_db.appSettings)
          ..where((t) => t.settingKey.equals(key)))
        .go();
  }
}
