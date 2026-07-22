// Web backend for the AR live-camera surface widget: a live rear-camera
// feed sourced from the browser's `getUserMedia()` API, rendered through a
// registered `HtmlElementView` platform view. This is the web analogue of
// the iOS `UiKitView` camera surface `ArScreen` constructs natively (see
// `ar_screen.dart` / `ar_support.dart`'s `isArSupported()` gate) — same
// visual role (a full-bleed live camera feed the AR overlay paints on top
// of), but sourced from an `HTMLVideoElement` + `MediaStream` instead of
// ARKit.
//
// Wasm-clean: built only on `dart:js_interop` + `package:web` bindings (the
// same idiom `photo_image_cache_web.dart` / `image_ops_web.dart` use) plus
// `dart:ui_web` for the platform-view registry — no `dart:html`, no
// `dart:io`.
import 'dart:async';
import 'dart:js_interop';
import 'dart:ui_web' as ui_web;

import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

Widget buildArCameraView({
  VoidCallback? onReady,
  void Function(String message)? onError,
}) {
  return _ArWebCameraView(onReady: onReady, onError: onError);
}

/// Message shown (and reported via [_ArWebCameraView.onError]) when
/// `getUserMedia()` rejects — most commonly the user denying the camera
/// permission prompt, but also covers "no camera hardware" and (on non-HTTPS
/// origins) the API being unavailable at all.
const String _kCameraUnavailableMessage =
    'Camera unavailable — check permissions';

class _ArWebCameraView extends StatefulWidget {
  const _ArWebCameraView({this.onReady, this.onError});

  final VoidCallback? onReady;
  final void Function(String message)? onError;

  @override
  State<_ArWebCameraView> createState() => _ArWebCameraViewState();
}

class _ArWebCameraViewState extends State<_ArWebCameraView> {
  /// Unique per State instance: `HtmlElementView` view types are global
  /// (process-wide) registry keys, so two live camera views mounted at once
  /// (e.g. during a screen transition) must never collide on the same
  /// `<video>` element.
  late final String _viewType = 'ar-web-camera-$hashCode';

  late final web.HTMLVideoElement _video;

  /// The active camera stream, kept only so [dispose] can stop every track
  /// and release the hardware. Null until `getUserMedia()` resolves — and
  /// stays null forever if it rejects, which [dispose] guards for.
  web.MediaStream? _stream;

  bool _error = false;

  @override
  void initState() {
    super.initState();
    _video = web.HTMLVideoElement()
      ..autoplay = true
      ..muted = true
      ..setAttribute('playsinline', 'true')
      ..setAttribute('webkit-playsinline', 'true')
      ..style.width = '100%'
      ..style.height = '100%'
      ..style.objectFit = 'cover';
    ui_web.platformViewRegistry.registerViewFactory(
      _viewType,
      (int viewId) => _video,
    );
    unawaited(_startCamera());
  }

  Future<void> _startCamera() async {
    try {
      final constraints = web.MediaStreamConstraints(
        // `{'facingMode': 'environment'}.jsify()!` is the robust way to
        // build an arbitrary constraints object: `MediaTrackConstraints`
        // itself models only a fixed, non-exhaustive set of fields, whereas
        // `jsify()` on a plain Dart map produces exactly the JS object shape
        // `getUserMedia` expects, sidestepping the need to instantiate a
        // second package:web dictionary type just for this one key.
        video: <String, String>{'facingMode': 'environment'}.jsify()!,
      );
      final stream = await web.window.navigator.mediaDevices
          .getUserMedia(constraints)
          .toDart;
      if (!mounted) {
        // Disposed while awaiting the permission prompt/hardware — the
        // stream was still just granted, so release it immediately rather
        // than leaking an open camera nobody can see.
        for (final track in stream.getTracks().toDart) {
          track.stop();
        }
        return;
      }
      _stream = stream;
      _video.srcObject = stream;
      widget.onReady?.call();
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = true);
      widget.onError?.call(_kCameraUnavailableMessage);
    }
  }

  @override
  void dispose() {
    // Release the camera unconditionally — this MUST run even if
    // `getUserMedia()` never resolved (guarded by the null check) so the
    // hardware/permission indicator never outlives this widget.
    final stream = _stream;
    if (stream != null) {
      for (final track in stream.getTracks().toDart) {
        track.stop();
      }
    }
    _video.pause();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error) {
      return const ColoredBox(
        color: Color(0xFF000000),
        child: Center(
          child: Text(
            _kCameraUnavailableMessage,
            key: Key('ar-web-camera-error'),
            style: TextStyle(color: Color(0xFFFFFFFF)),
          ),
        ),
      );
    }
    return HtmlElementView(
      viewType: _viewType,
      key: const Key('ar-web-camera'),
    );
  }
}
