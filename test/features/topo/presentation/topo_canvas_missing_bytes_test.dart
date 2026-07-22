// F-A2 regression test (image-load-latch removal): TopoCanvasScreen used to
// resolve `_imageSize` via a real `PhotoImageProvider(...).resolve()` decode
// probe, whose `onError` PERMANENTLY latched `_imageLoadError = true` — the
// only way to recover was to leave the screen and re-enter (which re-ran the
// probe from scratch). That meant a photo whose bytes were momentarily
// unavailable (a friend opening the wall mid-download, a cold web-cache
// miss) blanked the whole canvas until the user backed out and came back.
//
// `_imageSize` is now derived directly from the displayed photo's persisted
// `PhotoRef.width`/`PhotoRef.height` (`wallOriginalsProvider`) — never from a
// codec decode — so a photo with genuinely-missing bytes still has a known,
// valid size and paints `TopoCanvasBody` immediately; any missing-bytes
// handling is `TopoCanvasBody`'s own non-latching `PhotoImage` placeholder,
// not a screen-level error state. This test deliberately does NOT use
// `debugInitialImageSize` — it exercises the real (non-test-seam)
// `wallOriginalsProvider`-derived path.
import 'package:masi/app/theme.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/features/library/application/library_providers.dart';
import 'package:masi/features/topo/presentation/topo_canvas_screen.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

void main() {
  testWidgets(
    'F-A2: a wall whose attached photo has no bytes on disk paints '
    'TopoCanvasBody from the stored PhotoRef size on the FIRST settle — no '
    'permanent error state, and no leave+re-enter needed to recover',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          nowMsProvider.overrideWithValue(() => 1000),
        ],
      );
      addTearDown(container.dispose);

      final crud = container.read(libraryCrudRepositoryProvider);
      final area = await crud.createArea('Area');
      final sector = await crud.createSector(area.id, 'Sector');
      final wall = await crud.createWall(sector.id, 'Wall');

      // Attaches a photo whose source file genuinely does not exist on
      // disk (mirrors canvas_chrome_gating_test.dart's own pattern):
      // `attachPhotoToWall` never touches the missing bytes — it just
      // records the wall's chosen width/height on the Photos row — so this
      // models a photo that's unreadable at render time (mid-download,
      // cold cache miss, etc.) while still having a valid persisted size.
      await tester.runAsync(() async {
        await crud.attachPhotoToWall(
          wall.id,
          XFile('/tmp/f-a2-missing-bytes.jpg'),
          400,
          300,
        );
      });

      // Deliberately NOT passing debugInitialImageSize: this must resolve
      // through the real wallOriginalsProvider-derived path.
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: MasiTheme.light,
            home: TopoCanvasScreen(wallId: wall.id),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('topo-image-error-state')),
        findsNothing,
        reason:
            'F-A2: there is no more permanent image-load-error state to '
            'show — missing bytes must never latch one',
      );
      expect(
        find.byKey(const Key('topo-image-loading')),
        findsNothing,
        reason:
            'F-A2: the stored PhotoRef size resolves synchronously once '
            'wallOriginalsProvider emits — it must not still be spinning '
            'after pumpAndSettle',
      );
      expect(
        find.byType(TopoCanvasBody),
        findsOneWidget,
        reason:
            'F-A2: the canvas must paint TopoCanvasBody using the stored '
            'size even though the photo bytes are unreadable',
      );

      final body = tester.widget<TopoCanvasBody>(find.byType(TopoCanvasBody));
      expect(
        body.imageSize,
        const Size(400, 300),
        reason:
            "F-A2: imageSize must come from the PhotoRef's stored "
            'width/height, not a codec decode of the (missing) bytes',
      );

      // Recovery-without-remount: pumping again (as further frames/rebuilds
      // would naturally occur) must keep showing the SAME resolved state —
      // never regress back to a loading/error state that would require the
      // user to leave and re-enter the screen.
      await tester.pump();
      expect(find.byType(TopoCanvasBody), findsOneWidget);
      expect(find.byKey(const Key('topo-image-error-state')), findsNothing);
    },
  );
}
