import 'package:flutter_test/flutter_test.dart';
import 'package:masi/core/diagnostics/build_info.dart';

/// The build stamp's PURE half. The `String.fromEnvironment` consts themselves
/// are compile-time and cannot be varied from a test — `flutter test` passes
/// none of the defines, so they are exercised here in exactly the state a
/// support reader must be able to trust: unstamped, and therefore honest about
/// it. The formatting functions take their inputs as arguments precisely so
/// this file can cover the stamped cases too.
void main() {
  group('parseBuildTime', () {
    test('an empty define is not a time — it is the absence of one', () {
      expect(parseBuildTime(''), isNull);
    });

    test('garbage is null, never a silently-invented instant', () {
      expect(parseBuildTime('not a timestamp'), isNull);
      expect(parseBuildTime('v1.2.3'), isNull);
      // Note what is NOT asserted: `DateTime.tryParse` accepts an ISO-8601
      // SHAPE with out-of-range components and rolls them over (month 13
      // becomes January of the next year), so it is not a range validator.
      // That is fine here — the only producer of this define is
      // `tool/build_web.sh`'s `date -u`, and a stamp that is off by a rollover
      // is still a stamp, whereas rejecting it would report the build as
      // unstamped and lose the version/commit context along with it.
    });

    test('a UTC stamp round-trips', () {
      expect(parseBuildTime('2026-08-26T14:03:00Z'), DateTime.utc(2026, 8, 26, 14, 3));
    });

    test(
      'an offset stamp is normalised to UTC, so two reports from two '
      'timezones are comparable by eye',
      () {
        final parsed = parseBuildTime('2026-08-26T16:03:00+02:00');
        expect(parsed, DateTime.utc(2026, 8, 26, 14, 3));
        expect(parsed!.isUtc, isTrue);
      },
    );
  });

  group('formatBuildAge', () {
    final built = DateTime.utc(2026, 8, 26, 12);

    test('under a minute reads "just now", not "0m ago"', () {
      expect(
        formatBuildAge(built, now: built.add(const Duration(seconds: 59))),
        'just now',
      );
    });

    test('minutes, then hours, then days — coarse on purpose', () {
      expect(
        formatBuildAge(built, now: built.add(const Duration(minutes: 42))),
        '42m ago',
      );
      expect(
        formatBuildAge(built, now: built.add(const Duration(hours: 3))),
        '3h ago',
      );
      expect(
        formatBuildAge(built, now: built.add(const Duration(days: 9))),
        '9d ago',
      );
    });

    test(
      'a build time in the FUTURE reports clock skew rather than a negative '
      'age — a wrong device clock is a live explanation for expired JWTs and '
      'last-writer-wins resolving the wrong way, so it is worth naming',
      () {
        expect(
          formatBuildAge(built, now: built.subtract(const Duration(hours: 2))),
          'clock skew',
        );
      },
    );

    test(
      'a few seconds of slack is NOT skew — a fresh deploy legitimately lands '
      'slightly "in the future" from an unsynchronised client',
      () {
        expect(
          formatBuildAge(built, now: built.subtract(const Duration(seconds: 20))),
          'just now',
        );
      },
    );

    test('a local `now` is compared in UTC, not in wall-clock digits', () {
      final now = built.add(const Duration(hours: 5)).toLocal();
      expect(formatBuildAge(built, now: now), '5h ago');
    });
  });

  group('formatBuildStamp', () {
    test(
      'an unstamped build says so explicitly — never a plausible-looking '
      'default, because a stamp that invents a build time gets believed',
      () {
        expect(formatBuildStamp(null), 'unknown (build not stamped)');
      },
    );

    test('carries both an absolute UTC stamp and a relative age', () {
      final built = DateTime.utc(2026, 8, 26, 14, 3);
      expect(
        formatBuildStamp(built, now: built.add(const Duration(hours: 2))),
        '2026-08-26 14:03 UTC · 2h ago',
      );
    });

    test('pads every field, so two stamps line up character-for-character', () {
      final built = DateTime.utc(2026, 1, 2, 3, 4);
      expect(
        formatBuildStamp(built, now: built),
        '2026-01-02 03:04 UTC · just now',
      );
    });
  });

  group('BuildInfo, as an UNSTAMPED build sees it', () {
    test(
      'commit and branch are the honest "unknown", and the label collapses to '
      'it rather than inventing half a sentence',
      () {
        expect(BuildInfo.gitSha, BuildInfo.unknown);
        expect(BuildInfo.gitBranch, BuildInfo.unknown);
        expect(BuildInfo.commitLabel, BuildInfo.unknown);
      },
    );

    test('there is no build time, and isStamped says so', () {
      expect(BuildInfo.buildTimeRaw, isEmpty);
      expect(BuildInfo.buildTime, isNull);
      expect(BuildInfo.isStamped, isFalse);
    });

    test(
      'the version still has a real value — unlike a commit, it is genuinely '
      'knowable without the define, and mirrors pubspec.yaml',
      () {
        expect(BuildInfo.appVersion, isNotEmpty);
        expect(BuildInfo.appVersion, isNot(BuildInfo.unknown));
      },
    );

    test(
      'runtimeToken carries NO whitespace — it goes into a single-line '
      'key=value blob, where a space would end the token early',
      () {
        expect(BuildInfo.runtimeToken, isNot(contains(' ')));
        expect(BuildInfo.runtimeLabel, isNotEmpty);
      },
    );

    test('the mode label is one of the three real modes', () {
      expect(BuildInfo.modeLabel, isIn(['debug', 'profile', 'release']));
    });
  });
}
