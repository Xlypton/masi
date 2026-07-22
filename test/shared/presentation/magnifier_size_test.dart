import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:masi/shared/presentation/masi_icon.dart';

/// Regression test for the search-field magnifier bug: `MasiIcon('search',
/// size: 13, ...)` passed as `InputDecoration.prefixIcon` rendered ~48x48
/// instead of the requested 13x13.
///
/// Root cause: `InputDecorator` wraps `prefixIcon` in a `ConstrainedBox`
/// whose default constraints are `BoxConstraints(minWidth:
/// kMinInteractiveDimension, minHeight: kMinInteractiveDimension)` (48x48)
/// UNLESS `InputDecoration.prefixIconConstraints` is set explicitly. The SVG
/// (via flutter_svg -> vector_graphics) is internally wrapped in a
/// `SizedBox(width: 13, height: 13)`; `SizedBox` tightens to its requested
/// size only within the *incoming* constraint range, so when the parent
/// forces minWidth/minHeight to 48, the 13x13 request is clamped UP to
/// 48x48. MasiIcon itself is not at fault — a bare MasiIcon (no
/// InputDecorator ancestor) renders at its exact requested size.
void main() {
  testWidgets('bare MasiIcon renders at requested size (baseline)', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: MasiIcon('search', size: 13, color: Colors.black)),
      ),
    );
    await tester.pumpAndSettle();

    final size = tester.getSize(find.byType(MasiIcon));
    expect(size, const Size(13, 13));
  });

  testWidgets(
    'MasiIcon as bare TextField prefixIcon is inflated to ~48x48 (bug)',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: TextField(
              decoration: InputDecoration(
                prefixIcon: MasiIcon('search', size: 13, color: Colors.black),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final size = tester.getSize(find.byType(MasiIcon));
      // This documents the BUG: without prefixIconConstraints, the default
      // InputDecorator minimum (kMinInteractiveDimension = 48) forces the
      // icon to render far larger than the requested 13x13.
      expect(size, const Size(48, 48));
    },
  );

  testWidgets(
    'MasiIcon prefixIcon with explicit prefixIconConstraints renders at requested size (fix)',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: TextField(
              decoration: InputDecoration(
                prefixIcon: MasiIcon('search', size: 16, color: Colors.black),
                prefixIconConstraints: BoxConstraints.tightFor(
                  width: 16,
                  height: 16,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final size = tester.getSize(find.byType(MasiIcon));
      expect(size, const Size(16, 16));
    },
  );
}
