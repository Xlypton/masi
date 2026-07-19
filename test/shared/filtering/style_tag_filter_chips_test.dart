// Widget tests for StyleTagFilterChips: renders the curated style-tag chips
// (kCuratedRouteStyles) and emits onChanged with the right Set<String> on
// interaction. Mirrors style_filter_chips_test.dart's shape for the newer
// multi-tag facet.

import 'package:climbtopo/app/theme.dart';
import 'package:climbtopo/core/routes/route_styles.dart';
import 'package:climbtopo/shared/filtering/style_tag_filter_chips.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _buildChips({
  required Set<String> selected,
  required ValueChanged<Set<String>> onChanged,
}) {
  return MaterialApp(
    theme: MasiTheme.light,
    home: Scaffold(
      body: StyleTagFilterChips(selected: selected, onChanged: onChanged),
    ),
  );
}

void main() {
  group('StyleTagFilterChips', () {
    testWidgets('renders exactly one chip per curated style, keyed '
        'filter-styletag-<key>', (tester) async {
      await tester.pumpWidget(
        _buildChips(selected: const {}, onChanged: (_) {}),
      );
      await tester.pump();

      for (final style in kCuratedRouteStyles) {
        expect(
          find.byKey(Key('filter-styletag-${style.key}')),
          findsOneWidget,
        );
      }
      expect(find.byKey(const Key('filter-styletag-dyno')), findsOneWidget);
      expect(find.byKey(const Key('filter-styletag-crimpy')), findsOneWidget);
    });

    testWidgets('tapping an unselected chip emits it added to the set', (
      tester,
    ) async {
      Set<String>? emitted;
      await tester.pumpWidget(
        _buildChips(selected: const {}, onChanged: (v) => emitted = v),
      );
      await tester.pump();

      await tester.tap(find.byKey(const Key('filter-styletag-dyno')));
      await tester.pump();

      expect(emitted, {'dyno'});
    });

    testWidgets(
      'tapping an already-selected chip emits it removed from the set',
      (tester) async {
        Set<String>? emitted;
        await tester.pumpWidget(
          _buildChips(
            selected: const {'dyno', 'crimpy'},
            onChanged: (v) => emitted = v,
          ),
        );
        await tester.pump();

        await tester.tap(find.byKey(const Key('filter-styletag-dyno')));
        await tester.pump();

        expect(emitted, {'crimpy'});
      },
    );

    testWidgets(
      'selecting one chip does not disturb the others already selected',
      (tester) async {
        Set<String>? emitted;
        await tester.pumpWidget(
          _buildChips(
            selected: const {'slabby'},
            onChanged: (v) => emitted = v,
          ),
        );
        await tester.pump();

        await tester.tap(find.byKey(const Key('filter-styletag-dyno')));
        await tester.pump();

        expect(emitted, {'slabby', 'dyno'});
      },
    );
  });
}
