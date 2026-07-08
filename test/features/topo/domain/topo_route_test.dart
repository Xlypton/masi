import 'dart:io';

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
      const b = TopoSymbol(type: SymbolType.rest, position: Offset(0.3, 0.4));

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
    }) {
      return TopoRoute(
        id: id,
        number: number,
        points: points,
        symbols: symbols,
        colorIndex: colorIndex,
        visible: visible,
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
