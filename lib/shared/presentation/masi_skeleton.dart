import 'package:flutter/material.dart';

import '../../app/theme.dart';
import 'masi_shimmer.dart';

/// A single shaped shimmer placeholder — the building block of every skeleton
/// in the app.
///
/// **Why skeletons rather than spinners.** A shaped placeholder says *what*
/// is coming and roughly how much of it; a centred spinner says only that the
/// app is busy. It also solves the worst state this app had: a list rendering
/// its empty message while the data was still on its way, so "loading" and
/// "you have nothing" looked identical.
///
/// Three shapes, all shimmering via [MasiShimmer] (so all of them respect
/// reduced motion — the sweep freezes on a single frame — for free):
///
/// ```dart
/// const MasiSkeleton.line(width: 140)                  // a text line
/// const MasiSkeleton.box(width: 52, height: 52, radius: 10) // a thumbnail
/// const MasiSkeleton.circle(diameter: 40)              // an avatar
/// ```
///
/// A `null` [width] or [height] means "take the parent's" — fine inside a
/// [Column] with `crossAxisAlignment: stretch` or an [Expanded], but it must
/// be bounded in that axis: a `null`-width skeleton placed directly in a
/// [Row] has unbounded width and will throw, exactly as a `SizedBox` would.
///
/// Prefer the ready-made composites below over hand-assembling shapes:
/// [MasiSkeletonListRow] (Areas/Sectors/Walls/Topos rows),
/// [MasiSkeletonFeedCard] (a Community feed card) and [MasiSkeletonList]
/// (either of those, repeated, laid out exactly like the real list). A
/// skeleton whose geometry does not match the content it precedes makes the
/// screen jump when data arrives, which is worse than a spinner — so if you
/// need a new shape, measure the real widget first.
///
/// **Testing.** [MasiShimmer]'s sweep repeats forever, so any tree containing
/// a skeleton hangs `pumpAndSettle()`. Drive it with explicit
/// `tester.pump(duration)` calls (or `tester.pump()` a fixed number of times),
/// and assert on `find.byType(MasiSkeleton)` / the composites' keys.
class MasiSkeleton extends StatelessWidget {
  /// A rounded rectangle — a thumbnail, an image slot, a chip, a pill.
  const MasiSkeleton.box({
    super.key,
    this.width,
    this.height,
    this.radius = MasiRadii.card,
  });

  /// A text line: a low bar with a fully-rounded cap. [height] is the bar's
  /// own thickness, NOT the text slot it stands in — see
  /// [MasiSkeleton.textLine], which reserves a real line box.
  const MasiSkeleton.line({
    super.key,
    this.width,
    this.height = lineThickness,
    this.radius = lineThickness / 2,
  });

  /// A circle — an avatar.
  const MasiSkeleton.circle({super.key, required double diameter})
    : width = diameter,
      height = diameter,
      radius = diameter / 2;

  /// Default [MasiSkeleton.line] bar thickness.
  static const double lineThickness = 11;

  /// A [MasiSkeleton.line] centred inside the line box a [Text] of
  /// [fontSize] would occupy, so a column of them lands at the same height as
  /// the real text it stands in for.
  ///
  /// [widthFactor] is a fraction of the available width (real labels are not
  /// all full-width, and a skeleton of identical full-width bars reads as a
  /// table, not as prose).
  static Widget textLine({
    required double fontSize,
    double widthFactor = 1,
    double? thickness,
  }) {
    return SizedBox(
      // 1.3x: close to the line height Flutter gives the app's text styles at
      // their default `height`, which is what makes a stack of these match the
      // real row rather than sitting a few pixels short of it.
      height: fontSize * 1.3,
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        child: FractionallySizedBox(
          widthFactor: widthFactor,
          child: MasiSkeleton.line(height: thickness ?? lineThickness),
        ),
      ),
    );
  }

  final double? width;
  final double? height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(
        width: width,
        height: height,
        child: const _SkeletonFill(),
      ),
    );
  }
}

/// The shimmer a skeleton shape is filled with.
///
/// Light mode overrides [MasiShimmer]'s base: its default [MasiColors.surface2]
/// (#FBFAFE) is within a couple of percent of the white [MasiColors.surface]
/// card a skeleton row paints on, so an un-tinted bar there is effectively
/// invisible. [MasiColors.amethyst200] reads clearly on white while staying
/// well short of looking like real content, and the default
/// [MasiColors.amethyst100] highlight is still lighter than it, so the sweep
/// survives.
///
/// Dark mode passes nothing: there `surface2` is already a step LIGHTER than
/// the `surface` card, so the default pairing is correct as-is.
class _SkeletonFill extends StatelessWidget {
  const _SkeletonFill();

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    final isLight = Theme.of(context).brightness == Brightness.light;
    return MasiShimmer(base: isLight ? colors.amethyst200 : null);
  }
}

/// A placeholder for one row of the Areas / Sectors / Walls / Topos lists —
/// i.e. `crud_list_scaffold.dart`'s `_buildRow`.
///
/// Geometry is copied from that row, because a mismatch is what makes content
/// jump on arrival: a [MasiColors.surface] [Material] at [MasiRadii.card],
/// padded `horizontal: MasiSpacing.md, vertical: MasiSpacing.sm`, holding a
/// title line and (by default) a subtitle line. [height] (64) is a MINIMUM,
/// not a fixed size: the real row's height comes from its 48 px trailing
/// [IconButton]s (rename/delete) rather than from its text, so a skeleton
/// built out of text bars alone lands ~14 px short of it — but the real row
/// DOES grow past 48 px at large accessibility text scales, and so must this,
/// or the jump comes back for exactly the users least able to absorb it.
/// Hence the bar slots are text-scaled and the height is a floor.
class MasiSkeletonListRow extends StatelessWidget {
  const MasiSkeletonListRow({
    super.key,
    this.showSubtitle = true,
    this.titleWidthFactor = 0.55,
  });

  /// The real row's height at the default text scale — 48 px `IconButton` +
  /// 2 × [MasiSpacing.sm]. Public so a caller reserving space (a
  /// `SliverFixedExtentList`, a sized box) can use the same number rather than
  /// re-deriving it. A minimum, not a cap: see the class doc.
  static const double height = 64;

  /// Draw the second, shorter line. Match the list you are standing in for.
  ///
  /// In `crud_list_scaffold.dart` that is decided by whether the screen passes
  /// `subtitleOf`, so derive it — `showSubtitle: subtitleOf != null` — rather
  /// than hardcoding per screen. Today only `areas_screen.dart` passes one (the
  /// area description); Sectors and Walls do not.
  ///
  /// (An earlier version of this comment claimed the opposite — that
  /// Sectors/Walls carry a subtitle and Areas do not. It was wrong, and it was
  /// copied into adoption work before anyone checked it against the call sites.
  /// Deriving from `subtitleOf` is what makes the question unaskable.)
  final bool showSubtitle;

  /// Fraction of the row's text column the title bar spans.
  final double titleWidthFactor;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    return Material(
      color: colors.surface,
      borderRadius: BorderRadius.circular(MasiRadii.card),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: height),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: MasiSpacing.md,
            vertical: MasiSpacing.sm,
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // titleMedium (17) — the row's name.
                    MasiSkeleton.textLine(
                      fontSize: scaler.scale(17),
                      widthFactor: titleWidthFactor,
                    ),
                    if (showSubtitle) ...[
                      const SizedBox(height: 2),
                      // titleSmall (15) — the row's subtitle.
                      MasiSkeleton.textLine(
                        fontSize: scaler.scale(15),
                        widthFactor: 0.3,
                      ),
                    ],
                  ],
                ),
              ),
              // Stands in for the trailing chevron only. The rename/delete
              // icon buttons are deliberately NOT drawn: they are chrome that
              // appears instantly with the row, and shimmering fake controls
              // invites taps on something that cannot be tapped.
              const SizedBox(width: MasiSpacing.md),
              const MasiSkeleton.box(width: 8, height: 14, radius: 4),
            ],
          ),
        ),
      ),
    );
  }
}

/// A placeholder for one Community-feed card — `community_feed_screen.dart`'s
/// `_FeedRow`.
///
/// Same [Material] / radius / padding as that row, then its three-part
/// content: the 52×52 thumbnail at radius 10, and a text column of
/// name (titleMedium 17) → grade pill + route count → likes/comments/owner
/// (titleSmall 15). Comes out at [height] 86 at the default text scale,
/// matching the real card, so the feed does not jump when the first page
/// lands; like [MasiSkeletonListRow] that height is a floor and the text slots
/// scale, so it still matches at large accessibility text scales.
class MasiSkeletonFeedCard extends StatelessWidget {
  const MasiSkeletonFeedCard({super.key, this.titleWidthFactor = 0.6});

  /// The real card's height at the default text scale: 22 (title) + 2 + 24
  /// (pill row) + 2 + 20 (meta row) content, plus 2 × [MasiSpacing.sm]
  /// padding. A minimum, not a cap.
  static const double height = 86;

  /// The real feed thumbnail: 52 px at radius 10 (`_Thumbnail`).
  static const double thumbnailSize = 52;

  final double titleWidthFactor;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    return Material(
      color: colors.surface,
      borderRadius: BorderRadius.circular(MasiRadii.card),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: height),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: MasiSpacing.md,
            vertical: MasiSpacing.sm,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const MasiSkeleton.box(
                width: thumbnailSize,
                height: thumbnailSize,
                radius: 10,
              ),
              const SizedBox(width: MasiSpacing.md),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    MasiSkeleton.textLine(
                      fontSize: scaler.scale(17),
                      widthFactor: titleWidthFactor,
                    ),
                    const SizedBox(height: 2),
                    // The grade pill + "N routes" line: a pill-shaped block
                    // rather than a bar, because that line is a control-shaped
                    // chip in the real card.
                    const SizedBox(
                      height: 24,
                      child: Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: MasiSkeleton.box(
                          width: 88,
                          height: 18,
                          radius: MasiRadii.control,
                        ),
                      ),
                    ),
                    const SizedBox(height: 2),
                    MasiSkeleton.textLine(
                      fontSize: scaler.scale(15),
                      widthFactor: 0.75,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: MasiSpacing.md),
              const MasiSkeleton.box(width: 8, height: 14, radius: 4),
            ],
          ),
        ),
      ),
    );
  }
}

/// A whole list of skeleton rows, laid out exactly like the real list it
/// stands in for — this is what a screen's loading branch should render.
///
/// ```dart
/// // Areas / Sectors / Walls / Topos
/// skeleton: (context) => const MasiSkeletonList.listRows(),
/// // Community feed
/// skeleton: (context) => const MasiSkeletonList.feedCards(),
/// ```
///
/// Row widths vary down the list ([_widthFactors]) so it reads as a list of
/// different things rather than a table. Not scrollable and not tappable: it
/// stands in for content that is not there yet, so a drag or a tap must do
/// nothing rather than something surprising.
///
/// It is a [ListView], so — like the real list it replaces — it needs a
/// bounded height: a [Scaffold.body], an [Expanded], a sized box. That is
/// already true wherever it is handed to `MasiAsyncView.skeleton`.
///
/// Cost note: every shape is its own [MasiShimmer], i.e. its own ticker and
/// its own [RepaintBoundary]. The default counts are deliberately modest (and
/// a couple of rows past the fold is enough to read as "a list"); do not raise
/// [count] into the dozens on the strength of a large screen.
class MasiSkeletonList extends StatelessWidget {
  /// Areas / Sectors / Walls / Topos.
  const MasiSkeletonList.listRows({
    super.key,
    this.count = 6,
    this.padding,
    this.showSubtitle = true,
  }) : _feed = false;

  /// The Community feed.
  const MasiSkeletonList.feedCards({super.key, this.count = 4, this.padding})
    : _feed = true,
      showSubtitle = true;

  /// On the skeleton list's outermost widget, for tests and for screens that
  /// need to tell "loading" from "empty" in a driver flow.
  static const Key listKey = Key('masi-skeleton-list');

  /// How many placeholder rows.
  final int count;

  /// Defaults to the real list's own padding — `crud_list_scaffold.dart` uses
  /// `horizontal: lg, vertical: md`; the community feed uses
  /// `horizontal: lg, vertical: sm`.
  final EdgeInsetsGeometry? padding;

  /// Forwarded to [MasiSkeletonListRow.showSubtitle]; ignored by
  /// `.feedCards`.
  final bool showSubtitle;

  final bool _feed;

  /// Deterministic (not random — a skeleton must not re-shuffle on every
  /// rebuild) width variation, cycled over the rows.
  static const List<double> _widthFactors = [0.62, 0.44, 0.71, 0.5, 0.58, 0.4];

  @override
  Widget build(BuildContext context) {
    final resolvedPadding =
        padding ??
        EdgeInsets.symmetric(
          horizontal: MasiSpacing.lg,
          vertical: _feed ? MasiSpacing.sm : MasiSpacing.md,
        );

    return Semantics(
      key: listKey,
      container: true,
      label: 'Loading',
      child: IgnorePointer(
        child: ListView.separated(
          // Nothing to reveal by scrolling, and an overscroll glow on
          // placeholder content reads as a bug.
          physics: const NeverScrollableScrollPhysics(),
          padding: resolvedPadding,
          itemCount: count,
          separatorBuilder: (context, index) =>
              const SizedBox(height: MasiSpacing.sm),
          itemBuilder: (context, index) {
            final widthFactor = _widthFactors[index % _widthFactors.length];
            return _feed
                ? MasiSkeletonFeedCard(titleWidthFactor: widthFactor)
                : MasiSkeletonListRow(
                    showSubtitle: showSubtitle,
                    titleWidthFactor: widthFactor,
                  );
          },
        ),
      ),
    );
  }
}
