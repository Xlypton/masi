import 'package:climbtopo/features/topo/data/route_mapper.dart';
import 'package:climbtopo/features/topo/domain/topo_route.dart';
import 'package:flutter_test/flutter_test.dart';

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
}
