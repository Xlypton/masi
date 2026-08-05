// Shared network-blocking guard for widget tests that render a REAL,
// production map screen through a path that has NO injectable tile-provider
// seam -- i.e. tests that go through the actual `appRouter`/route builders
// rather than constructing `CommunityMapScreen` (or any other map widget)
// directly, so there is no test-only constructor parameter to hand a fake
// `TileProvider` through.
//
// ## Why this file exists (#29)
//
// `router_test.dart`'s `/map`-family tests navigate via the REAL `appRouter`,
// which builds the REAL `CommunityMapScreen` with no `tileProvider` override
// (production correctly leaves that seam null so it defaults to the real
// `NetworkTileProvider`). That means those tests were attempting a genuine
// outbound socket connection toward a live tile host during a plain
// `flutter_test` run -- confirmed by instrumenting `dart:io`'s
// `HttpOverrides.createHttpClient` and observing a real `connectionFactory`
// call with a tile-host URI, right before this fix.
//
// This guard closes that gap WITHOUT touching production code: it wraps a
// test body in an `HttpOverrides` zone whose `HttpClient` is otherwise REAL
// -- only its `connectionFactory` (the point immediately before DNS lookup /
// socket connect) is replaced, to record the target URI and THROW instead of
// ever touching a real socket. Everything else about the client (including
// `close()`) stays real, avoiding a brittle from-scratch reimplementation of
// the whole `HttpClient` interface.
//
// This is the ONE shared mechanism for every test that mounts a map/tile
// widget with no injectable-tileProvider escape hatch, replacing what would
// otherwise be N copy-pasted `HttpOverrides` subclasses (one per call site).
// Tests that DO have an injectable `tileProvider`/`setLocationTileProvider`
// constructor seam (most of `community_*_test.dart`,
// `set_location_search_test.dart`, `topos_screen_test.dart`,
// `topo_canvas_edit_location_test.dart`) don't need this guard: they already
// make network access impossible by never constructing a real
// `NetworkTileProvider` in the first place.
import 'dart:io';

/// Runs [body] inside a zone where every outbound `HttpClient` connection
/// attempt throws a [StateError] instead of touching the network.
///
/// [attempts] is populated (as a side effect visible after [run] completes)
/// with the string form of every URI that was blocked -- useful for a test
/// that wants to assert something WAS attempted, as a regression guard
/// against the seam this wraps silently disappearing.
class BlockedNetworkGuard {
  /// Every URI a blocked connection attempt targeted, in order.
  final List<String> attempts = [];

  /// Runs [body] with real outbound sockets replaced by a throw. [body]'s
  /// own return value/error propagates normally; only the socket-connect
  /// call site is intercepted.
  Future<T> run<T>(Future<T> Function() body) {
    final overrides = _BlockingHttpOverrides(attempts);
    return HttpOverrides.runZoned(
      body,
      createHttpClient: overrides.createHttpClient,
    );
  }
}

class _BlockingHttpOverrides extends HttpOverrides {
  _BlockingHttpOverrides(this._attempts);

  final List<String> _attempts;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    // A REAL HttpClient -- only `connectionFactory` is swapped out, right at
    // the point before a DNS lookup / socket connect would occur.
    final client = super.createHttpClient(context);
    client.connectionFactory = (Uri uri, String? proxyHost, int? proxyPort) {
      _attempts.add(uri.toString());
      throw StateError(
        'BlockedNetworkGuard: refused a real outbound socket connect to '
        '$uri. This test must never touch the network -- if this fires, '
        'either a new call site started performing real network I/O, or an '
        'existing tile-provider test seam regressed to null.',
      );
    };
    return client;
  }
}
