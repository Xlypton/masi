import 'package:climbtopo/app/theme.dart';
import 'package:climbtopo/core/db/app_database.dart';
import 'package:climbtopo/core/db/database_provider.dart';
import 'package:climbtopo/features/account/application/auth_providers.dart';
import 'package:climbtopo/features/account/data/auth_repository.dart';
import 'package:climbtopo/features/community/application/comments_providers.dart';
import 'package:climbtopo/features/community/presentation/community_topo_detail_screen.dart';
import 'package:climbtopo/features/library/application/library_providers.dart';
import 'package:climbtopo/features/logbook/application/ascents_providers.dart';
import 'package:climbtopo/features/logbook/data/ascents_repository.dart';
import 'package:climbtopo/features/topo/data/route_repository.dart';
import 'package:climbtopo/features/topo/domain/topo_route.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Minimal in-memory [AuthRepository] test double: a FIXED signed-in
/// session (no live emit tracking needed by this suite) — trimmed from
/// account_screen_test.dart's own `FakeAuthRepository`, which this suite
/// doesn't import directly since that class is private to its file.
class _FakeAuthRepository implements AuthRepository {
  _FakeAuthRepository(this._session);

  final AuthSessionState _session;

  @override
  AuthSessionState get currentSession => _session;

  @override
  Stream<AuthSessionState> authStateChanges() => Stream.value(_session);

  @override
  Future<void> sendMagicLink(String email) async {}

  @override
  Future<void> signOut() async {}
}

void main() {
  /// Seeds a real in-memory DB with Area -> Sector -> Wall -> Photo
  /// (`'original'`) -> one graded Route, mirroring the harness pattern in
  /// `test/features/topo/presentation/canvas_mode_intent_test.dart`'s
  /// `seedWall()`. Also signs in a fixed [_FakeAuthRepository] so
  /// `currentAuthorNameProvider` (comment authorship) resolves
  /// deterministically to `'climber'` instead of falling back to
  /// `'Anonymous'`.
  Future<
    ({
      AppDatabase db,
      ProviderContainer container,
      String wallId,
      String routeDbId,
    })
  >
  seedWallWithRoute(WidgetTester tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        nowMsProvider.overrideWithValue(() => 1000),
        authRepositoryProvider.overrideWithValue(
          _FakeAuthRepository(
            const AuthSessionState.signedIn('climber@example.com'),
          ),
        ),
      ],
    );

    final crud = container.read(libraryCrudRepositoryProvider);
    final area = await crud.createArea('Area');
    final sector = await crud.createSector(area.id, 'Sector');
    final wall = await crud.createWall(sector.id, 'Wall');

    // attachPhotoToWall copies a real file (PhotoFiles.importPhoto) — real
    // I/O hangs under flutter_test's fake-async unless run inside
    // `tester.runAsync`, mirroring canvas_mode_intent_test.dart's identical
    // guard.
    late String photoId;
    await tester.runAsync(() async {
      photoId = await crud.attachPhotoToWall(
        wall.id,
        '/tmp/community-detail-test-photo.jpg',
        1000,
        2000,
      );
    });

    final routeRepo = RouteRepository(db, nowMs: () => 1000);
    await routeRepo.upsertRoute(
      wall.id,
      photoId,
      const TopoRoute(
        id: 1,
        number: 1,
        points: [Offset(0.1, 0.1), Offset(0.2, 0.2)],
        gradeRaw: '6a',
      ),
    );
    final dbIds = await routeRepo.routeDbIdsByNumber(wall.id);

    return (
      db: db,
      container: container,
      wallId: wall.id,
      routeDbId: dbIds[1]!,
    );
  }

  Widget wrap(ProviderContainer container, Widget child) {
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp(theme: MasiTheme.light, home: child),
    );
  }

  testWidgets(
    'D4a: read-only detail hides every editing affordance but keeps the '
    'route legend',
    (tester) async {
      final seeded = await seedWallWithRoute(tester);
      addTearDown(seeded.db.close);
      addTearDown(seeded.container.dispose);

      await tester.pumpWidget(
        wrap(
          seeded.container,
          CommunityTopoDetailScreen(
            wallId: seeded.wallId,
            debugInitialImageSize: const Size(1000, 2000),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Mode toggle / slice-mode entry point: gone entirely.
      expect(find.byKey(const Key('topo-mode-toggle')), findsNothing);
      expect(find.byKey(const Key('topo-slice-mode-button')), findsNothing);

      // The draw toolbar cluster: gone entirely (unreachable since draw
      // mode itself is unreachable).
      expect(find.byKey(const Key('topo-undo-button')), findsNothing);
      expect(find.byKey(const Key('topo-redo-button')), findsNothing);
      expect(find.byKey(const Key('topo-clear-button')), findsNothing);
      expect(find.byKey(const Key('topo-commit-button')), findsNothing);

      // Metadata-edit glyph: gone (no route is even selected here, but this
      // asserts the CONTROL is gone, not merely "nothing is selected").
      expect(find.byKey(const Key('topo-edit-metadata-button')), findsNothing);

      // Symbol palette / PhotoSelector / capture FAB: also editing
      // affordances the readOnly flag hides.
      expect(find.byKey(const Key('photo-selector')), findsNothing);
      expect(
        find.byTooltip('Pick a photo'),
        findsNothing,
        reason: 'the capture/replace-photo FAB must not render read-only',
      );

      // No publish control exists anywhere in this codebase yet (confirmed
      // by grep before writing this suite) — nothing to find, but this
      // documents the intent so a future publish UI addition is reminded
      // to gate on readOnly too.
      expect(find.textContaining('Publish'), findsNothing);

      // The route legend (routes + swatches) still renders.
      expect(find.byKey(const Key('topo-route-legend')), findsOneWidget);
      expect(find.textContaining('Route 1'), findsWidgets);

      // The legend's own editing affordances (visibility/delete) are also
      // hidden in read-only mode.
      expect(find.byKey(const Key('topo-route-visibility-1')), findsNothing);
      expect(find.byKey(const Key('topo-route-delete-1')), findsNothing);
    },
  );

  testWidgets(
    'D4b: tapping community-like-button toggles state and updates the count',
    (tester) async {
      final seeded = await seedWallWithRoute(tester);
      addTearDown(seeded.db.close);
      addTearDown(seeded.container.dispose);

      await tester.pumpWidget(
        wrap(
          seeded.container,
          CommunityTopoDetailScreen(
            wallId: seeded.wallId,
            debugInitialImageSize: const Size(1000, 2000),
          ),
        ),
      );
      await tester.pumpAndSettle();

      String likeCountText() => tester
          .widget<Text>(find.byKey(const Key('community-like-count')))
          .data!;

      expect(likeCountText(), '0');
      expect(find.byIcon(Icons.favorite_border), findsOneWidget);
      expect(find.byIcon(Icons.favorite), findsNothing);

      await tester.tap(find.byKey(const Key('community-like-button')));
      await tester.pumpAndSettle();

      expect(likeCountText(), '1');
      expect(find.byIcon(Icons.favorite), findsOneWidget);
      expect(find.byIcon(Icons.favorite_border), findsNothing);

      await tester.tap(find.byKey(const Key('community-like-button')));
      await tester.pumpAndSettle();

      expect(likeCountText(), '0');
      expect(find.byIcon(Icons.favorite_border), findsOneWidget);
    },
  );

  testWidgets(
    'D4c: submitting a comment appends a community-comment-<id> row',
    (tester) async {
      final seeded = await seedWallWithRoute(tester);
      addTearDown(seeded.db.close);
      addTearDown(seeded.container.dispose);

      await tester.pumpWidget(
        wrap(
          seeded.container,
          CommunityTopoDetailScreen(
            wallId: seeded.wallId,
            debugInitialImageSize: const Size(1000, 2000),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('community-comment-field')),
        'Great line!',
      );
      await tester.tap(find.byKey(const Key('community-comment-submit')));
      await tester.pumpAndSettle();

      final commentsRepo = seeded.container.read(commentsRepositoryProvider);
      final comments = await commentsRepo.commentsForWall(seeded.wallId);
      expect(comments, hasLength(1));
      expect(comments.single.body, 'Great line!');
      // Derived from the fake signed-in session's email local-part.
      expect(comments.single.authorName, 'climber');

      expect(
        find.byKey(Key('community-comment-${comments.single.id}')),
        findsOneWidget,
      );
      expect(find.text('Great line!'), findsOneWidget);
      expect(find.text('climber'), findsOneWidget);
    },
  );

  testWidgets(
    'D4d: log-ascent sheet opens and logs an ascent against the correct '
    'route',
    (tester) async {
      final seeded = await seedWallWithRoute(tester);
      addTearDown(seeded.db.close);
      addTearDown(seeded.container.dispose);

      await tester.pumpWidget(
        wrap(
          seeded.container,
          CommunityTopoDetailScreen(
            wallId: seeded.wallId,
            debugInitialImageSize: const Size(1000, 2000),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final ascentButtonKey = Key(
        'community-log-ascent-${seeded.routeDbId}',
      );
      await tester.ensureVisible(find.byKey(ascentButtonKey));
      await tester.pumpAndSettle();
      expect(find.byKey(ascentButtonKey), findsOneWidget);

      await tester.tap(find.byKey(ascentButtonKey));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('community-log-ascent-sheet')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('community-ascent-save')));
      await tester.pumpAndSettle();

      // The sheet closes on save.
      expect(
        find.byKey(const Key('community-log-ascent-sheet')),
        findsNothing,
      );

      final ascentsRepo = seeded.container.read(ascentsRepositoryProvider);
      final ascents = await ascentsRepo.ascentsForRoute(seeded.routeDbId);
      expect(ascents, hasLength(1));
      expect(ascents.single.style, AscentStyle.redpoint);
      expect(ascents.single.wallId, seeded.wallId);
    },
  );

  testWidgets(
    'D4e: saving the log-ascent sheet releases focus from the notes field '
    '(keyboard-dismiss regression guard)',
    (tester) async {
      final seeded = await seedWallWithRoute(tester);
      addTearDown(seeded.db.close);
      addTearDown(seeded.container.dispose);

      await tester.pumpWidget(
        wrap(
          seeded.container,
          CommunityTopoDetailScreen(
            wallId: seeded.wallId,
            debugInitialImageSize: const Size(1000, 2000),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final ascentButtonKey = Key(
        'community-log-ascent-${seeded.routeDbId}',
      );
      await tester.ensureVisible(find.byKey(ascentButtonKey));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(ascentButtonKey));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('community-log-ascent-sheet')),
        findsOneWidget,
      );

      // Focus the notes field and enter text, so it holds focus (and the
      // keyboard would be shown) going into Save.
      await tester.enterText(
        find.byKey(const Key('community-ascent-notes')),
        'Felt great',
      );
      await tester.pumpAndSettle();
      // The FocusNode backing an EditableText is owned by an internal
      // `Focus` widget (built by EditableTextState) whose *widget-level*
      // `debugLabel` argument is set to `'EditableText'` — so
      // `primaryFocus.context?.widget` is that wrapping `Focus`, not an
      // `EditableText` itself, and the widget's own `debugLabel` field (not
      // the FocusNode's, which is unset) is the reliable signal that the
      // notes field currently holds focus.
      expect(
        _holdsTextFieldFocus(),
        isTrue,
        reason: 'the notes field should hold focus after entering text',
      );

      await tester.tap(find.byKey(const Key('community-ascent-save')));
      await tester.pumpAndSettle();

      // The sheet closes on save...
      expect(
        find.byKey(const Key('community-log-ascent-sheet')),
        findsNothing,
      );
      // ...and the notes field's focus must have been released rather than
      // stranded on a now-disposed field (#20a keyboard-dismiss fix).
      expect(
        _holdsTextFieldFocus(),
        isFalse,
        reason:
            'focus must be released (not left on a text field) once the '
            'log-ascent sheet is saved and popped',
      );
    },
  );
}

/// Whether [FocusManager.instance.primaryFocus] is currently held by a text
/// field's [EditableText]. `primaryFocus.context.widget` is the internal
/// `Focus` widget an `EditableTextState` builds around itself (see the D4e
/// test's comment) rather than the `EditableText` itself, so this checks
/// that `Focus` widget's own `debugLabel` field, which `EditableTextState`
/// always sets to the literal string `'EditableText'`.
bool _holdsTextFieldFocus() {
  final widget = FocusManager.instance.primaryFocus?.context?.widget;
  return widget is Focus && widget.debugLabel == 'EditableText';
}
