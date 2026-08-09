// What the Topos-home row's 52px tile actually decodes (decode-memory pass,
// MEM-7).
//
// Two separate things are asserted, and they fail in opposite directions:
//
//  - the row must decode the small `thumbs/<id>.jpg` derivative, never the
//    full-resolution original. A list is N of these at once, and a 24.5 MP
//    original is ~98 MB of RGBA; mobile Safari answers a page over its memory
//    budget by silently discarding and reloading it.
//  - the decode hint must be WIDTH ONLY. `cacheWidth` and `cacheHeight` set to
//    the same number is not "decode it small", it is `ResizeImage` with the
//    default `exact` policy, which scales the bitmap to precisely 52x52
//    whatever the source's aspect ratio was — `BoxFit.fill`, performed in the
//    decoder. Every portrait photo therefore arrived squashed by ~1.33x and
//    the tile's own `BoxFit.cover` had nothing left to crop, because by then
//    the bitmap really was square. That is a visual bug hiding inside a
//    performance hint, which is why it survived: it looks like a rendering
//    choice, not a mistake.
//
// Asserting on the widget's parameters rather than on pixels is deliberate —
// a widget test cannot drive a real image codec (it hangs under fake-async),
// and these two values ARE the decision.

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:masi/app/theme.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/features/backup/application/sync_orchestrator.dart';
import 'package:masi/features/library/application/library_providers.dart';
import 'package:masi/features/library/data/library_crud_repository.dart';
import 'package:masi/features/library/presentation/topos_screen.dart';
import 'package:masi/features/topo/presentation/photo_image.dart';

import '../../../support/async_drain.dart';

class _FakeSyncOrchestrator extends SyncOrchestrator {
  @override
  SyncOrchestratorState build() => const SyncOrchestratorState();

  @override
  Future<void> pullNow({bool throttled = false}) async {}
}

Widget _wrap(ProviderContainer container) => UncontrolledProviderScope(
  container: container,
  child: MaterialApp.router(
    theme: MasiTheme.light,
    routerConfig: GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(path: '/', builder: (context, state) => const ToposScreen()),
        GoRoute(
          path: '/walls/:wallId',
          builder: (context, state) => const SizedBox(),
        ),
        GoRoute(path: '/areas', builder: (context, state) => const SizedBox()),
        GoRoute(
          path: '/community',
          builder: (context, state) => const SizedBox(),
        ),
      ],
    ),
  ),
);

/// One own topo with one PORTRAIT photo attached — portrait on purpose: a
/// square source could not show the squash this file exists to prevent.
Future<PhotoImage> _pumpRowThumbnail(WidgetTester tester) async {
  final db = AppDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  final repo = LibraryCrudRepository(db, nowMs: () => 1000);
  final container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(db),
      nowMsProvider.overrideWithValue(() => 1000),
      libraryCrudRepositoryProvider.overrideWithValue(repo),
      syncOrchestratorProvider.overrideWith(_FakeSyncOrchestrator.new),
    ],
  );
  addTearDown(container.dispose);

  await tester.runAsync(() async {
    final wallId = await repo.createTopo('Dolomitici');
    await db
        .into(db.photos)
        .insert(
          PhotosCompanion.insert(
            id: 'photo-1',
            createdAt: 1000,
            updatedAt: 1000,
            wallId: wallId,
            localPath: 'photos/photo-1.jpg',
            kind: 'original',
            width: 3024,
            height: 4032,
          ),
        );
  });

  await tester.pumpWidget(_wrap(container));
  await drainAsync(tester, rounds: 6, settle: false);
  // NOT `pumpAndSettle()`: the tile's `loadingPlaceholder` is a `MasiShimmer`,
  // whose repeating controller never completes, so settling would spin until
  // it times out (same trap `community_screen_test.dart` documents).
  await tester.pump(const Duration(milliseconds: 100));

  return tester.widget<PhotoImage>(find.byType(PhotoImage));
}

void main() {
  testWidgets(
    'the row decodes the `thumbs/<id>.jpg` derivative, not the '
    'full-resolution original',
    (tester) async {
      final image = await _pumpRowThumbnail(tester);

      expect(image.storedPath, 'thumbs/photo-1.jpg');
    },
  );

  testWidgets(
    'the decode hint is width-only — passing cacheHeight too would resize to '
    'an exact square and squash every portrait photo by ~1.33x',
    (tester) async {
      final image = await _pumpRowThumbnail(tester);

      expect(image.cacheHeight, isNull);
      expect(
        image.cacheWidth,
        (52 * tester.view.devicePixelRatio).round(),
      );
      // The hint has to be BELOW the source, or it buys nothing at all.
      expect(image.cacheWidth, lessThan(3024));
    },
  );
}
