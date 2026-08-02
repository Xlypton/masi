import 'dart:math';

import 'package:masi/features/backup/application/sync_retry_schedule.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SyncRetrySchedule', () {
    test('production defaults are ~2s doubling to a 5min ceiling', () {
      final schedule = SyncRetrySchedule();
      expect(schedule.base, const Duration(seconds: 2));
      expect(schedule.ceiling, const Duration(minutes: 5));
      expect(schedule.envelopeFor(1), const Duration(seconds: 2));
      expect(schedule.envelopeFor(2), const Duration(seconds: 4));
      expect(schedule.envelopeFor(3), const Duration(seconds: 8));
      expect(schedule.envelopeFor(8), const Duration(seconds: 256));
    });

    test(
      'the envelope grows monotonically and is CLAMPED at the ceiling -- '
      'bounded interval, so it never drifts into never-retrying',
      () {
        final schedule = SyncRetrySchedule();
        for (var attempt = 1; attempt < 40; attempt++) {
          expect(
            schedule.envelopeFor(attempt + 1),
            greaterThanOrEqualTo(schedule.envelopeFor(attempt)),
            reason: 'attempt $attempt -> ${attempt + 1} must not shrink',
          );
          expect(
            schedule.envelopeFor(attempt),
            lessThanOrEqualTo(const Duration(minutes: 5)),
          );
        }
        expect(schedule.envelopeFor(9), const Duration(minutes: 5));
        expect(schedule.envelopeFor(1000), const Duration(minutes: 5));
      },
    );

    test(
      'unbounded attempts: a very high attempt number neither overflows nor '
      'throws -- "never give up" (D-2) means the loop must survive an '
      'outage of any length',
      () {
        final schedule = SyncRetrySchedule(random: Random(7));
        for (final attempt in <int>[0, -1, 1, 100, 1000000]) {
          final delay = schedule.delayFor(attempt);
          expect(delay, greaterThanOrEqualTo(Duration.zero));
          expect(delay, lessThanOrEqualTo(const Duration(minutes: 5)));
        }
      },
    );

    test(
      'delayFor jitters INSIDE [envelope/2, envelope] -- equal jitter, so '
      'consecutive attempts still separate while avoiding a thundering herd',
      () {
        final schedule = SyncRetrySchedule(random: Random(42));
        for (var attempt = 1; attempt <= 12; attempt++) {
          final envelope = schedule.envelopeFor(attempt);
          for (var i = 0; i < 50; i++) {
            final delay = schedule.delayFor(attempt);
            expect(
              delay.inMilliseconds,
              inInclusiveRange(
                envelope.inMilliseconds ~/ 2,
                envelope.inMilliseconds,
              ),
              reason:
                  'attempt $attempt delay $delay outside envelope $envelope',
            );
          }
        }
      },
    );

    test('a seeded Random makes delayFor reproducible', () {
      expect(
        [
          for (var a = 1; a <= 5; a++)
            SyncRetrySchedule(random: Random(1)).delayFor(a),
        ],
        [
          for (var a = 1; a <= 5; a++)
            SyncRetrySchedule(random: Random(1)).delayFor(a),
        ],
      );
    });

    test('base/ceiling are injectable so tests never wait out 2s', () {
      final schedule = SyncRetrySchedule(
        base: const Duration(milliseconds: 10),
        ceiling: const Duration(milliseconds: 40),
        random: Random(3),
      );
      expect(schedule.envelopeFor(1), const Duration(milliseconds: 10));
      expect(schedule.envelopeFor(2), const Duration(milliseconds: 20));
      expect(schedule.envelopeFor(3), const Duration(milliseconds: 40));
      expect(schedule.envelopeFor(9), const Duration(milliseconds: 40));
    });
  });
}
