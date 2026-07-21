import 'dart:io';

import 'package:climbtopo/core/grades/grade_system.dart';
import 'package:climbtopo/features/topo/domain/topo_route.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TopoRoute defaults (A1)', () {
    test('symbols empty and visible true when not specified', () {
      const route = TopoRoute(
        id: 1,
        number: 1,
        points: [Offset(0.1, 0.1), Offset(0.2, 0.2)],
      );

      expect(route.symbols, isEmpty);
      expect(route.visible, isTrue);
    });

    test('metadata fields default to null when not specified', () {
      const route = TopoRoute(
        id: 1,
        number: 1,
        points: [Offset(0.1, 0.1), Offset(0.2, 0.2)],
      );

      expect(route.name, isNull);
      expect(route.gradeSystem, isNull);
      expect(route.gradeRaw, isNull);
      expect(route.gradeSortKey, isNull);
      expect(route.style, isNull);
      expect(route.description, isNull);
    });
  });

  group('TopoRoute.copyWith (A2)', () {
    const base = TopoRoute(
      id: 1,
      number: 1,
      points: [Offset(0.1, 0.1)],
      symbols: [TopoSymbol(type: SymbolType.bolt, position: Offset(0.1, 0.1))],
      colorIndex: 0,
      visible: true,
    );

    test('changing id preserves all other fields', () {
      final updated = base.copyWith(id: 99);

      expect(updated.id, 99);
      expect(updated.number, base.number);
      expect(updated.points, base.points);
      expect(updated.symbols, base.symbols);
      expect(updated.colorIndex, base.colorIndex);
      expect(updated.visible, base.visible);
    });

    test('changing number preserves all other fields', () {
      final updated = base.copyWith(number: 5);

      expect(updated.number, 5);
      expect(updated.id, base.id);
      expect(updated.points, base.points);
      expect(updated.symbols, base.symbols);
      expect(updated.colorIndex, base.colorIndex);
      expect(updated.visible, base.visible);
    });

    test('changing points preserves all other fields', () {
      final newPoints = [const Offset(0.5, 0.5), const Offset(0.6, 0.6)];
      final updated = base.copyWith(points: newPoints);

      expect(updated.points, newPoints);
      expect(updated.id, base.id);
      expect(updated.number, base.number);
      expect(updated.symbols, base.symbols);
      expect(updated.colorIndex, base.colorIndex);
      expect(updated.visible, base.visible);
    });

    test('changing symbols preserves all other fields', () {
      const newSymbols = [
        TopoSymbol(type: SymbolType.anchor, position: Offset(0.9, 0.9)),
      ];
      final updated = base.copyWith(symbols: newSymbols);

      expect(updated.symbols, newSymbols);
      expect(updated.id, base.id);
      expect(updated.number, base.number);
      expect(updated.points, base.points);
      expect(updated.colorIndex, base.colorIndex);
      expect(updated.visible, base.visible);
    });

    test('changing colorIndex preserves all other fields', () {
      final updated = base.copyWith(colorIndex: 3);

      expect(updated.colorIndex, 3);
      expect(updated.id, base.id);
      expect(updated.number, base.number);
      expect(updated.points, base.points);
      expect(updated.symbols, base.symbols);
      expect(updated.visible, base.visible);
    });

    test('changing visible preserves all other fields', () {
      final updated = base.copyWith(visible: false);

      expect(updated.visible, isFalse);
      expect(updated.id, base.id);
      expect(updated.number, base.number);
      expect(updated.points, base.points);
      expect(updated.symbols, base.symbols);
      expect(updated.colorIndex, base.colorIndex);
    });

    test('no-arg copyWith returns equal instance', () {
      final updated = base.copyWith();
      expect(updated, base);
    });
  });

  group('TopoRoute metadata copyWith (M4 A1)', () {
    const base = TopoRoute(
      id: 1,
      number: 1,
      points: [Offset(0.1, 0.1)],
      name: 'Base Route',
      gradeSystem: GradeSystem.french,
      gradeRaw: '6a',
      gradeSortKey: 7.0,
      style: 'sport',
      description: 'A nice route.',
    );

    test('changing only name preserves the rest', () {
      final updated = base.copyWith(name: 'New Name');

      expect(updated.name, 'New Name');
      expect(updated.gradeSystem, base.gradeSystem);
      expect(updated.gradeRaw, base.gradeRaw);
      expect(updated.gradeSortKey, base.gradeSortKey);
      expect(updated.style, base.style);
      expect(updated.description, base.description);
      expect(updated.id, base.id);
      expect(updated.number, base.number);
      expect(updated.points, base.points);
    });

    test('changing only gradeRaw preserves the rest', () {
      final updated = base.copyWith(gradeRaw: '7a');

      expect(updated.gradeRaw, '7a');
      expect(updated.name, base.name);
      expect(updated.gradeSystem, base.gradeSystem);
      expect(updated.gradeSortKey, base.gradeSortKey);
      expect(updated.style, base.style);
      expect(updated.description, base.description);
    });

    test('changing only gradeSystem preserves the rest', () {
      final updated = base.copyWith(gradeSystem: GradeSystem.uiaa);

      expect(updated.gradeSystem, GradeSystem.uiaa);
      expect(updated.name, base.name);
      expect(updated.gradeRaw, base.gradeRaw);
      expect(updated.gradeSortKey, base.gradeSortKey);
      expect(updated.style, base.style);
      expect(updated.description, base.description);
    });

    test('changing only gradeSortKey preserves the rest', () {
      final updated = base.copyWith(gradeSortKey: 13.0);

      expect(updated.gradeSortKey, 13.0);
      expect(updated.name, base.name);
      expect(updated.gradeSystem, base.gradeSystem);
      expect(updated.gradeRaw, base.gradeRaw);
      expect(updated.style, base.style);
      expect(updated.description, base.description);
    });

    test('changing only style preserves the rest', () {
      final updated = base.copyWith(style: 'trad');

      expect(updated.style, 'trad');
      expect(updated.name, base.name);
      expect(updated.gradeSystem, base.gradeSystem);
      expect(updated.gradeRaw, base.gradeRaw);
      expect(updated.gradeSortKey, base.gradeSortKey);
      expect(updated.description, base.description);
    });

    test('changing only description preserves the rest', () {
      final updated = base.copyWith(description: 'Updated description.');

      expect(updated.description, 'Updated description.');
      expect(updated.name, base.name);
      expect(updated.gradeSystem, base.gradeSystem);
      expect(updated.gradeRaw, base.gradeRaw);
      expect(updated.gradeSortKey, base.gradeSortKey);
      expect(updated.style, base.style);
    });

    test('no-arg copyWith returns equal instance', () {
      final updated = base.copyWith();
      expect(updated, base);
    });

    test(
      'copyWith(gradeSortKey: null, setGradeSortKey: true) explicitly '
      'clears the sort key',
      () {
        final updated = base.copyWith(
          gradeSortKey: null,
          setGradeSortKey: true,
        );

        expect(updated.gradeSortKey, isNull);
        expect(updated.name, base.name);
        expect(updated.gradeSystem, base.gradeSystem);
        expect(updated.gradeRaw, base.gradeRaw);
        expect(updated.style, base.style);
        expect(updated.description, base.description);
      },
    );

    test(
      'copyWith(gradeSortKey: null) with setGradeSortKey left at its '
      'default (false) preserves the existing sort key',
      () {
        final updated = base.copyWith(gradeSortKey: null);

        expect(updated.gradeSortKey, base.gradeSortKey);
      },
    );
  });

  group('TopoRoute metadata copyWith set-sentinels (M4 cleanup Fix 2+3)', () {
    const base = TopoRoute(
      id: 1,
      number: 1,
      points: [Offset(0.1, 0.1)],
      name: 'Base Route',
      gradeSystem: GradeSystem.french,
      gradeRaw: '6a',
      gradeSortKey: 7.0,
      style: 'sport',
      description: 'A nice route.',
    );

    test(
      'copyWith(name: null) without nameSet preserves the existing name '
      '(back-compat default)',
      () {
        final updated = base.copyWith(name: null);
        expect(updated.name, base.name);
      },
    );

    test(
      'copyWith(name: null, nameSet: true) explicitly clears the name',
      () {
        final updated = base.copyWith(name: null, nameSet: true);
        expect(updated.name, isNull);
        expect(updated.gradeSystem, base.gradeSystem);
        expect(updated.gradeRaw, base.gradeRaw);
        expect(updated.style, base.style);
        expect(updated.description, base.description);
      },
    );

    test(
      'copyWith(gradeSystem: null, gradeSystemSet: true) explicitly clears '
      'gradeSystem',
      () {
        final updated = base.copyWith(gradeSystem: null, gradeSystemSet: true);
        expect(updated.gradeSystem, isNull);
        expect(updated.name, base.name);
      },
    );

    test(
      'copyWith(gradeSystem: null) without gradeSystemSet preserves the '
      'existing gradeSystem',
      () {
        final updated = base.copyWith(gradeSystem: null);
        expect(updated.gradeSystem, base.gradeSystem);
      },
    );

    test(
      'copyWith(gradeRaw: null, gradeRawSet: true) explicitly clears '
      'gradeRaw',
      () {
        final updated = base.copyWith(gradeRaw: null, gradeRawSet: true);
        expect(updated.gradeRaw, isNull);
        expect(updated.name, base.name);
      },
    );

    test(
      'copyWith(gradeRaw: null) without gradeRawSet preserves the existing '
      'gradeRaw',
      () {
        final updated = base.copyWith(gradeRaw: null);
        expect(updated.gradeRaw, base.gradeRaw);
      },
    );

    test(
      'copyWith(style: null, styleSet: true) explicitly clears style',
      () {
        final updated = base.copyWith(style: null, styleSet: true);
        expect(updated.style, isNull);
        expect(updated.name, base.name);
      },
    );

    test(
      'copyWith(style: null) without styleSet preserves the existing '
      'style',
      () {
        final updated = base.copyWith(style: null);
        expect(updated.style, base.style);
      },
    );

    test(
      'copyWith(description: null, descriptionSet: true) explicitly '
      'clears description',
      () {
        final updated = base.copyWith(
          description: null,
          descriptionSet: true,
        );
        expect(updated.description, isNull);
        expect(updated.name, base.name);
      },
    );

    test(
      'copyWith(description: null) without descriptionSet preserves the '
      'existing description',
      () {
        final updated = base.copyWith(description: null);
        expect(updated.description, base.description);
      },
    );

    test(
      'all five sentinels together clear every metadata field except '
      'gradeSortKey, which needs its own sentinel',
      () {
        final updated = base.copyWith(
          name: null,
          nameSet: true,
          gradeSystem: null,
          gradeSystemSet: true,
          gradeRaw: null,
          gradeRawSet: true,
          gradeSortKey: null,
          setGradeSortKey: true,
          style: null,
          styleSet: true,
          description: null,
          descriptionSet: true,
        );

        expect(updated.name, isNull);
        expect(updated.gradeSystem, isNull);
        expect(updated.gradeRaw, isNull);
        expect(updated.gradeSortKey, isNull);
        expect(updated.style, isNull);
        expect(updated.description, isNull);
        // Non-metadata fields untouched.
        expect(updated.id, base.id);
        expect(updated.number, base.number);
        expect(updated.points, base.points);
      },
    );
  });

  group('TopoRoute per-route metadata (#41/#42/#44) defaults', () {
    test('betaVideoUrl/stars default to null and styleTags to empty', () {
      const route = TopoRoute(
        id: 1,
        number: 1,
        points: [Offset(0.1, 0.1)],
      );

      expect(route.betaVideoUrl, isNull);
      expect(route.styleTags, isEmpty);
      expect(route.stars, isNull);
    });
  });

  group(
    'TopoRoute betaVideoUrl/styleTags/stars copyWith set-sentinels '
    '(#41/#42/#44)',
    () {
      const base = TopoRoute(
        id: 1,
        number: 1,
        points: [Offset(0.1, 0.1)],
        betaVideoUrl: 'https://example.com/beta',
        styleTags: ['dyno', 'custom-tag'],
        stars: 2,
      );

      test('no-arg copyWith preserves all three fields', () {
        final updated = base.copyWith();
        expect(updated.betaVideoUrl, base.betaVideoUrl);
        expect(updated.styleTags, base.styleTags);
        expect(updated.stars, base.stars);
      });

      test('changing only betaVideoUrl preserves the rest', () {
        final updated = base.copyWith(
          betaVideoUrl: 'https://example.com/other',
        );
        expect(updated.betaVideoUrl, 'https://example.com/other');
        expect(updated.styleTags, base.styleTags);
        expect(updated.stars, base.stars);
      });

      test(
        'copyWith(betaVideoUrl: null) without betaVideoUrlSet preserves '
        'the existing value',
        () {
          final updated = base.copyWith(betaVideoUrl: null);
          expect(updated.betaVideoUrl, base.betaVideoUrl);
        },
      );

      test(
        'copyWith(betaVideoUrl: null, betaVideoUrlSet: true) explicitly '
        'clears it',
        () {
          final updated = base.copyWith(
            betaVideoUrl: null,
            betaVideoUrlSet: true,
          );
          expect(updated.betaVideoUrl, isNull);
          expect(updated.styleTags, base.styleTags);
          expect(updated.stars, base.stars);
        },
      );

      test('changing only styleTags preserves the rest', () {
        final updated = base.copyWith(styleTags: ['juggy']);
        expect(updated.styleTags, ['juggy']);
        expect(updated.betaVideoUrl, base.betaVideoUrl);
        expect(updated.stars, base.stars);
      });

      test(
        'copyWith(styleTags: null) without styleTagsSet preserves the '
        'existing tags',
        () {
          final updated = base.copyWith(styleTags: null);
          expect(updated.styleTags, base.styleTags);
        },
      );

      test(
        'copyWith(styleTags: null, styleTagsSet: true) explicitly clears '
        'to an empty list (there is no "unset" list state, unlike the '
        'nullable scalar fields)',
        () {
          final updated = base.copyWith(styleTags: null, styleTagsSet: true);
          expect(updated.styleTags, isEmpty);
          expect(updated.betaVideoUrl, base.betaVideoUrl);
          expect(updated.stars, base.stars);
        },
      );

      test('changing only stars preserves the rest', () {
        final updated = base.copyWith(stars: 3);
        expect(updated.stars, 3);
        expect(updated.betaVideoUrl, base.betaVideoUrl);
        expect(updated.styleTags, base.styleTags);
      });

      test(
        'copyWith(stars: null) without starsSet preserves the existing '
        'stars',
        () {
          final updated = base.copyWith(stars: null);
          expect(updated.stars, base.stars);
        },
      );

      test(
        'copyWith(stars: null, starsSet: true) explicitly clears the '
        'rating back to unrated',
        () {
          final updated = base.copyWith(stars: null, starsSet: true);
          expect(updated.stars, isNull);
          expect(updated.betaVideoUrl, base.betaVideoUrl);
          expect(updated.styleTags, base.styleTags);
        },
      );
    },
  );

  group('TopoRoute value equality (#41/#42/#44)', () {
    test('equal betaVideoUrl/styleTags/stars produce equal instances', () {
      const a = TopoRoute(
        id: 1,
        number: 1,
        points: [Offset(0.1, 0.1)],
        betaVideoUrl: 'https://example.com',
        styleTags: ['dyno'],
        stars: 1,
      );
      const b = TopoRoute(
        id: 1,
        number: 1,
        points: [Offset(0.1, 0.1)],
        betaVideoUrl: 'https://example.com',
        styleTags: ['dyno'],
        stars: 1,
      );

      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('different betaVideoUrl makes routes unequal', () {
      const a = TopoRoute(
        id: 1,
        number: 1,
        points: [Offset(0.1, 0.1)],
        betaVideoUrl: 'https://example.com/a',
      );
      const b = TopoRoute(
        id: 1,
        number: 1,
        points: [Offset(0.1, 0.1)],
        betaVideoUrl: 'https://example.com/b',
      );
      expect(a, isNot(b));
    });

    test('different styleTags makes routes unequal', () {
      const a = TopoRoute(
        id: 1,
        number: 1,
        points: [Offset(0.1, 0.1)],
        styleTags: ['dyno'],
      );
      const b = TopoRoute(
        id: 1,
        number: 1,
        points: [Offset(0.1, 0.1)],
        styleTags: ['crimpy'],
      );
      expect(a, isNot(b));
    });

    test('different stars makes routes unequal', () {
      const a = TopoRoute(id: 1, number: 1, points: [Offset(0.1, 0.1)], stars: 1);
      const b = TopoRoute(id: 1, number: 1, points: [Offset(0.1, 0.1)], stars: 2);
      expect(a, isNot(b));
    });
  });

  group('TopoSymbol.copyWith (A2)', () {
    const base = TopoSymbol(type: SymbolType.bolt, position: Offset(0.1, 0.2));

    test('changing type preserves position', () {
      final updated = base.copyWith(type: SymbolType.crux);

      expect(updated.type, SymbolType.crux);
      expect(updated.position, base.position);
    });

    test('changing position preserves type', () {
      final updated = base.copyWith(position: const Offset(0.9, 0.9));

      expect(updated.position, const Offset(0.9, 0.9));
      expect(updated.type, base.type);
    });
  });

  group('TopoSymbol value equality (A3)', () {
    test('equal fields produce equal instances and hashCodes', () {
      const a = TopoSymbol(type: SymbolType.top, position: Offset(0.3, 0.4));
      const b = TopoSymbol(type: SymbolType.top, position: Offset(0.3, 0.4));

      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('different type is not equal', () {
      const a = TopoSymbol(type: SymbolType.top, position: Offset(0.3, 0.4));
      const b = TopoSymbol(type: SymbolType.crux, position: Offset(0.3, 0.4));

      expect(a, isNot(b));
    });

    test('different position is not equal', () {
      const a = TopoSymbol(type: SymbolType.top, position: Offset(0.3, 0.4));
      const b = TopoSymbol(type: SymbolType.top, position: Offset(0.9, 0.9));

      expect(a, isNot(b));
    });
  });

  group('TopoRoute value equality (A3)', () {
    TopoRoute makeRoute({
      int id = 1,
      int number = 1,
      List<Offset> points = const [Offset(0.1, 0.1), Offset(0.2, 0.2)],
      List<TopoSymbol> symbols = const [
        TopoSymbol(type: SymbolType.bolt, position: Offset(0.1, 0.1)),
      ],
      int colorIndex = 0,
      bool visible = true,
      String? name,
      GradeSystem? gradeSystem,
      String? gradeRaw,
      double? gradeSortKey,
      String? style,
      String? description,
    }) {
      return TopoRoute(
        id: id,
        number: number,
        points: points,
        symbols: symbols,
        colorIndex: colorIndex,
        visible: visible,
        name: name,
        gradeSystem: gradeSystem,
        gradeRaw: gradeRaw,
        gradeSortKey: gradeSortKey,
        style: style,
        description: description,
      );
    }

    test('equal field values (deep list contents) are == and same hashCode', () {
      final a = makeRoute();
      final b = makeRoute();

      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('different points makes routes unequal', () {
      final a = makeRoute();
      final b = makeRoute(points: const [Offset(0.9, 0.9)]);

      expect(a, isNot(b));
    });

    test('different symbols makes routes unequal', () {
      final a = makeRoute();
      final b = makeRoute(
        symbols: const [
          TopoSymbol(type: SymbolType.anchor, position: Offset(0.5, 0.5)),
        ],
      );

      expect(a, isNot(b));
    });

    test('different visible makes routes unequal', () {
      final a = makeRoute();
      final b = makeRoute(visible: false);

      expect(a, isNot(b));
    });

    test('different colorIndex makes routes unequal', () {
      final a = makeRoute();
      final b = makeRoute(colorIndex: 2);

      expect(a, isNot(b));
    });

    test('different number makes routes unequal', () {
      final a = makeRoute();
      final b = makeRoute(number: 2);

      expect(a, isNot(b));
    });

    test('different id makes routes unequal', () {
      final a = makeRoute();
      final b = makeRoute(id: 2);

      expect(a, isNot(b));
    });

    test('equal metadata field values are == and same hashCode', () {
      final a = makeRoute(
        name: 'Route A',
        gradeSystem: GradeSystem.french,
        gradeRaw: '6a',
        gradeSortKey: 7.0,
        style: 'sport',
        description: 'desc',
      );
      final b = makeRoute(
        name: 'Route A',
        gradeSystem: GradeSystem.french,
        gradeRaw: '6a',
        gradeSortKey: 7.0,
        style: 'sport',
        description: 'desc',
      );

      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('different name makes routes unequal', () {
      final a = makeRoute(name: 'Route A');
      final b = makeRoute(name: 'Route B');

      expect(a, isNot(b));
    });

    test('different gradeSystem makes routes unequal', () {
      final a = makeRoute(gradeSystem: GradeSystem.french);
      final b = makeRoute(gradeSystem: GradeSystem.uiaa);

      expect(a, isNot(b));
    });

    test('different gradeRaw makes routes unequal', () {
      final a = makeRoute(gradeRaw: '6a');
      final b = makeRoute(gradeRaw: '7a');

      expect(a, isNot(b));
    });

    test('different gradeSortKey makes routes unequal', () {
      final a = makeRoute(gradeSortKey: 7.0);
      final b = makeRoute(gradeSortKey: 13.0);

      expect(a, isNot(b));
    });

    test('different style makes routes unequal', () {
      final a = makeRoute(style: 'sport');
      final b = makeRoute(style: 'trad');

      expect(a, isNot(b));
    });

    test('different description makes routes unequal', () {
      final a = makeRoute(description: 'one');
      final b = makeRoute(description: 'two');

      expect(a, isNot(b));
    });
  });

  group('routeColorIndexFor (A4)', () {
    test('number 1 maps to index 0', () {
      expect(routeColorIndexFor(1), 0);
    });

    test('number 2 maps to index 1', () {
      expect(routeColorIndexFor(2), 1);
    });

    test('wraps around palette length', () {
      expect(routeColorIndexFor(kRoutePaletteLength + 1), 0);
      expect(routeColorIndexFor(kRoutePaletteLength + 2), 1);
    });

    test('kRoutePaletteLength is 8', () {
      expect(kRoutePaletteLength, 8);
    });
  });

  group('layering constraint (A5)', () {
    test('topo_route.dart does not import material or widgets', () {
      final source = File(
        'lib/features/topo/domain/topo_route.dart',
      ).readAsStringSync();

      expect(source.contains('package:flutter/material.dart'), isFalse);
      expect(source.contains('package:flutter/widgets.dart'), isFalse);
    });
  });
}
