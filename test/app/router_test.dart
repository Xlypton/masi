import 'package:climbtopo/app/router.dart';
import 'package:climbtopo/app/theme.dart';
import 'package:climbtopo/core/db/app_database.dart';
import 'package:climbtopo/core/db/database_provider.dart';
import 'package:climbtopo/features/community/presentation/community_screen.dart';
import 'package:climbtopo/features/community/presentation/community_topo_detail_screen.dart';
import 'package:climbtopo/features/library/presentation/areas_screen.dart';
import 'package:climbtopo/features/library/presentation/topos_screen.dart';
import 'package:climbtopo/features/logbook/presentation/logbook_screen.dart';
import 'package:climbtopo/features/topo/presentation/topo_canvas_screen.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Builds a [ProviderContainer] wired to a fresh in-memory database, mirroring
/// the pattern in `areas_screen_test.dart`: `db.close` is registered BEFORE
/// `container.dispose` (addTearDown runs LIFO), so the container disposes
/// Riverpod's live watch subscriptions before the underlying Drift connection
/// closes.
ProviderContainer _makeContainer() {
  final db = AppDatabase(NativeDatabase.memory());
  final container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(db),
      nowMsProvider.overrideWithValue(() => 1000),
    ],
  );
  addTearDown(db.close);
  addTearDown(container.dispose);
  return container;
}

Widget _wrapRouter(ProviderContainer container) {
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp.router(routerConfig: appRouter, theme: MasiTheme.light),
  );
}

/// Advances real asynchronous Drift work interleaved with fake-clock pumps to
/// get past the initial `CircularProgressIndicator` (which a bare
/// `pumpAndSettle` would spin on forever), then settles bounded animations —
/// see the identical helper's doc comment in `areas_screen_test.dart`.
Future<void> _drain(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 30));
  }
  await tester.pumpAndSettle();
}

void main() {
  group('router: / renders the new Topos home', () {
    // `appRouter` is a module-level singleton (see `lib/app/router.dart`),
    // so its current location persists across tests within this file —
    // `MaterialApp.router` does not reset it on a fresh pump. Force it back
    // to `/` before every test so each one starts from a known location
    // regardless of where a previous test's navigation left it.
    setUp(() => appRouter.go('/'));

    testWidgets('/ renders ToposScreen', (tester) async {
      final container = _makeContainer();

      await tester.pumpWidget(_wrapRouter(container));
      await _drain(tester);

      expect(find.byType(ToposScreen), findsOneWidget);
      expect(find.byType(AreasScreen), findsNothing);
    });

    testWidgets('/areas renders AreasScreen', (tester) async {
      final container = _makeContainer();

      await tester.pumpWidget(_wrapRouter(container));
      await _drain(tester);

      appRouter.go('/areas');
      await _drain(tester);

      expect(find.byType(AreasScreen), findsOneWidget);
    });

    testWidgets('tapping topos-organize from ToposScreen navigates to '
        'AreasScreen', (tester) async {
      final container = _makeContainer();

      await tester.pumpWidget(_wrapRouter(container));
      await _drain(tester);

      expect(find.byType(ToposScreen), findsOneWidget);

      await tester.tap(find.byKey(const Key('topos-organize')));
      await _drain(tester);

      expect(find.byType(AreasScreen), findsOneWidget);
    });

    testWidgets('/walls/:wallId still renders TopoCanvasScreen', (
      tester,
    ) async {
      final container = _makeContainer();

      await tester.pumpWidget(_wrapRouter(container));
      await _drain(tester);

      // A nonexistent wall id is enough here: the assertion is about the
      // ROUTE resolving to the canvas screen TYPE, not about a loaded photo
      // — TopoCanvasScreen is expected to render an empty/error state for a
      // wall it can't find.
      appRouter.go('/walls/nonexistent-wall-id');
      await _drain(tester);

      expect(find.byType(TopoCanvasScreen), findsOneWidget);
    });
  });

  group(
    'D1a: new community/logbook routes register and build their screens',
    () {
      setUp(() => appRouter.go('/'));

      testWidgets('/community renders CommunityScreen', (tester) async {
        final container = _makeContainer();

        await tester.pumpWidget(_wrapRouter(container));
        await _drain(tester);

        appRouter.go('/community');
        await _drain(tester);

        expect(find.byType(CommunityScreen), findsOneWidget);
      });

      testWidgets(
        '/community/topo/:wallId renders CommunityTopoDetailScreen bound to '
        'that wallId',
        (tester) async {
          final container = _makeContainer();

          await tester.pumpWidget(_wrapRouter(container));
          await _drain(tester);

          // A nonexistent wall id is enough here (mirrors the existing
          // `/walls/:wallId` route test above): the assertion is about the
          // ROUTE resolving to the right screen TYPE bound to the right
          // path param, not about a fully loaded shared topo.
          appRouter.go('/community/topo/nonexistent-wall-id');
          await _drain(tester);

          expect(find.byType(CommunityTopoDetailScreen), findsOneWidget);
          final screen = tester.widget<CommunityTopoDetailScreen>(
            find.byType(CommunityTopoDetailScreen),
          );
          expect(screen.wallId, 'nonexistent-wall-id');
        },
      );

      testWidgets('/logbook renders LogbookScreen', (tester) async {
        final container = _makeContainer();

        await tester.pumpWidget(_wrapRouter(container));
        await _drain(tester);

        appRouter.go('/logbook');
        await _drain(tester);

        expect(find.byType(LogbookScreen), findsOneWidget);
      });

      testWidgets(
        'existing routes (/, /areas, /walls/:wallId) still resolve after the '
        'new routes were added',
        (tester) async {
          final container = _makeContainer();

          await tester.pumpWidget(_wrapRouter(container));
          await _drain(tester);
          expect(find.byType(ToposScreen), findsOneWidget);

          appRouter.go('/areas');
          await _drain(tester);
          expect(find.byType(AreasScreen), findsOneWidget);

          appRouter.go('/walls/nonexistent-wall-id');
          await _drain(tester);
          expect(find.byType(TopoCanvasScreen), findsOneWidget);
        },
      );
    },
  );

  group('D1b: Home nav entry points to Community/Logbook', () {
    setUp(() => appRouter.go('/'));

    testWidgets('tapping home-community-button navigates from ToposScreen to '
        'CommunityScreen', (tester) async {
      final container = _makeContainer();

      await tester.pumpWidget(_wrapRouter(container));
      await _drain(tester);
      expect(find.byType(ToposScreen), findsOneWidget);

      await tester.tap(find.byKey(const Key('home-community-button')));
      await _drain(tester);

      expect(find.byType(CommunityScreen), findsOneWidget);
    });

    testWidgets('tapping home-logbook-button navigates from ToposScreen to '
        'LogbookScreen', (tester) async {
      final container = _makeContainer();

      await tester.pumpWidget(_wrapRouter(container));
      await _drain(tester);
      expect(find.byType(ToposScreen), findsOneWidget);

      await tester.tap(find.byKey(const Key('home-logbook-button')));
      await _drain(tester);

      expect(find.byType(LogbookScreen), findsOneWidget);
    });
  });
}
