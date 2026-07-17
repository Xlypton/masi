// Tests for `mapContentSearch` (A4) — the unified map search's pure
// merge/filter function over the four located-entity read models. No
// database involved: every input is a hand-built fixture, mirroring how the
// map UI subtask will feed it live provider data.
import 'package:climbtopo/features/community/data/map_search.dart';
import 'package:climbtopo/features/library/data/library_crud_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

void main() {
  final locatedTopo = TopoRef(
    wallId: 'wall-1',
    name: 'Sunny Boulder',
    thumbnailPath: null,
    routeCount: 2,
    createdAt: 1000,
    areaId: 'area-1',
    areaName: 'Squamish',
    latitude: 49.0,
    longitude: -123.0,
  );
  final unlocatedTopo = TopoRef(
    wallId: 'wall-2',
    name: 'No Coords Boulder',
    thumbnailPath: null,
    routeCount: 0,
    createdAt: 900,
    // latitude/longitude both default to null.
  );
  const namedRoute = LocatedRouteRef(
    routeId: 'route-1',
    number: 3,
    name: 'Sunny Crack',
    wallId: 'wall-1',
    wallName: 'Sunny Boulder',
    latitude: 49.1,
    longitude: -123.1,
  );
  const unnamedRoute = LocatedRouteRef(
    routeId: 'route-2',
    number: 5,
    wallId: 'wall-3',
    wallName: 'Other Wall',
    latitude: 50.0,
    longitude: -124.0,
  );
  const sector = LocatedSectorRef(
    id: 'sector-1',
    name: 'Sunny Slabs',
    latitude: 49.2,
    longitude: -123.2,
  );
  const area = LocatedAreaRef(
    id: 'area-1',
    name: 'Sunnyside Crag',
    latitude: 49.3,
    longitude: -123.3,
  );

  List<MapSearchResult> search(String query) => mapContentSearch(
    query: query,
    topos: [locatedTopo, unlocatedTopo],
    routes: [namedRoute, unnamedRoute],
    sectors: [sector],
    areas: [area],
  );

  group('A5c: mapContentSearch', () {
    test('empty query returns no results', () {
      expect(search(''), isEmpty);
    });

    test('whitespace-only query returns no results', () {
      expect(search('   '), isEmpty);
    });

    test('matches case-insensitively across all four kinds, preserving the '
        'topo -> route -> sector -> area group order', () {
      final results = search('sunny');

      expect(results, hasLength(4));
      expect(results.map((r) => r.kind).toList(), [
        MapSearchKind.topo,
        MapSearchKind.route,
        MapSearchKind.sector,
        MapSearchKind.area,
      ]);
      expect(results[0].title, 'Sunny Boulder');
      expect(results[1].title, 'Sunny Crack');
      expect(results[2].title, 'Sunny Slabs');
      expect(results[3].title, 'Sunnyside Crag');
    });

    test('an uppercase query still matches lowercase titles', () {
      final results = search('CRACK');
      expect(results, hasLength(1));
      expect(results.single.title, 'Sunny Crack');
    });

    test('a topo with no coordinates never matches, even by name', () {
      final results = search('No Coords');
      expect(results, isEmpty);
    });

    test("an unnamed route matches its 'Route <number>' fallback title", () {
      final results = search('Route 5');
      expect(results, hasLength(1));
      expect(results.single.kind, MapSearchKind.route);
      expect(results.single.title, 'Route 5');
    });

    test('a query matching nothing returns an empty list', () {
      expect(search('nonexistent-crag-xyz'), isEmpty);
    });

    test("a topo hit carries its wallId, coordinates, and area name as "
        "subtitle", () {
      final result = search('Sunny Boulder').single;
      expect(result.kind, MapSearchKind.topo);
      expect(result.wallId, 'wall-1');
      expect(result.subtitle, 'Squamish');
      expect(result.location, const LatLng(49.0, -123.0));
    });

    test("a route hit carries its wallId and wall name as subtitle", () {
      final result = search('Sunny Crack').single;
      expect(result.kind, MapSearchKind.route);
      expect(result.wallId, 'wall-1');
      expect(result.subtitle, 'Sunny Boulder');
      expect(result.location, const LatLng(49.1, -123.1));
    });

    test('sector and area hits have no wallId and no subtitle', () {
      final sectorResult = search('Sunny Slabs').single;
      expect(sectorResult.kind, MapSearchKind.sector);
      expect(sectorResult.wallId, isNull);
      expect(sectorResult.subtitle, isNull);
      expect(sectorResult.location, const LatLng(49.2, -123.2));

      final areaResult = search('Sunnyside Crag').single;
      expect(areaResult.kind, MapSearchKind.area);
      expect(areaResult.wallId, isNull);
      expect(areaResult.subtitle, isNull);
      expect(areaResult.location, const LatLng(49.3, -123.3));
    });
  });
}
