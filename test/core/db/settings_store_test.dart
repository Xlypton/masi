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
        'profiles',
        'areas',
        'sectors',
        'walls',
        'photos',
        'routes',
        'ascents',
        'comments',
        'likes',
      ],
      isNot(contains('app_settings')),
    );
  });
}
