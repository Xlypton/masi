import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:masi/app/theme.dart';
import 'package:masi/shared/presentation/masi_shimmer.dart';
import 'package:masi/shared/presentation/masi_skeleton.dart';

/// Tests for the `MasiSkeleton` family — shaped placeholders, the default
/// loading affordance anywhere the content's shape is known.
///
/// Every skeleton contains a `MasiShimmer`, whose sweep repeats forever, so
/// **no test in this file may call `pumpAndSettle()`** (it would spin until it
/// times out). Bounded `tester.pump(duration)` throughout — except in the
/// reduced-motion test, where the sweep is frozen and settling is asserted to
/// be possible.
Widget _wrap(
  Widget child, {
  bool disableAnimations = false,
  ThemeData? theme,
  Size size = const Size(390, 700),
}) {
  return MediaQuery(
    data: MediaQueryData(disableAnimations: disableAnimations, size: size),
    child: MaterialApp(
      theme: theme ?? MasiTheme.light,
      home: Scaffold(body: child),
    ),
  );
}

void main() {
  group('shapes', () {
    testWidgets('line, box and circle each render a shimmer at their size', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              MasiSkeleton.line(width: 140),
              MasiSkeleton.box(width: 52, height: 52, radius: 10),
              MasiSkeleton.circle(diameter: 40),
            ],
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byType(MasiSkeleton), findsNWidgets(3));
      expect(find.byType(MasiShimmer), findsNWidgets(3));

      final shapes = find.byType(MasiSkeleton);
      expect(
        tester.getSize(shapes.at(0)),
        const Size(140, MasiSkeleton.lineThickness),
      );
      expect(tester.getSize(shapes.at(1)), const Size(52, 52));
      expect(tester.getSize(shapes.at(2)), const Size(40, 40));
      expect(tester.takeException(), isNull);
    });

    testWidgets('textLine reserves the line box a Text of that size occupies, '
        'not just the bar', (tester) async {
      await tester.pumpWidget(
        _wrap(
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [MasiSkeleton.textLine(fontSize: 17, widthFactor: 0.5)],
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));

      // The bar is thin; the slot it stands in is a real 17px line box, which
      // is what keeps a column of these the same height as the text it
      // replaces.
      expect(tester.getSize(find.byType(MasiSkeleton)).height, 11);
      final slot = tester.getSize(
        find.ancestor(
          of: find.byType(MasiSkeleton),
          matching: find.byType(SizedBox),
        ).first,
      );
      expect(slot.height, closeTo(17 * 1.3, 0.01));
    });
  });

  group('contrast', () {
    // The bug this guards: MasiShimmer's default base is `surface2` (#FBFAFE),
    // which is within a couple of percent of the white `surface` a skeleton row
    // paints on — an un-tinted bar on a light-mode card is invisible.
    testWidgets('light mode tints the shimmer base away from the white card', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(const MasiSkeletonListRow()));
      await tester.pump(const Duration(milliseconds: 100));

      final shimmer = tester.widget<MasiShimmer>(
        find.byType(MasiShimmer).first,
      );
      expect(shimmer.base, MasiColors.light.amethyst200);
    });

    testWidgets('dark mode keeps the default base, which is already a step '
        'lighter than its card', (tester) async {
      await tester.pumpWidget(
        _wrap(const MasiSkeletonListRow(), theme: MasiTheme.dark),
      );
      await tester.pump(const Duration(milliseconds: 100));

      final shimmer = tester.widget<MasiShimmer>(
        find.byType(MasiShimmer).first,
      );
      expect(shimmer.base, isNull);
    });
  });

  group('composites match the real rows they stand in for', () {
    testWidgets('a list row is 64 high — the height the real row gets from its '
        '48px icon buttons', (tester) async {
      await tester.pumpWidget(_wrap(const MasiSkeletonListRow()));
      await tester.pump(const Duration(milliseconds: 100));

      expect(
        tester.getSize(find.byType(MasiSkeletonListRow)).height,
        MasiSkeletonListRow.height,
      );
      expect(MasiSkeletonListRow.height, 64);
    });

    testWidgets('a subtitle-less list row is still 64 high', (tester) async {
      await tester.pumpWidget(
        _wrap(const MasiSkeletonListRow(showSubtitle: false)),
      );
      await tester.pump(const Duration(milliseconds: 100));

      expect(
        tester.getSize(find.byType(MasiSkeletonListRow)).height,
        MasiSkeletonListRow.height,
      );
    });

    testWidgets('a feed card is 86 high with a 52px thumbnail slot', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(const MasiSkeletonFeedCard()));
      await tester.pump(const Duration(milliseconds: 100));

      expect(
        tester.getSize(find.byType(MasiSkeletonFeedCard)).height,
        MasiSkeletonFeedCard.height,
      );
      expect(MasiSkeletonFeedCard.height, 86);
      expect(
        tester.getSize(find.byType(MasiSkeleton).first),
        const Size(
          MasiSkeletonFeedCard.thumbnailSize,
          MasiSkeletonFeedCard.thumbnailSize,
        ),
      );
    });
  });

  group('MasiSkeletonList', () {
    testWidgets('listRows renders the asked-for number of rows', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(const MasiSkeletonList.listRows(count: 4)));
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byType(MasiSkeletonListRow), findsNWidgets(4));
      expect(find.byKey(MasiSkeletonList.listKey), findsOneWidget);
    });

    testWidgets('feedCards renders feed-shaped cards', (tester) async {
      await tester.pumpWidget(_wrap(const MasiSkeletonList.feedCards(count: 3)));
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byType(MasiSkeletonFeedCard), findsNWidgets(3));
      expect(find.byType(MasiSkeletonListRow), findsNothing);
    });

    testWidgets('row widths vary, so it reads as a list rather than a table', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(const MasiSkeletonList.listRows(count: 3)));
      await tester.pump(const Duration(milliseconds: 100));

      final factors = tester
          .widgetList<MasiSkeletonListRow>(find.byType(MasiSkeletonListRow))
          .map((row) => row.titleWidthFactor)
          .toSet();
      expect(factors.length, greaterThan(1));
    });

    testWidgets('announces itself as loading, so it can never be mistaken for '
        'an empty list', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_wrap(const MasiSkeletonList.listRows(count: 2)));
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.bySemanticsLabel('Loading'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('is not scrollable and not tappable — there is nothing there '
        'to scroll to or press', (tester) async {
      await tester.pumpWidget(_wrap(const MasiSkeletonList.listRows()));
      await tester.pump(const Duration(milliseconds: 100));

      final listView = tester.widget<ListView>(find.byType(ListView));
      expect(listView.physics, isA<NeverScrollableScrollPhysics>());
      expect(find.byType(IgnorePointer), findsWidgets);
    });
  });

  group('reduced motion', () {
    testWidgets('a skeleton list still renders, frozen, and the tree settles', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          const MasiSkeletonList.listRows(count: 3),
          disableAnimations: true,
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byType(MasiSkeletonListRow), findsNWidgets(3));
      // Only possible because every shimmer froze its controller.
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });
}
