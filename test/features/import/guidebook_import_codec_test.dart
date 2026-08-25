import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:masi/core/grades/grade_system.dart';
import 'package:masi/features/import/data/guidebook_import_codec.dart';
import 'package:masi/features/import/domain/guidebook_import.dart';
import 'package:masi/features/topo/domain/topo_route.dart';

/// Decodes [map] and fails the test if it was rejected.
GuidebookImport _decoded(Map<String, Object?> map) {
  final result = decodeGuidebookImportMap(map);
  expect(
    result,
    isA<ImportDecoded>(),
    reason: result is ImportRejected ? result.message : null,
  );
  return (result as ImportDecoded).import;
}

Map<String, Object?> _payload({
  Object? gradeSystem = 'french',
  List<Object?>? routes,
  Object? version = 1,
}) {
  return <String, Object?>{
    'v': version,
    'boulder': 'Cul de Chien',
    'gradeSystem': gradeSystem,
    'routes': routes ??
        <Object?>[
          <String, Object?>{
            'number': 1,
            'name': 'Le Toit',
            'gradeRaw': '6a+',
            'stars': 2,
            'description': 'Sit start, undercling to the lip',
            'positionHint': 'leftmost, up the obvious arête',
            'points': <Object?>[
              <Object?>[0.21, 0.94],
              <Object?>[0.24, 0.55],
              <Object?>[0.22, 0.16],
            ],
          },
        ],
  };
}

bool _hasWarning(GuidebookImport i, ImportWarningKind kind, {int? route}) {
  return i.warnings
      .any((w) => w.kind == kind && (route == null || w.routeNumber == route));
}

void main() {
  group('version gate (assertion 5)', () {
    test('a future version is rejected and names both versions', () {
      final result = decodeGuidebookImportMap(_payload(version: 2));
      expect(result, isA<ImportRejected>());
      expect((result as ImportRejected).message, contains('v2'));
    });

    test('a missing version marker is rejected', () {
      final map = _payload()..remove('v');
      expect(decodeGuidebookImportMap(map), isA<ImportRejected>());
    });

    test('a non-integer version is rejected', () {
      expect(
        decodeGuidebookImportMap(_payload(version: '1')),
        isA<ImportRejected>(),
      );
    });
  });

  group('grades are never trusted (assertions 2 and 3)', () {
    test('an invalid grade resolves to null rather than being stored', () {
      final import = _decoded(
        _payload(routes: [
          <String, Object?>{'name': 'Nope', 'gradeRaw': '7Z+'},
        ]),
      );
      final route = import.routes.single;

      // The raw token survives for display...
      expect(route.gradeRaw, '7Z+');
      // ...but never resolves onto the ladder.
      expect(route.resolvedGradeRaw(GradeSystem.french), isNull);
      expect(route.resolvedGradeSortKey(GradeSystem.french), isNull);

      final topo = route.toTopoRoute(id: 1, system: GradeSystem.french);
      expect(topo.gradeRaw, isNull);
      expect(topo.gradeSystem, isNull);
      expect(topo.gradeSortKey, isNull);
      expect(_hasWarning(import, ImportWarningKind.invalidGrade, route: 1),
          isTrue);
    });

    test('a payload-supplied gradeSortKey is ignored, not honoured', () {
      final import = _decoded(
        _payload(routes: [
          // A model inventing a sort key is the dangerous case: wrong sorting
          // is invisible on screen in a way a wrong grade is not.
          <String, Object?>{
            'name': 'Le Toit',
            'gradeRaw': '6a+',
            'gradeSortKey': 999.0,
          },
        ]),
      );
      final topo =
          import.routes.single.toTopoRoute(id: 1, system: GradeSystem.french);

      expect(topo.gradeSortKey, isNot(999.0));
      expect(topo.gradeSortKey, gradeSortKey(GradeSystem.french, '6a+'));
    });

    test('a valid grade is normalized onto the ladder', () {
      final import = _decoded(
        _payload(routes: [
          <String, Object?>{'name': 'Shouty', 'gradeRaw': ' 6A+ '},
        ]),
      );
      final topo =
          import.routes.single.toTopoRoute(id: 1, system: GradeSystem.french);

      expect(topo.gradeRaw, '6a+');
      expect(topo.gradeSystem, GradeSystem.french);
      expect(topo.gradeSortKey, gradeSortKey(GradeSystem.french, '6a+'));
    });

    test('with no system named, the token is kept and judged later', () {
      final import = _decoded(_payload(gradeSystem: null));
      final route = import.routes.single;

      expect(import.gradeSystem, isNull);
      expect(_hasWarning(import, ImportWarningKind.unknownGradeSystem), isTrue);
      // Not flagged as invalid — nothing could judge it yet.
      expect(_hasWarning(import, ImportWarningKind.invalidGrade), isFalse);

      // The raw token survived, so choosing the system in the review sheet
      // fills the grade in without the user retyping it.
      expect(route.gradeRaw, '6a+');
      expect(route.resolvedGradeRaw(GradeSystem.french), '6a+');
      // ...and choosing the wrong ladder simply yields nothing.
      expect(route.resolvedGradeRaw(GradeSystem.uiaa), isNull);
      expect(route.resolvedGradeRaw(null), isNull);
    });

    test("'font' is understood as the French ladder", () {
      final import = _decoded(_payload(gradeSystem: 'Font'));
      expect(import.gradeSystem, GradeSystem.french);
      expect(_hasWarning(import, ImportWarningKind.unknownGradeSystem), isFalse);
    });

    test('an unrecognized system warns instead of guessing', () {
      final import = _decoded(_payload(gradeSystem: 'V-scale'));
      expect(import.gradeSystem, isNull);
      expect(_hasWarning(import, ImportWarningKind.unknownGradeSystem), isTrue);
    });
  });

  group('geometry degrades to unplaced (assertion 4)', () {
    ImportedRoute routeWithPoints(Object? points) {
      return _decoded(
        _payload(routes: [
          <String, Object?>{'name': 'R', 'points': points},
        ]),
      ).routes.single;
    }

    test('a good line survives verbatim', () {
      final route = routeWithPoints(<Object?>[
        <Object?>[0.2, 0.9],
        <Object?>[0.3, 0.1],
      ]);
      expect(route.isPlaced, isTrue);
      expect(route.points, const [Offset(0.2, 0.9), Offset(0.3, 0.1)]);
    });

    test('a missing line yields an unplaced route, not a failure', () {
      final route = routeWithPoints(null);
      expect(route.isPlaced, isFalse);
      expect(route.points, isEmpty);
      expect(route.name, 'R', reason: 'metadata must survive');
    });

    test('a single point is not a line', () {
      final route = routeWithPoints(<Object?>[
        <Object?>[0.5, 0.5],
      ]);
      expect(route.isPlaced, isFalse);
    });

    test('a non-finite coordinate voids the whole line', () {
      final route = routeWithPoints(<Object?>[
        <Object?>[0.2, 0.9],
        <Object?>[double.nan, 0.4],
        <Object?>[0.3, 0.1],
      ]);
      expect(route.isPlaced, isFalse,
          reason: 'a NaN means the model was not reading a real position, so '
              'the neighbouring points are not trustworthy either');
      expect(route.points, isEmpty);
    });

    test('infinity voids the line too', () {
      final route = routeWithPoints(<Object?>[
        <Object?>[0.2, 0.9],
        <Object?>[double.infinity, 0.4],
      ]);
      expect(route.isPlaced, isFalse);
    });

    test('out-of-range but finite coordinates are clamped, not voided', () {
      final import = _decoded(
        _payload(routes: [
          <String, Object?>{
            'name': 'R',
            'points': <Object?>[
              <Object?>[-0.4, 1.8],
              <Object?>[0.3, 0.1],
            ],
          },
        ]),
      );
      final route = import.routes.single;

      expect(route.isPlaced, isTrue);
      expect(route.points.first, const Offset(0.0, 1.0));
      expect(_hasWarning(import, ImportWarningKind.clampedPoint, route: 1),
          isTrue);
    });

    test('every coordinate stays inside the photo', () {
      final route = routeWithPoints(<Object?>[
        <Object?>[-5, -5],
        <Object?>[9, 9],
      ]);
      for (final p in route.points) {
        expect(p.dx, inInclusiveRange(0.0, 1.0));
        expect(p.dy, inInclusiveRange(0.0, 1.0));
      }
    });

    test('a malformed pair voids the line', () {
      expect(
        routeWithPoints(<Object?>[
          <Object?>[0.2],
          <Object?>[0.3, 0.1],
        ]).isPlaced,
        isFalse,
      );
      expect(
        routeWithPoints(<Object?>[
          'nonsense',
          <Object?>[0.3, 0.1],
        ]).isPlaced,
        isFalse,
      );
      expect(routeWithPoints('a line').isPlaced, isFalse);
    });

    test('an over-long line is truncated, not voided', () {
      final many = List<Object?>.generate(
        kMaxImportedPoints + 20,
        (i) => <Object?>[i / 200.0, i / 200.0],
      );
      final import = _decoded(
        _payload(routes: [
          <String, Object?>{'name': 'R', 'points': many},
        ]),
      );
      expect(import.routes.single.points, hasLength(kMaxImportedPoints));
      expect(_hasWarning(import, ImportWarningKind.tooManyPoints), isTrue);
    });

    test('integer coordinates are accepted', () {
      final route = routeWithPoints(<Object?>[
        <Object?>[0, 1],
        <Object?>[1, 0],
      ]);
      expect(route.isPlaced, isTrue);
      expect(route.points.first, const Offset(0.0, 1.0));
    });
  });

  group('numbering is positional (assertion 6)', () {
    test('routes are renumbered 1..N in payload order', () {
      final import = _decoded(
        _payload(routes: [
          <String, Object?>{'number': 7, 'name': 'A'},
          <String, Object?>{'number': 7, 'name': 'B'},
          <String, Object?>{'name': 'C'},
        ]),
      );

      expect(import.routes.map((r) => r.number), [1, 2, 3]);
      expect(import.routes.map((r) => r.name), ['A', 'B', 'C']);
    });

    test("the book's duplicate numbers cannot collide on upsert", () {
      // RouteRepository keys on (photoId, number); honouring the payload's
      // own numbers here would let route B overwrite route A.
      final import = _decoded(
        _payload(routes: [
          <String, Object?>{'number': 1, 'name': 'A'},
          <String, Object?>{'number': 1, 'name': 'B'},
        ]),
      );
      final numbers = import.routes.map((r) => r.number).toList();
      expect(numbers.toSet(), hasLength(numbers.length));
    });

    test('a non-object entry is skipped with a warning', () {
      final import = _decoded(
        _payload(routes: [
          <String, Object?>{'name': 'A'},
          'not a route',
          <String, Object?>{'name': 'C'},
        ]),
      );
      expect(import.routes.map((r) => r.name), ['A', 'C']);
      expect(import.routes.map((r) => r.number), [1, 2]);
      expect(_hasWarning(import, ImportWarningKind.droppedRoute), isTrue);
    });

    test('colour index follows the route number', () {
      final import = _decoded(
        _payload(routes: [
          <String, Object?>{'name': 'A'},
          <String, Object?>{'name': 'B'},
        ]),
      );
      expect(
        import.routes.map((r) => r.toTopoRoute(id: r.number).colorIndex),
        [routeColorIndexFor(1), routeColorIndexFor(2)],
      );
    });
  });

  group('empty and malformed payloads', () {
    test('no routes key is rejected', () {
      final map = _payload()..remove('routes');
      expect(decodeGuidebookImportMap(map), isA<ImportRejected>());
    });

    test('an empty route list is rejected', () {
      expect(
        decodeGuidebookImportMap(_payload(routes: [])),
        isA<ImportRejected>(),
      );
    });

    test('a list of only junk is rejected rather than importing nothing', () {
      final result = decodeGuidebookImportMap(
        _payload(routes: ['junk', 42]),
      );
      expect(result, isA<ImportRejected>());
    });

    test('non-JSON text is rejected with a readable message', () {
      final result = decodeGuidebookImportJson('Sure! Here are the routes:');
      expect(result, isA<ImportRejected>());
      expect((result as ImportRejected).message, isNot(contains('Exception')));
    });

    test('a JSON array is rejected', () {
      expect(decodeGuidebookImportJson('[1,2,3]'), isA<ImportRejected>());
    });

    test('empty input is rejected', () {
      expect(decodeGuidebookImportJson('   '), isA<ImportRejected>());
      expect(decodeGuidebookImportLink('  '), isA<ImportRejected>());
    });
  });

  group('field bounds', () {
    test('stars outside 0..3 are dropped', () {
      ImportedRoute withStars(Object? stars) => _decoded(
            _payload(routes: [
              <String, Object?>{'name': 'R', 'stars': stars},
            ]),
          ).routes.single;

      expect(withStars(0).stars, 0, reason: '0 stars is a real rating');
      expect(withStars(3).stars, 3);
      expect(withStars(4).stars, isNull);
      expect(withStars(-1).stars, isNull);
      expect(withStars('two').stars, isNull);
      expect(withStars(double.nan).stars, isNull);
      expect(withStars(2.4).stars, 2, reason: 'a near-integer is rounded');
    });

    test('over-long text is truncated with a warning', () {
      final import = _decoded(
        _payload(routes: [
          <String, Object?>{
            'name': 'x' * (kMaxImportedNameChars + 50),
            'description': 'y' * (kMaxImportedDescriptionChars + 50),
          },
        ]),
      );
      final route = import.routes.single;

      expect(route.name, hasLength(kMaxImportedNameChars));
      expect(route.description, hasLength(kMaxImportedDescriptionChars));
      expect(_hasWarning(import, ImportWarningKind.truncatedText), isTrue);
    });

    test('blank and non-string text becomes null', () {
      final route = _decoded(
        _payload(routes: [
          <String, Object?>{'name': '   ', 'description': 42},
        ]),
      ).routes.single;

      expect(route.name, isNull);
      expect(route.description, isNull);
    });

    test('surplus routes are dropped with a warning', () {
      final many = List<Object?>.generate(
        kMaxImportedRoutes + 5,
        (i) => <String, Object?>{'name': 'R$i'},
      );
      final import = _decoded(_payload(routes: many));

      expect(import.routes, hasLength(kMaxImportedRoutes));
      expect(_hasWarning(import, ImportWarningKind.tooManyRoutes), isTrue);
    });

    test('unknown keys are ignored, not fatal', () {
      final map = _payload()..['somethingNew'] = {'a': 1};
      (map['routes'] as List).add(<String, Object?>{
        'name': 'Future',
        'unknownField': [1, 2, 3],
      });
      final import = _decoded(map);
      expect(import.routes, hasLength(2));
    });
  });

  group('deep-link decoding', () {
    String link(Map<String, Object?> map) =>
        base64Url.encode(utf8.encode(jsonEncode(map)));

    test('a base64url link round-trips', () {
      final result = decodeGuidebookImportLink(link(_payload()));
      expect(result, isA<ImportDecoded>());
      expect((result as ImportDecoded).import.boulder, 'Cul de Chien');
    });

    test('missing padding is tolerated', () {
      final encoded = link(_payload()).replaceAll('=', '');
      expect(decodeGuidebookImportLink(encoded), isA<ImportDecoded>());
    });

    test('non-ASCII survives the round trip', () {
      final result = decodeGuidebookImportLink(link(_payload()));
      final import = (result as ImportDecoded).import;
      expect(import.routes.single.positionHint, contains('arête'));
    });

    test('a damaged link is rejected readably', () {
      final result = decodeGuidebookImportLink('!!!not base64!!!');
      expect(result, isA<ImportRejected>());
      expect((result as ImportRejected).message, isNot(contains('Exception')));
    });
  });

  group('whole-payload shape', () {
    test('a full payload maps onto TopoRoute intact', () {
      final import = _decoded(_payload());
      final topo =
          import.routes.single.toTopoRoute(id: 1, system: import.gradeSystem);

      expect(import.boulder, 'Cul de Chien');
      expect(topo.number, 1);
      expect(topo.name, 'Le Toit');
      expect(topo.gradeRaw, '6a+');
      expect(topo.gradeSystem, GradeSystem.french);
      expect(topo.stars, 2);
      expect(topo.description, 'Sit start, undercling to the lip');
      expect(topo.points, hasLength(3));
      expect(topo.style, 'boulder');
      expect(topo.visible, isTrue);
    });

    test('positionHint is import scaffolding, not route metadata', () {
      final import = _decoded(_payload());
      final route = import.routes.single;

      expect(route.positionHint, isNotNull);
      final topo = route.toTopoRoute(id: 1, system: import.gradeSystem);
      expect(topo.description, isNot(contains('leftmost')));
    });

    test('unplaced routes are reported for the draw queue', () {
      final import = _decoded(
        _payload(routes: [
          <String, Object?>{
            'name': 'placed',
            'points': <Object?>[
              <Object?>[0.1, 0.9],
              <Object?>[0.2, 0.1],
            ],
          },
          <String, Object?>{'name': 'unplaced'},
        ]),
      );

      expect(import.hasAnyGeometry, isTrue);
      expect(import.unplacedRoutes.map((r) => r.name), ['unplaced']);
    });

    test('a metadata-only page still imports cleanly', () {
      final import = _decoded(
        _payload(routes: [
          <String, Object?>{'name': 'A', 'gradeRaw': '6a'},
          <String, Object?>{'name': 'B', 'gradeRaw': '7a'},
        ]),
      );

      expect(import.hasAnyGeometry, isFalse);
      expect(import.unplacedRoutes, hasLength(2));
      expect(
        import.routes
            .map((r) => r.toTopoRoute(id: r.number, system: GradeSystem.french))
            .map((r) => r.gradeRaw),
        ['6a', '7a'],
      );
    });
  });
}
