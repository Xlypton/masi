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
import 'package:climbtopo/features/topo/presentation/topo_canvas_screen.dart';
import 'package:climbtopo/shared/presentation/masi_icon.dart';
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
        '/tmp/community-detail-test-photo-2.jpg',
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
      // Named + graded route: "1. Sunny Arete • 6a". `findsWidgets` (not
      // `findsOneWidget`) because the SAME label also renders inside the
      // collapsing header's own embedded (gesture-disabled) RouteLegend —
      // see this screen's `_openFullCanvas` doc for why that copy is
      // intentionally left in the tree, just inert.
      expect(
        find.text('1. Sunny Arete • 6a', skipOffstage: false),
        findsWidgets,
      );
      // Unnamed, ungraded route falls back to the generic label.
      expect(find.text('Route 2', skipOffstage: false), findsWidgets);

      // Pre-seeded comments render.
      expect(find.text('Nice line!', skipOffstage: false), findsOneWidget);
      expect(
        find.text('Sent it yesterday.', skipOffstage: false),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'D4: the comment submit button renders MasiIcon(\'send_check\') — '
    'masi_send.svg does not exist in assets/icons/masi/ yet',
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
      expect(submitIcon.name, 'send_check');
    },
  );

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
      expect(
        find.byKey(namedAscentKey, skipOffstage: false),
        findsOneWidget,
      );

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
      expect(
        find.byKey(namedAscentKey, skipOffstage: false),
        findsOneWidget,
      );
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

      final openCanvas = find.byKey(
        const Key('community-detail-open-canvas'),
      );
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
