// Unit tests for ToposFilter / applyToposFilter / ToposFilterController
// (Subtask D of the filtering plan, ~/.claude/plans/masi-filtering.md).
// Pure logic + Notifier state, no widget harness needed -- the widget-level
// (Filters sheet + live list) coverage lives in topos_screen_test.dart.

import 'package:climbtopo/core/grades/grade_system.dart';
import 'package:climbtopo/features/library/application/library_providers.dart';
import 'package:climbtopo/features/library/data/library_crud_repository.dart';
import 'package:climbtopo/shared/filtering/grade_range.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

TopoRef _topo({
  required String wallId,
  String? areaId,
  String visibility = 'private',
  List<double> routeGradeKeys = const [],
}) {
  return TopoRef(
    wallId: wallId,
    name: 'Topo $wallId',
    thumbnailPath: null,
    routeCount: routeGradeKeys.length,
    createdAt: 1000,
    visibility: visibility,
    areaId: areaId,
    areaName: areaId == null ? null : 'Area $areaId',
    routeGradeKeys: routeGradeKeys,
  );
}

void main() {
  group('ToposFilter.isActive', () {
    test('false for the default filter', () {
      expect(const ToposFilter().isActive, isFalse);
    });

    test('true when grade is active', () {
      expect(
        const ToposFilter(grade: GradeRange(minToken: '6a')).isActive,
        isTrue,
      );
    });

    test('true when visibility != all', () {
      expect(
        const ToposFilter(
          visibility: ToposVisibilityFilter.shared,
        ).isActive,
        isTrue,
      );
    });

    test('true when areaIds is non-empty', () {
      expect(const ToposFilter(areaIds: {'area-1'}).isActive, isTrue);
    });
  });

  group('ToposFilter.matches — grade facet (D2)', () {
    const range = GradeRange(minToken: '6a', maxToken: '7a');

    test('matches when at least one route grade key falls in range', () {
      const filter = ToposFilter(grade: range);
      final topo = _topo(
        wallId: 'w1',
        routeGradeKeys: [gradeSortKey(GradeSystem.french, '6b')],
      );
      expect(filter.matches(topo), isTrue);
    });

    test('excludes when no route grade key falls in range', () {
      const filter = ToposFilter(grade: range);
      final topo = _topo(
        wallId: 'w1',
        routeGradeKeys: [gradeSortKey(GradeSystem.french, '8a')],
      );
      expect(filter.matches(topo), isFalse);
    });

    test(
      'excludes a topo with no graded routes when the grade filter is '
      'active',
      () {
        const filter = ToposFilter(grade: range);
        final topo = _topo(wallId: 'w1');
        expect(filter.matches(topo), isFalse);
      },
    );

    test(
      'an inactive grade filter matches regardless of routeGradeKeys',
      () {
        const filter = ToposFilter();
        expect(filter.matches(_topo(wallId: 'w1')), isTrue);
      },
    );

    test('matches inclusively at both range boundaries', () {
      const filter = ToposFilter(grade: range);
      expect(
        filter.matches(
          _topo(
            wallId: 'w1',
            routeGradeKeys: [gradeSortKey(GradeSystem.french, '6a')],
          ),
        ),
        isTrue,
      );
      expect(
        filter.matches(
          _topo(
            wallId: 'w2',
            routeGradeKeys: [gradeSortKey(GradeSystem.french, '7a')],
          ),
        ),
        isTrue,
      );
    });
  });

  group('ToposFilter.matches — visibility facet (D2)', () {
    test('all matches both private and shared topos', () {
      const filter = ToposFilter();
      expect(filter.matches(_topo(wallId: 'w1')), isTrue);
      expect(
        filter.matches(_topo(wallId: 'w2', visibility: 'shared')),
        isTrue,
      );
    });

    test('shared matches only shared topos', () {
      const filter = ToposFilter(visibility: ToposVisibilityFilter.shared);
      expect(
        filter.matches(_topo(wallId: 'w1', visibility: 'shared')),
        isTrue,
      );
      expect(
        filter.matches(_topo(wallId: 'w2', visibility: 'private')),
        isFalse,
      );
    });

    test('private matches only private topos', () {
      const filter = ToposFilter(visibility: ToposVisibilityFilter.private);
      expect(
        filter.matches(_topo(wallId: 'w1', visibility: 'private')),
        isTrue,
      );
      expect(
        filter.matches(_topo(wallId: 'w2', visibility: 'shared')),
        isFalse,
      );
    });
  });

  group('ToposFilter.matches — area facet incl. Unfiled (D2)', () {
    test('empty areaIds matches every topo regardless of area', () {
      const filter = ToposFilter();
      expect(filter.matches(_topo(wallId: 'w1', areaId: 'area-1')), isTrue);
      expect(filter.matches(_topo(wallId: 'w2')), isTrue);
    });

    test(
      'a selected real area matches only topos filed under that areaId',
      () {
        const filter = ToposFilter(areaIds: {'area-1'});
        expect(
          filter.matches(_topo(wallId: 'w1', areaId: 'area-1')),
          isTrue,
        );
        expect(
          filter.matches(_topo(wallId: 'w2', areaId: 'area-2')),
          isFalse,
        );
        expect(filter.matches(_topo(wallId: 'w3')), isFalse);
      },
    );

    test(
      'selecting Unfiled matches only topos with a null areaId',
      () {
        const filter = ToposFilter(areaIds: {ToposFilter.unfiledAreaId});
        expect(filter.matches(_topo(wallId: 'w1')), isTrue);
        expect(
          filter.matches(_topo(wallId: 'w2', areaId: 'area-1')),
          isFalse,
        );
      },
    );

    test(
      'selecting both a real area and Unfiled matches topos from either',
      () {
        const filter = ToposFilter(
          areaIds: {'area-1', ToposFilter.unfiledAreaId},
        );
        expect(
          filter.matches(_topo(wallId: 'w1', areaId: 'area-1')),
          isTrue,
        );
        expect(filter.matches(_topo(wallId: 'w2')), isTrue);
        expect(
          filter.matches(_topo(wallId: 'w3', areaId: 'area-2')),
          isFalse,
        );
      },
    );
  });

  group('ToposFilter.matches — combined facets are AND-ed (D2)', () {
    test('a topo must satisfy every active facet simultaneously', () {
      const filter = ToposFilter(
        grade: GradeRange(minToken: '6a', maxToken: '7a'),
        visibility: ToposVisibilityFilter.shared,
        areaIds: {'area-1'},
      );
      final matching = _topo(
        wallId: 'w1',
        areaId: 'area-1',
        visibility: 'shared',
        routeGradeKeys: [gradeSortKey(GradeSystem.french, '6b')],
      );
      expect(filter.matches(matching), isTrue);

      final wrongVisibility = _topo(
        wallId: 'w2',
        areaId: 'area-1',
        visibility: 'private',
        routeGradeKeys: [gradeSortKey(GradeSystem.french, '6b')],
      );
      expect(filter.matches(wrongVisibility), isFalse);

      final wrongArea = _topo(
        wallId: 'w3',
        areaId: 'area-2',
        visibility: 'shared',
        routeGradeKeys: [gradeSortKey(GradeSystem.french, '6b')],
      );
      expect(filter.matches(wrongArea), isFalse);

      final wrongGrade = _topo(
        wallId: 'w4',
        areaId: 'area-1',
        visibility: 'shared',
        routeGradeKeys: [gradeSortKey(GradeSystem.french, '8a')],
      );
      expect(filter.matches(wrongGrade), isFalse);
    });
  });

  group('applyToposFilter (D2)', () {
    test('an inactive filter returns every topo, unchanged order', () {
      final topos = [
        _topo(wallId: 'w1'),
        _topo(wallId: 'w2', visibility: 'shared'),
      ];
      expect(applyToposFilter(topos, const ToposFilter()), topos);
    });

    test('filters down to only matching topos, preserving relative order', () {
      final w1 = _topo(wallId: 'w1', visibility: 'shared');
      final w2 = _topo(wallId: 'w2', visibility: 'private');
      final w3 = _topo(wallId: 'w3', visibility: 'shared');

      final filtered = applyToposFilter(
        [w1, w2, w3],
        const ToposFilter(visibility: ToposVisibilityFilter.shared),
      );

      expect(filtered, [w1, w3]);
    });
  });

  group('ToposFilter equality/copyWith', () {
    test(
      'equal when grade/visibility/areaIds all match (areaIds is '
      'order-independent)',
      () {
        const a = ToposFilter(
          visibility: ToposVisibilityFilter.shared,
          areaIds: {'a', 'b'},
        );
        const b = ToposFilter(
          visibility: ToposVisibilityFilter.shared,
          areaIds: {'b', 'a'},
        );
        expect(a, equals(b));
        expect(a.hashCode, equals(b.hashCode));
      },
    );

    test('not equal when a facet differs', () {
      const a = ToposFilter(visibility: ToposVisibilityFilter.shared);
      const b = ToposFilter(visibility: ToposVisibilityFilter.private);
      expect(a == b, isFalse);
    });

    test('copyWith replaces only the given field', () {
      const base = ToposFilter(visibility: ToposVisibilityFilter.shared);
      final changed = base.copyWith(areaIds: {'area-1'});
      expect(changed.visibility, ToposVisibilityFilter.shared);
      expect(changed.areaIds, {'area-1'});
    });
  });

  group('ToposFilterController (Notifier)', () {
    test('starts at the default (inactive) filter', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(toposFilterProvider), const ToposFilter());
    });

    test(
      'setGrade/setVisibility/toggleArea each update state independently',
      () {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final notifier = container.read(toposFilterProvider.notifier);

        notifier.setGrade(const GradeRange(minToken: '6a'));
        expect(container.read(toposFilterProvider).grade.minToken, '6a');

        notifier.setVisibility(ToposVisibilityFilter.private);
        expect(
          container.read(toposFilterProvider).visibility,
          ToposVisibilityFilter.private,
        );

        notifier.toggleArea('area-1');
        expect(container.read(toposFilterProvider).areaIds, {'area-1'});
        notifier.toggleArea('area-1');
        expect(container.read(toposFilterProvider).areaIds, isEmpty);
      },
    );

    test('clear resets every facet back to the default filter', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(toposFilterProvider.notifier);
      notifier.setGrade(const GradeRange(minToken: '6a'));
      notifier.setVisibility(ToposVisibilityFilter.shared);
      notifier.toggleArea('area-1');

      notifier.clear();

      expect(container.read(toposFilterProvider), const ToposFilter());
    });
  });
}
