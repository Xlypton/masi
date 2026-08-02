import 'package:flutter_test/flutter_test.dart';
import 'package:masi/core/db/storage_durability_provider.dart';

/// [storageBlockedNotice] is the single source of the sentence three separate
/// screens show when creating is turned off (the topos-home banner, the
/// area/sector/wall lists, and the topo canvas). Pinning it here rather than
/// in each screen's widget test keeps "do the words say the right thing" in
/// one place and lets the widget tests assert only "is the sentence present
/// and is the control off".
void main() {
  test('a healthy backend is not blocked', () {
    expect(
      storageBlockedNotice(
        const StorageDurability(backend: StorageBackend.opfsLocks),
      ),
      isNull,
    );
  });

  test('a still-probing verdict is not blocked', () {
    // Matches the interlock's existing rule: block only on a KNOWN-bad
    // verdict, never on a not-yet-known one, or every widget test and the
    // first few hundred ms of every web boot would be blocked.
    expect(storageBlockedNotice(const StorageDurability.probing()), isNull);
  });

  test('an in-memory backend is blocked, and says why in terms of reloading', () {
    final notice = storageBlockedNotice(
      const StorageDurability(backend: StorageBackend.inMemory),
    );
    expect(notice, isNotNull);
    expect(notice, contains('blocked in this browser'));
    expect(notice, contains('lost'));
  });

  test('a schema downgrade says nothing has been lost, not that saving is '
      'broken', () {
    final notice = storageBlockedNotice(
      const StorageDurability.unavailable(
        'SchemaDowngradeException: ...',
        cause: StorageUnavailableCause.schemaDowngrade,
      ),
    );
    expect(notice, isNotNull);
    // The guard's whole point is that the database is untouched. Telling this
    // climber their topos can't be saved is a false alarm about their records.
    expect(notice, contains('Nothing has been lost'));
    expect(notice, contains('reload'));
    expect(notice, isNot(contains('blocked in this browser')));
  });

  test('an unclassified failed open promises only what is true', () {
    final notice = storageBlockedNotice(
      const StorageDurability.unavailable('Bad worker: boom'),
    );
    expect(notice, isNotNull);
    // A failed OPEN deletes nothing, so this much may be said honestly — but
    // unlike the downgrade case it must not claim the data is intact and
    // openable.
    expect(notice, contains('have not been deleted'));
    expect(notice, isNot(contains('Nothing has been lost')));
  });
}
