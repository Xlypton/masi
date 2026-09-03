import 'package:flutter/material.dart';

/// Builds a route's screen only after its deferred library has loaded.
///
/// ## Why this exists, and what it actually buys
///
/// The router used to import all 17 screens eagerly, so a climber opening the
/// app to look at a wall downloaded the AR stack and the moderation queue
/// before the first frame. `deferred as` moves those out of the initial
/// download — but `loadLibrary()` returns a `Future`, and go_router's
/// `builder` must return a `Widget` synchronously, so something has to bridge
/// the two. This is that bridge.
///
/// **It only pays off on the dart2js bundle, and that is not a defect — it is
/// the primary target.** A `--wasm` build emits BOTH `main.dart.wasm` (blink)
/// and `main.dart.js` (everything WebKit, i.e. every browser on iOS). dart2wasm
/// splits a program only when passed `--enable-deferred-loading`, and Flutter's
/// `build web` never passes it (see `flutter_tools`'
/// `build_system/targets/web.dart`, which passes several
/// `--extra-compiler-option`s but not that one, and exposes no passthrough for
/// it). So on blink `loadLibrary()` resolves against code that is already
/// there, and this widget costs one already-completed `Future`. On iOS the
/// deferred part file is a real fetch, and the initial download is smaller by
/// the size of these features. Measure before assuming otherwise: it is easy to
/// read "deferred loading did nothing" off a wasm build and conclude the change
/// is inert, when the half that matters was never being measured.
///
/// ## The already-loaded fast path is load-bearing
///
/// [_loaded] is why a second navigation to the same route builds the screen
/// synchronously instead of showing a frame of [_DeferredPending] first.
/// Without it every visit to `/admin` — including on native and on blink, where
/// the library was never absent — would flash a spinner for one frame on the
/// way in, which reads as jank introduced by an optimisation. `loadLibrary()`
/// is idempotent and cheap once loaded, so this cache is about the FRAME, not
/// about the load.
///
/// A failed load is deliberately NOT cached: an iPhone that lost signal
/// mid-fetch must be able to retry, and the retry has to be able to succeed.
class DeferredRoute extends StatefulWidget {
  const DeferredRoute({
    required this.name,
    required this.load,
    required this.builder,
    super.key,
  });

  /// Stable identity for the deferred library, used as the [_loaded] cache key.
  /// Not user-visible; it names the library, not the screen.
  final String name;

  /// The generated `loadLibrary()` of the deferred import.
  final Future<void> Function() load;

  /// Builds the screen. Called only once [load] has completed, so it is safe
  /// to reference the deferred library's types inside it.
  final WidgetBuilder builder;

  /// Libraries whose `loadLibrary()` has already completed successfully in
  /// this app run.
  static final Set<String> _loaded = <String>{};

  /// Test seam: forget everything [DeferredRoute] has cached.
  ///
  /// Widget tests share one isolate across cases, so a library marked loaded
  /// by an earlier test would let a later one skip the pending state it is
  /// trying to assert on — a test that passes by never exercising its subject.
  @visibleForTesting
  static void resetForTest() => _loaded.clear();

  @override
  State<DeferredRoute> createState() => _DeferredRouteState();
}

class _DeferredRouteState extends State<DeferredRoute> {
  Future<void>? _pending;
  Object? _error;

  @override
  void initState() {
    super.initState();
    if (!DeferredRoute._loaded.contains(widget.name)) _start();
  }

  void _start() {
    _error = null;
    final future = widget.load();
    _pending = future;
    future.then(
      (_) {
        if (!mounted) return;
        DeferredRoute._loaded.add(widget.name);
        setState(() => _pending = null);
      },
      onError: (Object error, StackTrace _) {
        if (!mounted) return;
        // Deliberately not recorded in `_loaded`: see the class doc.
        setState(() {
          _pending = null;
          _error = error;
        });
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return _DeferredFailed(onRetry: () => setState(_start));
    }
    if (_pending != null) return const _DeferredPending();
    return widget.builder(context);
  }
}

/// Shown while a deferred library is in flight.
///
/// A plain [Scaffold] rather than a bare [CircularProgressIndicator] so it
/// paints the theme's background: an unparented indicator over a transparent
/// ground renders as a spinner floating on whatever the previous route left
/// behind.
class _DeferredPending extends StatelessWidget {
  const _DeferredPending();

  @override
  Widget build(BuildContext context) => const Scaffold(
    body: Center(child: CircularProgressIndicator()),
  );
}

/// Shown when `loadLibrary()` failed — in practice, a phone that lost signal
/// partway into fetching the part file.
///
/// It offers a retry rather than only an apology because the failure is
/// genuinely transient and the user is already where they wanted to be; making
/// them navigate away and back would be a worse version of the same button.
class _DeferredFailed extends StatelessWidget {
  const _DeferredFailed({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(),
    body: Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Text(
              "This part of the app couldn't be loaded.",
              textAlign: TextAlign.center,
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            const Text(
              'It downloads the first time you open it, so this usually means '
              'the connection dropped. Everything already on this device is '
              'unaffected.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton(
              key: const Key('deferred-route-retry'),
              onPressed: onRetry,
              child: const Text('Try again'),
            ),
          ],
        ),
      ),
    ),
  );
}
