import 'package:masi/app/theme.dart';
import 'package:masi/core/db/app_database.dart' hide Comment;
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/features/account/application/auth_providers.dart';
import 'package:masi/features/account/data/auth_repository.dart';
import 'package:masi/features/community/application/comments_providers.dart';
import 'package:masi/features/community/application/community_topo_detail_providers.dart';
import 'package:masi/features/community/data/comments_repository.dart'
    show Comment;
import 'package:masi/features/community/presentation/community_topo_detail_screen.dart';
import 'package:masi/features/library/application/library_providers.dart';
import 'package:masi/features/logbook/application/ascents_providers.dart';
import 'package:masi/features/logbook/data/ascents_repository.dart';
import 'package:masi/features/topo/data/route_repository.dart';
import 'package:masi/features/topo/domain/topo_route.dart';
import 'package:masi/features/topo/presentation/topo_canvas.dart';
import 'package:masi/features/topo/presentation/topo_canvas_screen.dart';
import 'package:masi/features/topo/presentation/topo_painter.dart';
import 'package:masi/shared/presentation/masi_icon.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

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
  Future<void> signInWithGoogle() async {}

  @override
  Future<void> verifyEmailOtp(String email, String code) async {}

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
        XFile('/tmp/community-detail-test-photo.jpg'),
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

  /// D6 seed: like [seedWallWithRoute], but with TWO routes — one NAMED
  /// (+graded) and one left unnamed/ungraded — plus a couple of pre-seeded
  /// comments, so the #30/#26 redesign assertions (named-vs-unnamed route
  /// label, comment thread rendering) have real data to check against
  /// without driving any UI interaction to create it.
  Future<
    ({
      AppDatabase db,
      ProviderContainer container,
      String wallId,
      String namedRouteDbId,
      String unnamedRouteDbId,
    })
  >
  seedWallWithTwoRoutesAndComments(WidgetTester tester) async {
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

    late String photoId;
    await tester.runAsync(() async {
      photoId = await crud.attachPhotoToWall(
        wall.id,
        XFile('/tmp/community-detail-test-photo-2.jpg'),
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
        name: 'Sunny Arete',
        gradeRaw: '6a',
      ),
    );
    await routeRepo.upsertRoute(
      wall.id,
      photoId,
      const TopoRoute(
        id: 2,
        number: 2,
        points: [Offset(0.3, 0.3), Offset(0.4, 0.4)],
      ),
    );
    final dbIds = await routeRepo.routeDbIdsByNumber(wall.id);

    final commentsRepo = container.read(commentsRepositoryProvider);
    await commentsRepo.addComment(
      wallId: wall.id,
      body: 'Nice line!',
      authorName: 'alex',
    );
    await commentsRepo.addComment(
      wallId: wall.id,
      body: 'Sent it yesterday.',
      authorName: 'sam',
    );

    return (
      db: db,
      container: container,
      wallId: wall.id,
      namedRouteDbId: dbIds[1]!,
      unnamedRouteDbId: dbIds[2]!,
    );
  }

  testWidgets(
    'D4a: read-only detail hides every editing affordance, and (since the '
    'embedded header is now chromeless) its own floating route legend too',
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

      // #31 ghost-chevron/legend-bleed fix: the header's embedded
      // TopoCanvasScreen is `embedded: true` (see TopoCanvasScreen.embedded's
      // doc), so it never paints its own floating RouteLegend overlay at
      // all — neither the expanded card (`topo-route-legend-overlay`, whose
      // own RouteLegend child carries this `topo-route-legend` key) nor the
      // collapsed chip (`topo-route-legend-chip`). This used to assert the
      // opposite ("still renders") before `embedded` existed.
      expect(find.byKey(const Key('topo-route-legend')), findsNothing);
      expect(find.byKey(const Key('topo-route-legend-overlay')), findsNothing);
      expect(find.byKey(const Key('topo-route-legend-chip')), findsNothing);

      // The route is still visible, just via this screen's own "Routes"
      // section below the header rather than the (now-suppressed) embedded
      // legend — skipOffstage: false since that section starts below the
      // initial viewport fold (see scrollKeyIntoView's doc).
      expect(find.textContaining('Route 1', skipOffstage: false), findsWidgets);

      // The legend's own editing affordances (visibility/delete) are also
      // hidden in read-only mode — moot now that no legend renders at all
      // in the embedded header, but kept as a belt-and-suspenders guard in
      // case a future change resurrects it there.
      expect(find.byKey(const Key('topo-route-visibility-1')), findsNothing);
      expect(find.byKey(const Key('topo-route-delete-1')), findsNothing);
    },
  );

  testWidgets(
    'chrome title: the collapsing header shows the wall/topo name so the '
    'viewer always knows which topo they\'re on',
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

      final titleWidget = tester.widget<Text>(
        find.byKey(const Key('community-detail-title'), skipOffstage: false),
      );
      // seedWallWithRoute names the wall literally 'Wall'.
      expect(titleWidget.data, 'Wall');
    },
  );

  testWidgets('comment empty state: renders a placeholder when the wall has no '
      'comments yet, and it disappears once one is posted', (tester) async {
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

    expect(
      find.byKey(const Key('community-comments-empty'), skipOffstage: false),
      findsOneWidget,
    );

    await tester.enterText(
      find.byKey(const Key('community-comment-field')),
      'First!',
    );
    // The submit IconButton is disabled/enabled off a ValueListenableBuilder
    // watching `_commentController` directly (see the "comment submit
    // button" group above) — `enterText` fires that listener synchronously
    // but the rebuilt (now-enabled) IconButton instance isn't in the
    // element tree until a frame is pumped. Skipping this `pump()` taps
    // the still-disabled button from the PREVIOUS build (a no-op), so the
    // comment is silently never submitted.
    await tester.pump();
    await tester.tap(find.byKey(const Key('community-comment-submit')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('community-comments-empty'), skipOffstage: false),
      findsNothing,
    );
  });

  testWidgets(
    'comment submit button: disabled for an empty/whitespace-only draft, '
    'enabled once real text is entered',
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

      IconButton submitButton() => tester.widget<IconButton>(
        find.byKey(const Key('community-comment-submit'), skipOffstage: false),
      );

      // Empty draft: disabled.
      expect(submitButton().onPressed, isNull);

      // Whitespace-only draft: still disabled.
      await tester.enterText(
        find.byKey(const Key('community-comment-field')),
        '   ',
      );
      await tester.pump();
      expect(submitButton().onPressed, isNull);

      // Real text: enabled.
      await tester.enterText(
        find.byKey(const Key('community-comment-field')),
        'Nice!',
      );
      await tester.pump();
      expect(submitButton().onPressed, isNotNull);

      // Clearing it back out disables it again.
      await tester.enterText(
        find.byKey(const Key('community-comment-field')),
        '',
      );
      await tester.pump();
      expect(submitButton().onPressed, isNull);
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

      Finder heartIcon(String name) => find.byWidgetPredicate(
        (widget) => widget is MasiIcon && widget.name == name,
      );

      expect(likeCountText(), '0');
      expect(heartIcon('heart'), findsOneWidget);
      expect(heartIcon('heart_fill'), findsNothing);

      await tester.tap(find.byKey(const Key('community-like-button')));
      await tester.pumpAndSettle();

      expect(likeCountText(), '1');
      expect(heartIcon('heart_fill'), findsOneWidget);
      expect(heartIcon('heart'), findsNothing);

      await tester.tap(find.byKey(const Key('community-like-button')));
      await tester.pumpAndSettle();

      expect(likeCountText(), '0');
      expect(heartIcon('heart'), findsOneWidget);
      expect(heartIcon('heart_fill'), findsNothing);
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
      // See the identical comment in the "comment empty state" test above:
      // the submit button needs a pumped frame to pick up the now-enabled
      // `onPressed` before it can be usefully tapped.
      await tester.pump();
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

      final ascentButtonKey = Key('community-log-ascent-${seeded.routeDbId}');
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
      expect(find.byKey(const Key('community-log-ascent-sheet')), findsNothing);

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

      final ascentButtonKey = Key('community-log-ascent-${seeded.routeDbId}');
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
      expect(find.byKey(const Key('community-log-ascent-sheet')), findsNothing);
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

  testWidgets(
    'D5: a named route renders "N. Name • grade" and an unnamed route '
    'renders "Route N"',
    (tester) async {
      final seeded = await seedWallWithTwoRoutesAndComments(tester);
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

      // `skipOffstage: false` throughout this test: the collapsing header
      // takes ~48% of the (800x600 test) viewport, so the Comments/Routes
      // body content below it can start below the initial visible fold —
      // still fully built (a short, non-lazy SliverChildListDelegate list),
      // just filtered out of the DEFAULT (skipOffstage: true) finders. These
      // are pure existence checks (no tap), so skipping that visibility
      // filter is enough — no scrolling needed.
      //
      // Named + graded route: "1. Sunny Arete • 6a". `findsWidgets` (rather
      // than the stricter `findsOneWidget`) purely to stay tolerant of
      // exactly how many places this label happens to render — currently
      // just this screen's own "Routes" section, since #31 made the
      // collapsing header's embedded TopoCanvasScreen `embedded: true` (see
      // that flag's doc), which suppresses its own floating RouteLegend
      // (and hence this same label) entirely.
      // Redesign: the grade now renders in its own leading pill/badge
      // (`_GradeBadge`) rather than appended to the name text
      // (`_routeNameLabel`), so the name and grade are separate Text
      // widgets — asserted as two separate finds instead of one combined
      // string.
      expect(find.text('1. Sunny Arete', skipOffstage: false), findsWidgets);
      expect(find.text('6a', skipOffstage: false), findsWidgets);
      // Unnamed, ungraded route falls back to the generic label (no grade
      // badge renders, since gradeRaw is null).
      expect(find.text('Route 2', skipOffstage: false), findsWidgets);

      // Pre-seeded comments render.
      expect(find.text('Nice line!', skipOffstage: false), findsOneWidget);
      expect(
        find.text('Sent it yesterday.', skipOffstage: false),
        findsOneWidget,
      );
    },
  );

  testWidgets('D4 (redesign): the comment submit button renders '
      "MasiIcon('send_fill') — masi_send_fill.svg now exists in "
      'assets/icons/masi/, added alongside the comment-input redesign', (
    tester,
  ) async {
    final seeded = await seedWallWithTwoRoutesAndComments(tester);
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

    // `skipOffstage: false` on both finders: the comment submit button
    // sits inside the scrollable body below the collapsing header and can
    // be at/near the initial viewport fold (see the D5 test's comment) —
    // this is a pure existence/type check (no tap), so it doesn't need
    // scrolling, just to not be filtered out by the default onstage-only
    // traversal.
    final submitIcon = tester.widget<MasiIcon>(
      find.descendant(
        of: find.byKey(
          const Key('community-comment-submit'),
          skipOffstage: false,
        ),
        matching: find.byType(MasiIcon, skipOffstage: false),
      ),
    );
    expect(submitIcon.name, 'send_fill');
  });

  testWidgets(
    'D3: the Routes section is expanded by default and its header toggles '
    'it closed/open, without disturbing the per-route log-ascent keys',
    (tester) async {
      final seeded = await seedWallWithTwoRoutesAndComments(tester);
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

      const sectionKeyValue = Key('community-routes-section');
      // `skipOffstage: false`: the Routes section header can start below
      // the initial viewport fold (below the collapsing header + the
      // like/comments content above it) — see `scrollKeyIntoView`'s doc.
      // This is a pure existence check, so no scrolling needed yet.
      expect(find.byKey(sectionKeyValue, skipOffstage: false), findsOneWidget);

      final namedAscentKey = Key(
        'community-log-ascent-${seeded.namedRouteDbId}',
      );

      // Default expanded: the per-route Log-ascent button already exists
      // with no interaction (existence check only — `skipOffstage: false`,
      // no scroll needed).
      expect(find.byKey(namedAscentKey, skipOffstage: false), findsOneWidget);

      // Tapping the header collapses it — `scrollKeyIntoView` first, since
      // an actual `tap()` (unlike the existence checks above) dispatches a
      // synthetic pointer event at the widget's real on-screen position,
      // which must be genuinely within the visible viewport.
      await scrollKeyIntoView(tester, sectionKeyValue);
      await tester.tap(find.byKey(sectionKeyValue));
      await tester.pumpAndSettle();
      expect(
        find.byKey(namedAscentKey, skipOffstage: false),
        findsNothing,
        reason: 'collapsing the Routes section must hide its rows',
      );

      // Tapping again re-expands it, and the SAME per-route key/behavior
      // survives the round trip.
      await scrollKeyIntoView(tester, sectionKeyValue);
      await tester.tap(find.byKey(sectionKeyValue));
      await tester.pumpAndSettle();
      expect(find.byKey(namedAscentKey, skipOffstage: false), findsOneWidget);
    },
  );

  testWidgets(
    'D2: tapping community-detail-open-canvas pushes a full-screen, still '
    'readOnly TopoCanvasScreen bound to the same wall',
    (tester) async {
      final seeded = await seedWallWithTwoRoutesAndComments(tester);
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

      // Only the collapsing header's own embedded (gesture-disabled) copy
      // exists before the tap. `skipOffstage: false` for consistency with
      // the post-tap count below (both routes are onstage right now, so it
      // doesn't change this particular number, but it keeps the "before"
      // and "after" counts directly comparable rather than mixing finder
      // semantics between them).
      final countBefore = find
          .byType(TopoCanvasScreen, skipOffstage: false)
          .evaluate()
          .length;
      expect(countBefore, 1);

      final openCanvas = find.byKey(const Key('community-detail-open-canvas'));
      expect(openCanvas, findsOneWidget);
      // `warnIfMissed: true` (the default) would already flag a genuine
      // hit-test miss on the header's tap catcher; asserting the count grew
      // below is the real proof the tap actually reached `_openFullCanvas`.
      await tester.tap(openCanvas);
      await tester.pumpAndSettle();

      // A NEW TopoCanvasScreen is now pushed full-screen on top of the
      // detail screen. The original, embedded in the collapsing header, is
      // NOT disposed — Navigator keeps prior routes mounted (`maintainState`
      // defaults to true) — but is now covered by the new opaque route, so
      // it is genuinely OFFSTAGE (not painted/hit-testable). A plain
      // `find.byType` (default `skipOffstage: true`) would therefore only
      // ever see the topmost one and stay pinned at 1 regardless of whether
      // the push happened — a trivially-passing check. `skipOffstage: false`
      // counts both, so the count growing from 1 to 2 is genuine proof a
      // second TopoCanvasScreen now exists in the tree because of the push.
      // Every TopoCanvasScreen bound to this wall must stay readOnly: a
      // community topo may belong to someone else and must never become
      // editable from this screen.
      final screens = tester.widgetList<TopoCanvasScreen>(
        find.byType(TopoCanvasScreen, skipOffstage: false),
      );
      expect(screens.length, greaterThan(countBefore));
      expect(screens.every((w) => w.readOnly), isTrue);
      expect(screens.every((w) => w.wallId == seeded.wallId), isTrue);
    },
  );

  testWidgets('#31: the header\'s embedded canvas is chromeless — no '
      'topo-back-button, no floating route legend — while the photo + route '
      'overlays still render', (tester) async {
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

    // Ghost-chevron/legend-bleed fix: the header's embedded
    // TopoCanvasScreen is `embedded: true` (see TopoCanvasScreen.embedded's
    // doc) — its own top GlassChrome pill (wall-name title + the
    // `topo-back-button` chevron) is never painted at all now, not merely
    // made inert by the ancestor IgnorePointer as it used to be.
    expect(find.byKey(const Key('topo-back-button')), findsNothing);

    // Nor is its floating RouteLegend overlay, in either form.
    expect(find.byKey(const Key('topo-route-legend')), findsNothing);
    expect(find.byKey(const Key('topo-route-legend-overlay')), findsNothing);
    expect(find.byKey(const Key('topo-route-legend-chip')), findsNothing);

    // The photo + its route overlays still render: TopoCanvas is mounted
    // with the resolved image size, and TopoPainter (the actual
    // photo/route-overlay renderer) is fed the wall's committed route —
    // only the interactive/floating chrome is suppressed, per
    // TopoCanvasScreen.embedded's contract.
    final canvas = tester.widget<TopoCanvas>(find.byType(TopoCanvas));
    expect(canvas.imageSize, const Size(1000, 2000));

    // Mirrors topo_canvas_fit_test.dart's own `findTopoPainter` idiom.
    final customPaint = tester.widget<CustomPaint>(
      find.byWidgetPredicate(
        (widget) => widget is CustomPaint && widget.painter is TopoPainter,
      ),
    );
    final painter = customPaint.painter as TopoPainter;
    expect(painter.routes, hasLength(1));

    // This screen's own back button — the only FUNCTIONAL one — is
    // unaffected by any of the above.
    expect(
      find.byKey(const Key('community-detail-back-button')),
      findsOneWidget,
    );
  });

  testWidgets(
    '#31: the full-screen canvas pushed via community-detail-open-canvas '
    'still shows its own top pill + route legend chrome (embedded is only '
    'ever set on the header\'s copy, never on the pushed one)',
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

      await tester.tap(find.byKey(const Key('community-detail-open-canvas')));
      await tester.pumpAndSettle();

      // The pushed, full-screen TopoCanvasScreen (`_openFullCanvas` leaves
      // `embedded` at its default `false`) keeps its normal top pill and
      // route legend — only the header's own embedded preview goes
      // chromeless. `skipOffstage: false` since the header's now-covered,
      // still-mounted copy remains in the tree too (see the D2 test's own
      // doc) and neither of these keys is unique to whichever copy is on
      // top.
      expect(
        find.byKey(const Key('topo-back-button'), skipOffstage: false),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('topo-route-legend'), skipOffstage: false),
        findsOneWidget,
      );
    },
  );

  group('Routes section per-route metadata (#41 beta-video, #42 style tags, '
      '#44 stars)', () {
    testWidgets('a route with betaVideoUrl shows a route-beta-<dbId> button; a '
        'route without one does not', (tester) async {
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
      addTearDown(db.close);
      addTearDown(container.dispose);

      final crud = container.read(libraryCrudRepositoryProvider);
      final area = await crud.createArea('Area');
      final sector = await crud.createSector(area.id, 'Sector');
      final wall = await crud.createWall(sector.id, 'Wall');
      late String photoId;
      await tester.runAsync(() async {
        photoId = await crud.attachPhotoToWall(
          wall.id,
          XFile('/tmp/community-detail-metadata-test-photo.jpg'),
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
          betaVideoUrl: 'https://example.com/beta',
          styleTags: ['dyno', 'my-custom-tag'],
          stars: 2,
        ),
      );
      await routeRepo.upsertRoute(
        wall.id,
        photoId,
        const TopoRoute(
          id: 2,
          number: 2,
          points: [Offset(0.3, 0.3), Offset(0.4, 0.4)],
        ),
      );
      final dbIds = await routeRepo.routeDbIdsByNumber(wall.id);

      await tester.pumpWidget(
        wrap(
          container,
          CommunityTopoDetailScreen(
            wallId: wall.id,
            debugInitialImageSize: const Size(1000, 2000),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final withMetaDbId = dbIds[1]!;
      final withoutMetaDbId = dbIds[2]!;

      await scrollKeyIntoView(
        tester,
        Key('community-log-ascent-$withMetaDbId'),
      );

      expect(
        find.byKey(Key('route-beta-$withMetaDbId'), skipOffstage: false),
        findsOneWidget,
        reason: 'the route with a betaVideoUrl must show its button',
      );
      expect(
        find.byKey(Key('route-beta-$withoutMetaDbId'), skipOffstage: false),
        findsNothing,
        reason: 'the route without a betaVideoUrl must not',
      );

      expect(
        find.byKey(
          Key('route-styletag-$withMetaDbId-dyno'),
          skipOffstage: false,
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(
          Key('route-styletag-$withMetaDbId-my-custom-tag'),
          skipOffstage: false,
        ),
        findsOneWidget,
      );

      expect(
        find.byKey(Key('route-stars-$withMetaDbId'), skipOffstage: false),
        findsOneWidget,
      );
      expect(
        find.byKey(Key('route-stars-$withoutMetaDbId'), skipOffstage: false),
        findsNothing,
      );
    });
  });

  // The failure mode this screen shipped with: both section gates read a bare
  // `!asyncThing.hasValue`. On an AsyncError `hasValue` is false and
  // `isLoading` is false, and neither of these providers re-emits on its own —
  // so the gate revealed its skeleton at 180 ms and was never handed a
  // `false` again. The shimmer then repeated for the life of the screen and the
  // failure had no rendering at all.
  group('a section whose read FAILED', () {
    /// Seeds the same real DB as [seedWallWithRoute], with the routes and
    /// comments providers overridden to fail. Both failures are realistic: the
    /// routes future does three awaits against drift, and the comments stream is
    /// a drift `watch()`.
    Future<({AppDatabase db, ProviderContainer container, String wallId})>
    seedWithFailingSections(WidgetTester tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      final container = ProviderContainer(
        // Riverpod v3 retries a failed provider on a backoff by default, which
        // would re-run these throwing bodies mid-assertion and leave pending
        // timers behind.
        retry: (_, _) => null,
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          nowMsProvider.overrideWithValue(() => 1000),
          authRepositoryProvider.overrideWithValue(
            _FakeAuthRepository(
              const AuthSessionState.signedIn('climber@example.com'),
            ),
          ),
          routeEntriesForWallProvider.overrideWith(
            (ref, wallId) async =>
                throw StateError('SqliteException: no such column: photo_id'),
          ),
          commentsForWallProvider.overrideWith(
            (ref, wallId) => Stream<List<Comment>>.error(
              StateError('SqliteException: database is locked'),
            ),
          ),
        ],
      );
      final crud = container.read(libraryCrudRepositoryProvider);
      final area = await crud.createArea('Area');
      final sector = await crud.createSector(area.id, 'Sector');
      final wall = await crud.createWall(sector.id, 'Wall');
      await tester.runAsync(() async {
        await crud.attachPhotoToWall(
          wall.id,
          XFile('/tmp/community-detail-failing-photo.jpg'),
          1000,
          2000,
        );
      });
      return (db: db, container: container, wallId: wall.id);
    }

    Future<void> pumpFailing(
      WidgetTester tester,
      String wallId,
      ProviderContainer container,
    ) async {
      await tester.pumpWidget(
        wrap(
          container,
          CommunityTopoDetailScreen(
            wallId: wallId,
            debugInitialImageSize: const Size(1000, 2000),
          ),
        ),
      );
      // Deliver the errors, then cross the reveal delay AND the
      // minimum-visible hold: if the gate is still holding a skeleton after
      // this, it is holding it forever.
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));
    }

    testWidgets('stops the routes shimmer and offers a retry instead of '
        'shimmering forever', (tester) async {
      final seeded = await seedWithFailingSections(tester);
      addTearDown(seeded.db.close);
      addTearDown(seeded.container.dispose);
      await pumpFailing(tester, seeded.wallId, seeded.container);

      expect(
        find.byKey(const Key('community-routes-skeleton'), skipOffstage: false),
        findsNothing,
        reason:
            'the skeleton was never handed a false and shimmered for the '
            'life of the screen',
      );
      expect(
        find.byKey(const Key('community-routes-error'), skipOffstage: false),
        findsOneWidget,
        reason: 'a failed read had no rendering on this screen at all',
      );
      expect(
        find.byKey(const Key('community-routes-retry'), skipOffstage: false),
        findsOneWidget,
      );
      // Developer text stays out of the user's face, same rule as
      // MasiAsyncView's showErrorDetail default.
      expect(find.textContaining('SqliteException'), findsNothing);
    });

    testWidgets('stops the comments shimmer and offers a retry', (
      tester,
    ) async {
      final seeded = await seedWithFailingSections(tester);
      addTearDown(seeded.db.close);
      addTearDown(seeded.container.dispose);
      await pumpFailing(tester, seeded.wallId, seeded.container);

      expect(
        find.byKey(
          const Key('community-comments-skeleton'),
          skipOffstage: false,
        ),
        findsNothing,
      );
      expect(
        find.byKey(const Key('community-comments-error'), skipOffstage: false),
        findsOneWidget,
      );
      // NOT the empty state: "no comments yet" about a thread that failed to
      // load is a false statement about somebody's topo.
      expect(
        find.byKey(const Key('community-comments-empty'), skipOffstage: false),
        findsNothing,
      );
    });

    testWidgets('the routes retry re-runs the read, and a success clears the '
        'failure notice', (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      var attempts = 0;
      final container = ProviderContainer(
        retry: (_, _) => null,
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          nowMsProvider.overrideWithValue(() => 1000),
          authRepositoryProvider.overrideWithValue(
            _FakeAuthRepository(
              const AuthSessionState.signedIn('climber@example.com'),
            ),
          ),
          routeEntriesForWallProvider.overrideWith((ref, wallId) async {
            if (attempts++ == 0) throw StateError('transient');
            return const <RouteEntry>[];
          }),
        ],
      );
      addTearDown(container.dispose);
      final crud = container.read(libraryCrudRepositoryProvider);
      final area = await crud.createArea('Area');
      final sector = await crud.createSector(area.id, 'Sector');
      final wall = await crud.createWall(sector.id, 'Wall');
      await tester.runAsync(() async {
        await crud.attachPhotoToWall(
          wall.id,
          XFile('/tmp/community-detail-retry-photo.jpg'),
          1000,
          2000,
        );
      });

      await pumpFailing(tester, wall.id, container);
      expect(
        find.byKey(const Key('community-routes-error'), skipOffstage: false),
        findsOneWidget,
      );

      // `Scrollable.ensureVisible` + explicit pumps rather than
      // `scrollKeyIntoView`, whose `pumpAndSettle` would hang on the embedded
      // canvas's own shimmer.
      await Scrollable.ensureVisible(
        tester.element(
          find.byKey(const Key('community-routes-retry'), skipOffstage: false),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byKey(const Key('community-routes-retry')));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));

      expect(attempts, 2);
      expect(
        find.byKey(const Key('community-routes-error'), skipOffstage: false),
        findsNothing,
      );
    });
  });

  group('Redesign golden (visual regression)', () {
    testWidgets(
      'the redesigned screen (photo header with gradient-scrim title, '
      'card-based routes list, filled rounded comment input + send_fill '
      'button) renders a stable golden image',
      (tester) async {
        final seeded = await seedWallWithTwoRoutesAndComments(tester);
        addTearDown(seeded.db.close);
        addTearDown(seeded.container.dispose);

        // Pin physical size + device pixel ratio so the checked-in golden
        // PNG's dimensions/content are deterministic across machines,
        // mirroring topo_painter_golden_test.dart's own golden test. Tall
        // enough that the redesigned screen's header + like row + comments
        // + routes card all render without being clipped by the test
        // viewport (no scrolling needed to capture them in one shot).
        tester.view.physicalSize = const Size(400, 1200);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        // A dedicated RepaintBoundary + GlobalKey (rather than
        // `find.byType(RepaintBoundary)`, as topo_painter_golden_test.dart
        // uses) since this is a full screen with many Material widgets
        // (IconButton, TextField, OutlinedButton, ...) that can themselves
        // introduce their own internal RepaintBoundary descendants --
        // `find.byType` would risk matching more than one and throwing on
        // the matcher's internal `.single`.
        final repaintKey = GlobalKey();
        await tester.pumpWidget(
          wrap(
            seeded.container,
            RepaintBoundary(
              key: repaintKey,
              child: CommunityTopoDetailScreen(
                wallId: seeded.wallId,
                debugInitialImageSize: const Size(1000, 2000),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        await expectLater(
          find.byKey(repaintKey),
          matchesGoldenFile('goldens/community_topo_detail.png'),
        );
      },
    );
  });
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

/// Scrolls the detail screen's `CustomScrollView` until the element keyed
/// [key] is genuinely onstage (not just present in the tree), then settles.
///
/// The collapsing header (D1) takes ~48% of the test surface's default
/// 800x600 viewport, so this screen's Comments/Routes body content can
/// start below the initial visible fold — still fully built (a short,
/// non-lazy `SliverChildListDelegate` list), just excluded from a plain
/// `tester.ensureVisible`'s DEFAULT `skipOffstage: true` finder, which would
/// otherwise throw "0 widgets found" for a target that's in the tree but
/// not yet onstage (`SliverMultiBoxAdaptorElement.debugVisitOnstageChildren`
/// filters by current viewport paint bounds, not by whether the element
/// exists). Resolving the element with an explicit `skipOffstage: false`
/// finder first, then handing that resolved [Element] straight to the
/// static `Scrollable.ensureVisible` (which only cares about real render
/// geometry, not the onstage/finder concept at all), sidesteps that
/// chicken-and-egg problem so a subsequent plain `tester.tap(find.byKey(key))`
/// lands on the target's real, now-visible on-screen position.
Future<void> scrollKeyIntoView(WidgetTester tester, Key key) async {
  await Scrollable.ensureVisible(
    tester.element(find.byKey(key, skipOffstage: false)),
  );
  await tester.pumpAndSettle();
}
