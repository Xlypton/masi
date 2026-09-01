// The inbox's section headings.
//
// An inbox is scanned for "is this still current?" before it is read for
// "what is it?", and an unheaded list makes that question unanswerable without
// doing the age arithmetic on every row. These are the boundaries the headings
// draw, pinned to a fixed clock — the whole reason `notificationBucket` takes
// a `now` rather than reading one.
import 'package:flutter_test/flutter_test.dart';
import 'package:masi/features/notifications/domain/app_notification.dart';

final _now = DateTime(2026, 9, 1, 10, 30);

AppNotification _at(DateTime when, {String id = 'n'}) => AppNotification.fromRow({
  'id': id,
  'kind': 'like',
  'createdAt': when.millisecondsSinceEpoch,
})!;

void main() {
  group('the buckets', () {
    test('this morning is Today', () {
      expect(
        notificationBucket(DateTime(2026, 9, 1, 8).millisecondsSinceEpoch, now: _now),
        NotificationAgeBucket.today,
      );
    });

    test(
      'last night at 23:50 is NOT Today, even though it is inside 24 hours — '
      '"today" is a calendar day to the person reading it, not an elapsed '
      'duration',
      () {
        expect(
          notificationBucket(
            DateTime(2026, 8, 31, 23, 50).millisecondsSinceEpoch,
            now: _now,
          ),
          NotificationAgeBucket.thisWeek,
        );
      },
    );

    test('six days back is still This week; seven is Earlier', () {
      expect(
        notificationBucket(DateTime(2026, 8, 26, 9).millisecondsSinceEpoch, now: _now),
        NotificationAgeBucket.thisWeek,
      );
      expect(
        notificationBucket(DateTime(2026, 8, 25, 9).millisecondsSinceEpoch, now: _now),
        NotificationAgeBucket.earlier,
      );
    });

    test('a timestamp in the future reads as Today rather than falling off '
        'the end — a device clock behind the server must not hide an entry', () {
      expect(
        notificationBucket(DateTime(2026, 9, 2).millisecondsSinceEpoch, now: _now),
        NotificationAgeBucket.today,
      );
    });
  });

  group('grouping', () {
    test('splits a newest-first list into its sections, in order', () {
      final sections = groupNotificationsByAge([
        _at(DateTime(2026, 9, 1, 9), id: 'a'),
        _at(DateTime(2026, 9, 1, 8), id: 'b'),
        _at(DateTime(2026, 8, 30), id: 'c'),
        _at(DateTime(2026, 7, 1), id: 'd'),
      ], now: _now);

      expect(
        sections.map((s) => s.bucket),
        [
          NotificationAgeBucket.today,
          NotificationAgeBucket.thisWeek,
          NotificationAgeBucket.earlier,
        ],
      );
      expect(sections.first.items.map((n) => n.id), ['a', 'b']);
    });

    test('an empty bucket produces no heading — a section of nothing is '
        'clutter, not structure', () {
      final sections = groupNotificationsByAge([
        _at(DateTime(2026, 9, 1, 9), id: 'a'),
        _at(DateTime(2026, 7, 1), id: 'b'),
      ], now: _now);
      expect(sections.map((s) => s.bucket), [
        NotificationAgeBucket.today,
        NotificationAgeBucket.earlier,
      ]);
    });

    test('an empty inbox produces no sections at all', () {
      expect(groupNotificationsByAge(const [], now: _now), isEmpty);
    });
  });

  group('the kind glyph', () {
    test('every known kind has its own, so a like and an edit proposal are '
        'not the same row at a glance', () {
      final known = NotificationKind.values
          .where((k) => k != NotificationKind.unknown)
          .map(notificationKindGlyph)
          .toSet();
      expect(known, hasLength(NotificationKind.values.length - 1));
    });

    test('an unknown kind falls back to the bell\'s own glyph — as much as a '
        'build meeting a new verb can honestly claim', () {
      expect(notificationKindGlyph(NotificationKind.unknown), 'flash');
    });
  });
}
