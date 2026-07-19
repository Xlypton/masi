import 'package:climbtopo/core/db/app_database.dart' as db;
import 'package:climbtopo/core/grades/grade_system.dart';
import 'package:climbtopo/features/topo/data/route_mapper.dart';
import 'package:climbtopo/features/topo/domain/topo_route.dart';
import 'package:flutter_test/flutter_test.dart';

db.Route _row({
  String? name,
  String? gradeSystem,
  String? gradeRaw,
  double? gradeSortKey,
  String? style,
  String? description,
  String? betaVideoUrl,
  String? styleTagsJson,
  int? stars,
}) {
  return db.Route(
    id: 'route-1',
    createdAt: 0,
    updatedAt: 0,
    dirty: false,
    wallId: 'wall-1',
    photoId: 'photo-1',
    number: 1,
    name: name,
    gradeSystem: gradeSystem,
    gradeRaw: gradeRaw,
    gradeSortKey: gradeSortKey,
    style: style,
    description: description,
    colorIndex: 0,
    pointsJson: '[]',
    symbolsJson: '[]',
    sortOrder: 1,
    visible: true,
    betaVideoUrl: betaVideoUrl,
    styleTagsJson: styleTagsJson,
    stars: stars,
  );
}

void main() {
  group('encodePoints/decodePoints', () {
    test('round-trips an empty list', () {
      final json = encodePoints(const []);
      expect(decodePoints(json), isEmpty);
    });

    test('round-trips many points with fractional coordinates', () {
      const points = [
        Offset(0.0, 0.0),
        Offset(12.5, 87.25),
        Offset(99.999, 0.001),
        Offset(50.5, 50.5),
      ];

      final json = encodePoints(points);
      final decoded = decodePoints(json);

      expect(decoded, points);
    });
  });

  group('encodeSymbols/decodeSymbols', () {
    test('round-trips an empty list', () {
      final json = encodeSymbols(const []);
      expect(decodeSymbols(json), isEmpty);
    });

    test('round-trips all SymbolType values', () {
      final symbols = [
        for (final type in SymbolType.values)
          TopoSymbol(type: type, position: Offset(type.index * 10.0, 5.5)),
      ];

      final json = encodeSymbols(symbols);
      final decoded = decodeSymbols(json);

      expect(decoded, symbols);
      expect(decoded.map((s) => s.type).toSet(), SymbolType.values.toSet());
    });
  });

  group('rowToDomain metadata (M4 A4)', () {
    test('reads all 6 metadata columns into the domain object', () {
      final row = _row(
        name: 'Le Toit',
        gradeSystem: 'french',
        gradeRaw: '6a+',
        gradeSortKey: 8.0,
        style: 'sport',
        description: 'Great warm-up.',
      );

      final route = rowToDomain(row, 1);

      expect(route.name, 'Le Toit');
      expect(route.gradeSystem, GradeSystem.french);
      expect(route.gradeRaw, '6a+');
      expect(route.gradeSortKey, 8.0);
      expect(route.style, 'sport');
      expect(route.description, 'Great warm-up.');
    });

    test('a row with no metadata maps to all-null metadata fields', () {
      final row = _row();

      final route = rowToDomain(row, 1);

      expect(route.name, isNull);
      expect(route.gradeSystem, isNull);
      expect(route.gradeRaw, isNull);
      expect(route.gradeSortKey, isNull);
      expect(route.style, isNull);
      expect(route.description, isNull);
    });

    test('a null gradeSystem column loads as null', () {
      final row = _row(gradeSystem: null, gradeRaw: '6a');

      final route = rowToDomain(row, 1);

      expect(route.gradeSystem, isNull);
    });

    test(
      'a corrupt/unknown gradeSystem string loads as null without throwing',
      () {
        final row = _row(gradeSystem: 'not-a-real-system');

        expect(() => rowToDomain(row, 1), returnsNormally);
        expect(rowToDomain(row, 1).gradeSystem, isNull);
      },
    );

    test('parses "uiaa" gradeSystem correctly', () {
      final row = _row(gradeSystem: 'uiaa', gradeRaw: 'VI+');

      final route = rowToDomain(row, 1);

      expect(route.gradeSystem, GradeSystem.uiaa);
      expect(route.gradeRaw, 'VI+');
    });
  });

  group('rowToDomain per-route metadata (#41/#42/#44)', () {
    test('reads betaVideoUrl, styleTags (decoded), and stars', () {
      final row = _row(
        betaVideoUrl: 'https://example.com/beta',
        styleTagsJson: '["dyno","custom-tag"]',
        stars: 2,
      );

      final route = rowToDomain(row, 1);

      expect(route.betaVideoUrl, 'https://example.com/beta');
      expect(route.styleTags, ['dyno', 'custom-tag']);
      expect(route.stars, 2);
    });

    test(
      'a row with all three columns null maps to null betaVideoUrl/stars '
      'and empty styleTags',
      () {
        final row = _row();

        final route = rowToDomain(row, 1);

        expect(route.betaVideoUrl, isNull);
        expect(route.styleTags, isEmpty);
        expect(route.stars, isNull);
      },
    );
  });
}
