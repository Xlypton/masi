import 'dart:async';

import 'package:flutter/material.dart';

import 'package:masi/shared/presentation/masi_shimmer.dart';

/// The "this photo is still coming" fill for [PhotoImage]'s
/// `loadingPlaceholder` slot: a [MasiShimmer] that stops sweeping once it has
/// been up long enough to have said everything it can say.
///
/// **Why the two states.** `loadingPlaceholder` exists so a photo being resolved
/// stops looking like a photo that is gone (see [PhotoImage]'s doc, and the
/// `placeholder` next to every call site — a grey box with an `image` glyph,
/// which must only ever mean "missing"). A sweeping shimmer is the right way to
/// say "coming" for the first moment. It is NOT the right thing to keep doing
/// indefinitely: unlike a list row's placeholder, a photo's load has no bound —
/// on web the bytes may be coming out of IndexedDB, or being fetched on demand
/// from the shared bucket over a bad connection (see
/// `missing_photo_byte_resolver.dart`), or, for a canvas-sized original, still
/// decoding. An animation that has been sweeping for [animateFor] has stopped
/// being information and become a permanently ticking, permanently
/// re-compositing surface — over the largest bitmap slot in the app, in the
/// canvas's case.
///
/// So after [animateFor] this freezes on a single representative frame, which is
/// exactly what [MasiShimmer] already does for a reduced-motion user (it is the
/// same mechanism: a `disableAnimations` [MediaQuery] over a fresh shimmer). The
/// visual stays a shimmer — still plainly distinct from the missing-photo
/// placeholder — it simply stops moving.
///
/// A welcome side effect in tests: a frozen shimmer schedules no frames, so a
/// tree holding one SETTLES. `Image.file`'s load never resolves under
/// `flutter_test`'s fake async (real file I/O only runs inside
/// `tester.runAsync`), so every canvas/strip test that pumps a nonexistent
/// fixture path holds this widget forever — with an unbounded sweep that turns
/// every `pumpAndSettle()` in the suite into a timeout.
class PhotoLoadingFill extends StatefulWidget {
  const PhotoLoadingFill({super.key, this.width, this.height, this.radius = 0});

  /// How long the sweep runs before freezing.
  ///
  /// Two seconds because that is about where a sweep stops being reassurance
  /// and becomes noise — a local decode or an IndexedDB read finishes in
  /// milliseconds, so anything still sweeping at two seconds is a load whose
  /// duration this animation cannot usefully narrate anyway. It is also
  /// deliberately well under Material's 4 s [SnackBar] window: a widget test
  /// only settles once this stops, so a longer sweep would silently swallow
  /// every SnackBar assertion made on a screen that happens to be holding a
  /// still-loading photo.
  static const Duration animateFor = Duration(seconds: 2);

  /// Size of the fill. `null` takes the parent's, which is what both call sites
  /// want inside their already-sized box.
  final double? width;
  final double? height;

  /// Corner rounding. Defaults to square: the canvas photo is full-bleed, and
  /// the strip thumbnail is already clipped by its own `ClipRRect`.
  final double radius;

  @override
  State<PhotoLoadingFill> createState() => _PhotoLoadingFillState();
}

class _PhotoLoadingFillState extends State<PhotoLoadingFill> {
  Timer? _freezeTimer;
  bool _frozen = false;

  @override
  void initState() {
    super.initState();
    _freezeTimer = Timer(PhotoLoadingFill.animateFor, () {
      _freezeTimer = null;
      if (mounted) setState(() => _frozen = true);
    });
  }

  @override
  void dispose() {
    // Cancelled so a widget disposed mid-load neither fires setState on an
    // unmounted State nor leaves a pending timer behind at test teardown.
    _freezeTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Widget fill = const MasiShimmer();
    if (_frozen) {
      final media = MediaQuery.maybeOf(context);
      if (media != null) {
        // Inserting a widget above the shimmer replaces its element, so the
        // fresh `_MasiShimmerState` reads `disableAnimations` in its own
        // `didChangeDependencies` and stops its controller on a mid-sweep frame
        // — the reduced-motion path, reused rather than reimplemented.
        fill = MediaQuery(
          data: media.copyWith(disableAnimations: true),
          child: fill,
        );
      }
    }
    final box = SizedBox(
      width: widget.width,
      height: widget.height,
      child: fill,
    );
    // No clip at all for the square case, rather than a zero-radius ClipRRect:
    // the canvas viewport is asserted to contain NO ClipRRect anywhere (it is
    // full-bleed with sharp edges by design — see `topo_canvas_fit_test.dart`),
    // and a clip layer nothing needs is a saveLayer nothing needs either.
    if (widget.radius <= 0) return box;
    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.radius),
      child: box,
    );
  }
}
