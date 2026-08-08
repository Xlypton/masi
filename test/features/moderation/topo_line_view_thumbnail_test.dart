// Which resolution [TopoLineView] actually decodes (decode-memory pass,
// MEM-1).
//
// The suggestions inbox puts EVERY unanswered suggestion on screen at once,
// each one a photo in a 180px-tall row. Decoding the full-resolution original
// behind a box that size costs ~98 MB of RGBA per 24.5 MP photo, and mobile
// Safari — the primary target — responds to a page over its memory budget by
// silently discarding and reloading it. So this is a crash class, not a
// slowness complaint, and the only thing standing between the two behaviours
// is which storage key the widget hands to `PhotoImage`.
//
// The second test is the more important one. The naive fix here is to swap the
// original for the thumbnail unconditionally, and that would quietly break the
// OTHER user of this widget: `propose_line_screen` renders it inside a 6x-zoom
// `InteractiveViewer` so a stranger can place a line on an individual hold. A
// 512px-max-edge thumbnail at 6x is exactly the mush that makes that
// impossible — and it would fail as bad drawings, not as an error anyone could
// trace back to here.

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:masi/app/theme.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/features/account/application/auth_providers.dart';
import 'package:masi/features/moderation/application/suggestion_providers.dart';
import 'package:masi/features/moderation/data/suggestions_remote.dart';
import 'package:masi/features/moderation/domain/edit_suggestion.dart';
import 'package:masi/features/moderation/presentation/suggestions_inbox_screen.dart';
import 'package:masi/features/moderation/presentation/topo_line_view.dart';
import 'package:masi/features/topo/data/photo_files.dart';
import 'package:masi/features/topo/data/photo_repository.dart';
import 'package:masi/features/topo/presentation/photo_image.dart';
import 'package:masi/shared/presentation/masi_pending_button.dart';

const _photo = PhotoRef(
  id: 'photo-1',
  wallId: 'wall-1',
  kind: 'original',
  // The stored key shape every non-legacy row has — `thumbKeyFor` rewrites
  // only the basename, so this is what the derivation is exercised against.
  localPath: 'photos/photo-1.jpg',
  width: 400,
  height: 800,
);

/// A row-sized box, i.e. the inbox's own `SizedBox(height: 180)`.
Widget _wrap(Widget child) => ProviderScope(
  child: MaterialApp(
    theme: MasiTheme.light,
    home: Scaffold(
      body: Center(child: SizedBox(width: 300, height: 180, child: child)),
    ),
  ),
);

/// The storage key the widget actually asked [PhotoImage] to render. Asserting
/// on the key rather than on pixels is deliberate: a widget test cannot drive a
/// real image decode (it hangs under fake-async), and the key IS the decision —
/// everything downstream of it is `PhotoImage`'s already-tested behaviour.
String _renderedKey(WidgetTester tester) =>
    tester.widget<PhotoImage>(find.byType(PhotoImage)).storedPath;

// ---------------------------------------------------------------------------
// The tests below exercise the REAL suggestions-inbox call site — not
// `TopoLineView` in isolation like the three above — because the dead-code bug
// this file is named for was never a bug in the widget. `useThumbnail`'s
// default (`false`) was always correct; the widget just had no caller passing
// `true`. Only `SuggestionsInboxScreen`'s own row can prove that got wired up,
// and only it can prove the fallback (MEM-1 activation, step 2) actually
// engages when a photo has no thumbnail behind it.

const _inboxWallId = 'wall-1';
const _inboxPhotoId = 'photo-1';

Map<String, dynamic> _suggestionRow() => {
  'id': 'g1',
  'wallId': _inboxWallId,
  'wallName': 'Dolomitici',
  'routeId': null,
  'routeName': null,
  'photoId': _inboxPhotoId,
  'authorId': 'u1',
  'authorName': 'Kata',
  'kind': 'route.geometry',
  'patch': {
    'points': [
      {'x': 0.4, 'y': 0.1},
      {'x': 0.45, 'y': 0.9},
    ],
  },
  'note': null,
  'isStale': false,
  'createdAt': 1000,
};

class _StubSuggestionsRemote implements SuggestionsRemote {
  _StubSuggestionsRemote(this.rows);
  final List<Map<String, dynamic>> rows;

  @override
  Future<List<Map<String, dynamic>>> fetchForMe({int limit = 50}) async =>
      rows;

  @override
  Future<String> suggest({
    required String wallId,
    required SuggestionKind kind,
    required Map<String, Object?> patch,
    String? note,
    String? routeId,
    String? photoId,
  }) async => 'new';

  @override
  Future<String> resolve({
    required String suggestionId,
    required bool accept,
    String? note,
  }) async => 'accepted';
}

/// A [PhotoFiles] whose answer to [hasPhotoBytes] is fixed by the test,
/// rather than depending on a real filesystem — so "the thumbnail exists" vs
/// "it doesn't" can be exercised deterministically. Every other member is
/// inherited unchanged (an unwarmed docs path), exactly like the pre-existing
/// `suggestions_inbox_diff_test.dart` coverage, which never overrides
/// `photoFilesProvider` at all and still renders the row fine off a photo
/// path that resolves to nothing on disk.
class _FakePhotoFiles extends PhotoFiles {
  _FakePhotoFiles({required this.thumbHasBytes});
  final bool thumbHasBytes;

  @override
  Future<bool> hasPhotoBytes(String stored) async => thumbHasBytes;
}

Future<void> _seedInbox(AppDatabase db) async {
  await db.into(db.areas).insert(
    AreasCompanion.insert(
      id: 'area-1',
      createdAt: 100,
      updatedAt: 100,
      name: 'Area',
    ),
  );
  await db.into(db.sectors).insert(
    SectorsCompanion.insert(
      id: 'sector-1',
      createdAt: 100,
      updatedAt: 100,
      areaId: 'area-1',
      name: 'Sector',
      sortOrder: 0,
    ),
  );
  await db.into(db.walls).insert(
    WallsCompanion.insert(
      id: _inboxWallId,
      createdAt: 100,
      updatedAt: 100,
      sectorId: 'sector-1',
      name: 'Dolomitici',
      sortOrder: 0,
    ),
  );
  await db.into(db.photos).insert(
    PhotosCompanion.insert(
      id: _inboxPhotoId,
      createdAt: 100,
      updatedAt: 100,
      wallId: _inboxWallId,
      localPath: 'photos/$_inboxPhotoId.jpg',
      kind: 'original',
      width: 400,
      height: 800,
    ),
  );
}

Widget _wrapInbox(ProviderContainer container) => UncontrolledProviderScope(
  container: container,
  child: MaterialApp.router(
    theme: MasiTheme.light,
    routerConfig: GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(path: '/', builder: (_, _) => const SuggestionsInboxScreen()),
        GoRoute(path: '/walls/:wallId', builder: (_, _) => const SizedBox()),
      ],
    ),
  ),
);

ProviderContainer _inboxContainer(
  AppDatabase db, {
  required bool thumbHasBytes,
}) => ProviderContainer(
  overrides: [
    appDatabaseProvider.overrideWithValue(db),
    nowMsProvider.overrideWithValue(() => 5000),
    suggestionsRemoteProvider.overrideWithValue(
      _StubSuggestionsRemote([_suggestionRow()]),
    ),
    effectiveUidProvider.overrideWithValue('owner-uid'),
    photoFilesProvider.overrideWithValue(
      _FakePhotoFiles(thumbHasBytes: thumbHasBytes),
    ),
  ],
);

void main() {
  testWidgets(
    'useThumbnail renders the small `thumbs/<id>.jpg` derivative — the inbox '
    'must never decode N full-resolution originals behind 180px rows',
    (tester) async {
      await tester.pumpWidget(
        _wrap(
          const TopoLineView(
            photo: _photo,
            routes: [],
            useThumbnail: true,
          ),
        ),
      );
      await tester.pump();

      expect(_renderedKey(tester), 'thumbs/photo-1.jpg');
    },
  );

  testWidgets(
    'the default is still the full-resolution original — propose-line places '
    'a line on a hold at 6x zoom, where a 512px thumbnail is unusable',
    (tester) async {
      await tester.pumpWidget(
        _wrap(const TopoLineView(photo: _photo, routes: [])),
      );
      await tester.pump();

      expect(_renderedKey(tester), 'photos/photo-1.jpg');
    },
  );

  testWidgets(
    'the proposed line still renders over the thumbnail: points are percent '
    'fractions of the DISPLAY box, so swapping the source resolution must not '
    'move anything',
    (tester) async {
      await tester.pumpWidget(
        _wrap(
          const TopoLineView(
            photo: _photo,
            routes: [],
            proposedPoints: [Offset(0.4, 0.1), Offset(0.45, 0.9)],
            useThumbnail: true,
          ),
        ),
      );
      await tester.pump();

      // 400x800 contain-fitted into 300x180 is height-bound: 90x180.
      final box = tester.getSize(find.byType(PhotoImage));
      expect(box, const Size(90, 180));
      expect(
        tester.getSize(find.byType(CustomPaint).last),
        const Size(90, 180),
      );
    },
  );

  testWidgets(
    'the real inbox row activates useThumbnail — the dead-code bug this file '
    'is named for, proven only by the real call site, not the widget alone',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await tester.runAsync(() => _seedInbox(db));

      final container = _inboxContainer(db, thumbHasBytes: true);
      addTearDown(container.dispose);

      await tester.pumpWidget(_wrapInbox(container));
      await tester.pumpAndSettle();

      final diff = tester.widget<TopoLineView>(
        find.byKey(const Key('suggestion-diff-g1')),
      );
      expect(
        diff.useThumbnail,
        isTrue,
        reason:
            'a live call site must pass useThumbnail: true, or the MEM-1 fix '
            'never actually engages',
      );
    },
  );

  testWidgets(
    'a photo published before the thumbnail tier existed has nothing behind '
    'thumbs/<id>.jpg — the row falls back to the full-resolution original '
    'instead of rendering nothing, and Apply stays enabled: a moderator '
    'seeing the real picture beats one blocked by a missing derivative',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await tester.runAsync(() => _seedInbox(db));

      final container = _inboxContainer(db, thumbHasBytes: false);
      addTearDown(container.dispose);

      await tester.pumpWidget(_wrapInbox(container));
      await tester.pumpAndSettle();

      final diff = tester.widget<TopoLineView>(
        find.byKey(const Key('suggestion-diff-g1')),
      );
      expect(diff.useThumbnail, isFalse);

      final apply = tester.widget<MasiPendingButton>(
        find.byKey(const Key('suggestion-accept-g1')),
      );
      expect(
        apply.onPressed,
        isNotNull,
        reason:
            'a missing THUMBNAIL is not a missing photo — geometry resolved '
            'and the original is what the fallback now renders, so Apply '
            'must not be disabled over it',
      );
    },
  );
}
