// Widget tests for RouteMetadataSheet's #41 (beta-video URL), #42 (style
// tags), and #44 (0-3 star rating) fields — mirrors the harness pattern in
// route_metadata_intent_test.dart (ProviderContainer + drawControllerProvider,
// no image decode, no real canvas).

import 'package:climbtopo/app/theme.dart';
import 'package:climbtopo/core/routes/route_styles.dart';
import 'package:climbtopo/features/topo/application/draw_controller.dart';
import 'package:climbtopo/features/topo/domain/topo_route.dart';
import 'package:climbtopo/features/topo/presentation/route_metadata_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

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
        body: RouteMetadataSheet(routeId: routeId, initial: initial),
      ),
    ),
  );
}

int _seedRoute(ProviderContainer container) {
  final notifier = container.read(drawControllerProvider.notifier);
  notifier.addPoint(const Offset(0.1, 0.1));
  notifier.addPoint(const Offset(0.2, 0.2));
  notifier.commitRoute();
  return container.read(drawControllerProvider).routes.single.id;
}

TopoRoute _routeById(ProviderContainer container, int routeId) {
  return container
      .read(drawControllerProvider)
      .routes
      .firstWhere((r) => r.id == routeId);
}

/// Scrolls [key] into view before tapping it. The sheet grew (beta-URL/
/// style-tags/stars sections) and now overflows the default 800x600 test
/// surface; its body is a real `SingleChildScrollView` (see
/// `RouteMetadataSheet.build`), so every one of these keyed controls --
/// not just Save/Cancel -- may be off-screen depending on how far a prior
/// tap/scroll in the same test already moved the viewport.
Future<void> _tapKey(WidgetTester tester, String key) async {
  final finder = find.byKey(Key(key));
  await tester.ensureVisible(finder);
  await tester.tap(finder);
}

void main() {
  group('RouteMetadataSheet beta-video URL (#41)', () {
    testWidgets('pre-fills the field from initial.betaVideoUrl', (
      tester,
    ) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final routeId = _seedRoute(container);
      final initial = _routeById(
        container,
        routeId,
      ).copyWith(betaVideoUrl: 'https://example.com/beta', betaVideoUrlSet: true);

      await tester.pumpWidget(
        _buildSheet(container: container, routeId: routeId, initial: initial),
      );

      final field = tester.widget<TextField>(
        find.byKey(const Key('topo-meta-beta-url')),
      );
      expect(field.controller!.text, 'https://example.com/beta');
    });

    testWidgets(
      'entering a valid https URL and saving sets betaVideoUrl on the route',
      (tester) async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final routeId = _seedRoute(container);

        await tester.pumpWidget(
          _buildSheet(container: container, routeId: routeId),
        );

        await tester.enterText(
          find.byKey(const Key('topo-meta-beta-url')),
          'https://youtu.be/abc123',
        );
        await _tapKey(tester, 'topo-meta-save');
        await tester.pumpAndSettle();

        expect(
          _routeById(container, routeId).betaVideoUrl,
          'https://youtu.be/abc123',
        );
      },
    );

    testWidgets(
      'an empty URL field saves as null (clears any prior beta video)',
      (tester) async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final routeId = _seedRoute(container);
        final initial = _routeById(container, routeId).copyWith(
          betaVideoUrl: 'https://example.com/old',
          betaVideoUrlSet: true,
        );

        await tester.pumpWidget(
          _buildSheet(
            container: container,
            routeId: routeId,
            initial: initial,
          ),
        );

        await tester.enterText(
          find.byKey(const Key('topo-meta-beta-url')),
          '',
        );
        await _tapKey(tester, 'topo-meta-save');
        await tester.pumpAndSettle();

        expect(_routeById(container, routeId).betaVideoUrl, isNull);
      },
    );

    testWidgets(
      'a non-http(s) value (e.g. plain text) saves as null rather than '
      'persisting garbage',
      (tester) async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final routeId = _seedRoute(container);

        await tester.pumpWidget(
          _buildSheet(container: container, routeId: routeId),
        );

        await tester.enterText(
          find.byKey(const Key('topo-meta-beta-url')),
          'not a url',
        );
        await _tapKey(tester, 'topo-meta-save');
        await tester.pumpAndSettle();

        expect(_routeById(container, routeId).betaVideoUrl, isNull);
      },
    );
  });

  group('RouteMetadataSheet style tags (#42)', () {
    testWidgets('toggling two curated chips and saving sets both tags', (
      tester,
    ) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final routeId = _seedRoute(container);

      await tester.pumpWidget(
        _buildSheet(container: container, routeId: routeId),
      );

      await _tapKey(tester, 'topo-meta-styletag-dyno');
      await tester.pump();
      await _tapKey(tester, 'topo-meta-styletag-crimpy');
      await tester.pump();
      await _tapKey(tester, 'topo-meta-save');
      await tester.pumpAndSettle();

      expect(
        _routeById(container, routeId).styleTags.toSet(),
        {'dyno', 'crimpy'},
      );
    });

    testWidgets('tapping a selected chip again deselects it', (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final routeId = _seedRoute(container);

      await tester.pumpWidget(
        _buildSheet(container: container, routeId: routeId),
      );

      await _tapKey(tester, 'topo-meta-styletag-dyno');
      await tester.pump();
      await _tapKey(tester, 'topo-meta-styletag-dyno');
      await tester.pump();
      await _tapKey(tester, 'topo-meta-save');
      await tester.pumpAndSettle();

      expect(_routeById(container, routeId).styleTags, isEmpty);
    });

    testWidgets(
      'adding a custom tag via the add field/button appends it to the '
      'selected set and saves it lowercased/trimmed',
      (tester) async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final routeId = _seedRoute(container);

        await tester.pumpWidget(
          _buildSheet(container: container, routeId: routeId),
        );

        await tester.enterText(
          find.byKey(const Key('topo-meta-styletag-add-field')),
          '  Sit-Start  ',
        );
        await _tapKey(tester, 'topo-meta-styletag-add-button');
        await tester.pump();

        // The newly-added custom tag renders its own toggle chip.
        expect(
          find.byKey(const Key('topo-meta-styletag-sit-start')),
          findsOneWidget,
        );

        await _tapKey(tester, 'topo-meta-save');
        await tester.pumpAndSettle();

        expect(_routeById(container, routeId).styleTags, ['sit-start']);
      },
    );

    testWidgets('pre-fills selected chips from initial.styleTags', (
      tester,
    ) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final routeId = _seedRoute(container);
      final initial = _routeById(container, routeId).copyWith(
        styleTags: const ['dyno'],
        styleTagsSet: true,
      );

      await tester.pumpWidget(
        _buildSheet(container: container, routeId: routeId, initial: initial),
      );

      // Deselect it — proves the chip started selected.
      await _tapKey(tester, 'topo-meta-styletag-dyno');
      await tester.pump();
      await _tapKey(tester, 'topo-meta-save');
      await tester.pumpAndSettle();

      expect(_routeById(container, routeId).styleTags, isEmpty);
    });
  });

  group('RouteMetadataSheet star rating (#44)', () {
    testWidgets('tapping star 3 sets stars to 3 and saves it', (
      tester,
    ) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final routeId = _seedRoute(container);

      await tester.pumpWidget(
        _buildSheet(container: container, routeId: routeId),
      );

      await _tapKey(tester, 'topo-meta-stars-3');
      await tester.pump();
      await _tapKey(tester, 'topo-meta-save');
      await tester.pumpAndSettle();

      expect(_routeById(container, routeId).stars, 3);
    });

    testWidgets(
      'tapping the currently-set star again clears the rating to null',
      (tester) async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final routeId = _seedRoute(container);
        final initial = _routeById(
          container,
          routeId,
        ).copyWith(stars: 2, starsSet: true);

        await tester.pumpWidget(
          _buildSheet(
            container: container,
            routeId: routeId,
            initial: initial,
          ),
        );

        await _tapKey(tester, 'topo-meta-stars-2');
        await tester.pump();
        await _tapKey(tester, 'topo-meta-save');
        await tester.pumpAndSettle();

        expect(_routeById(container, routeId).stars, isNull);
      },
    );
  });

  group('RouteMetadataSheet: full save sets beta URL + tags + stars '
      'together', () {
    testWidgets(
      'setting a URL, two curated tags, a custom tag, and 3 stars all '
      'persist together on a single save',
      (tester) async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final routeId = _seedRoute(container);

        await tester.pumpWidget(
          _buildSheet(container: container, routeId: routeId),
        );

        await tester.enterText(
          find.byKey(const Key('topo-meta-beta-url')),
          'https://example.com/beta',
        );
        await _tapKey(tester, 'topo-meta-styletag-dyno');
        await tester.pump();
        await _tapKey(tester, 'topo-meta-styletag-crimpy');
        await tester.pump();
        await tester.enterText(
          find.byKey(const Key('topo-meta-styletag-add-field')),
          'my-tag',
        );
        await _tapKey(tester, 'topo-meta-styletag-add-button');
        await tester.pump();
        await _tapKey(tester, 'topo-meta-stars-3');
        await tester.pump();
        await _tapKey(tester, 'topo-meta-save');
        await tester.pumpAndSettle();

        final saved = _routeById(container, routeId);
        expect(saved.betaVideoUrl, 'https://example.com/beta');
        expect(saved.styleTags.toSet(), {'dyno', 'crimpy', 'my-tag'});
        expect(saved.stars, 3);

        // The curated tag lookup round-trips correctly for display too.
        expect(curatedStyleForKey('dyno')?.label, 'Dyno');
        expect(curatedStyleForKey('my-tag'), isNull);
      },
    );
  });
}
