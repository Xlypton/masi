import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

/// A single candidate place returned by [GeocodingService.search]: a
/// human-readable label plus the WGS84 coordinates the Set-location map
/// picker's search field moves the map to when the user taps it.
class PlaceResult {
  const PlaceResult({
    required this.displayName,
    required this.latitude,
    required this.longitude,
  });

  final String displayName;
  final double latitude;
  final double longitude;
}

/// Abstraction over "look up candidate places for this free-text query", so
/// `set_location_picker.dart`'s search field never talks to a geocoding
/// backend directly and is trivially fakeable in widget tests.
///
/// [search] is deliberately best-effort and NEVER throws: any non-200
/// response, malformed body, network error, or timeout resolves to an empty
/// list rather than propagating an exception -- exactly like
/// `location_service.dart`'s [LocationService.currentLocation] never
/// throwing -- so a flaky/offline geocoding lookup never crashes or stalls
/// the picker, it just shows no results.
abstract class GeocodingService {
  Future<List<PlaceResult>> search(String query);
}

/// The real [GeocodingService], backed by the free OpenStreetMap Nominatim
/// search API (no API key required):
/// `https://nominatim.openstreetmap.org/search?q=<query>&format=json&limit=5&addressdetails=0`.
///
/// [client] is a test-injectable seam that defaults to a PLAIN
/// `http.Client()` -- deliberately NOT `community_screen.dart`'s
/// `buildResilientTileHttpClient()`, which wraps a `RetryClient` that
/// automatically retries 429/5xx responses with backoff. That policy fits
/// map tiles (many small, cheap, parallel requests against a CDN) but is
/// wrong here: Nominatim's usage policy caps callers at ~1 request/second
/// and a 429 means "you're already over that limit" -- auto-retrying it
/// would hammer the very endpoint that just rate-limited us. The search
/// field's own debounce already ensures at most one request per settled
/// query, which is what the usage policy expects; a single plain request
/// (still bounded by [_timeout]) is the compliant behavior. Tests can still
/// supply a fake, non-network `http.Client` instead of a real one.
class NominatimGeocodingService implements GeocodingService {
  NominatimGeocodingService({http.Client? client})
    : _client = client ?? http.Client();

  final http.Client _client;

  /// Exposes the constructed [_client] so a test can assert on ITS
  /// concrete type (e.g. that it is NOT a `RetryClient`) without touching
  /// the real network -- the only way to observe the difference between
  /// this class's default and `buildResilientTileHttpClient()`'s, since
  /// `_client` itself is private to this library.
  @visibleForTesting
  http.Client get debugClient => _client;

  /// Nominatim's usage policy (https://operations.osmfoundation.org/policies/nominatim/)
  /// rejects requests carrying an empty/default `http` package User-Agent --
  /// this must always be sent.
  static const _userAgent = 'Masi/1.0 (com.xlypton.masi)';

  static const _timeout = Duration(seconds: 8);

  @override
  Future<List<PlaceResult>> search(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return const [];

    try {
      final uri = Uri.https('nominatim.openstreetmap.org', '/search', {
        'q': trimmed,
        'format': 'json',
        'limit': '5',
        'addressdetails': '0',
      });
      final response = await _client
          .get(uri, headers: const {'User-Agent': _userAgent})
          .timeout(_timeout);

      if (response.statusCode != 200) return const [];

      final decoded = jsonDecode(response.body);
      if (decoded is! List) return const [];

      final results = <PlaceResult>[];
      for (final entry in decoded) {
        if (entry is! Map) continue;
        final displayName = entry['display_name'];
        final latitude = _parseDouble(entry['lat']);
        final longitude = _parseDouble(entry['lon']);
        if (displayName is! String || latitude == null || longitude == null) {
          continue;
        }
        results.add(
          PlaceResult(
            displayName: displayName,
            latitude: latitude,
            longitude: longitude,
          ),
        );
      }
      return results;
    } catch (_) {
      // Best-effort, mirroring GeolocatorLocationService.currentLocation: a
      // timeout, malformed JSON, DNS failure, or any other error must never
      // propagate -- an empty result list just means "show nothing".
      return const [];
    }
  }

  /// Nominatim returns `lat`/`lon` as JSON strings (e.g. `"46.0569"`), but
  /// parses defensively in case that ever changes to a numeric type.
  static double? _parseDouble(Object? value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }
}

/// The app-wide [GeocodingService] seam. Overridden in tests with a fake
/// that returns fixed [PlaceResult]s -- never the real
/// [NominatimGeocodingService], which would touch a real network.
final geocodingServiceProvider = Provider<GeocodingService>(
  (ref) => NominatimGeocodingService(),
);
