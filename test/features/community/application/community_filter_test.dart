import 'package:masi/features/community/application/community_providers.dart';
import 'package:masi/features/community/data/community_repository.dart';
import 'package:masi/shared/filtering/grade_range.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Covers Subtask B's B2 assertion: `CommunityFilter.matches` (grade-only,
/// style-only, both, neither) plus the AND-with-name-search combination
/// used by `CommunityScreen`'s `_FeedView`. Pure Dart -- no widget harness,
/// no database -- constructing `SharedTopo` directly.
void main() {
  SharedTopo topo({
    required String wallId,
    String name = 'Some Topo',
    List<double> routeGradeKeys = const [],
    Set<String> routeStyles = const {},
    Set<String> routeStyleTags = const {},
  }) {
    return SharedTopo(
      wallId: wallId,
      name: name,
      routeCount: routeGradeKeys.length,
      likeCount: 0,
      commentCount: 0,
      routeGradeKeys: routeGradeKeys,
      routeStyles: routeStyles,
      routeStyleTags: routeStyleTags,
    );
  }

  group('B2: CommunityFilter.matches', () {
    test('an inactive filter (no grade, no styles) matches every topo, '
        'including one with no routes at all', () {
      const filter = CommunityFilter();
      expect(filter.isActive, isFalse);

      expect(filter.matches(topo(wallId: 'w1')), isTrue);
      expect(
        filter.matches(
          topo(wallId: 'w2', routeGradeKeys: [7.0], routeStyles: {'sport'}),
        ),
        isTrue,
      );
    });

    test('grade-only: matches iff ANY routeGradeKey falls in range', () {
      const filter = CommunityFilter(
        grade: GradeRange(minToken: '6a', maxToken: '7a'),
      );
      expect(filter.isActive, isTrue);

      // One route (6b, key 9.0) is in [7.0, 13.0] -> matches.
      expect(
        filter.matches(
          topo(wallId: 'w-in', routeGradeKeys: [3.0, 9.0]),
        ),
        isTrue,
      );
      // No route falls in range -> excluded.
      expect(
        filter.matches(topo(wallId: 'w-out', routeGradeKeys: [3.0, 25.0])),
        isFalse,
      );
      // No routes at all -> excluded (an active grade filter can't match
      // an ungraded/routeless topo).
      expect(filter.matches(topo(wallId: 'w-empty')), isFalse);
    });

    test('style-only: matches iff ANY routeStyle is in the selected set', () {
      const filter = CommunityFilter(styles: {'sport', 'boulder'});
      expect(filter.isActive, isTrue);

      expect(
        filter.matches(topo(wallId: 'w-in', routeStyles: {'trad', 'sport'})),
        isTrue,
      );
      expect(
        filter.matches(topo(wallId: 'w-out', routeStyles: {'trad'})),
        isFalse,
      );
      expect(filter.matches(topo(wallId: 'w-empty')), isFalse);
    });

    test(
      'both active: a topo must satisfy the grade range AND the style '
      'selection (independently -- not necessarily via the same route)',
      () {
        const filter = CommunityFilter(
          grade: GradeRange(minToken: '6a', maxToken: '7a'),
          styles: {'sport'},
        );

        // Satisfies grade (9.0 in range) AND style ('sport' present).
        expect(
          filter.matches(
            topo(
              wallId: 'w-both',
              routeGradeKeys: [9.0],
              routeStyles: {'sport'},
            ),
          ),
          isTrue,
        );
        // Grade matches but style doesn't -> excluded.
        expect(
          filter.matches(
            topo(
              wallId: 'w-grade-only',
              routeGradeKeys: [9.0],
              routeStyles: {'trad'},
            ),
          ),
          isFalse,
        );
        // Style matches but grade doesn't -> excluded.
        expect(
          filter.matches(
            topo(
              wallId: 'w-style-only',
              routeGradeKeys: [25.0],
              routeStyles: {'sport'},
            ),
          ),
          isFalse,
        );
      },
    );

    test('copyWith replaces only the given field', () {
      const base = CommunityFilter(styles: {'sport'});
      final withGrade = base.copyWith(
        grade: const GradeRange(minToken: '6a'),
      );

      expect(withGrade.grade.minToken, '6a');
      expect(withGrade.styles, {'sport'});
    });

    test('value equality: same grade + same style set (any order) are '
        'equal', () {
      const a = CommunityFilter(
        grade: GradeRange(minToken: '6a', maxToken: '7a'),
        styles: {'sport', 'trad'},
      );
      const b = CommunityFilter(
        grade: GradeRange(minToken: '6a', maxToken: '7a'),
        styles: {'trad', 'sport'},
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });
  });

  group('style-tags facet: CommunityFilter.styleTags', () {
    test(
      'a topo with routeStyleTags {dyno, crimpy} passes a filter selecting '
      '{crimpy} but fails one selecting {slabby}',
      () {
        final t = topo(
          wallId: 'w1',
          routeStyleTags: {'dyno', 'crimpy'},
        );

        expect(
          const CommunityFilter(styleTags: {'crimpy'}).matches(t),
          isTrue,
        );
        expect(
          const CommunityFilter(styleTags: {'slabby'}).matches(t),
          isFalse,
        );
      },
    );

    test('an empty styleTags selection always passes, regardless of the '
        "topo's own tags (including none at all)", () {
      const filter = CommunityFilter();
      expect(filter.matches(topo(wallId: 'w-none')), isTrue);
      expect(
        filter.matches(topo(wallId: 'w-some', routeStyleTags: {'dyno'})),
        isTrue,
      );
    });

    test(
      'combines (AND) correctly with an active grade filter: both must '
      'pass independently',
      () {
        const filter = CommunityFilter(
          grade: GradeRange(minToken: '6a', maxToken: '7a'),
          styleTags: {'crimpy'},
        );

        // Grade in range AND tag present -> matches.
        expect(
          filter.matches(
            topo(
              wallId: 'w-both',
              routeGradeKeys: [9.0],
              routeStyleTags: {'crimpy'},
            ),
          ),
          isTrue,
        );
        // Grade in range but tag missing -> excluded.
        expect(
          filter.matches(
            topo(
              wallId: 'w-grade-only',
              routeGradeKeys: [9.0],
              routeStyleTags: {'slabby'},
            ),
          ),
          isFalse,
        );
        // Tag present but grade out of range -> excluded.
        expect(
          filter.matches(
            topo(
              wallId: 'w-tag-only',
              routeGradeKeys: [25.0],
              routeStyleTags: {'crimpy'},
            ),
          ),
          isFalse,
        );
      },
    );

    test('isActive is true when styleTags is non-empty, even with no other '
        'sub-filter active', () {
      expect(const CommunityFilter().isActive, isFalse);
      expect(const CommunityFilter(styleTags: {'dyno'}).isActive, isTrue);
    });

    test('copyWith replaces only styleTags, leaving grade/styles untouched', () {
      const base = CommunityFilter(styles: {'sport'});
      final withTags = base.copyWith(styleTags: {'dyno'});

      expect(withTags.styleTags, {'dyno'});
      expect(withTags.styles, {'sport'});
      expect(withTags.grade, const GradeRange());
    });

    test(
      'value equality considers styleTags (order-independent) and clear() '
      'resets it along with grade/styles',
      () {
        const a = CommunityFilter(styleTags: {'dyno', 'crimpy'});
        const b = CommunityFilter(styleTags: {'crimpy', 'dyno'});
        expect(a, b);
        expect(a.hashCode, b.hashCode);

        final container = ProviderContainer();
        addTearDown(container.dispose);
        final notifier = container.read(communityFilterProvider.notifier);
        notifier.setStyleTags({'dyno'});
        expect(container.read(communityFilterProvider).styleTags, {'dyno'});

        notifier.clear();
        expect(
          container.read(communityFilterProvider),
          const CommunityFilter(),
        );
        expect(container.read(communityFilterProvider).styleTags, isEmpty);
      },
    );
  });

  group('B2: AND with name search (as CommunityScreen._FeedView applies it)', () {
    /// Mirrors `_FeedView.build`'s combination logic exactly: a query-based
    /// name search narrows the list first, then `CommunityFilter.matches`
    /// narrows further.
    List<SharedTopo> applyBoth(
      List<SharedTopo> topos,
      String query,
      CommunityFilter filter,
    ) {
      final searchFiltered = query.isEmpty
          ? topos
          : topos.where((t) => t.name.toLowerCase().contains(query)).toList();
      return searchFiltered.where(filter.matches).toList();
    }

    test(
      'a topo must match BOTH the name search and the grade/style filter',
      () {
        const filter = CommunityFilter(styles: {'sport'});
        final topos = [
          topo(wallId: 'w1', name: 'Sunny Wall', routeStyles: {'sport'}),
          topo(wallId: 'w2', name: 'Sunny Slab', routeStyles: {'trad'}),
          topo(wallId: 'w3', name: 'Shady Wall', routeStyles: {'sport'}),
        ];

        final result = applyBoth(topos, 'sunny', filter);

        expect(result.map((t) => t.wallId), ['w1']);
      },
    );

    test('an empty query + an active filter still filters correctly', () {
      const filter = CommunityFilter(
        grade: GradeRange(minToken: '7a'),
      );
      final topos = [
        topo(wallId: 'w1', routeGradeKeys: [13.0]),
        topo(wallId: 'w2', routeGradeKeys: [3.0]),
      ];

      final result = applyBoth(topos, '', filter);

      expect(result.map((t) => t.wallId), ['w1']);
    });
  });

  group('B: communityFilterProvider (Riverpod v3 Notifier)', () {
    test('starts inactive; setGrade/setStyles/clear update state '
        'reactively', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(container.read(communityFilterProvider), const CommunityFilter());

      final notifier = container.read(communityFilterProvider.notifier);
      notifier.setGrade(const GradeRange(minToken: '6a', maxToken: '7a'));
      notifier.setStyles({'sport'});

      final filtered = container.read(communityFilterProvider);
      expect(filtered.grade.minToken, '6a');
      expect(filtered.styles, {'sport'});
      expect(filtered.isActive, isTrue);

      notifier.clear();
      expect(container.read(communityFilterProvider), const CommunityFilter());
    });
  });
}
