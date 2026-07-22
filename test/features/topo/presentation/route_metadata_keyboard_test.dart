// Intended-behavior tests for #20a (keyboard dismiss): dismissing the
// RouteMetadataSheet bottom sheet — via either Save or Cancel — must never
// leave the on-screen keyboard stranded. See `RouteMetadataSheet._pop`
// (route_metadata_sheet.dart), which now unfocuses immediately before
// `Navigator.maybePop()`; both `_save` and `_cancel` route through it.
//
// Harness (buildSheet/_seedRoute) mirrors route_metadata_intent_test.dart's
// own boilerplate — this widget is designed to be pumped directly (see its
// class doc), no image decode or real canvas path required.

import 'package:masi/app/theme.dart';
import 'package:masi/features/topo/application/draw_controller.dart';
import 'package:masi/features/topo/domain/topo_route.dart';
import 'package:masi/features/topo/presentation/route_metadata_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// FIX #6 (family-keyed `drawControllerProvider(_testWallId)`): stand-in wallId, paired
/// consistently everywhere this file constructs `RouteMetadataSheet` or
/// reads the provider directly.
const _testWallId = 'test-wall';

Widget _buildSheet({
  required ProviderContainer container,
  required int routeId,
  TopoRoute? initial,
}) {
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: MasiTheme.light,
      home: Scaffold(
        body: RouteMetadataSheet(
          wallId: _testWallId,
          routeId: routeId,
          initial: initial,
        ),
      ),
    ),
  );
}

int _seedRoute(ProviderContainer container) {
  // FIX #6 (autoDispose pending-timer gotcha): keep this family member
  // alive for the whole test -- see route_legend_gap_test.dart's
  // `_seedRoutes` for the full explanation.
  container.listen(drawControllerProvider(_testWallId), (_, _) {});
  final notifier = container.read(drawControllerProvider(_testWallId).notifier);
  notifier.addPoint(const Offset(0.1, 0.1));
  notifier.addPoint(const Offset(0.2, 0.2));
  notifier.commitRoute();
  return container.read(drawControllerProvider(_testWallId)).routes.single.id;
}

void main() {
  group('RouteMetadataSheet keyboard dismiss (#20a)', () {
    testWidgets(
      'focusing the name field then tapping topo-meta-save dismisses the '
      'keyboard',
      (tester) async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final routeId = _seedRoute(container);

        await tester.pumpWidget(
          _buildSheet(container: container, routeId: routeId),
        );
        await tester.pump();

        await tester.tap(find.byKey(const Key('topo-meta-name')));
        await tester.enterText(
          find.byKey(const Key('topo-meta-name')),
          'Le Toit',
        );
        await tester.pump();

        // Sanity: the field is actually focused/attached to the platform
        // text input before we assert anything about it being dismissed.
        final nameFieldFocus = tester.state<EditableTextState>(
          find.descendant(
            of: find.byKey(const Key('topo-meta-name')),
            matching: find.byType(EditableText),
          ),
        ).widget.focusNode;
        expect(
          nameFieldFocus.hasFocus,
          isTrue,
          reason: 'sanity check: the name field must be focused before Save',
        );
        expect(tester.testTextInput.hasAnyClients, isTrue);

        // The sheet grew (beta-URL/style-tags/stars sections) and now
        // overflows the default 800x600 test surface; its body is a real
        // SingleChildScrollView (see RouteMetadataSheet.build), so Save must
        // be scrolled into view before tapping it, same as any other
        // off-screen-but-scrollable control.
        await tester.ensureVisible(find.byKey(const Key('topo-meta-save')));
        await tester.tap(find.byKey(const Key('topo-meta-save')));
        await tester.pump();

        expect(
          tester.testTextInput.hasAnyClients,
          isFalse,
          reason:
              'Save must unfocus before popping, closing the platform text '
              'input connection — otherwise the keyboard stays stranded',
        );
        expect(
          nameFieldFocus.hasFocus,
          isFalse,
          reason: "the name field's own FocusNode must no longer have focus",
        );
      },
    );

    testWidgets(
      'focusing the description field then tapping topo-meta-cancel '
      'dismisses the keyboard (without persisting the edit)',
      (tester) async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final routeId = _seedRoute(container);
        final before = container.read(drawControllerProvider(_testWallId)).routes.single;

        await tester.pumpWidget(
          _buildSheet(container: container, routeId: routeId),
        );
        await tester.pump();

        await tester.tap(find.byKey(const Key('topo-meta-description')));
        await tester.enterText(
          find.byKey(const Key('topo-meta-description')),
          'unsaved notes',
        );
        await tester.pump();

        final descriptionFieldFocus = tester.state<EditableTextState>(
          find.descendant(
            of: find.byKey(const Key('topo-meta-description')),
            matching: find.byType(EditableText),
          ),
        ).widget.focusNode;
        expect(descriptionFieldFocus.hasFocus, isTrue);
        expect(tester.testTextInput.hasAnyClients, isTrue);

        // See the Save test above: the sheet now overflows the test
        // surface and must be scrolled to reach Cancel.
        await tester.ensureVisible(find.byKey(const Key('topo-meta-cancel')));
        await tester.tap(find.byKey(const Key('topo-meta-cancel')));
        await tester.pump();

        expect(
          tester.testTextInput.hasAnyClients,
          isFalse,
          reason:
              'Cancel must unfocus before popping, exactly like Save (both '
              'route through RouteMetadataSheet._pop)',
        );
        expect(descriptionFieldFocus.hasFocus, isFalse);

        // Cancel must still not persist the edit — a plain regression guard
        // alongside the keyboard-dismiss assertion above (already covered
        // more thoroughly by A5d in route_metadata_intent_test.dart).
        final after = container.read(drawControllerProvider(_testWallId)).routes.single;
        expect(after.description, before.description);
      },
    );
  });
}
