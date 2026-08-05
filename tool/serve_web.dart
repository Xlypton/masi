// Static server for a built web bundle that reproduces the production
// `web/_headers` contract: COOP + COEP + CORP (cross-origin isolation, which
// dart2wasm and drift's OPFS worker both require) and `application/wasm`.
//
//   dart run tool/serve_web.dart build/web_e2e 8099
//   dart run tool/serve_web.dart build/web 8099
//
// Same job as `tool/serve_web_isolated.py`, in Dart rather than Python — the
// Dart SDK ships with Flutter, so this needs no extra toolchain (Python is not
// installed on every dev box; see `docs/DEV_SETUP.md` §6).
//
// WITHOUT the three isolation headers the browser never exposes
// `SharedArrayBuffer`, drift's storage probe never offers `opfsLocks`, and the
// app silently falls back to the IndexedDB VFS — whose `xSync` is a documented
// no-op. You would then be testing a weaker storage backend than production
// ships. Verify with `self.crossOriginIsolated === true` in the console.
import 'dart:io';

const _mime = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.wasm': 'application/wasm',
  '.css': 'text/css; charset=utf-8',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
  '.ttf': 'font/ttf',
  '.otf': 'font/otf',
  '.woff2': 'font/woff2',
};

String _mimeFor(String path) {
  final dot = path.lastIndexOf('.');
  if (dot < 0) return 'application/octet-stream';
  return _mime[path.substring(dot).toLowerCase()] ?? 'application/octet-stream';
}

Future<void> main(List<String> args) async {
  final root = Directory(args.isNotEmpty ? args[0] : 'build/web');
  final port = args.length > 1 ? int.parse(args[1]) : 8099;
  if (!root.existsSync()) {
    stderr.writeln('no such directory: ${root.path}');
    stderr.writeln('usage: dart run tool/serve_web.dart <dir> [port]');
    exit(2);
  }

  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
  stdout.writeln('serving ${root.absolute.path} on http://localhost:$port');

  await for (final req in server) {
    final res = req.response;
    res.headers.set('Cross-Origin-Opener-Policy', 'same-origin');
    res.headers.set('Cross-Origin-Embedder-Policy', 'require-corp');
    res.headers.set('Cross-Origin-Resource-Policy', 'same-origin');
    res.headers.set('Cache-Control', 'no-cache');

    var rel = Uri.decodeComponent(req.uri.path);
    if (rel.startsWith('/')) rel = rel.substring(1);
    if (rel.isEmpty) rel = 'index.html';

    var file = File(
      '${root.path}${Platform.pathSeparator}'
      '${rel.replaceAll('/', Platform.pathSeparator)}',
    );

    // `usePathUrlStrategy()` means deep links (e.g. /community/topo/<id>) are
    // routed client-side — serve the shell for extensionless misses rather
    // than 404ing a route the app itself knows how to handle.
    if (!file.existsSync()) {
      if (!rel.contains('.')) {
        file = File('${root.path}${Platform.pathSeparator}index.html');
      } else {
        res.statusCode = HttpStatus.notFound;
        await res.close();
        continue;
      }
    }

    final bytes = await file.readAsBytes();
    res.headers.set('Content-Type', _mimeFor(file.path));
    res.headers.set('Content-Length', bytes.length.toString());
    res.add(bytes);
    await res.close();
  }
}
