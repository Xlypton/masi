import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../../../shared/presentation/masi_skeleton.dart';
import '../application/ascent_route_art_providers.dart';
import 'route_art_picture.dart';

/// The route a shared ascent was logged against, drawn on its rock, at the top
/// of the ascent detail screen.
///
/// The detail screen is *about* one climb, and until now it described that
/// climb entirely in words — a name, a grade, a wall, a date. The feed row that
/// leads here already shows the line on the rock; opening it dropped the
/// picture and kept the text, which is backwards. This is the same picture the
/// row shows, large: same provider, same crop, same painter (see
/// [RouteArtPicture]), so tapping a row lands on a bigger version of exactly
/// what was tapped.
///
/// **It shows nothing rather than something broken.** A shared ascent whose art
/// cannot be resolved is ordinary, not exceptional — the wall's photo may not
/// have synced to this device, the route may have been deleted, the ascent may
/// predate any drawn line. In every one of those cases this collapses to zero
/// height and the screen reads exactly as it did before this widget existed. An
/// empty framed box would be worse than no box: it asserts a picture exists and
/// then fails to show it.
class AscentRouteArtHeader extends ConsumerWidget {
  const AscentRouteArtHeader({
    super.key,
    required this.wallId,
    required this.routeNumber,
    this.heightFraction = _defaultHeightFraction,
  });

  /// The wall whose primary photo carries the route.
  final String wallId;

  /// The `TopoRoute.number` this ascent was logged against. `null` when the
  /// ascent's route can no longer be joined, which shows nothing.
  final int? routeNumber;

  /// How much of the viewport's HEIGHT the square may take, when the available
  /// width would make it taller than that.
  ///
  /// The picture is square (the crop is square in pixel space — see
  /// [routeArtCrop]), so on a phone "as wide as the screen" and "nearly half
  /// the screen tall" are the same instruction. The cap is what keeps the
  /// climber's name, the route and the grade on screen WITH the picture rather
  /// than under it, on a short window as well as a tall phone — a hero image
  /// that pushes the caption off the fold stops being a caption.
  final double heightFraction;

  static const double _defaultHeightFraction = 0.42;

  /// The gap between the picture and the text that follows it. Lives here, not
  /// in the parent's child list, so that a collapsed header leaves NO trace —
  /// a stray [SizedBox] above the climber's name is exactly the kind of
  /// unexplained gap that reads as a rendering bug.
  static const double _bottomGap = MasiSpacing.md;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final number = routeNumber;
    if (number == null) return const SizedBox.shrink();

    final art = ref.watch(
      ascentRouteArtProvider((wallId: wallId, routeNumber: number)),
    );
    final resolved = art.asData?.value;

    if (resolved == null) {
      // Loading is the only unresolved state that reserves space. An error, or
      // a resolved `null`, both mean "there is no picture here" — and this
      // screen's answer to that is silence, not an error card. The ascent
      // itself loaded fine; only its illustration is missing.
      if (!art.isLoading) return const SizedBox.shrink();
      return _framed(
        (side) => MasiSkeleton.box(
          width: side,
          height: side,
          radius: MasiRadii.card,
        ),
      );
    }

    final crop = routeArtCrop(resolved);
    if (crop == null) return const SizedBox.shrink();

    return _framed(
      (side) => RouteArtPicture(
        storedPath: resolved.thumbnailPath,
        route: resolved.route,
        crop: crop,
        side: side,
        borderRadius: MasiRadii.card,
      ),
    );
  }

  /// Sizes [build]'s square against both axes and centres it, so the loading
  /// slot and the picture that replaces it occupy the same box — a skeleton
  /// that resolves into a differently-sized picture is a layout jump with extra
  /// steps.
  Widget _framed(Widget Function(double side) child) {
    return Padding(
      padding: const EdgeInsets.only(bottom: _bottomGap),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final side = math.min(
            constraints.maxWidth,
            MediaQuery.sizeOf(context).height * heightFraction,
          );
          return Center(child: child(side));
        },
      ),
    );
  }
}
