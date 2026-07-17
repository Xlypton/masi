import 'dart:convert';

import 'package:climbtopo/core/location/geocoding_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' show BaseClient, BaseRequest, StreamedResponse;
import 'package:http/retry.dart' show RetryClient;

/// A fake [BaseClient] that resolves every request synchronously to a
/// scripted status/body (or throws [throwOn]) — never touches real
/// DNS/sockets, mirroring `community_screen_test.dart`'s identically-shaped
/// `_SpyHttpClient`. [lastRequest] lets tests assert on the exact URL/
/// headers [NominatimGeocodingService.search] sent.
class _FakeHttpClient extends BaseClient {
  _FakeHttpClient({this.statusCode = 200, this.body = '[]', this.throwOn});

  final int statusCode;
  final String body;
  final Object? throwOn;

  BaseRequest? lastRequest;

  @override
  Future<StreamedResponse> send(BaseRequest request) async {
    lastRequest = request;
    final throwable = throwOn;
    if (throwable != null) throw throwable;
    return StreamedResponse(Stream.value(utf8.encode(body)), statusCode);
  }
}

void main() {
  group('NominatimGeocodingService', () {
    test(
      'parses a valid Nominatim JSON array into PlaceResults and sends the '
      'expected request',
      () async {
        final client = _FakeHttpClient(
          body: jsonEncode([
            {
              'display_name': 'Railay Beach, Krabi, Thailand',
              'lat': '8.0104',
              'lon': '98.8375',
            },
            {
              'display_name': 'Fontainebleau, France',
              'lat': '48.4045',
              'lon': '2.7016',
            },
          ]),
        );
        final service = NominatimGeocodingService(client: client);

        final results = await service.search('railay');

        expect(results, hasLength(2));
        expect(results[0].displayName, 'Railay Beach, Krabi, Thailand');
        expect(results[0].latitude, closeTo(8.0104, 0.0001));
        expect(results[0].longitude, closeTo(98.8375, 0.0001));
        expect(results[1].displayName, 'Fontainebleau, France');

        final sentRequest = client.lastRequest;
        expect(sentRequest, isNotNull);
        expect(sentRequest!.url.host, 'nominatim.openstreetmap.org');
        expect(sentRequest.url.path, '/search');
        expect(sentRequest.url.queryParameters['q'], 'railay');
        expect(sentRequest.url.queryParameters['format'], 'json');
        expect(sentRequest.url.queryParameters['limit'], '5');
        expect(sentRequest.url.queryParameters['addressdetails'], '0');
        expect(
          sentRequest.headers['User-Agent'],
          'ClimbTopo/1.0 (com.climbtopo.climbtopo)',
          reason: 'Nominatim rejects requests with an empty/default '
              'User-Agent',
        );
      },
    );

    test('returns [] on a non-200 response', () async {
      final client = _FakeHttpClient(statusCode: 503, body: 'Service busy');
      final service = NominatimGeocodingService(client: client);

      final results = await service.search('anything');

      expect(results, isEmpty);
    });

    test('returns [] on a malformed (non-JSON) body', () async {
      final client = _FakeHttpClient(body: 'not json{{{');
      final service = NominatimGeocodingService(client: client);

      final results = await service.search('anything');

      expect(results, isEmpty);
    });

    test('returns [] when the body is valid JSON but not a list', () async {
      final client = _FakeHttpClient(body: jsonEncode({'error': 'boom'}));
      final service = NominatimGeocodingService(client: client);

      final results = await service.search('anything');

      expect(results, isEmpty);
    });

    test('returns [] (never throws) when the underlying client throws', () async {
      final client = _FakeHttpClient(throwOn: Exception('boom'));
      final service = NominatimGeocodingService(client: client);

      final results = await service.search('anything');

      expect(results, isEmpty);
    });

    test(
      'returns [] for an empty/whitespace-only query without calling the '
      'client at all',
      () async {
        final client = _FakeHttpClient();
        final service = NominatimGeocodingService(client: client);

        final results = await service.search('   ');

        expect(results, isEmpty);
        expect(client.lastRequest, isNull);
      },
    );

    test(
      'defaults to a plain http.Client, never the tile-retry policy '
      '(Nominatim is rate-limited at ~1 req/s -- auto-retrying its 429s '
      'would hammer the endpoint that just throttled us)',
      () {
        final service = NominatimGeocodingService();

        expect(
          service.debugClient,
          isNot(isA<RetryClient>()),
          reason:
              'buildResilientTileHttpClient() (4 retries on 429/5xx with '
              'backoff) is the right policy for map tiles, not for a '
              'rate-limited geocoding API',
        );
      },
    );

    test(
      'skips entries missing display_name/lat/lon rather than crashing',
      () async {
        final client = _FakeHttpClient(
          body: jsonEncode([
            {'display_name': 'Good Place', 'lat': '1.0', 'lon': '2.0'},
            {'lat': '1.0', 'lon': '2.0'},
            {'display_name': 'Bad lat', 'lat': 'oops', 'lon': '2.0'},
          ]),
        );
        final service = NominatimGeocodingService(client: client);

        final results = await service.search('mixed');

        expect(results, hasLength(1));
        expect(results.single.displayName, 'Good Place');
      },
    );
  });
}
