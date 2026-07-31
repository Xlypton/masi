# §1c-A — `lastKnownUid` + the single uid door

Fragment of the Stage-1 plan for `docs/superpowers/specs/2026-07-30-web-offline-reliability-design.md` §1c,
items **1** (persist `lastKnownUid`) and **2** (unify the uid door). Fixes **L4**'s read half and the
**native silent-empty-library bug**.

**Out of scope here** (other fragments): the web router's fail-closed `hasError` redirect (§1c-3) and the
affected-row-count guards on `_ownOrUnowned` mutations (§1c-4).

Baseline to keep green: `flutter analyze` **0 issues**, `flutter test` **1576 passing**.

---

## Public symbols this fragment produces

Contract-dictated (consumed by the router fragment):

| Symbol | File | Type |
|---|---|---|
| `lastKnownUidProvider` | `lib/features/account/application/auth_providers.dart` | `NotifierProvider<LastKnownUid, String?>` |
| `effectiveUidProvider` | same | `Provider<String?>` |
| `hasKnownLocalSessionProvider` | same | `Provider<bool>` |

Supporting symbols this fragment also introduces (all named, none renameable by later fragments):

| Symbol | File |
|---|---|
| `class LastKnownUid extends Notifier<String?>` (`hydrate()` / `remember(String)` / `forget()`) | `lib/features/account/application/auth_providers.dart` |
| `enum AuthSignOutCause { userInitiated, sessionExpired, sessionMissing, unknown }` | `lib/features/account/data/auth_repository.dart` |
| `AuthSignOutCause? authSignOutCauseFrom(SignOutReason?)` | same |
| `AuthSessionState.signOutCause` field + `AuthSessionState.signedOut({AuthSignOutCause? cause})` | same |
| `class AppSettings extends Table` (row class `AppSettingRow`) | `lib/core/db/tables.dart` |
| `class SettingsStore` + `SettingsStore.lastKnownUidKey` | `lib/core/db/settings_store.dart` |
| `settingsStoreProvider` | `lib/core/db/database_provider.dart` |
| `void handleAuthStateForLastKnownUid(...)` | `lib/app/last_known_uid_bootstrap.dart` |

`currentUidProvider` **keeps its name and its `Provider<String? Function()>` type** — its body is
redefined to delegate to `effectiveUidProvider`, so all seven existing repository providers
(`database_provider.dart:33`, `:53`; `library_providers.dart:23`; `ascents_providers.dart:14`;
`profile_providers.dart:14`; `likes_providers.dart:14`; `comments_providers.dart:17`) inherit the
fallback with **zero edits**. That is the "consistent helper, not scattered ad-hoc edits" choice.

---

## Persistence mechanism — decision + justification

**There is no existing small-settings mechanism in this repo.** Verified: `grep -rn
"shared_preferences\|SharedPreferences" lib` → 0 hits, absent from `pubspec.yaml`; `lib/core/db/tables.dart`
declares 9 tables and none is a settings/KV table; the one existing "setting"
(`WifiOnlySetting`, `backup_providers.dart:44`) is an in-memory `Notifier` that persists nothing.

So the only durable local store that already exists on **both** targets with **one** implementation is
**drift**. On web the session itself lives in `window.localStorage`; on native it lives in
SharedPreferences-via-`supabase_flutter` — neither is reachable through a shared seam, and adding
`shared_preferences` would mean a new package **plus** a new conditional-import seam.

Therefore: a **local-only drift KV table** (`AppSettings`, schema **v8 → v9**, a pure
`m.createTable` exactly like the v7→v8 `Profiles` migration). It is deliberately **not** a
`SyncColumns` table and is **not** added to `syncTableNames` (`sync_remote.dart:34-44`) nor to
`BackupRepository`'s hand-enumerated export/import lists (`backup_repository.dart:46-67`, `:98-140`),
both of which enumerate tables explicitly — so device-local state can never leak to the cloud.

**Known side effect, mitigated:** `SyncOrchestrator.build` listens to unfiltered
`db.tableUpdates()` (`sync_orchestrator.dart:159`), so *any* drift write schedules a debounced push.
`LastKnownUid.remember` therefore **short-circuits when `state == uid`**, so the once-per-hour
`tokenRefreshed` re-emission writes nothing. Only a genuine account change writes — and that
*should* trigger a push. Asserted in Task 3.

---

## Task 1: local-only `AppSettings` KV table + `SettingsStore` (schema v9)

**Files:**
- Modify `lib/core/db/tables.dart` (append after `SyncColumns`, before `Profiles` at `:36`)
- Modify `lib/core/db/app_database.dart:14-26` (tables list), `:31` (`schemaVersion`), `:190-192` (add the `from < 9` branch after the existing `from < 8` branch)
- Create `lib/core/db/settings_store.dart`
- Modify `lib/core/db/database_provider.dart:20` (add `settingsStoreProvider` after `nowMsProvider` at `:24-27`)
- Regenerate `lib/core/db/app_database.g.dart` (build_runner)
- Test: create `test/core/db/settings_store_test.dart`
- Test: modify `test/core/db/app_database_test.dart:16-18` (`schemaVersion is 8` → `9`)
- Test: modify `test/core/db/app_database_migration_test.dart:1793` (group `fresh onCreate`, table-name set at `:1806-1818`) + append a new v8→v9 group

**Interfaces:**
- Produces `class AppSettings extends Table` → drift getter `appSettings`, row class `AppSettingRow`, companion `AppSettingsCompanion`, SQL table `app_settings`, columns `setting_key` (TEXT PK) / `setting_value` (TEXT NULL) / `updated_at` (INT NOT NULL).
- Produces:
  ```dart
  class SettingsStore {
    SettingsStore(AppDatabase db, {required int Function() nowMs});
    static const String lastKnownUidKey = 'lastKnownUid';
    Future<String?> read(String key);
    Future<void> write(String key, String value);
    Future<void> remove(String key);
  }
  final settingsStoreProvider = Provider<SettingsStore>(...);
  ```

- [ ] **Step 1: Write the failing test** — `test/core/db/settings_store_test.dart`:

```dart
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/settings_store.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late SettingsStore store;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    store = SettingsStore(db, nowMs: () => 4242);
  });

  tearDown(() async {
    await db.close();
  });

  test('read returns null for a key that was never written', () async {
    expect(await store.read('nope'), isNull);
  });

  test('write then read round-trips the value', () async {
    await store.write(SettingsStore.lastKnownUidKey, 'user-u1');
    expect(await store.read(SettingsStore.lastKnownUidKey), 'user-u1');
  });

  test('write is an upsert: the second value replaces the first', () async {
    await store.write(SettingsStore.lastKnownUidKey, 'user-u1');
    await store.write(SettingsStore.lastKnownUidKey, 'user-u2');
    expect(await store.read(SettingsStore.lastKnownUidKey), 'user-u2');
    final rows = await db.select(db.appSettings).get();
    expect(rows, hasLength(1), reason: 'upsert must not accumulate rows');
    expect(rows.single.updatedAt, 4242);
  });

  test('remove deletes the key so read returns null again', () async {
    await store.write(SettingsStore.lastKnownUidKey, 'user-u1');
    await store.remove(SettingsStore.lastKnownUidKey);
    expect(await store.read(SettingsStore.lastKnownUidKey), isNull);
    expect(await db.select(db.appSettings).get(), isEmpty);
  });

  test('remove on an absent key is a silent no-op', () async {
    await store.remove('never-written');
    expect(await store.read('never-written'), isNull);
  });

  test('app_settings is NOT a synced table', () async {
    // Guards the "device state must never reach the cloud" invariant.
    expect(
      const [
        'profiles', 'areas', 'sectors', 'walls', 'photos',
        'routes', 'ascents', 'comments', 'likes',
      ],
      isNot(contains('app_settings')),
    );
  });
}
```

Append this group to `test/core/db/app_database_migration_test.dart` (before the final `}` of `main`):

```dart
  group('v8 -> v9 migration (local-only app_settings KV table)', () {
    late Directory tempDir;
    late File dbFile;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('masi_v9_migration_');
      dbFile = File(p.join(tempDir.path, 'v8.sqlite'));
    });

    tearDown(() async {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    test(
      'creates app_settings on an existing v8 database without losing rows',
      () async {
        // Build a REAL current-schema file via onCreate, seed a row, then
        // rewind it to the pre-v9 shape on disk (drop the new table, stamp
        // user_version = 8). Reopening then forces drift down the
        // onUpgrade(m, 8, 9) path a real updating device takes.
        final fresh = AppDatabase(NativeDatabase(dbFile));
        await fresh
            .into(fresh.areas)
            .insert(
              AreasCompanion.insert(
                id: 'area-v8',
                createdAt: 100,
                updatedAt: 100,
                name: 'Pre-v9 Area',
              ),
            );
        await fresh.close();

        final raw = sqlite3lib.sqlite3.open(dbFile.path);
        raw.execute('DROP TABLE app_settings; PRAGMA user_version = 8;');
        expect(raw.select('PRAGMA user_version;').first.values.first, 8);
        raw.close();

        final db = AppDatabase(NativeDatabase(dbFile));
        addTearDown(db.close);

        // Forces the migration to actually run (drift is lazy).
        final area = await (db.select(db.areas)
              ..where((t) => t.id.equals('area-v8')))
            .getSingle();
        expect(
          area.name,
          'Pre-v9 Area',
          reason: 'pre-existing row must survive the v8 -> v9 migration',
        );

        final tableNames = await db
            .customSelect(
              "SELECT name FROM sqlite_master WHERE type = 'table' "
              "AND name NOT LIKE 'sqlite_%'",
            )
            .map((row) => row.read<String>('name'))
            .get();
        expect(
          tableNames,
          contains('app_settings'),
          reason: 'the from < 9 branch must createTable(appSettings)',
        );

        // The new table is usable immediately after the migration.
        final store = SettingsStore(db, nowMs: () => 900);
        await store.write(SettingsStore.lastKnownUidKey, 'user-u1');
        expect(await store.read(SettingsStore.lastKnownUidKey), 'user-u1');
      },
    );
  });
```

That group needs `import 'package:masi/core/db/settings_store.dart';` added to the file's imports
(`dart:io`, `p`, `sqlite3lib`, `AreasCompanion` are already imported — verified at `:1-8`).

Also change `test/core/db/app_database_test.dart:16-17` to:

```dart
  test('schemaVersion is 9', () {
    expect(db.schemaVersion, 9);
  });
```

and add `'app_settings',` to the expected set in `app_database_migration_test.dart:1806-1818`.

- [ ] **Step 2: Run it, see it fail**
```bash
export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test test/core/db/settings_store_test.dart test/core/db/app_database_test.dart
```
Expected: `settings_store_test.dart` fails to **compile** —
`Error: Couldn't resolve the package 'masi' URI 'package:masi/core/db/settings_store.dart'` /
`Error: The getter 'appSettings' isn't defined for the class 'AppDatabase'`.
`app_database_test.dart` fails with `Expected: 9  Actual: 8`.

- [ ] **Step 3: Minimal implementation**

`lib/core/db/tables.dart` — append after the `SyncColumns` mixin (`:23`):

```dart
/// LOCAL-ONLY key/value store for tiny device-scoped settings. Deliberately
/// does NOT mix in [SyncColumns] and is deliberately absent from
/// `syncTableNames` (`features/backup/data/sync_remote.dart`) and from
/// `BackupRepository`'s hand-enumerated export/import lists — both enumerate
/// tables explicitly, so nothing here can ever reach the cloud. This is where
/// state that must survive a *sign-out* lives, which is exactly why it must
/// not be owned by, keyed by, or synced with any account.
///
/// Introduced (schema v9) for `lastKnownUid` — see
/// `features/account/application/auth_providers.dart`'s [LastKnownUid]. Drift
/// is used rather than `shared_preferences` because it is the ONLY durable
/// local store this repo already has on both web (OPFS/IndexedDB) and native
/// (SQLite file), with one implementation and no conditional-import seam.
@DataClassName('AppSettingRow')
class AppSettings extends Table {
  /// Opaque setting name. Not called `key` — `KEY` is a SQLite keyword and
  /// `key` collides with `Widget.key` conventions in generated code.
  TextColumn get settingKey => text()();

  /// The setting's value, always TEXT (callers encode/decode). Nullable so a
  /// present-but-unset key is expressible; `SettingsStore.remove` deletes the
  /// row outright rather than nulling it.
  TextColumn get settingValue => text().nullable()();

  /// ms-epoch of the last write, from the injected `nowMs` clock seam — purely
  /// diagnostic (nothing reads it for behavior).
  IntColumn get updatedAt => integer()();

  @override
  Set<Column> get primaryKey => {settingKey};
}
```

`lib/core/db/app_database.dart` — add `AppSettings,` to the `tables:` list (`:14-26`), bump `:31` to
`int get schemaVersion => 9;`, and append after the `from < 8` branch (`:190-192`):

```dart
      // v8 -> v9: adds the local-only `AppSettings` key/value table (§1c),
      // the durable home of `lastKnownUid` — the uid local reads/writes are
      // scoped by when no live session is available (a captive-portal hard
      // sign-out, an offline token-refresh failure, or a cold boot before
      // Supabase resolves). Same shape as the v7 -> v8 `Profiles` addition: a
      // brand-new table unrelated to any existing row/column, so a pure
      // `m.createTable` with nothing to backfill and no pre-existing data
      // touched. NOT a SyncColumns table and NOT in `syncTableNames` — see
      // `tables.dart`'s `AppSettings` doc for why device state must never
      // sync.
      if (from < 9) {
        await m.createTable(appSettings);
      }
```

Create `lib/core/db/settings_store.dart`:

```dart
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
/// that must never fail boot (see [LastKnownUid.hydrate]) guard their own
/// call sites.
class SettingsStore {
  SettingsStore(this._db, {required this.nowMs});

  final AppDatabase _db;
  final int Function() nowMs;

  /// Key under which the last uid that held a real session on this device is
  /// stored. See `auth_providers.dart`'s [LastKnownUid] for the lifecycle:
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
```

`lib/core/db/database_provider.dart` — add `import 'settings_store.dart';` and, after `nowMsProvider`
(`:24-27`):

```dart
/// The shared [SettingsStore] over the local-only `AppSettings` table, wired
/// to the same [appDatabaseProvider]/[nowMsProvider] seams every repository
/// provider here uses. Override `appDatabaseProvider` in tests, as usual.
final settingsStoreProvider = Provider<SettingsStore>(
  (ref) => SettingsStore(
    ref.watch(appDatabaseProvider),
    nowMs: ref.watch(nowMsProvider),
  ),
);
```

Regenerate:
```bash
export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && dart run build_runner build --delete-conflicting-outputs
```

- [ ] **Step 4: Run it, see it pass**
```bash
export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test test/core/db/
export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter analyze
export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test
```

- [ ] **Step 5: Commit**
```bash
git add lib/core/db/tables.dart lib/core/db/app_database.dart lib/core/db/app_database.g.dart \
        lib/core/db/settings_store.dart lib/core/db/database_provider.dart \
        test/core/db/settings_store_test.dart test/core/db/app_database_test.dart \
        test/core/db/app_database_migration_test.dart
git commit -m "feat(db): local-only AppSettings KV table + SettingsStore (schema v9)

Durable home for device-scoped state that must survive a sign-out, starting
with lastKnownUid (§1c). Not a SyncColumns table and absent from
syncTableNames / BackupRepository's export lists, so it can never sync.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

**Assertions:**
1. `db.schemaVersion == 9`.
2. `SettingsStore` round-trips write→read, upserts in place (exactly 1 row after two writes), and `remove` deletes the row; `remove` on an absent key does not throw.
3. Opening a real on-disk v8 database (user_version stamped to 8, `app_settings` dropped) creates `app_settings` via `onUpgrade` **and** leaves a pre-existing `areas` row intact.
4. `grep -n "app_settings\|appSettings" lib/features/backup/` returns **nothing** — the new table is in neither `syncTableNames` nor `BackupRepository`'s enumerations.
5. Whole-project `flutter analyze` 0, `flutter test` green (1576 + 6 new, migration/onCreate table-set tests updated).

**What could go wrong:** (a) forgetting the `from < 9` branch — caught by the v8→v9 migration test (a fresh install would pass via `onCreate` and hide it, which is exactly why the test rewinds a real file); (b) drift naming the row class `AppSetting` and colliding with future code — avoided by the explicit `@DataClassName('AppSettingRow')`; (c) the table silently joining the sync payload — caught by assertion 4 plus the fact that both sync/backup table lists are hand-enumerated.

---

## Task 2: distinguish user-initiated sign-out from `sessionExpired`

**Files:**
- Modify `lib/features/account/data/auth_repository.dart:12-44` (`AuthSessionState`), `:147-152` (`authStateChanges`), `:154-156` (`currentSession`), `:193-198` (`_toSessionState`)
- Test: create `test/features/account/data/auth_sign_out_cause_test.dart`

**Interfaces:**
- Produces `enum AuthSignOutCause { userInitiated, sessionExpired, sessionMissing, unknown }`
- Produces `AuthSignOutCause? authSignOutCauseFrom(SignOutReason? reason)`
- Produces `final AuthSignOutCause? signOutCause` on `AuthSessionState`, plus
  `const AuthSessionState.signedOut({AuthSignOutCause? cause})` — **an optional named param, so all
  ~40 existing `const AuthSessionState.signedOut()` call sites in `lib/` and `test/` keep compiling
  unchanged**, and `operator ==`/`hashCode` stay email-only so no existing equality assertion breaks.

Real gotrue API (verified in `~/.pub-cache/hosted/pub.dev/gotrue-2.26.0`):
`AuthState` (`lib/src/types/auth_state.dart:5-23`) carries `AuthChangeEvent event`, `Session? session`,
`SignOutReason? signOutReason`, `bool fromBroadcast`. `enum SignOutReason` (`lib/src/types/sign_out_reason.dart:6-21`)
has exactly `userInitiated`, `sessionExpired`, `sessionMissing`. `signOutReason` is **`null` for every
event other than `AuthChangeEvent.signedOut`, and also null for a `signedOut` received cross-tab via
`BroadcastChannel`** — which is precisely why `null` must map to `unknown`/"do not clear", never to
"user initiated".

- [ ] **Step 1: Write the failing test** — `test/features/account/data/auth_sign_out_cause_test.dart`:

```dart
import 'package:masi/features/account/data/auth_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show SignOutReason;

void main() {
  group('authSignOutCauseFrom', () {
    test('maps every real gotrue SignOutReason case', () {
      expect(
        authSignOutCauseFrom(SignOutReason.userInitiated),
        AuthSignOutCause.userInitiated,
      );
      expect(
        authSignOutCauseFrom(SignOutReason.sessionExpired),
        AuthSignOutCause.sessionExpired,
      );
      expect(
        authSignOutCauseFrom(SignOutReason.sessionMissing),
        AuthSignOutCause.sessionMissing,
      );
    });

    test('covers the whole enum — a new gotrue case must not slip through', () {
      // If gotrue adds a case, this fails and forces an explicit decision
      // rather than silently mapping it to `unknown`.
      expect(SignOutReason.values, hasLength(3));
      for (final reason in SignOutReason.values) {
        expect(authSignOutCauseFrom(reason), isNotNull);
      }
    });

    test('a null reason is NOT user-initiated', () {
      // A cross-tab `signedOut` (fromBroadcast) and every non-signedOut event
      // carry a null reason. Treating null as user-initiated would clear
      // lastKnownUid on a mere token-refresh failure and re-open L4.
      expect(authSignOutCauseFrom(null), isNull);
      expect(authSignOutCauseFrom(null), isNot(AuthSignOutCause.userInitiated));
    });
  });

  group('AuthSessionState.signOutCause', () {
    test('defaults to null on the existing zero-arg signedOut ctor', () {
      const state = AuthSessionState.signedOut();
      expect(state.signOutCause, isNull);
      expect(state.isSignedIn, isFalse);
    });

    test('carries the cause when supplied', () {
      const state = AuthSessionState.signedOut(
        cause: AuthSignOutCause.userInitiated,
      );
      expect(state.signOutCause, AuthSignOutCause.userInitiated);
    });

    test('a signed-in state never carries a cause', () {
      final state = AuthSessionState.signedIn('a@b.c', uid: 'u1');
      expect(state.signOutCause, isNull);
    });

    test('equality stays email-only (unchanged contract)', () {
      // Existing assertions across account_screen_test.dart etc. rely on this.
      expect(
        const AuthSessionState.signedOut(cause: AuthSignOutCause.userInitiated),
        const AuthSessionState.signedOut(cause: AuthSignOutCause.sessionExpired),
      );
    });
  });
}
```

- [ ] **Step 2: Run it, see it fail**
```bash
export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test test/features/account/data/auth_sign_out_cause_test.dart
```
Expected: compile failure — `Error: Undefined name 'authSignOutCauseFrom'.` and
`Error: The getter 'signOutCause' isn't defined for the class 'AuthSessionState'.`

- [ ] **Step 3: Minimal implementation** — `lib/features/account/data/auth_repository.dart`.

Insert above `class AuthSessionState` (`:12`):

```dart
/// Why a session ended, as this app's own narrow enum rather than gotrue's
/// [SignOutReason].
///
/// Kept app-local (mapped by [authSignOutCauseFrom]) for two reasons: test
/// doubles like `FakeAuthRepository` can emit plain values without
/// constructing real Supabase types — the same rationale that keeps
/// [AuthSessionState] free of `Session`/`User` — and [unknown] exists here
/// with no gotrue counterpart, for a `signedOut` whose reason gotrue does not
/// report (a cross-tab `BroadcastChannel` sign-out, `AuthState.fromBroadcast`).
///
/// Only [userInitiated] is allowed to clear locally-scoped ownership state
/// (see `auth_providers.dart`'s [LastKnownUid.forget]). Everything else —
/// [sessionExpired] (a captive portal answering the refresh with an HTML body,
/// classified as a non-retryable `AuthUnknownException`, which is L4's
/// trigger), [sessionMissing], [unknown] — means "the network took the session
/// away", never "the user asked to be signed out".
enum AuthSignOutCause { userInitiated, sessionExpired, sessionMissing, unknown }

/// Maps gotrue's [SignOutReason] onto [AuthSignOutCause].
///
/// `null` in -> `null` out, deliberately: gotrue sets `signOutReason` only on
/// [AuthChangeEvent.signedOut], and leaves it null even there when the event
/// arrived cross-tab via `BroadcastChannel`. A null must therefore NEVER be
/// read as "user initiated" — doing so would clear `lastKnownUid` on a
/// transient refresh failure and re-open L4.
AuthSignOutCause? authSignOutCauseFrom(SignOutReason? reason) {
  return switch (reason) {
    SignOutReason.userInitiated => AuthSignOutCause.userInitiated,
    SignOutReason.sessionExpired => AuthSignOutCause.sessionExpired,
    SignOutReason.sessionMissing => AuthSignOutCause.sessionMissing,
    null => null,
  };
}
```

Then in `AuthSessionState` replace the two constructors (`:13-16`) and add the field after `uid` (`:31`):

```dart
  const AuthSessionState.signedOut({AuthSignOutCause? cause})
    : email = null,
      uid = null,
      signOutCause = cause;

  const AuthSessionState.signedIn(String signedInEmail, {this.uid})
    : email = signedInEmail,
      signOutCause = null;
```
```dart
  /// Why this signed-out state came about, or `null` when unknown / when this
  /// is a signed-in state. See [AuthSignOutCause]: ONLY
  /// [AuthSignOutCause.userInitiated] may clear locally-scoped ownership
  /// state. Like [uid], deliberately NOT part of [operator ==]/[hashCode] —
  /// equality stays keyed on [email] alone so existing equality-based
  /// assertions are unaffected.
  final AuthSignOutCause? signOutCause;
```

And update `toString` (`:42-43`) to
`'AuthSessionState(email: $email, uid: $uid, signOutCause: $signOutCause)'`.

Then in `SupabaseAuthRepository`, replace `:147-156` and `:193-198`:

```dart
  @override
  Stream<AuthSessionState> authStateChanges() {
    return _client.auth.onAuthStateChange.map(
      // `state.signOutReason` is gotrue's own, non-null only on a
      // `signedOut` event it originated itself — this is what lets §1c tell a
      // deliberate sign-out apart from an involuntary one WITHOUT parsing
      // error strings.
      (state) => _toSessionState(state.session, state.signOutReason),
    );
  }

  @override
  AuthSessionState get currentSession => _toSessionState(_client.auth.currentSession);
```
```dart
  static AuthSessionState _toSessionState(
    Session? session, [
    SignOutReason? reason,
  ]) {
    final email = session?.user.email;
    return (email == null || email.isEmpty)
        ? AuthSessionState.signedOut(cause: authSignOutCauseFrom(reason))
        : AuthSessionState.signedIn(email, uid: session?.user.id);
  }
```

(`_toSessionState`'s signed-out branch loses its `const`, since `cause` is now a runtime value — the
call site is a `.map` on a live stream, so this allocates nothing measurable.)

- [ ] **Step 4: Run it, see it pass**
```bash
export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test test/features/account/
export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter analyze && flutter test
```

- [ ] **Step 5: Commit**
```bash
git add lib/features/account/data/auth_repository.dart \
        test/features/account/data/auth_sign_out_cause_test.dart
git commit -m "feat(auth): thread SignOutReason through AuthSessionState as AuthSignOutCause

Nothing in lib/ read SignOutReason before (grep: 0 hits), so a captive-portal
sessionExpired sign-out was indistinguishable from a deliberate one. Needed by
§1c to clear lastKnownUid on user-initiated sign-out ONLY.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

**Assertions:**
1. All three real `SignOutReason` cases map to their `AuthSignOutCause` counterpart; `SignOutReason.values` has length 3 and every member maps non-null (so a gotrue upgrade adding a case fails loudly).
2. `authSignOutCauseFrom(null)` is `null` and is **not** `userInitiated`.
3. `const AuthSessionState.signedOut()` still compiles with zero args and yields `signOutCause == null`.
4. `AuthSessionState` equality is still email-only: two signed-out states with different causes compare equal.
5. Whole-project `flutter analyze` 0, `flutter test` green — **no existing test needed editing** (this is the check that the ctor change is source-compatible).

**What could go wrong:** making `cause` positional or required would break ~40 existing `AuthSessionState.signedOut()` call sites — assertion 3 + assertion 5 catch it. Adding `signOutCause` to `operator ==` would silently break `account_screen_test.dart`'s equality assertions — assertion 4 catches it.

---

## Task 3: `lastKnownUidProvider` / `effectiveUidProvider` / `hasKnownLocalSessionProvider`

**Files:**
- Modify `lib/features/account/application/auth_providers.dart:28-54` (rewrite `currentUidProvider`; add the three new providers + `LastKnownUid` above it)
- Create `lib/app/last_known_uid_bootstrap.dart`
- Modify `lib/main.dart:76-79` (add `hydrate()` to the awaited `Future.wait`)
- Modify `lib/app/app.dart:108-117` (add a second `ref.listen`, `fireImmediately: true`)
- Test: create `test/features/account/application/last_known_uid_test.dart`
- Test: create `test/app/last_known_uid_bootstrap_test.dart`

**Interfaces:**
```dart
// lib/features/account/application/auth_providers.dart
class LastKnownUid extends Notifier<String?> {
  @override String? build();
  Future<void> hydrate();
  Future<void> remember(String uid);
  Future<void> forget();
}
final lastKnownUidProvider = NotifierProvider<LastKnownUid, String?>(LastKnownUid.new);
final effectiveUidProvider = Provider<String?>((ref) { ... });
final hasKnownLocalSessionProvider = Provider<bool>((ref) => ref.watch(effectiveUidProvider) != null);
final currentUidProvider = Provider<String? Function()>((ref) => () => ref.read(effectiveUidProvider));

// lib/app/last_known_uid_bootstrap.dart
void handleAuthStateForLastKnownUid(
  AsyncValue<AuthSessionState> next, {
  required void Function(String uid) remember,
  required void Function() forget,
});
```
Consumes: `settingsStoreProvider` (Task 1), `AuthSignOutCause` (Task 2), `authStateProvider`,
`authRepositoryProvider`.

Verified Riverpod facts this design rests on: plain `Provider`/`NotifierProvider` default to
`isAutoDispose = false` (`riverpod-3.3.2/lib/src/providers/provider.dart:24`), so `lastKnownUidProvider`'s
state lives for the whole app run; `library_providers_test.dart:34-38`'s "auto-disposed by default"
comment is wrong. And `ref.watch` on a **StreamProvider** returns an `AsyncValue` and does not
rethrow a create-time failure — an uninitialized Supabase surfaces as a permanent `AsyncError`
(documented at `router.dart:106`, consumed at `:132`), never as a throw.

- [ ] **Step 1: Write the failing tests**

`test/app/last_known_uid_bootstrap_test.dart` (pure, no providers):

```dart
import 'package:masi/app/last_known_uid_bootstrap.dart';
import 'package:masi/features/account/data/auth_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late List<String> remembered;
  late int forgotten;

  setUp(() {
    remembered = [];
    forgotten = 0;
  });

  void run(AsyncValue<AuthSessionState> next) {
    handleAuthStateForLastKnownUid(
      next,
      remember: remembered.add,
      forget: () => forgotten++,
    );
  }

  test('a signed-in emission remembers the uid', () {
    run(AsyncData(AuthSessionState.signedIn('a@b.c', uid: 'user-u1')));
    expect(remembered, ['user-u1']);
    expect(forgotten, 0);
  });

  test('an account switch remembers the new uid', () {
    run(AsyncData(AuthSessionState.signedIn('a@b.c', uid: 'user-u1')));
    run(AsyncData(AuthSessionState.signedIn('b@b.c', uid: 'user-u2')));
    expect(remembered, ['user-u1', 'user-u2']);
    expect(forgotten, 0);
  });

  test('AsyncLoading touches nothing', () {
    run(const AsyncLoading());
    expect(remembered, isEmpty);
    expect(forgotten, 0);
  });

  test('AsyncError touches nothing — this is the offline-refresh case', () {
    // gotrue's 10s ticker addError()s an AuthRetryableFetchException on every
    // offline refresh attempt. That must not disturb lastKnownUid at all.
    run(AsyncError(Exception('AuthRetryableFetchException'), StackTrace.empty));
    expect(remembered, isEmpty);
    expect(forgotten, 0);
  });

  test('a sessionExpired sign-out does NOT forget (L4)', () {
    run(const AsyncData(
      AuthSessionState.signedOut(cause: AuthSignOutCause.sessionExpired),
    ));
    expect(forgotten, 0, reason: 'involuntary sign-out must keep the uid');
  });

  test('a sessionMissing sign-out does NOT forget', () {
    run(const AsyncData(
      AuthSessionState.signedOut(cause: AuthSignOutCause.sessionMissing),
    ));
    expect(forgotten, 0);
  });

  test('a cause-less (cross-tab / unknown) sign-out does NOT forget', () {
    run(const AsyncData(AuthSessionState.signedOut()));
    expect(forgotten, 0);
  });

  test('a userInitiated sign-out DOES forget', () {
    run(const AsyncData(
      AuthSessionState.signedOut(cause: AuthSignOutCause.userInitiated),
    ));
    expect(forgotten, 1);
    expect(remembered, isEmpty);
  });

  test('an empty uid is ignored rather than remembered', () {
    run(AsyncData(AuthSessionState.signedIn('a@b.c', uid: '')));
    expect(remembered, isEmpty);
    expect(forgotten, 0);
  });
}
```

`test/features/account/application/last_known_uid_test.dart`:

```dart
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/core/db/settings_store.dart';
import 'package:masi/features/account/application/auth_providers.dart';
import 'package:masi/features/account/data/auth_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Stream-driven [AuthRepository] double: [currentSession] is the synchronous
/// door `effectiveUidProvider` reads, [emit] drives `authStateProvider`.
/// Mirrors `FakeAuthRepository` in
/// `test/features/backup/data/sync_service_test.dart:287-307`, which only
/// needed `currentSession` (push/pull are one-shot) — this one adds the
/// stream half.
class StreamingFakeAuthRepository implements AuthRepository {
  StreamingFakeAuthRepository(this.currentSession);

  @override
  AuthSessionState currentSession;

  final _controller = StreamController<AuthSessionState>.broadcast();

  /// Sets [currentSession] AND pushes the same value down the stream, the way
  /// gotrue does (its synchronous getter and its stream never disagree).
  void emit(AuthSessionState state) {
    currentSession = state;
    _controller.add(state);
  }

  /// Pushes a stream error WITHOUT touching [currentSession] — exactly what
  /// gotrue's offline 10s refresh ticker does
  /// (`notifyException` -> `addError(AuthRetryableFetchException)`).
  void emitError(Object error) => _controller.addError(error);

  @override
  Stream<AuthSessionState> authStateChanges() => _controller.stream;

  @override
  Future<void> sendMagicLink(String email) async {}
  @override
  Future<void> signInWithGoogle() async {}
  @override
  Future<void> verifyEmailOtp(String email, String code) async {}
  @override
  Future<void> signOut() async {}

  Future<void> dispose() => _controller.close();
}

const _signedOut = AuthSessionState.signedOut();
final _signedInU1 = AuthSessionState.signedIn('u1@example.com', uid: 'user-u1');

void main() {
  late AppDatabase db;

  ({ProviderContainer container, StreamingFakeAuthRepository auth}) make({
    AuthSessionState initial = _signedOut,
  }) {
    db = AppDatabase(NativeDatabase.memory());
    final auth = StreamingFakeAuthRepository(initial);
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        nowMsProvider.overrideWithValue(() => 1000),
        authRepositoryProvider.overrideWithValue(auth),
      ],
    );
    addTearDown(db.close);
    addTearDown(container.dispose);
    addTearDown(auth.dispose);
    return (container: container, auth: auth);
  }

  group('LastKnownUid', () {
    test('build() starts null', () {
      final t = make();
      expect(t.container.read(lastKnownUidProvider), isNull);
    });

    test('remember writes through to SettingsStore and updates state', () async {
      final t = make();
      await t.container.read(lastKnownUidProvider.notifier).remember('user-u1');
      expect(t.container.read(lastKnownUidProvider), 'user-u1');
      expect(
        await t.container.read(settingsStoreProvider).read(
          SettingsStore.lastKnownUidKey,
        ),
        'user-u1',
      );
    });

    test('hydrate restores a persisted uid into state', () async {
      final t = make();
      await t.container
          .read(settingsStoreProvider)
          .write(SettingsStore.lastKnownUidKey, 'user-u1');
      expect(t.container.read(lastKnownUidProvider), isNull);
      await t.container.read(lastKnownUidProvider.notifier).hydrate();
      expect(t.container.read(lastKnownUidProvider), 'user-u1');
    });

    test('forget clears both state and the persisted value', () async {
      final t = make();
      final notifier = t.container.read(lastKnownUidProvider.notifier);
      await notifier.remember('user-u1');
      await notifier.forget();
      expect(t.container.read(lastKnownUidProvider), isNull);
      expect(
        await t.container.read(settingsStoreProvider).read(
          SettingsStore.lastKnownUidKey,
        ),
        isNull,
      );
    });

    test('re-remembering the same uid does not write again', () async {
      // SyncOrchestrator listens to UNFILTERED db.tableUpdates()
      // (sync_orchestrator.dart:159), so a redundant app_settings write would
      // schedule a full sync push on every hourly tokenRefreshed re-emission.
      final t = make();
      final notifier = t.container.read(lastKnownUidProvider.notifier);
      await notifier.remember('user-u1');
      await t.container
          .read(settingsStoreProvider)
          .remove(SettingsStore.lastKnownUidKey);
      await notifier.remember('user-u1');
      expect(
        await t.container.read(settingsStoreProvider).read(
          SettingsStore.lastKnownUidKey,
        ),
        isNull,
        reason: 'the second remember of an identical uid must be a no-op',
      );
    });

    test('hydrate degrades silently when the store throws', () async {
      // Must never break boot: main() awaits hydrate() before runApp.
      final broken = AppDatabase(NativeDatabase.memory());
      await broken.close();
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(broken),
          nowMsProvider.overrideWithValue(() => 1000),
          authRepositoryProvider.overrideWithValue(
            StreamingFakeAuthRepository(_signedOut),
          ),
        ],
      );
      addTearDown(container.dispose);
      await expectLater(
        container.read(lastKnownUidProvider.notifier).hydrate(),
        completes,
      );
      expect(container.read(lastKnownUidProvider), isNull);
    });
  });

  group('effectiveUidProvider', () {
    test('prefers the live session uid', () {
      final t = make(initial: _signedInU1);
      expect(t.container.read(effectiveUidProvider), 'user-u1');
    });

    test('is null when there is no session and no lastKnownUid', () {
      final t = make();
      expect(t.container.read(effectiveUidProvider), isNull);
    });

    test(
      'falls back to lastKnownUid after a sessionExpired sign-out — L4',
      () async {
        final t = make(initial: _signedInU1);
        await t.container.read(lastKnownUidProvider.notifier).remember('user-u1');
        // Hard sign-out: gotrue's _removeSession() has run, so the
        // SYNCHRONOUS door now reports signed-out too.
        t.auth.emit(const AuthSessionState.signedOut(
          cause: AuthSignOutCause.sessionExpired,
        ));
        await Future<void>.delayed(Duration.zero);
        expect(t.container.read(effectiveUidProvider), 'user-u1');
      },
    );

    test(
      'survives an auth-stream error with the session still in memory',
      () async {
        // The offline-refresh case: addError() only, currentSession intact.
        final t = make(initial: _signedInU1);
        final sub = t.container.listen(effectiveUidProvider, (_, __) {});
        addTearDown(sub.close);
        t.auth.emitError(Exception('AuthRetryableFetchException'));
        await Future<void>.delayed(Duration.zero);
        expect(t.container.read(authStateProvider).hasError, isTrue);
        expect(
          t.container.read(effectiveUidProvider),
          'user-u1',
          reason: 'asData is null on AsyncError; the sync door is not',
        );
      },
    );

    test('is null after a user-initiated sign-out', () async {
      final t = make(initial: _signedInU1);
      final notifier = t.container.read(lastKnownUidProvider.notifier);
      await notifier.remember('user-u1');
      t.auth.emit(const AuthSessionState.signedOut(
        cause: AuthSignOutCause.userInitiated,
      ));
      await notifier.forget();
      await Future<void>.delayed(Duration.zero);
      expect(t.container.read(effectiveUidProvider), isNull);
    });

    test('rebuilds when lastKnownUid changes', () async {
      final t = make();
      final seen = <String?>[];
      final sub = t.container.listen(
        effectiveUidProvider,
        (_, next) => seen.add(next),
        fireImmediately: true,
      );
      addTearDown(sub.close);
      await t.container.read(lastKnownUidProvider.notifier).remember('user-u1');
      expect(seen, [null, 'user-u1']);
    });

    test('degrades to lastKnownUid when auth cannot be built at all', () async {
      // No authRepositoryProvider override => supabaseClientProvider throws
      // (Supabase.instance is a late field). authStateProvider must become an
      // AsyncError, NOT crash, and the fallback must still work.
      final only = AppDatabase(NativeDatabase.memory());
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(only),
          nowMsProvider.overrideWithValue(() => 1000),
        ],
      );
      addTearDown(only.close);
      addTearDown(container.dispose);
      await container.read(lastKnownUidProvider.notifier).remember('user-u1');
      expect(container.read(effectiveUidProvider), 'user-u1');
    });
  });

  group('hasKnownLocalSessionProvider', () {
    test('true with a live session, false with nothing', () {
      expect(make(initial: _signedInU1).container.read(hasKnownLocalSessionProvider), isTrue);
      expect(make().container.read(hasKnownLocalSessionProvider), isFalse);
    });

    test('true offline on lastKnownUid alone — signed-in-offline', () async {
      final t = make();
      await t.container.read(lastKnownUidProvider.notifier).remember('user-u1');
      expect(t.container.read(hasKnownLocalSessionProvider), isTrue);
    });
  });

  group('currentUidProvider delegates to the same door', () {
    test('agrees with effectiveUidProvider, including the fallback', () async {
      final t = make();
      expect(t.container.read(currentUidProvider)(), isNull);
      await t.container.read(lastKnownUidProvider.notifier).remember('user-u1');
      expect(t.container.read(currentUidProvider)(), 'user-u1');
      expect(
        t.container.read(currentUidProvider)(),
        t.container.read(effectiveUidProvider),
      );
    });
  });
}
```

(add `import 'dart:async';` at the top of that file for `StreamController`.)

- [ ] **Step 2: Run it, see it fail**
```bash
export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test test/app/last_known_uid_bootstrap_test.dart test/features/account/application/last_known_uid_test.dart
```
Expected: compile failures —
`Error: Couldn't resolve the package 'masi' URI 'package:masi/app/last_known_uid_bootstrap.dart'`,
`Error: Undefined name 'lastKnownUidProvider'.`, `Error: Undefined name 'effectiveUidProvider'.`,
`Error: Undefined name 'hasKnownLocalSessionProvider'.`

- [ ] **Step 3: Minimal implementation**

`lib/features/account/application/auth_providers.dart` — add `import '../../../core/db/database_provider.dart';`
and `import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;` (extend the existing
foundation import at `:1`), then replace `:28-54` (the whole `currentUidProvider` block) with:

```dart
/// Holds the uid of the last account that had a real session on this device,
/// persisted in the local-only `AppSettings` table via [SettingsStore] so it
/// survives an app restart AND a hard sign-out.
///
/// This is the root fix for L4 and for the native silent-empty-library bug:
/// local data ownership must NOT depend on a reachable network. A captive
/// portal answering gotrue's token refresh with an HTML body is classified as
/// a non-retryable `AuthUnknownException`, so gotrue calls `_removeSession()`
/// and erases the persisted session — after which the live uid is null, every
/// `_ownOrUnowned` guard collapses to `ownerId IS NULL`, and the user's whole
/// library becomes invisible and unwritable while reporting success. Keeping
/// the uid locally means that scenario degrades to "offline", not "somebody
/// else".
///
/// Lifecycle (driven by `app/last_known_uid_bootstrap.dart`'s
/// [handleAuthStateForLastKnownUid], wired in `MasiApp.build`):
///  - [remember] on every auth emission that carries a session uid.
///  - [forget] ONLY on a signed-out emission whose
///    [AuthSessionState.signOutCause] is [AuthSignOutCause.userInitiated].
///    `sessionExpired`/`sessionMissing`/unknown(cross-tab) must NOT clear it.
///  - [hydrate] once at boot, awaited in `main.dart`'s `bootApp` before
///    `runApp`, so no provider ever observes a spuriously-null uid on the
///    first frame.
///
/// [state] is the read path and is always updated SYNCHRONOUSLY, before the
/// async persist — so an account switch never serves a stale uid for the
/// duration of a drift write.
class LastKnownUid extends Notifier<String?> {
  @override
  String? build() => null;

  /// Loads the persisted uid into [state]. Never throws: `main()` awaits this
  /// before `runApp`, and an unopenable/failed database must degrade to "no
  /// last-known uid" rather than a white screen — the same log-and-continue
  /// stance `main()` takes around `Supabase.initialize`.
  Future<void> hydrate() async {
    try {
      final stored = await ref
          .read(settingsStoreProvider)
          .read(SettingsStore.lastKnownUidKey);
      if (stored != null && stored.isNotEmpty) state = stored;
    } catch (e, st) {
      debugPrint('lastKnownUid hydrate failed; continuing without it: $e\n$st');
    }
  }

  /// Records [uid] as the last known local session owner.
  ///
  /// Short-circuits when [state] already equals [uid]: `SyncOrchestrator`
  /// listens to UNFILTERED `db.tableUpdates()` (`sync_orchestrator.dart:159`),
  /// so a redundant write here would schedule a full sync push on every
  /// hourly `tokenRefreshed` re-emission of the same session. Only a genuine
  /// account change writes — and that legitimately warrants a push.
  Future<void> remember(String uid) async {
    if (uid.isEmpty || state == uid) return;
    state = uid;
    try {
      await ref
          .read(settingsStoreProvider)
          .write(SettingsStore.lastKnownUidKey, uid);
    } catch (e, st) {
      debugPrint('lastKnownUid persist failed: $e\n$st');
    }
  }

  /// Clears the last known uid — user-initiated sign-out ONLY.
  Future<void> forget() async {
    state = null;
    try {
      await ref
          .read(settingsStoreProvider)
          .remove(SettingsStore.lastKnownUidKey);
    } catch (e, st) {
      debugPrint('lastKnownUid clear failed: $e\n$st');
    }
  }
}

final lastKnownUidProvider = NotifierProvider<LastKnownUid, String?>(
  LastKnownUid.new,
);

/// THE single "who am I, for LOCAL data" door. Every local read/write scoping
/// decision — `watchTopos`' owner filter, `_ownOrUnowned`, `listOwnAreas`,
/// `listOwnSectors`, the logbook query, my-profile lookups, "is this mine"
/// badges — must resolve its uid here and nowhere else.
///
/// Resolution order:
///  1. The live session uid, read through the SYNCHRONOUS door
///     (`AuthRepository.currentSession`), which survives a retryable
///     auth-stream error because gotrue's offline refresh ticker only
///     `addError()`s and leaves the in-memory session intact.
///  2. Otherwise [lastKnownUidProvider].
///
/// The `ref.watch(authStateProvider)` below exists for REACTIVITY ONLY — its
/// value is deliberately discarded. That is the whole point: the old
/// `toposProvider` read `ref.watch(authStateProvider).asData?.value.uid`, and
/// `asData` is null for `AsyncError` just as much as for `AsyncLoading`, so a
/// single transient stream error collapsed the owner filter to
/// `owner_id IS NULL` and rendered "No topos yet" as a SUCCESSFUL empty
/// stream (no Retry affordance). Watching without trusting gives the rebuild
/// on sign-in/out/account-switch without the false signed-out.
///
/// `ref.watch` on a `StreamProvider` never rethrows a create-time failure —
/// an uninitialized Supabase makes `authStateProvider` a permanent
/// `AsyncError` (see `router.dart`'s doc), not a throw. The synchronous read
/// below CAN throw (`supabaseClientProvider` reads a `late` field), so it
/// keeps the try/catch this provider inherited from `currentUidProvider`:
/// absent auth degrades to signed-out, never crashes a create/edit path.
final effectiveUidProvider = Provider<String?>((ref) {
  ref.watch(authStateProvider);
  String? liveUid;
  try {
    liveUid = ref.read(authRepositoryProvider).currentSession.uid;
  } catch (_) {
    liveUid = null;
  }
  if (liveUid != null && liveUid.isNotEmpty) return liveUid;
  return ref.watch(lastKnownUidProvider);
});

/// Whether this device knows who its local data belongs to — i.e.
/// [effectiveUidProvider] resolved to something.
///
/// The router's web auth gate consumes this to tell "signed-in but offline"
/// (a persisted/last-known session, backend unreachable) apart from "never
/// signed in here", instead of failing closed on `authStateProvider.hasError`.
final hasKnownLocalSessionProvider = Provider<bool>(
  (ref) => ref.watch(effectiveUidProvider) != null,
);

/// Lazily-evaluated `String? Function()` form of [effectiveUidProvider], for
/// the repository constructors that take a `currentUid` seam and call it
/// per-INSERT/per-query.
///
/// Name and type are unchanged from before §1c so all seven repository
/// providers that pass `currentUid: ref.watch(currentUidProvider)`
/// (`database_provider.dart`, `library_providers.dart`, `ascents_providers.dart`,
/// `profile_providers.dart`, `likes_providers.dart`, `comments_providers.dart`)
/// inherit the last-known-uid fallback with no edit — ONE door, not seven
/// call-site patches. The uid is still read inside the closure (lazily, per
/// call) so this provider never rebuilds on auth changes and there is no
/// provider-construction cycle with the repository providers that consume it.
final currentUidProvider = Provider<String? Function()>((ref) {
  return () => ref.read(effectiveUidProvider);
});
```

Create `lib/app/last_known_uid_bootstrap.dart`:

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/account/data/auth_repository.dart';

/// Pure edge-handler backing `MasiApp`'s `ref.listen(authStateProvider, ...)`
/// last-known-uid bootstrap — the sibling of
/// `handleAuthStateForClaimOwnership` in `claim_ownership_bootstrap.dart`, and
/// deliberately shaped the same way (a pure function over the AsyncValue, unit
/// tested on its own, with the provider wiring left to the call site).
///
/// Semantics, which are the entire point of §1c:
///  - `AsyncLoading`/`AsyncError` -> **do nothing**. gotrue's refresh ticker
///    fires every 10s and, once offline near expiry, pushes an
///    `AuthRetryableFetchException` down the stream on every tick with the
///    in-memory session still valid. Those must not touch the stored uid.
///  - a session uid present -> [remember] it.
///  - signed out with [AuthSignOutCause.userInitiated] -> [forget].
///  - signed out for ANY other reason (`sessionExpired` — L4's captive-portal
///    hard sign-out, `sessionMissing`, or a null/unknown cause such as a
///    cross-tab `BroadcastChannel` sign-out) -> **keep** the uid. Losing it
///    here is exactly what blackholes local writes.
///
/// Unlike the claim-ownership handler this needs no `previous`: every decision
/// is a function of the current emission alone, and both actions are
/// idempotent ([remember] no-ops on an unchanged uid, [forget] on an already
/// null one), so a duplicate emission is harmless.
void handleAuthStateForLastKnownUid(
  AsyncValue<AuthSessionState> next, {
  required void Function(String uid) remember,
  required void Function() forget,
}) {
  final session = next.asData?.value;
  if (session == null) return;
  final uid = session.uid;
  if (uid != null && uid.isNotEmpty) {
    remember(uid);
    return;
  }
  if (session.signOutCause == AuthSignOutCause.userInitiated) forget();
}
```

`lib/main.dart` — add `import 'features/account/application/auth_providers.dart';` and extend the
`Future.wait` at `:76-79`:

```dart
  await Future.wait([
    _initSupabase(),
    container.read(photoFilesProvider).warmDocsPath(),
    // Hydrate `lastKnownUid` from the local-only AppSettings table BEFORE the
    // first frame, for the same reason `warmDocsPath()` is awaited here: every
    // local read/write is scoped by `effectiveUidProvider`, and a cold
    // last-known uid would make the very first `watchTopos`/`_ownOrUnowned`
    // resolve as signed-out. Independent of the two above (drift only, no
    // auth touched — `LastKnownUid.build()` reads no auth provider, so this
    // cannot race `_initSupabase()` into a LateInitializationError), so it
    // runs concurrently: boot cost stays max(), not sum(). `hydrate()` never
    // throws (see its doc) so it cannot take `bootApp` down.
    container.read(lastKnownUidProvider.notifier).hydrate(),
  ]);
```

`lib/app/app.dart` — add `import 'last_known_uid_bootstrap.dart';` and, immediately after the existing
claim-ownership `ref.listen` (`:108-117`):

```dart
    // Last-known-uid bootstrap (§1c): keep `lastKnownUidProvider` in step with
    // the live auth stream so local data scoping survives an involuntary
    // sign-out. A SEPARATE listener from the claim-ownership one above, with
    // `fireImmediately: true`, deliberately: the claim handler is an
    // edge-detector whose semantics depend on `previous`, so firing it
    // immediately would change its behaviour, whereas this handler is a pure
    // function of the current emission and MUST see whatever value the stream
    // already holds (`Supabase.initialize` has completed by the time MasiApp
    // builds, so an `initialSession` emission may already be in flight).
    ref.listen<AsyncValue<AuthSessionState>>(
      authStateProvider,
      (previous, next) {
        final lastKnown = ref.read(lastKnownUidProvider.notifier);
        handleAuthStateForLastKnownUid(
          next,
          remember: (uid) => unawaited(lastKnown.remember(uid)),
          forget: () => unawaited(lastKnown.forget()),
        );
      },
      fireImmediately: true,
    );
```

- [ ] **Step 4: Run it, see it pass**
```bash
export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test test/app/last_known_uid_bootstrap_test.dart test/features/account/application/last_known_uid_test.dart
export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test test/features/library/application/library_providers_test.dart
export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter analyze && flutter test
```

- [ ] **Step 5: Commit**
```bash
git add lib/features/account/application/auth_providers.dart lib/app/last_known_uid_bootstrap.dart \
        lib/main.dart lib/app/app.dart \
        test/app/last_known_uid_bootstrap_test.dart \
        test/features/account/application/last_known_uid_test.dart
git commit -m "feat(auth): persist lastKnownUid and route every uid read through effectiveUidProvider

Local data ownership no longer depends on a reachable network: the live
session uid wins when present, otherwise the uid persisted in the local-only
AppSettings table. Cleared ONLY on a user-initiated sign-out; a
sessionExpired/sessionMissing/cross-tab sign-out and a transient auth-stream
error all keep it. Fixes L4's read half.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

**Assertions:**
1. `effectiveUidProvider` returns the live uid when a session exists; `lastKnownUid` when it does not; `null` when neither.
2. With `authStateProvider` in an **error** state and the in-memory session intact, `effectiveUidProvider` is still the signed-in uid (`authStateProvider.hasError` is `true` in the same test — pre-fix `asData?.value.uid` is null here).
3. After a `sessionExpired` sign-out (synchronous door also signed out), `effectiveUidProvider` still returns the remembered uid.
4. After a **user-initiated** sign-out, `lastKnownUid` and its persisted row are both cleared and `effectiveUidProvider` is `null`.
5. `remember(sameUid)` performs **no** second store write (the `tableUpdates()`/push-storm guard).
6. `hydrate()` against a closed database completes without throwing and leaves state `null`.
7. `hasKnownLocalSessionProvider` is `true` on lastKnownUid alone (signed-in-offline) and `false` with neither source.
8. `currentUidProvider()` and `effectiveUidProvider` always agree.
9. `handleAuthStateForLastKnownUid`: 10 cases green — remember on signed-in, remember on switch, no-op on Loading, no-op on Error, keep on sessionExpired, keep on sessionMissing, keep on null cause, forget on userInitiated, ignore empty uid.
10. `flutter test test/features/library/application/library_providers_test.dart` stays green **with no auth override in its container** — proving `effectiveUidProvider` newly constructing `authStateProvider` against an uninitialized Supabase yields an `AsyncError` rather than an uncaught test failure.
11. Whole-project `flutter analyze` 0, `flutter test` green.

**What could go wrong:**
- **`effectiveUidProvider` throwing on an uninitialized Supabase**, which would crash every INSERT in tests and on a first offline launch. Caught by assertions 10 + the "degrades to lastKnownUid when auth cannot be built at all" test. If assertion 10 fails, the documented fallback is to wrap the reactivity watch itself: `try { ref.watch(authStateProvider); } catch (_) {}` — this loses the dependency edge only in the case where auth cannot be constructed at all, where there is no live session to react to anyway.
- **A stale uid after an account switch** (user A signs out, B signs in, A's uid still served). Prevented by updating `state` synchronously before the async persist; covered by assertion 4 and the switch case in assertion 9.
- **A push storm** from writing `app_settings` on every hourly token refresh. Caught by assertion 5.
- **`hydrate()` racing `_initSupabase()` into a `LateInitializationError`.** Prevented structurally: `LastKnownUid.build()` returns `null` and reads no auth provider, and the auth listener lives in `MasiApp.build` (after `Supabase.initialize` is awaited), not in the notifier's `build()`. Caught by `flutter test test/app/app_test.dart` + the web boot integration test.

---

## Task 4: route every local-data-scoping read through the door

**Files (each verified by opening the file):**

| # | File:line (current) | Current expression | Change |
|---|---|---|---|
| 1 | `lib/features/library/application/library_providers.dart:67` | `ref.watch(authStateProvider).asData?.value.uid` | `ref.watch(effectiveUidProvider)` |
| 2 | `lib/features/library/presentation/topos_row.dart:324` | `ref.read(authStateProvider).asData?.value.uid` → `repo.listOwnSectors(myUid)` | `ref.read(effectiveUidProvider)` |
| 3 | `lib/features/library/presentation/sectors_screen.dart:67` | `ref.read(authStateProvider).asData?.value.uid` → `repo.listOwnAreas(myUid)` | `ref.read(effectiveUidProvider)` |
| 4 | `lib/features/account/application/profile_providers.dart:39` | `ref.watch(authStateProvider).asData?.value.uid` (`myDisplayNameProvider`) | `ref.watch(effectiveUidProvider)` |
| 5 | `lib/features/community/presentation/community_map_screen.dart:643` | `ref.watch(authStateProvider).asData?.value.uid` (`isMine`) | `ref.watch(effectiveUidProvider)` |
| 6 | `lib/features/community/presentation/community_feed_screen.dart:513` | `ref.watch(authStateProvider).asData?.value.uid` (`_OwnBadge`) | `ref.watch(effectiveUidProvider)` |
| 7 | `lib/features/logbook/presentation/logbook_providers.dart:137` | `ref.watch(currentUidProvider)()` | `ref.watch(effectiveUidProvider)` |

Site 7 is a `ref.watch` of the never-rebuilding `currentUidProvider`, so the logbook query is
currently frozen at its first uid and does not refresh on sign-in — switching it to
`effectiveUidProvider` fixes the door **and** that latent non-reactivity.

Sites 2/3 use `ref.read` inside an async `_handleMove` callback, which is correct there (a one-shot
read at gesture time, not a build dependency) — only the source changes.

Files whose `authStateProvider` reads are **left alone** (classified as legitimately wanting live
auth state, not a uid door):

| File:line | Why it stays |
|---|---|
| `lib/app/router.dart:128`, `:151` | The web auth gate + router refresh. **Another fragment** (§1c-3) rewires this to `hasKnownLocalSessionProvider`. |
| `lib/app/app.dart:108` | Claim-on-sign-in edge detector — must fire only for a **genuinely new live session**; a last-known uid must never trigger `claimOwnership`. |
| `lib/features/library/presentation/topos_screen.dart:153` | Reads `email` for the account-button initials. Chrome for the live auth state; `effectiveUidProvider` carries no email. |
| `lib/features/community/application/community_topo_detail_providers.dart:126` | Reads `email` to derive `currentAuthorNameProvider`. Same reason. |
| `lib/features/account/presentation/account_screen.dart:219`, `:230` | The sign-in/sign-out UI itself — it must show loading and error states honestly. |
| `lib/features/backup/application/sync_orchestrator.dart:170` | Pull-on-sign-in. Must require a real reachable session; syncing on a stale offline uid is wrong. |

`grep -rn "asData" lib` also matches ~30 non-uid unwraps (`areasProvider`, `myLocationProvider`,
`profileDisplayNameProvider(ownerId)`, like/comment counts, …). None is a uid read; all stay.

**Interfaces:** Consumes `effectiveUidProvider` (Task 3). Produces no new symbol.

- [ ] **Step 1: Write the failing test** — append to `test/features/library/application/library_providers_test.dart`
(reusing its existing `_makeContainer` / `_listenAndCollect` / `_waitUntil` helpers verbatim, plus
`StreamingFakeAuthRepository` from `test/features/account/application/last_known_uid_test.dart`).
`_makeContainer` gains an optional `overrides` parameter:

```dart
ProviderContainer _makeContainer({List<Override> overrides = const []}) {
  final db = AppDatabase(NativeDatabase.memory());
  final container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(db),
      nowMsProvider.overrideWithValue(() => 1000),
      ...overrides,
    ],
  );
  addTearDown(db.close);
  addTearDown(container.dispose);
  return container;
}
```

```dart
  group('A3b: toposProvider goes through effectiveUidProvider (§1c)', () {
    test(
      'still emits the signed-in user own topos while authStateProvider is '
      'in an ERROR state (native silent-empty-library bug)',
      () async {
        final auth = StreamingFakeAuthRepository(
          AuthSessionState.signedIn('u1@example.com', uid: 'user-u1'),
        );
        addTearDown(auth.dispose);
        final container = _makeContainer(
          overrides: [authRepositoryProvider.overrideWithValue(auth)],
        );

        final repo = container.read(libraryCrudRepositoryProvider);
        final area = await repo.createArea('Area');
        final sector = await repo.createSector(area.id, 'Sector');
        final wall = await repo.createWall(sector.id, 'Wall');
        // createWall stamps ownerId from the currentUid seam; assert that
        // rather than assuming it, so this test fails loudly if the write
        // door regresses instead of silently testing an unowned row.
        final ownerId = await container
            .read(appDatabaseProvider)
            .customSelect(
              'SELECT owner_id FROM walls WHERE id = ?',
              variables: [Variable<String>(wall.id)],
            )
            .map((r) => r.read<String?>('owner_id'))
            .getSingle();
        expect(ownerId, 'user-u1');

        final emissions = _listenAndCollect<List<TopoRef>>(
          container,
          toposProvider,
        );
        await _waitUntil(emissions, (e) => e.isNotEmpty);
        expect(emissions.last.map((t) => t.wallId), contains(wall.id));

        // gotrue's offline refresh ticker: addError only, session intact.
        auth.emitError(Exception('AuthRetryableFetchException'));
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(container.read(authStateProvider).hasError, isTrue);
        expect(
          emissions.last.map((t) => t.wallId),
          contains(wall.id),
          reason: 'pre-fix asData?.value.uid was null here, collapsing the '
              'owner filter to owner_id IS NULL and emitting an empty list',
        );
      },
    );

    test(
      'still emits own topos after a sessionExpired sign-out (L4 read half)',
      () async {
        final auth = StreamingFakeAuthRepository(
          AuthSessionState.signedIn('u1@example.com', uid: 'user-u1'),
        );
        addTearDown(auth.dispose);
        final container = _makeContainer(
          overrides: [authRepositoryProvider.overrideWithValue(auth)],
        );
        await container
            .read(lastKnownUidProvider.notifier)
            .remember('user-u1');

        final repo = container.read(libraryCrudRepositoryProvider);
        final area = await repo.createArea('Area');
        final sector = await repo.createSector(area.id, 'Sector');
        final wall = await repo.createWall(sector.id, 'Wall');

        final emissions = _listenAndCollect<List<TopoRef>>(
          container,
          toposProvider,
        );
        await _waitUntil(emissions, (e) => e.isNotEmpty);

        auth.emit(const AuthSessionState.signedOut(
          cause: AuthSignOutCause.sessionExpired,
        ));
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(
          emissions.last.map((t) => t.wallId),
          contains(wall.id),
          reason: 'a hard sign-out must not hide the local library',
        );

        // And local WRITES still target the right ownerId, not IS NULL.
        await repo.renameWall(wall.id, 'Renamed');
        final name = await repo.wallName(wall.id);
        expect(name, 'Renamed');
      },
    );

    test('emits an empty list after a user-initiated sign-out', () async {
      final auth = StreamingFakeAuthRepository(
        AuthSessionState.signedIn('u1@example.com', uid: 'user-u1'),
      );
      addTearDown(auth.dispose);
      final container = _makeContainer(
        overrides: [authRepositoryProvider.overrideWithValue(auth)],
      );
      final notifier = container.read(lastKnownUidProvider.notifier);
      await notifier.remember('user-u1');

      final repo = container.read(libraryCrudRepositoryProvider);
      final area = await repo.createArea('Area');
      final sector = await repo.createSector(area.id, 'Sector');
      await repo.createWall(sector.id, 'Wall');

      final emissions = _listenAndCollect<List<TopoRef>>(
        container,
        toposProvider,
      );
      await _waitUntil(emissions, (e) => e.isNotEmpty);

      auth.emit(const AuthSessionState.signedOut(
        cause: AuthSignOutCause.userInitiated,
      ));
      await notifier.forget();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(
        emissions.last,
        isEmpty,
        reason: 'signing out on purpose must scope reads back to unowned',
      );
    });
  });

  group('A3c: logbookEntriesProvider goes through the same door', () {
    test('uses the last-known uid when the live session is gone', () async {
      final auth = StreamingFakeAuthRepository(const AuthSessionState.signedOut(
        cause: AuthSignOutCause.sessionExpired,
      ));
      addTearDown(auth.dispose);
      final container = _makeContainer(
        overrides: [authRepositoryProvider.overrideWithValue(auth)],
      );
      await container.read(lastKnownUidProvider.notifier).remember('user-u1');
      expect(container.read(effectiveUidProvider), 'user-u1');
      // The query is built from effectiveUidProvider, so an owner-stamped
      // ascent stays visible. Emitting an empty (but successful) list is the
      // failure mode this guards.
      final emissions = _listenAndCollect<List<LogbookEntry>>(
        container,
        logbookEntriesProvider,
      );
      await _waitUntil(emissions, (e) => e.isNotEmpty);
      expect(emissions.last, isEmpty); // no ascents seeded; must not throw
    });
  });
```

(imports to add to that test file: `package:drift/drift.dart' show Variable`,
`masi/features/account/application/auth_providers.dart`,
`masi/features/account/data/auth_repository.dart`,
`masi/features/logbook/presentation/logbook_providers.dart`, and
`../../account/application/last_known_uid_test.dart' show StreamingFakeAuthRepository`.)

- [ ] **Step 2: Run it, see it fail**
```bash
export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test test/features/library/application/library_providers_test.dart
```
Expected: the first two tests fail on the post-error/post-sign-out expectation —
`Expected: contains '<wall-id>'  Actual: []`, with the stated `reason:` printed. The third passes
already (it is the regression guard for the fix, not a pre-existing bug).

- [ ] **Step 3: Minimal implementation** — the seven one-line source edits.

1. `lib/features/library/application/library_providers.dart:66-69`:
```dart
final toposProvider = StreamProvider<List<TopoRef>>((ref) {
  final ownerUid = ref.watch(effectiveUidProvider);
  return ref.watch(libraryCrudRepositoryProvider).watchTopos(ownerUid);
});
```
and rewrite the tail of its doc (`:63-65`) to:
```dart
/// Scoped through [effectiveUidProvider] — the SINGLE local-data uid door
/// (§1c). It must NOT read `authStateProvider.asData?.value.uid`: `asData` is
/// null for `AsyncError` as well as `AsyncLoading`, so one transient
/// auth-stream error (gotrue's offline 10s refresh ticker `addError`s on every
/// tick) collapsed `watchTopos`' owner filter to `owner_id IS NULL` and — since
/// `claimOwnership` stamps `ownerId` on every row at first sign-in — rendered
/// the whole library as a SUCCESSFUL empty stream ("No topos yet", no Retry).
/// [effectiveUidProvider] still rebuilds this provider on every auth emission,
/// so the account-switch reactivity described above is unchanged.
```
2. `lib/features/library/presentation/topos_row.dart:324` → `final myUid = ref.read(effectiveUidProvider);`
3. `lib/features/library/presentation/sectors_screen.dart:67` → `final myUid = ref.read(effectiveUidProvider);`
4. `lib/features/account/application/profile_providers.dart:39` → `final uid = ref.watch(effectiveUidProvider);`
5. `lib/features/community/presentation/community_map_screen.dart:643` → `final myUid = ref.watch(effectiveUidProvider);`
6. `lib/features/community/presentation/community_feed_screen.dart:513` → `final myUid = ref.watch(effectiveUidProvider);`
7. `lib/features/logbook/presentation/logbook_providers.dart:137` → `final uid = ref.watch(effectiveUidProvider);`

Each edit keeps the enclosing `authStateProvider` import only where the file still uses it — after the
change, `topos_row.dart`, `sectors_screen.dart`, `community_map_screen.dart`,
`community_feed_screen.dart` and `logbook_providers.dart` no longer reference `authStateProvider`;
they already import `auth_providers.dart`, which also exports `effectiveUidProvider`, so no import
changes are needed and `flutter analyze` will flag any that become unused.

Add a one-line comment at each of sites 2-7 pointing at the door, e.g.:
```dart
    // §1c: the single local-data uid door — never `authStateProvider.asData`,
    // which reads null on AsyncError too.
```

- [ ] **Step 4: Run it, see it pass**
```bash
export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test test/features/library/ test/features/logbook/ test/features/community/ test/features/account/
export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter analyze && flutter test
```

- [ ] **Step 5: Commit**
```bash
git add lib/features/library/application/library_providers.dart \
        lib/features/library/presentation/topos_row.dart \
        lib/features/library/presentation/sectors_screen.dart \
        lib/features/account/application/profile_providers.dart \
        lib/features/community/presentation/community_map_screen.dart \
        lib/features/community/presentation/community_feed_screen.dart \
        lib/features/logbook/presentation/logbook_providers.dart \
        test/features/library/application/library_providers_test.dart
git commit -m "fix(auth): route all 7 local-data uid reads through effectiveUidProvider

toposProvider read authStateProvider.asData?.value.uid, which is null on
AsyncError as well as AsyncLoading — one transient auth-stream error collapsed
watchTopos' owner filter to owner_id IS NULL and rendered the whole library as
a successful empty stream. Same door now for listOwnAreas/listOwnSectors,
myDisplayName, the two is-mine badges and the logbook query (which was also
frozen at its first uid).

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

**Assertions:**
1. `grep -rn "authStateProvider).asData?.value.uid\|authStateProvider).asData?.value\.uid" lib` returns **zero** hits.
2. `grep -rn "authStateProvider" lib --include="*.dart" | grep -v "^lib/features/account/application/auth_providers.dart" | grep -v "///" | grep -v "//"` matches only: `router.dart:128`, `router.dart:151`, `app.dart:108` + the new §1c listener, `topos_screen.dart:153`, `community_topo_detail_providers.dart:126`, `account_screen.dart:219`, `account_screen.dart:230`, `sync_orchestrator.dart:170`. Any other hit is an unfixed uid door.
3. With `authStateProvider` in an error state and the session intact, `toposProvider` emits the signed-in user's topos (non-empty), and the wall's stored `owner_id` is asserted to be that uid (so the test cannot pass on an unowned row).
4. After a `sessionExpired` sign-out, `toposProvider` still emits the topos **and** `renameWall` still takes effect.
5. After a **user-initiated** sign-out, `toposProvider` emits empty.
6. `logbookEntriesProvider` builds its query from the last-known uid when the live session is gone.
7. Whole-project `flutter analyze` 0 (this is also the check that no import went unused), `flutter test` green.

**What could go wrong:**
- **Missing a site.** Caught by assertions 1 + 2 — assertion 2 is an exhaustive allow-list, so a new or overlooked `authStateProvider` uid read fails it.
- **Over-fixing** — routing `sync_orchestrator.dart:170` or `app.dart:108` through the door would make the app try to sync, or run `claimOwnership`, on a merely *remembered* uid with no session. Assertion 2's allow-list pins both as unchanged.
- **A test that passes vacuously** because the seeded wall is unowned (`owner_id IS NULL` matches either way). Prevented by asserting `owner_id == 'user-u1'` before the interesting expectation.
- **`profile_providers.dart:39` re-subscribing on lastKnownUid churn** — `remember` is deduped (Task 3 assertion 5), so `effectiveUidProvider` only changes on a real account change, which should re-resolve the display name anyway.

---

## Cross-fragment notes

- The router fragment (§1c-3) should consume `hasKnownLocalSessionProvider` — "persisted-or-remembered session present" — instead of `authStateProvider.hasError`, and update the `router.dart:111-113` comment.
- The mutation-guard fragment (§1c-4) inherits the fixed write door for free: `_ownOrUnowned` reads `currentUid()`, which now resolves through `effectiveUidProvider`. Its remaining job is the discarded affected-row count.
- §1e should give `SyncOrchestrator`'s `db.tableUpdates()` subscription an explicit table filter that **excludes `app_settings`**, making `LastKnownUid.remember`'s dedupe a defence-in-depth measure rather than the only guard.
- §1a's storage-backend interlock lands in the same `connection_web.dart`/boot path this fragment adds `hydrate()` to; the two boot additions are independent.
- Doc correction owed elsewhere: `test/features/library/application/library_providers_test.dart:34-38` claims "Riverpod 3 providers are auto-disposed by default". They are not — `riverpod-3.3.2/lib/src/providers/provider.dart:24` defaults `isAutoDispose = false`, and `sync_orchestrator.dart:107` documents the correct behaviour.
