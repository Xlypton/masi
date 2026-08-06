// The local mirror of community facts (phase 4 / R-1), and the service that
// writes through it.
//
// The mirror is pull-only in the same sense WallModerationRows is: rows are
// written here only after the SERVER confirmed them. What is tested hardest is
// the malformed-row discipline (one bad row from a future server version must
// not abort an import) and the resolve-don't-delete rule.

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/grades/grade_system.dart';
import 'package:masi/features/moderation/application/community_facts_providers.dart';
import 'package:masi/features/moderation/data/community_facts_remote.dart';
import 'package:masi/features/moderation/data/community_facts_repository.dart';
import 'package:masi/features/moderation/domain/community_facts.dart';

/// Records what was asked of the server, and answers with canned rows.
class _FakeRemote implements CommunityFactsRemote {
  _FakeRemote({this.facts = const {}});

  Map<String, List<Map<String, dynamic>>> facts;

  final List<String> calls = [];
  Set<String> lastWallIds = const {};
  Set<String> lastRouteIds = const {};
  Object? throwOnWrite;

  @override
  Future<Map<String, List<Map<String, dynamic>>>> fetchFacts(
    Set<String> wallIds,
    Set<String> routeIds,
  ) async {
    calls.add('fetch');
    lastWallIds = wallIds;
    lastRouteIds = routeIds;
    return facts;
  }

  @override
  Future<Map<String, dynamic>> upsertGradeOpinion({
    required String routeId,
    required String gradeSystem,
    required String gradeRaw,
    required double? gradeSortKey,
  }) async {
    calls.add('upsertGradeOpinion');
    if (throwOnWrite != null) throw throwOnWrite!;
    return {
      'id': 'o1',
      'routeId': routeId,
      'authorId': 'me',
      'gradeSystem': gradeSystem,
      'gradeRaw': gradeRaw,
      'gradeSortKey': gradeSortKey,
      'createdAt': 1000,
    };
  }

  @override
  Future<void> deleteGradeOpinion(String id) async {
    calls.add('deleteGradeOpinion:$id');
  }

  @override
  Future<Map<String, dynamic>> upsertVerification({
    required String wallId,
    required bool accurate,
    String? note,
  }) async {
    calls.add('upsertVerification');
    if (throwOnWrite != null) throw throwOnWrite!;
    return {
      'id': 'v1',
      'wallId': wallId,
      'authorId': 'me',
      'accurate': accurate,
      'note': note,
      'createdAt': 1000,
    };
  }

  @override
  Future<Map<String, dynamic>> reportHazard({
    required String wallId,
    String? routeId,
    required String severity,
    required String body,
  }) async {
    calls.add('reportHazard');
    if (throwOnWrite != null) throw throwOnWrite!;
    return {
      'id': 'h1',
      'wallId': wallId,
      'routeId': routeId,
      'authorId': 'me',
      'severity': severity,
      'body': body,
      'resolvedAt': null,
      'resolvedBy': null,
      'createdAt': 1000,
    };
  }

  @override
  Future<void> resolveHazard({
    required String id,
    required bool resolved,
  }) async {
    calls.add('resolveHazard:$id:$resolved');
  }
}

Map<String, dynamic> _hazardRow({
  String id = 'h1',
  String wallId = 'w1',
  String severity = 'caution',
  int? resolvedAt,
}) => {
  'id': id,
  'wallId': wallId,
  'routeId': null,
  'authorId': 'reporter',
  'severity': severity,
  'body': 'Loose flake',
  'resolvedAt': resolvedAt,
  'resolvedBy': resolvedAt == null ? null : 'owner',
  'createdAt': 1000,
};

Map<String, dynamic> _opinionRow(
  String id,
  String raw, {
  String system = 'french',
  Object? sortKey,
}) => {
  'id': id,
  'routeId': 'r1',
  'authorId': 'a-$id',
  'gradeSystem': system,
  'gradeRaw': raw,
  'gradeSortKey': sortKey,
  'createdAt': 1000,
};

void main() {
  late AppDatabase db;
  late CommunityFactsRepository repo;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = CommunityFactsRepository(db);
  });
  tearDown(() => db.close());

  group('upsertFromRemote', () {
    test('imports all three kinds in one pass', () async {
      final written = await repo.upsertFromRemote({
        'hazards': [_hazardRow()],
        'verifications': [
          {
            'id': 'v1',
            'wallId': 'w1',
            'authorId': 'a',
            'accurate': true,
            'note': null,
            'createdAt': 1,
          },
        ],
        'opinions': [_opinionRow('o1', '6a', sortKey: 7.0)],
      });

      expect(written, 3);
      expect((await repo.watchHazards('w1').first).length, 1);
      expect((await repo.watchVerifications('w1').first).length, 1);
      expect((await repo.watchOpinions('r1').first).length, 1);
    });

    test(
      'a malformed row is skipped, not thrown on — one bad row from a future '
      'server version must not abort the whole import',
      () async {
        final written = await repo.upsertFromRemote({
          'hazards': [
            _hazardRow(id: 'good'),
            {'id': 'no-wall', 'severity': 'note', 'body': 'x'},
            {'id': 'no-body', 'wallId': 'w1', 'severity': 'note'},
            _hazardRow(id: 'good2'),
          ],
        });

        expect(written, 2);
        expect((await repo.watchHazards('w1').first).length, 2);
      },
    );

    test('re-importing the same row updates rather than duplicating', () async {
      await repo.upsertFromRemote({
        'hazards': [_hazardRow(severity: 'note')],
      });
      await repo.upsertFromRemote({
        'hazards': [_hazardRow(severity: 'danger')],
      });

      final hazards = await repo.watchHazards('w1').first;
      expect(hazards.length, 1);
      expect(hazards.single.severity, HazardSeverity.danger);
    });

    test('an unknown severity survives the round trip as danger', () async {
      await repo.upsertFromRemote({
        'hazards': [_hazardRow(severity: 'apocalyptic')],
      });

      final hazards = await repo.watchHazards('w1').first;
      expect(hazards.single.severity, HazardSeverity.danger);
    });

    test('an empty payload writes nothing and does not throw', () async {
      expect(await repo.upsertFromRemote(const {}), 0);
    });
  });

  group('watchHazards ordering', () {
    test(
      'unresolved first, then by severity — a resolved danger never outranks '
      'a live caution',
      () async {
        await repo.upsertFromRemote({
          'hazards': [
            _hazardRow(id: 'resolved-danger', severity: 'danger', resolvedAt: 9),
            _hazardRow(id: 'live-note', severity: 'note'),
            _hazardRow(id: 'live-danger', severity: 'danger'),
            _hazardRow(id: 'live-caution', severity: 'caution'),
          ],
        });

        final ids = (await repo.watchHazards('w1').first)
            .map((h) => h.id)
            .toList();
        expect(ids, [
          'live-danger',
          'live-caution',
          'live-note',
          'resolved-danger',
        ]);
      },
    );

    test('hazards are scoped to their wall', () async {
      await repo.upsertFromRemote({
        'hazards': [
          _hazardRow(id: 'a', wallId: 'w1'),
          _hazardRow(id: 'b', wallId: 'w2'),
        ],
      });

      expect((await repo.watchHazards('w1').first).single.id, 'a');
      expect((await repo.watchHazards('w2').first).single.id, 'b');
    });
  });

  group('grade opinions through the mirror', () {
    test('a consensus forms once three opinions land', () async {
      await repo.upsertFromRemote({
        'opinions': [
          _opinionRow('o1', '6a', sortKey: gradeSortKey(GradeSystem.french, '6a')),
          _opinionRow('o2', '6a+', sortKey: gradeSortKey(GradeSystem.french, '6a+')),
        ],
      });
      expect((await repo.watchConsensus('r1').first).hasConsensus, isFalse);

      await repo.upsertFromRemote({
        'opinions': [
          _opinionRow('o3', '6a+', sortKey: gradeSortKey(GradeSystem.french, '6a+')),
        ],
      });

      final consensus = await repo.watchConsensus('r1').first;
      expect(consensus.hasConsensus, isTrue);
      expect(consensus.displayGrade(GradeSystem.french), '6a+');
    });

    test(
      'a missing sort key is recomputed from the grade rather than dropping '
      'the opinion',
      () async {
        await repo.upsertFromRemote({
          'opinions': [_opinionRow('o1', '6a')],
        });

        final opinions = await repo.watchOpinions('r1').first;
        expect(opinions.single.sortKey, gradeSortKey(GradeSystem.french, '6a'));
      },
    );

    test(
      'an opinion on a grade system this build does not know is dropped, not '
      'given an invented position on the shared scale',
      () async {
        await repo.upsertFromRemote({
          'opinions': [
            _opinionRow('o1', '5.11a', system: 'yds'),
            _opinionRow('o2', '6a', sortKey: 7.0),
          ],
        });

        final opinions = await repo.watchOpinions('r1').first;
        expect(opinions.length, 1);
        expect(opinions.single.id, 'o2');
      },
    );

    test('an unparseable grade with no stored sort key is dropped too', () async {
      await repo.upsertFromRemote({
        'opinions': [_opinionRow('o1', 'not-a-grade')],
      });
      expect(await repo.watchOpinions('r1').first, isEmpty);
    });
  });

  group('clear', () {
    test('drops every kind, so a second account inherits nothing', () async {
      await repo.upsertFromRemote({
        'hazards': [_hazardRow()],
        'verifications': [
          {
            'id': 'v1',
            'wallId': 'w1',
            'authorId': 'a',
            'accurate': true,
            'createdAt': 1,
          },
        ],
        'opinions': [_opinionRow('o1', '6a', sortKey: 7.0)],
      });

      await repo.clear();

      expect(await repo.watchHazards('w1').first, isEmpty);
      expect(await repo.watchVerifications('w1').first, isEmpty);
      expect(await repo.watchOpinions('r1').first, isEmpty);
    });
  });

  group('CommunityFactsService', () {
    late _FakeRemote remote;
    late CommunityFactsService service;

    setUp(() {
      remote = _FakeRemote();
      service = CommunityFactsService(remote: remote, repository: repo);
    });

    test('reporting a hazard mirrors the server row immediately', () async {
      await service.reportHazard(
        wallId: 'w1',
        severity: HazardSeverity.danger,
        body: '  Bolt 2 spins  ',
      );

      final hazards = await repo.watchHazards('w1').first;
      expect(hazards.single.severity, HazardSeverity.danger);
      expect(
        hazards.single.body,
        'Bolt 2 spins',
        reason: 'the body is trimmed before it is sent',
      );
    });

    test('an empty hazard body is refused before it reaches the server', () async {
      await expectLater(
        service.reportHazard(
          wallId: 'w1',
          severity: HazardSeverity.note,
          body: '   ',
        ),
        throwsArgumentError,
      );
      expect(remote.calls, isEmpty);
    });

    test(
      'a write failure propagates and mirrors NOTHING — no silent queue, so '
      'the user learns their warning did not land',
      () async {
        remote.throwOnWrite = StateError('offline');

        await expectLater(
          service.reportHazard(
            wallId: 'w1',
            severity: HazardSeverity.danger,
            body: 'Loose block',
          ),
          throwsStateError,
        );
        expect(await repo.watchHazards('w1').first, isEmpty);
      },
    );

    test('stating a grade normalizes it and stores a sort key', () async {
      await service.stateGrade(
        routeId: 'r1',
        system: GradeSystem.french,
        raw: '6A+',
      );

      final opinions = await repo.watchOpinions('r1').first;
      expect(opinions.single.raw, '6a+');
      expect(opinions.single.sortKey, gradeSortKey(GradeSystem.french, '6a+'));
    });

    test(
      'a grade that is not on the ladder is refused locally, never sent — an '
      'opinion no client can place on the shared scale is invisible to every '
      'consensus, which is a silent failure',
      () async {
        await expectLater(
          service.stateGrade(
            routeId: 'r1',
            system: GradeSystem.french,
            raw: '5.11a',
          ),
          throwsArgumentError,
        );
        expect(remote.calls, isEmpty);
      },
    );

    test('withdrawing a grade drops it from the mirror', () async {
      await service.stateGrade(
        routeId: 'r1',
        system: GradeSystem.french,
        raw: '6a',
      );
      expect(await repo.watchOpinions('r1').first, hasLength(1));

      await service.withdrawGrade('o1');
      expect(await repo.watchOpinions('r1').first, isEmpty);
    });

    test('verifying mirrors the server row', () async {
      await service.verify(wallId: 'w1', accurate: false, note: 'wrong crack');

      final summary = await repo.watchVerificationSummary('w1').first;
      expect(summary.isDisputed, isTrue);
      expect(summary.inaccurateCount, 1);
    });

    test(
      'resolving a hazard re-pulls the wall rather than guessing the server '
      'clock — and the report itself is never deleted',
      () async {
        await repo.upsertFromRemote({
          'hazards': [_hazardRow(id: 'h1')],
        });

        remote.facts = {
          'hazards': [_hazardRow(id: 'h1', resolvedAt: 5000)],
        };

        await service.resolveHazard(
          hazardId: 'h1',
          wallId: 'w1',
          resolved: true,
        );

        expect(remote.calls, contains('resolveHazard:h1:true'));
        expect(
          remote.lastWallIds,
          {'w1'},
          reason: 'the resolve must actually re-pull something',
        );

        final hazards = await repo.watchHazards('w1').first;
        expect(
          hazards,
          hasLength(1),
          reason: 'resolving is not deleting — the report survives (C-12)',
        );
        expect(hazards.single.isResolved, isTrue);
        expect(hazards.single.body, 'Loose flake');
      },
    );
  });

  group('pullCommunityFacts', () {
    test('short-circuits before touching the network when asked for nothing', () async {
      final remote = _FakeRemote();
      final written = await pullCommunityFacts(
        remote: remote,
        repository: repo,
        wallIds: const {},
      );

      expect(written, 0);
      expect(remote.calls, isEmpty);
    });

    test('forwards both id sets and writes what comes back', () async {
      final remote = _FakeRemote(
        facts: {
          'hazards': [_hazardRow()],
          'opinions': [_opinionRow('o1', '6a', sortKey: 7.0)],
        },
      );

      final written = await pullCommunityFacts(
        remote: remote,
        repository: repo,
        wallIds: {'w1'},
        routeIds: {'r1'},
      );

      expect(written, 2);
      expect(remote.lastWallIds, {'w1'});
      expect(remote.lastRouteIds, {'r1'});
    });
  });
}
