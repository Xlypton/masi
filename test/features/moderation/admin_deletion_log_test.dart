// `currentlyAdminDeletedWalls` (`lib/features/moderation/data/
// admin_deletion_log_remote.dart`) and `AdminDeletedTopo.fromRow`
// (`lib/features/moderation/domain/admin_deleted_topo.dart`) — the pure logic
// behind the admin queue's "Removed" tab, which lists topos an
// `admin_delete_topo` call took down and that nobody has restored yet.
//
// The one property that matters more than any other here: a wall whose most
// RECENT wall-targeted log entry is a restore must not appear, even though an
// earlier `admin_delete` entry for the same wall still exists in the log. A
// naive "does an admin_delete row exist for this wall" query would keep an
// already-restored topo on an admin's todo list forever.

import 'package:flutter_test/flutter_test.dart';
import 'package:masi/features/moderation/data/admin_deletion_log_remote.dart';
import 'package:masi/features/moderation/domain/admin_deleted_topo.dart';

Map<String, dynamic> _entry({
  required String action,
  required String wallId,
  required int createdAt,
  String? reason,
  String actorId = 'admin-1',
  String targetType = 'wall',
}) => {
  'id': 'log-$wallId-$createdAt',
  'actorId': actorId,
  'action': action,
  'targetType': targetType,
  'targetId': wallId,
  'reason': reason,
  'createdAt': createdAt,
};

void main() {
  group('currentlyAdminDeletedWalls', () {
    test('a wall with only a delete entry is still awaiting a restore', () {
      final rows = [
        _entry(action: 'admin_delete', wallId: 'w1', createdAt: 1000),
      ];
      final result = currentlyAdminDeletedWalls(rows);
      expect(result, hasLength(1));
      expect(result.single['targetId'], 'w1');
    });

    test(
      'a wall whose MOST RECENT entry is a restore is excluded, even though '
      'an earlier delete entry for it still exists in the log',
      () {
        final rows = [
          _entry(action: 'admin_delete', wallId: 'w1', createdAt: 1000),
          _entry(action: 'admin_restore', wallId: 'w1', createdAt: 2000),
        ];
        expect(currentlyAdminDeletedWalls(rows), isEmpty);
      },
    );

    test(
      'delete -> restore -> delete again correctly reads as still deleted — '
      'ordering by createdAt, not by list position, decides the answer',
      () {
        final rows = [
          // Deliberately out of chronological order, to prove the reduction
          // sorts by the timestamp field rather than trusting input order.
          _entry(action: 'admin_delete', wallId: 'w1', createdAt: 3000),
          _entry(action: 'admin_restore', wallId: 'w1', createdAt: 2000),
          _entry(action: 'admin_delete', wallId: 'w1', createdAt: 1000),
        ];
        final result = currentlyAdminDeletedWalls(rows);
        expect(result, hasLength(1));
        expect(result.single['createdAt'], 3000);
      },
    );

    test(
      'a delete and a restore at the SAME timestamp read as RESTORED, in '
      'EITHER input order — a tie must not be decided by page ordering',
      () {
        // `createdAt` is a millisecond epoch stamped by the RPC, so a delete and
        // an immediate restore of the same wall can share one. With a strict
        // "newer wins" the survivor was then whichever row PostgREST happened to
        // hand over first, i.e. a restored topo could sit in the "awaiting
        // restore" list forever with no way for an admin to clear it. Both
        // orders are asserted because only one of them ever failed.
        final deleteFirst = [
          _entry(action: 'admin_delete', wallId: 'w1', createdAt: 5000),
          _entry(action: 'admin_restore', wallId: 'w1', createdAt: 5000),
        ];
        expect(currentlyAdminDeletedWalls(deleteFirst), isEmpty);
        expect(
          currentlyAdminDeletedWalls(deleteFirst.reversed.toList()),
          isEmpty,
        );
      },
    );

    test(
      'the tie-break does not swallow a genuinely later delete that shares a '
      'timestamp with an EARLIER restore',
      () {
        // Guards the fix against over-reaching: only an equal-timestamp restore
        // wins, and it must not make a strictly newer delete disappear.
        final rows = [
          _entry(action: 'admin_restore', wallId: 'w1', createdAt: 5000),
          _entry(action: 'admin_delete', wallId: 'w1', createdAt: 5001),
        ];
        final result = currentlyAdminDeletedWalls(rows);
        expect(result, hasLength(1));
        expect(result.single['createdAt'], 5001);
      },
    );

    test('multiple different walls are each judged independently', () {
      final rows = [
        _entry(action: 'admin_delete', wallId: 'w1', createdAt: 1000),
        _entry(action: 'admin_delete', wallId: 'w2', createdAt: 1500),
        _entry(action: 'admin_restore', wallId: 'w2', createdAt: 1600),
      ];
      final result = currentlyAdminDeletedWalls(rows);
      expect(result.map((r) => r['targetId']), ['w1']);
    });

    test('a row with no usable targetId or createdAt is skipped, not fatal', () {
      final rows = [
        _entry(action: 'admin_delete', wallId: 'w1', createdAt: 1000),
        {..._entry(action: 'admin_delete', wallId: 'w2', createdAt: 1000), 'targetId': null},
        {..._entry(action: 'admin_delete', wallId: 'w3', createdAt: 1000), 'createdAt': null},
      ];
      final result = currentlyAdminDeletedWalls(rows);
      expect(result.map((r) => r['targetId']), ['w1']);
    });

    test('an empty log means nothing to restore', () {
      expect(currentlyAdminDeletedWalls(const []), isEmpty);
    });
  });

  group('AdminDeletedTopo.fromRow', () {
    test('a well-formed row parses fully', () {
      final topo = AdminDeletedTopo.fromRow(
        _entry(
          action: 'admin_delete',
          wallId: 'w1',
          createdAt: 5000,
          reason: 'spam',
        ),
      )!;
      expect(topo.wallId, 'w1');
      expect(topo.deletedAt, 5000);
      expect(topo.reason, 'spam');
      expect(topo.actorId, 'admin-1');
    });

    test('a missing or blank reason reads as null, not an empty string', () {
      expect(
        AdminDeletedTopo.fromRow(
          _entry(action: 'admin_delete', wallId: 'w1', createdAt: 1),
        )!.reason,
        isNull,
      );
      expect(
        AdminDeletedTopo.fromRow(
          _entry(action: 'admin_delete', wallId: 'w1', createdAt: 1, reason: '   '),
        )!.reason,
        isNull,
      );
    });

    test('a row with no wall id or timestamp is dropped, not half-built', () {
      expect(
        AdminDeletedTopo.fromRow({
          ..._entry(action: 'admin_delete', wallId: 'w1', createdAt: 1),
          'targetId': '',
        }),
        isNull,
      );
      expect(
        AdminDeletedTopo.fromRow({
          ..._entry(action: 'admin_delete', wallId: 'w1', createdAt: 1),
          'createdAt': null,
        }),
        isNull,
      );
      expect(AdminDeletedTopo.fromRow(const {}), isNull);
    });
  });
}
