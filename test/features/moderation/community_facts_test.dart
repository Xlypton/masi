// Community facts (phase 4 / R-1) — the layer that is NOT gated behind the
// owner's approval.
//
// Two rules carry the whole phase and are tested hardest here:
//   * an unknown hazard severity fails LOUD (danger), the opposite direction
//     to moderation state, because under-displaying a safety warning hurts
//     somebody;
//   * the topo owner can resolve a hazard on their topo but there is no delete
//     path for them at all — C-12, safety content is never silently removed.

import 'package:flutter_test/flutter_test.dart';
import 'package:masi/core/grades/grade_system.dart';
import 'package:masi/features/moderation/domain/community_facts.dart';

HazardReport _hazard({
  String id = 'h1',
  String authorId = 'reporter',
  HazardSeverity severity = HazardSeverity.caution,
  int? resolvedAt,
  String? routeId,
}) => HazardReport(
  id: id,
  wallId: 'w1',
  routeId: routeId,
  authorId: authorId,
  severity: severity,
  body: 'Loose flake at the third clip',
  createdAt: 1000,
  resolvedAt: resolvedAt,
  resolvedBy: resolvedAt == null ? null : 'someone',
);

GradeOpinion _opinion(String raw, {GradeSystem system = GradeSystem.french}) =>
    GradeOpinion(
      id: 'o-$raw',
      routeId: 'r1',
      authorId: 'a-$raw',
      system: system,
      raw: raw,
      sortKey: gradeSortKey(system, raw),
      createdAt: 1000,
    );

void main() {
  group('HazardSeverity.fromWire', () {
    test('parses the three known severities', () {
      expect(HazardSeverity.fromWire('note'), HazardSeverity.note);
      expect(HazardSeverity.fromWire('caution'), HazardSeverity.caution);
      expect(HazardSeverity.fromWire('danger'), HazardSeverity.danger);
    });

    test(
      'an UNKNOWN severity fails loud as danger — never quietly demoted to a '
      'note, because the cost of under-displaying a warning is an injury',
      () {
        expect(HazardSeverity.fromWire('catastrophic'), HazardSeverity.danger);
        expect(HazardSeverity.fromWire(null), HazardSeverity.danger);
        expect(HazardSeverity.fromWire(''), HazardSeverity.danger);
      },
    );

    test('rank orders by seriousness', () {
      expect(
        HazardSeverity.danger.rank > HazardSeverity.caution.rank,
        isTrue,
      );
      expect(HazardSeverity.caution.rank > HazardSeverity.note.rank, isTrue);
      expect(HazardSeverity.danger.isUrgent, isTrue);
      expect(HazardSeverity.caution.isUrgent, isFalse);
    });
  });

  group('HazardReport.canResolve', () {
    test('the reporter can withdraw their own report', () {
      expect(
        _hazard(
          authorId: 'reporter',
        ).canResolve(uid: 'reporter', wallOwnerId: 'owner'),
        isTrue,
      );
    });

    test('the topo owner can mark it dealt with', () {
      expect(
        _hazard().canResolve(uid: 'owner', wallOwnerId: 'owner'),
        isTrue,
      );
    });

    test('an unrelated passer-by cannot', () {
      expect(
        _hazard().canResolve(uid: 'stranger', wallOwnerId: 'owner'),
        isFalse,
      );
    });

    test('a signed-out reader cannot', () {
      expect(_hazard().canResolve(uid: null, wallOwnerId: 'owner'), isFalse);
    });
  });

  group('HazardSummary', () {
    test('reports the worst UNRESOLVED severity, ignoring resolved ones', () {
      final summary = HazardSummary.of([
        _hazard(id: 'a', severity: HazardSeverity.note),
        _hazard(id: 'b', severity: HazardSeverity.caution),
        _hazard(id: 'c', severity: HazardSeverity.danger, resolvedAt: 2000),
      ]);

      expect(
        summary.worst,
        HazardSeverity.caution,
        reason: 'the danger was resolved; it must not drive the banner',
      );
      expect(summary.unresolvedCount, 2);
      expect(summary.resolvedCount, 1);
      expect(summary.hasUnresolved, isTrue);
    });

    test('nothing reported at all', () {
      final summary = HazardSummary.of(const []);
      expect(summary.worst, isNull);
      expect(summary.hasUnresolved, isFalse);
      expect(summary.hasAny, isFalse);
    });

    test(
      '"reported and resolved" stays distinguishable from "never reported" — '
      'collapsing them would erase the history resolve-not-delete exists for',
      () {
        final summary = HazardSummary.of([
          _hazard(severity: HazardSeverity.danger, resolvedAt: 2000),
        ]);

        expect(summary.hasUnresolved, isFalse);
        expect(summary.worst, isNull);
        expect(summary.hasAny, isTrue);
        expect(summary.resolvedCount, 1);
      },
    );
  });

  group('GradeConsensus', () {
    test('states nothing until three independent opinions exist', () {
      for (final raws in [
        <String>[],
        ['6a'],
        ['6a', '6b'],
      ]) {
        final consensus = GradeConsensus.of(raws.map(_opinion));
        expect(
          consensus.hasConsensus,
          isFalse,
          reason: '${raws.length} opinions must not be sold as a consensus',
        );
        expect(consensus.sortKey, isNull);
        expect(consensus.count, raws.length);
      }
    });

    test('three opinions yield the median', () {
      final consensus = GradeConsensus.of(['6a', '6b', '6a+'].map(_opinion));
      expect(consensus.hasConsensus, isTrue);
      expect(consensus.displayGrade(GradeSystem.french), '6a+');
      expect(consensus.count, 3);
    });

    test(
      'the median ignores a sandbagger a mean would have followed',
      () {
        final honest = ['7a', '7a', '7a', '7a+'];
        final withTroll = [...honest, '4a'];

        final before = GradeConsensus.of(honest.map(_opinion));
        final after = GradeConsensus.of(withTroll.map(_opinion));

        expect(after.displayGrade(GradeSystem.french), '7a');
        expect(
          after.sortKey,
          before.sortKey,
          reason: 'one absurd opinion must not move the community grade',
        );
      },
    );

    test(
      'an even split resolves to the HARDER of the two middles — never an '
      'invented average, and conservative in the safer direction',
      () {
        final consensus = GradeConsensus.of(['6a', '6b'].map(_opinion));
        expect(consensus.hasConsensus, isFalse);

        final four = GradeConsensus.of(
          ['6a', '6a+', '6b', '6b+'].map(_opinion),
        );
        expect(four.displayGrade(GradeSystem.french), '6b');
      },
    );

    test('spread exposes disagreement even when a median exists', () {
      final tight = GradeConsensus.of(['6a', '6a', '6a'].map(_opinion));
      final wide = GradeConsensus.of(['5c', '6a', '7a'].map(_opinion));

      expect(tight.spread, 0);
      expect(wide.spread, greaterThan(tight.spread));
    });

    test('flags a disagreement with the author worth surfacing', () {
      final author = gradeSortKey(GradeSystem.french, '6a');

      final agrees = GradeConsensus.of(
        ['6a', '6a+', '6a'].map(_opinion),
        authorSortKey: author,
      );
      final disagrees = GradeConsensus.of(
        ['7a', '7a', '7a+'].map(_opinion),
        authorSortKey: author,
      );

      expect(agrees.disagreesWithAuthor, isFalse);
      expect(disagrees.disagreesWithAuthor, isTrue);
    });

    test('an ungraded route can never disagree with anybody', () {
      final consensus = GradeConsensus.of(['7a', '7a', '7a'].map(_opinion));
      expect(consensus.authorSortKey, isNull);
      expect(consensus.disagreesWithAuthor, isFalse);
    });

    test(
      'UIAA and French opinions mix on the shared scale, and read back in '
      'either system',
      () {
        final consensus = GradeConsensus.of([
          _opinion('6a'),
          _opinion('VI+', system: GradeSystem.uiaa),
          _opinion('6a+'),
        ]);

        expect(consensus.hasConsensus, isTrue);
        expect(consensus.displayGrade(GradeSystem.french), isNotNull);
        expect(consensus.displayGrade(GradeSystem.uiaa), isNotNull);
      },
    );

    test('no consensus renders no grade in any system', () {
      final consensus = GradeConsensus.of([_opinion('6a')]);
      expect(consensus.displayGrade(GradeSystem.french), isNull);
      expect(consensus.displayGrade(GradeSystem.uiaa), isNull);
    });
  });

  group('VerificationSummary', () {
    test('counts both directions', () {
      final summary = VerificationSummary.of([
        TopoVerification(
          id: '1',
          wallId: 'w1',
          authorId: 'a',
          accurate: true,
          createdAt: 1,
        ),
        TopoVerification(
          id: '2',
          wallId: 'w1',
          authorId: 'b',
          accurate: true,
          createdAt: 2,
        ),
        TopoVerification(
          id: '3',
          wallId: 'w1',
          authorId: 'c',
          accurate: false,
          note: 'line is on the wrong crack',
          createdAt: 3,
        ),
      ]);

      expect(summary.accurateCount, 2);
      expect(summary.inaccurateCount, 1);
      expect(summary.total, 3);
    });

    test(
      'a single dissent still marks the topo disputed, however outvoted — one '
      'credible "the line is wrong" is worth reading',
      () {
        final summary = VerificationSummary.of([
          for (var i = 0; i < 20; i++)
            TopoVerification(
              id: 'ok$i',
              wallId: 'w1',
              authorId: 'a$i',
              accurate: true,
              createdAt: i,
            ),
          TopoVerification(
            id: 'no',
            wallId: 'w1',
            authorId: 'z',
            accurate: false,
            createdAt: 99,
          ),
        ]);

        expect(summary.isDisputed, isTrue);
        expect(summary.accurateCount, 20);
      },
    );

    test('nothing verified is not disputed', () {
      expect(VerificationSummary.of(const []).isDisputed, isFalse);
    });
  });
}
