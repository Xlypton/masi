import 'package:masi/core/grades/grade_system.dart';
import 'package:masi/features/logbook/data/ascents_repository.dart';
import 'package:masi/features/logbook/presentation/logbook_providers.dart';
import 'package:masi/shared/filtering/grade_range.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Builds a [LogbookEntry] with sensible defaults for fields irrelevant to
/// the filter predicate under test (ascentId/climbedAt/wallName), so each
/// test only has to spell out the fields it actually varies.
LogbookEntry _entry({
  String ascentId = 'a1',
  AscentStyle style = AscentStyle.redpoint,
  double? gradeSortKey,
  String? routeStyle,
}) {
  return LogbookEntry(
    ascentId: ascentId,
    climbedAt: DateTime.utc(2026, 1, 1),
    style: style,
    wallName: 'Wall',
    gradeSortKey: gradeSortKey,
    routeStyle: routeStyle,
  );
}

void main() {
  group('LogbookFilter.matches', () {
    test('no active facets matches every entry, including ungraded/'
        'unstyled ones', () {
      const filter = LogbookFilter();
      expect(filter.isActive, isFalse);

      expect(filter.matches(_entry()), isTrue);
      expect(
        filter.matches(
          _entry(
            gradeSortKey: gradeSortKey(GradeSystem.french, '7a'),
            routeStyle: 'sport',
          ),
        ),
        isTrue,
      );
    });

    test('grade-only: keeps entries whose gradeSortKey falls in range, '
        'excludes out-of-range and ungraded entries', () {
      final filter = LogbookFilter(
        grade: GradeRange(
          minToken: '6a',
          maxToken: '7a',
        ),
      );
      expect(filter.isActive, isTrue);

      expect(
        filter.matches(
          _entry(gradeSortKey: gradeSortKey(GradeSystem.french, '6b')),
        ),
        isTrue,
        reason: 'inside the [6a, 7a] range',
      );
      expect(
        filter.matches(
          _entry(gradeSortKey: gradeSortKey(GradeSystem.french, '5a')),
        ),
        isFalse,
        reason: 'below the range',
      );
      expect(
        filter.matches(
          _entry(gradeSortKey: gradeSortKey(GradeSystem.french, '8a')),
        ),
        isFalse,
        reason: 'above the range',
      );
      expect(
        filter.matches(_entry(gradeSortKey: null)),
        isFalse,
        reason: 'an ungraded entry cannot be known to fall in an active '
            'grade range',
      );
    });

    test('routeStyle-only: keeps entries whose routeStyle is selected', () {
      const filter = LogbookFilter(routeStyles: {'sport', 'trad'});

      expect(filter.matches(_entry(routeStyle: 'sport')), isTrue);
      expect(filter.matches(_entry(routeStyle: 'trad')), isTrue);
      expect(filter.matches(_entry(routeStyle: 'boulder')), isFalse);
      expect(
        filter.matches(_entry(routeStyle: null)),
        isFalse,
        reason: 'an unstyled entry does not match an active style filter',
      );
    });

    test('ascentType-only: keeps entries whose ascent style is selected', () {
      const filter = LogbookFilter(
        ascentTypes: {AscentStyle.onsight, AscentStyle.flash},
      );

      expect(filter.matches(_entry(style: AscentStyle.onsight)), isTrue);
      expect(filter.matches(_entry(style: AscentStyle.flash)), isTrue);
      expect(filter.matches(_entry(style: AscentStyle.redpoint)), isFalse);
    });

    test('combined facets AND together', () {
      final filter = LogbookFilter(
        grade: GradeRange(minToken: '6a', maxToken: '7c'),
        routeStyles: const {'sport'},
        ascentTypes: const {AscentStyle.redpoint},
      );

      expect(
        filter.matches(
          _entry(
            style: AscentStyle.redpoint,
            gradeSortKey: gradeSortKey(GradeSystem.french, '6c'),
            routeStyle: 'sport',
          ),
        ),
        isTrue,
        reason: 'satisfies all three active facets',
      );
      expect(
        filter.matches(
          _entry(
            style: AscentStyle.onsight, // wrong ascent type
            gradeSortKey: gradeSortKey(GradeSystem.french, '6c'),
            routeStyle: 'sport',
          ),
        ),
        isFalse,
      );
      expect(
        filter.matches(
          _entry(
            style: AscentStyle.redpoint,
            gradeSortKey: gradeSortKey(GradeSystem.french, '4a'), // out of range
            routeStyle: 'sport',
          ),
        ),
        isFalse,
      );
      expect(
        filter.matches(
          _entry(
            style: AscentStyle.redpoint,
            gradeSortKey: gradeSortKey(GradeSystem.french, '6c'),
            routeStyle: 'trad', // wrong style
          ),
        ),
        isFalse,
      );
    });

    test('copyWith replaces only the given field', () {
      const base = LogbookFilter(routeStyles: {'sport'});
      final updated = base.copyWith(ascentTypes: {AscentStyle.flash});

      expect(updated.routeStyles, {'sport'});
      expect(updated.ascentTypes, {AscentStyle.flash});
    });

    test('equality/hashCode are value-based (set order-independent)', () {
      const a = LogbookFilter(routeStyles: {'sport', 'trad'});
      const b = LogbookFilter(routeStyles: {'trad', 'sport'});
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });
  });

  group('logbookFilterProvider', () {
    test('defaults to an inactive filter', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final filter = container.read(logbookFilterProvider);
      expect(filter.isActive, isFalse);
      expect(filter, const LogbookFilter());
    });

    test('setGrade/setRouteStyles/setAscentTypes update state; clear '
        'resets to the default', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(logbookFilterProvider.notifier);

      notifier.setGrade(const GradeRange(minToken: '6a'));
      notifier.setRouteStyles({'sport'});
      notifier.setAscentTypes({AscentStyle.onsight});

      final filter = container.read(logbookFilterProvider);
      expect(filter.grade.minToken, '6a');
      expect(filter.routeStyles, {'sport'});
      expect(filter.ascentTypes, {AscentStyle.onsight});
      expect(filter.isActive, isTrue);

      notifier.clear();
      expect(container.read(logbookFilterProvider), const LogbookFilter());
    });
  });
}
