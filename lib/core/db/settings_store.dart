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

  /// When this device last LOOKED at the Community Feed, per account — the
  /// baseline the Feed tab's unseen dot compares new arrivals against.
  ///
  /// Lives here, in the local-only device store, rather than in a synced
  /// table, because "have I looked at this yet" is a property of a screen on a
  /// device and not of the account. Syncing it would mean reading the feed on
  /// a laptop silently clears the dot on a phone that has genuinely never
  /// shown the user those rows.
  ///
  /// Keyed by uid so switching accounts on one device does not inherit the
  /// other's baseline; signed-out gets its own bucket rather than sharing one
  /// with whoever signed in last.
  static String feedLastSeenKey(String? uid) =>
      'feedLastSeenAt:${uid ?? 'anon'}';

  /// Whether this device has ever finished drawing a route, which is what
  /// retires the draw-mode "tap to place points" hint.
  ///
  /// Deliberately NOT keyed by uid, unlike [feedLastSeenKey]. Knowing how to
  /// draw is a property of the PERSON holding the phone, not of the account
  /// they happen to be signed into — showing a climber the beginner hint again
  /// because they switched accounts would be telling them something they
  /// visibly already know. Device-scoped is also the honest default for a
  /// local-only store: it survives sign-out, which is exactly right here.
  static const String hasDrawnRouteKey = 'hasDrawnRoute';

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
