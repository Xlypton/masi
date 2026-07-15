import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:climbtopo/app/theme.dart';
import 'package:climbtopo/core/db/app_database.dart';
import 'package:climbtopo/core/db/database_provider.dart';
import 'package:climbtopo/core/grades/grade_system.dart';
import 'package:climbtopo/features/account/application/auth_providers.dart';
import 'package:climbtopo/features/account/data/auth_repository.dart';
import 'package:climbtopo/features/library/application/library_providers.dart';
import 'package:climbtopo/features/library/data/library_crud_repository.dart';
import 'package:climbtopo/features/library/presentation/topos_screen.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

/// A minimal-but-real 1x1 transparent PNG (base64), used to give
/// `ui.instantiateImageCodec` real bytes to decode in the "New topo" flow
/// tests, rather than a fake/mocked decode step.
final _tinyPngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY'
  '42YAAAAASUVORK5CYII=',
);

/// Builds a [ProviderContainer] wired to a fresh in-memory database and
/// registers teardown of both the container and the database connection.
///
/// addTearDown runs LIFO, so `db.close` is registered first: the container
/// must be disposed (cancelling Riverpod's live watch subscriptions) BEFORE
/// the underlying Drift connection is closed, otherwise closing the database
/// out from under a still-active watch stream hangs waiting on the
/// background executor isolate. (Mirrors
/// `test/features/library/presentation/areas_screen_test.dart`.)
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

/// Wraps [screen] in a real (minimal) [GoRouter] so `context.push` calls
/// (Organize -> `/areas`, row tap -> `/walls/:wallId`, and the "New topo"
/// flow's post-create push) resolve against a real `GoRouter` instead of
/// throwing for lack of one. The pushed-to routes only need to exist, not
/// look like anything real.
Widget _wrap(ProviderContainer container, Widget screen) {
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(path: '/', builder: (context, state) => screen),
      GoRoute(
        path: '/walls/:wallId',
        builder: (context, state) => const SizedBox(),
      ),
      GoRoute(path: '/areas', builder: (context, state) => const SizedBox()),
    ],
  );
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp.router(theme: MasiTheme.light, routerConfig: router),
  );
}

/// Advances real asynchronous work (Drift's in-memory background executor,
/// image decode, and any other awaited futures) that would otherwise never
/// make progress under `testWidgets`' fake-async clock, then pumps to flush
/// the resulting Riverpod-triggered rebuilds and any in-flight
/// dialog/route transitions. Mirrors `areas_screen_test.dart`'s `_drain`.
Future<void> _drain(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 30));
  }
  await tester.pumpAndSettle();
}

/// Runs [body] (which performs real Drift async work) under the real event
/// loop so its awaits actually complete, capturing the result.
Future<T> _dbWork<T>(WidgetTester tester, Future<T> Function() body) async {
  late T result;
  await tester.runAsync(() async {
    result = await body();
  });
  return result;
}

void main() {
  group('A1: empty state', () {
    testWidgets(
      'no topos shows topos-empty-state and the topos-new-topo button',
      (tester) async {
        final container = _makeContainer();

        await tester.pumpWidget(_wrap(container, const ToposScreen()));
        await _drain(tester);

        expect(find.byKey(const Key('topos-empty-state')), findsOneWidget);
        expect(find.text('No topos yet'), findsOneWidget);
        expect(find.byKey(const Key('topos-new-topo')), findsOneWidget);
      },
    );
  });

  group('A2: populated list rendering', () {
    testWidgets(
      'renders one row per topo with correct name/subtitle text; a null '
      'thumbnailPath renders the gradient fallback, not a broken image',
      (tester) async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWithValue(db),
            nowMsProvider.overrideWithValue(() => 1000),
            toposProvider.overrideWith(
              (ref) => Stream.value(const [
                TopoRef(
                  wallId: 'wall-1',
                  name: 'Topo One',
                  thumbnailPath: null,
                  routeCount: 0,
                  createdAt: 1000,
                ),
                TopoRef(
                  wallId: 'wall-2',
                  name: 'Topo Two',
                  thumbnailPath: null,
                  routeCount: 3,
                  createdAt: 900,
                ),
              ]),
            ),
          ],
        );
        addTearDown(container.dispose);

        await tester.pumpWidget(_wrap(container, const ToposScreen()));
        await _drain(tester);

        expect(find.byKey(const Key('topo-item-wall-1')), findsOneWidget);
        expect(find.byKey(const Key('topo-item-wall-2')), findsOneWidget);
        expect(find.text('Topo One'), findsOneWidget);
        expect(find.text('Topo Two'), findsOneWidget);
        expect(find.text('0 routes'), findsOneWidget);
        expect(find.text('3 routes'), findsOneWidget);
        // Neither row has a thumbnailPath, so no Image widget (which could
        // error-out/show a broken-image icon) should be present at all —
        // only the gradient fallback container.
        expect(find.byType(Image), findsNothing);
      },
    );
  });

  group('A3: delete confirm flow', () {
    testWidgets(
      'confirming delete calls softDeleteWall via the real repo and the '
      'row disappears once the stream re-emits',
      (tester) async {
        final container = _makeContainer();
        final wallId = await _dbWork(
          tester,
          () => container
              .read(libraryCrudRepositoryProvider)
              .createTopo('Roof Wall'),
        );

        await tester.pumpWidget(_wrap(container, const ToposScreen()));
        await _drain(tester);

        expect(find.text('Roof Wall'), findsOneWidget);

        await tester.tap(find.byKey(Key('topo-menu-$wallId')));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(Key('topo-delete-$wallId')));
        await tester.pumpAndSettle();

        expect(find.text('Delete?'), findsOneWidget);

        await tester.tap(find.byKey(Key('topo-delete-confirm-$wallId')));
        await _drain(tester);

        expect(find.text('Roof Wall'), findsNothing);
        expect(find.byKey(const Key('topos-empty-state')), findsOneWidget);

        final topos = await _dbWork(
          tester,
          () =>
              container.read(libraryCrudRepositoryProvider).watchTopos().first,
        );
        expect(topos, isEmpty);
      },
    );
  });

  group('A4: rename flow', () {
    testWidgets(
      'entering a new name and submitting calls renameWall via the real '
      'repo and updates the displayed name',
      (tester) async {
        final container = _makeContainer();
        final wallId = await _dbWork(
          tester,
          () => container
              .read(libraryCrudRepositoryProvider)
              .createTopo('Old Name'),
        );

        await tester.pumpWidget(_wrap(container, const ToposScreen()));
        await _drain(tester);

        expect(find.text('Old Name'), findsOneWidget);

        await tester.tap(find.byKey(Key('topo-menu-$wallId')));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(Key('topo-rename-$wallId')));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('crud-name-field')), findsOneWidget);

        await tester.enterText(
          find.byKey(const Key('crud-name-field')),
          'New Name',
        );
        await tester.pump();
        await tester.tap(find.byKey(const Key('crud-name-submit')));
        await tester.pumpAndSettle();
        await _drain(tester);

        expect(find.text('New Name'), findsOneWidget);
        expect(find.text('Old Name'), findsNothing);
      },
    );
  });

  group('#20: rename dialog keyboard dismissal', () {
    testWidgets(
      'submitting the rename dialog drops focus/keyboard, not just the '
      'dialog',
      (tester) async {
        final container = _makeContainer();
        final wallId = await _dbWork(
          tester,
          () => container
              .read(libraryCrudRepositoryProvider)
              .createTopo('Old Name'),
        );

        await tester.pumpWidget(_wrap(container, const ToposScreen()));
        await _drain(tester);

        await tester.tap(find.byKey(Key('topo-menu-$wallId')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(Key('topo-rename-$wallId')));
        await tester.pumpAndSettle();

        await tester.enterText(
          find.byKey(const Key('crud-name-field')),
          'New Name',
        );
        await tester.pump();
        expect(tester.testTextInput.hasAnyClients, isTrue);

        await tester.tap(find.byKey(const Key('crud-name-submit')));
        await tester.pumpAndSettle();

        expect(
          tester.testTextInput.hasAnyClients,
          isFalse,
          reason: 'submitting the rename dialog must dismiss the keyboard',
        );
      },
    );

    testWidgets(
      'cancelling the rename dialog drops focus/keyboard, not just the '
      'dialog',
      (tester) async {
        final container = _makeContainer();
        final wallId = await _dbWork(
          tester,
          () => container
              .read(libraryCrudRepositoryProvider)
              .createTopo('Old Name'),
        );

        await tester.pumpWidget(_wrap(container, const ToposScreen()));
        await _drain(tester);

        await tester.tap(find.byKey(Key('topo-menu-$wallId')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(Key('topo-rename-$wallId')));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('crud-name-field')));
        await tester.pump();
        expect(tester.testTextInput.hasAnyClients, isTrue);

        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();

        expect(
          tester.testTextInput.hasAnyClients,
          isFalse,
          reason: 'cancelling the rename dialog must dismiss the keyboard',
        );
      },
    );
  });

  group('A5: organize action', () {
    testWidgets('topos-organize is present in the trailing app-bar slot', (
      tester,
    ) async {
      final container = _makeContainer();

      await tester.pumpWidget(_wrap(container, const ToposScreen()));
      await _drain(tester);

      expect(
        find.descendant(
          of: find.byType(AppBar),
          matching: find.byKey(const Key('topos-organize')),
        ),
        findsOneWidget,
      );
    });
  });

  group('A6: new-topo flow', () {
    testWidgets(
      'cancelling the photo-source sheet is a no-op: no topo is created',
      (tester) async {
        final container = _makeContainer();

        await tester.pumpWidget(
          _wrap(
            container,
            ToposScreen(
              photoSourcePicker: (context) async => null,
              photoPicker: (source) async =>
                  throw StateError('must not be called after cancel'),
            ),
          ),
        );
        await _drain(tester);

        await tester.tap(find.byKey(const Key('topos-new-topo')));
        await _drain(tester);

        expect(find.byKey(const Key('topos-empty-state')), findsOneWidget);
        final topos = await _dbWork(
          tester,
          () =>
              container.read(libraryCrudRepositoryProvider).watchTopos().first,
        );
        expect(topos, isEmpty);
      },
    );

    testWidgets('picking a real photo creates exactly one topo with a non-null '
        'thumbnailPath, via the real repo (attachPhotoToWall really ran)', (
      tester,
    ) async {
      final container = _makeContainer();
      late Directory tempDir;
      late File pngFile;
      await tester.runAsync(() async {
        tempDir = await Directory.systemTemp.createTemp('topos_screen_test');
        pngFile = File('${tempDir.path}/photo.png');
        await pngFile.writeAsBytes(_tinyPngBytes);
      });
      addTearDown(() {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      });

      await tester.pumpWidget(
        _wrap(
          container,
          ToposScreen(
            photoSourcePicker: (context) async => ImageSource.gallery,
            photoPicker: (source) async => XFile(pngFile.path),
          ),
        ),
      );
      await _drain(tester);

      await tester.tap(find.byKey(const Key('topos-new-topo')));
      await _drain(tester);
      await _drain(tester);

      final topos = await _dbWork(
        tester,
        () => container.read(libraryCrudRepositoryProvider).watchTopos().first,
      );
      expect(topos.length, 1);
      expect(topos.single.thumbnailPath, isNotNull);
    });

    testWidgets(
      'tapping New topo while toposProvider is still loading is a no-op: '
      'the photo-source picker is never invoked and no topo is created '
      '(regression for the stale/loading topo-count defect)',
      (tester) async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWithValue(db),
            nowMsProvider.overrideWithValue(() => 1000),
            // A stream that never emits keeps toposProvider in AsyncLoading
            // forever, mimicking the still-loading window this defect
            // exploited.
            toposProvider.overrideWith(
              (ref) => const Stream<List<TopoRef>>.empty(),
            ),
          ],
        );
        addTearDown(container.dispose);

        var pickerInvoked = false;
        await tester.pumpWidget(
          _wrap(
            container,
            ToposScreen(
              photoSourcePicker: (context) async {
                pickerInvoked = true;
                return null;
              },
              photoPicker: (source) async =>
                  throw StateError('must not be called'),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        expect(find.byType(CircularProgressIndicator), findsOneWidget);

        final button = tester.widget<ElevatedButton>(
          find.byKey(const Key('topos-new-topo')),
        );
        expect(
          button.onPressed,
          isNull,
          reason: 'button must be visually disabled while not yet loaded',
        );

        await tester.tap(
          find.byKey(const Key('topos-new-topo')),
          warnIfMissed: false,
        );
        await tester.pump();

        expect(pickerInvoked, isFalse);

        final topos = await _dbWork(
          tester,
          () =>
              container.read(libraryCrudRepositoryProvider).watchTopos().first,
        );
        expect(topos, isEmpty);
      },
    );

    testWidgets('a fast double-tap on New topo only ever creates one topo '
        '(re-entrancy guard regression test)', (tester) async {
      final container = _makeContainer();
      late Directory tempDir;
      late File pngFile;
      await tester.runAsync(() async {
        tempDir = await Directory.systemTemp.createTemp(
          'topos_screen_test_reentrancy',
        );
        pngFile = File('${tempDir.path}/photo.png');
        await pngFile.writeAsBytes(_tinyPngBytes);
      });
      addTearDown(() {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      });

      var sourcePickerCalls = 0;
      final sourceCompleter = Completer<ImageSource?>();

      await tester.pumpWidget(
        _wrap(
          container,
          ToposScreen(
            photoSourcePicker: (context) async {
              sourcePickerCalls++;
              return sourceCompleter.future;
            },
            photoPicker: (source) async => XFile(pngFile.path),
          ),
        ),
      );
      await _drain(tester);

      // First tap starts the flow and suspends on the (uncompleted)
      // source-picker future; the flow's re-entrancy flag is set
      // synchronously before that await, so a second tap while it is
      // still in flight must be swallowed by the guard rather than
      // starting a second concurrent flow.
      await tester.tap(find.byKey(const Key('topos-new-topo')));
      await tester.tap(find.byKey(const Key('topos-new-topo')));
      await tester.pump();

      expect(
        sourcePickerCalls,
        1,
        reason:
            'second tap must be ignored while the first flow is '
            'still in flight',
      );

      await tester.runAsync(() async {
        sourceCompleter.complete(ImageSource.gallery);
      });
      await _drain(tester);
      await _drain(tester);

      final topos = await _dbWork(
        tester,
        () => container.read(libraryCrudRepositoryProvider).watchTopos().first,
      );
      expect(topos.length, 1);
    });

    testWidgets(
      'a picker exception is swallowed: the Topos home does not crash and '
      'remains usable',
      (tester) async {
        final container = _makeContainer();

        await tester.pumpWidget(
          _wrap(
            container,
            ToposScreen(
              photoSourcePicker: (context) async => ImageSource.gallery,
              photoPicker: (source) async => throw Exception('picker exploded'),
            ),
          ),
        );
        await _drain(tester);

        await tester.tap(find.byKey(const Key('topos-new-topo')));
        await _drain(tester);

        expect(tester.takeException(), isNull);
        expect(find.byKey(const Key('topos-empty-state')), findsOneWidget);
        expect(find.byKey(const Key('topos-new-topo')), findsOneWidget);

        final topos = await _dbWork(
          tester,
          () =>
              container.read(libraryCrudRepositoryProvider).watchTopos().first,
        );
        expect(topos, isEmpty);
      },
    );
  });

  group('A2b: singular route-count subtitle', () {
    testWidgets('a topo with exactly one route renders "1 route" (singular)', (
      tester,
    ) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          nowMsProvider.overrideWithValue(() => 1000),
          toposProvider.overrideWith(
            (ref) => Stream.value(const [
              TopoRef(
                wallId: 'wall-singular',
                name: 'Singular Wall',
                thumbnailPath: null,
                routeCount: 1,
                createdAt: 1000,
              ),
            ]),
          ),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(_wrap(container, const ToposScreen()));
      await _drain(tester);

      expect(find.text('1 route'), findsOneWidget);
      expect(find.text('1 routes'), findsNothing);
    });
  });

  group('B: new-topo button contrast', () {
    testWidgets(
      'B-a: while topos are still loading (button disabled), the resolved '
      'foreground color keeps adequate contrast on the accent background, '
      'not the low-contrast ~38%-opacity onSurface Material default',
      (tester) async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWithValue(db),
            nowMsProvider.overrideWithValue(() => 1000),
            // A stream that never emits keeps toposProvider in AsyncLoading
            // forever, so canCreate stays false and the button stays
            // disabled (mirrors the A6 loading regression test above).
            toposProvider.overrideWith(
              (ref) => const Stream<List<TopoRef>>.empty(),
            ),
          ],
        );
        addTearDown(container.dispose);

        await tester.pumpWidget(_wrap(container, const ToposScreen()));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        final button = tester.widget<ElevatedButton>(
          find.byKey(const Key('topos-new-topo')),
        );
        expect(button.onPressed, isNull, reason: 'still loading -> disabled');

        final resolvedForeground = button.style!.foregroundColor!.resolve(
          <WidgetState>{WidgetState.disabled},
        )!;
        final resolvedBackground = button.style!.backgroundColor!.resolve(
          <WidgetState>{WidgetState.disabled},
        )!;

        // Must be materially more opaque than Material's default disabled
        // foreground (onSurface @ 38% alpha = 0.38), which is what produced
        // the low-contrast dark-on-purple text.
        expect(resolvedForeground.a, greaterThanOrEqualTo(0.6));
        // And it must be derived from onAccent (white, in the light theme
        // used by this test's MaterialApp), not the dark onSurface fallback.
        expect(resolvedForeground.r, greaterThan(0.9));
        expect(resolvedForeground.g, greaterThan(0.9));
        expect(resolvedForeground.b, greaterThan(0.9));

        // The background must still read as the purple accent while
        // disabled/loading, not fall back to a washed-out grey fill.
        expect(
          (resolvedBackground.r - MasiColors.light.accent.r).abs(),
          lessThan(0.05),
        );
        expect(
          (resolvedBackground.g - MasiColors.light.accent.g).abs(),
          lessThan(0.05),
        );
        expect(
          (resolvedBackground.b - MasiColors.light.accent.b).abs(),
          lessThan(0.05),
        );
      },
    );

    testWidgets(
      'B-b: the enabled state is unchanged - accent background, white '
      'onAccent foreground',
      (tester) async {
        final container = _makeContainer();

        await tester.pumpWidget(_wrap(container, const ToposScreen()));
        await _drain(tester);

        final button = tester.widget<ElevatedButton>(
          find.byKey(const Key('topos-new-topo')),
        );
        expect(button.onPressed, isNotNull, reason: 'loaded -> enabled');

        final resolvedForeground = button.style!.foregroundColor!.resolve(
          <WidgetState>{},
        );
        final resolvedBackground = button.style!.backgroundColor!.resolve(
          <WidgetState>{},
        );

        expect(resolvedForeground, MasiColors.light.onAccent);
        expect(resolvedBackground, MasiColors.light.accent);
      },
    );
  });

  group('A11: grade pill', () {
    testWidgets(
      'a topo with a top grade shows a pill with the band color and label',
      (tester) async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWithValue(db),
            nowMsProvider.overrideWithValue(() => 1000),
            toposProvider.overrideWith(
              (ref) => Stream.value(const [
                TopoRef(
                  wallId: 'wall-graded',
                  name: 'Graded Wall',
                  thumbnailPath: null,
                  routeCount: 3,
                  createdAt: 1000,
                  topGradeLabel: '7a',
                  topGradeBand: GradeBand.hard,
                ),
              ]),
            ),
          ],
        );
        addTearDown(container.dispose);

        await tester.pumpWidget(_wrap(container, const ToposScreen()));
        await _drain(tester);

        expect(find.text('7a'), findsOneWidget);
        expect(find.text('3 routes'), findsOneWidget);

        final pillContainer = tester.widget<Container>(
          find
              .ancestor(of: find.text('7a'), matching: find.byType(Container))
              .first,
        );
        final decoration = pillContainer.decoration as BoxDecoration;
        expect(decoration.color, MasiColors.light.gradeHard);
      },
    );

    testWidgets('a topo with no graded routes shows no pill, just "N routes"', (
      tester,
    ) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          nowMsProvider.overrideWithValue(() => 1000),
          toposProvider.overrideWith(
            (ref) => Stream.value(const [
              TopoRef(
                wallId: 'wall-bare',
                name: 'Bare Wall',
                thumbnailPath: null,
                routeCount: 2,
                createdAt: 1000,
              ),
            ]),
          ),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(_wrap(container, const ToposScreen()));
      await _drain(tester);

      expect(find.text('2 routes'), findsOneWidget);
      // No grade label of any kind should render for an ungraded topo.
      expect(find.textContaining(RegExp(r'^\d+[a-c]\+?$')), findsNothing);
    });
  });

  group('account button reflects auth state (#19)', () {
    testWidgets(
      'signed-out renders the generic person_outline icon, no CircleAvatar, '
      'key preserved',
      (tester) async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWithValue(db),
            nowMsProvider.overrideWithValue(() => 1000),
            authStateProvider.overrideWith(
              (ref) => Stream.value(const AuthSessionState.signedOut()),
            ),
          ],
        );
        addTearDown(container.dispose);

        await tester.pumpWidget(_wrap(container, const ToposScreen()));
        await _drain(tester);

        expect(find.byKey(const Key('topos-account-button')), findsOneWidget);
        final button = tester.widget<IconButton>(
          find.byKey(const Key('topos-account-button')),
        );
        expect(button.icon, isA<Icon>());
        expect((button.icon as Icon).icon, Icons.person_outline);
        expect(find.byType(CircleAvatar), findsNothing);
      },
    );

    testWidgets(
      'a still-loading auth stream also renders the person_outline icon '
      '(never a blank/empty avatar)',
      (tester) async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWithValue(db),
            nowMsProvider.overrideWithValue(() => 1000),
            // Never emits: authStateProvider stays AsyncLoading forever.
            authStateProvider.overrideWith(
              (ref) => const Stream<AuthSessionState>.empty(),
            ),
          ],
        );
        addTearDown(container.dispose);

        await tester.pumpWidget(_wrap(container, const ToposScreen()));
        await _drain(tester);

        final button = tester.widget<IconButton>(
          find.byKey(const Key('topos-account-button')),
        );
        expect(button.icon, isA<Icon>());
        expect((button.icon as Icon).icon, Icons.person_outline);
        expect(find.byType(CircleAvatar), findsNothing);
      },
    );

    testWidgets(
      'signed-in with a real email renders a CircleAvatar showing initials '
      '("PK" for peter.keri@example.com), key preserved',
      (tester) async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWithValue(db),
            nowMsProvider.overrideWithValue(() => 1000),
            authStateProvider.overrideWith(
              (ref) => Stream.value(
                const AuthSessionState.signedIn('peter.keri@example.com'),
              ),
            ),
          ],
        );
        addTearDown(container.dispose);

        await tester.pumpWidget(_wrap(container, const ToposScreen()));
        await _drain(tester);

        expect(find.byKey(const Key('topos-account-button')), findsOneWidget);
        expect(
          find.descendant(
            of: find.byKey(const Key('topos-account-button')),
            matching: find.byType(CircleAvatar),
          ),
          findsOneWidget,
        );
        expect(find.text('PK'), findsOneWidget);
        // The generic icon must not be layered underneath the avatar.
        expect(
          find.descendant(
            of: find.byKey(const Key('topos-account-button')),
            matching: find.byIcon(Icons.person_outline),
          ),
          findsNothing,
        );
      },
    );
  });

  group('D1b: Community/Logbook nav buttons on the app bar', () {
    testWidgets(
      'home-community-button and home-logbook-button are present in the '
      'trailing app-bar slot alongside the existing Organize action',
      (tester) async {
        final container = _makeContainer();

        await tester.pumpWidget(_wrap(container, const ToposScreen()));
        await _drain(tester);

        expect(
          find.descendant(
            of: find.byType(AppBar),
            matching: find.byKey(const Key('home-community-button')),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byType(AppBar),
            matching: find.byKey(const Key('home-logbook-button')),
          ),
          findsOneWidget,
        );
        // The existing Organize action must still be intact.
        expect(find.byKey(const Key('topos-organize')), findsOneWidget);
      },
    );
  });

  group('D5d: publish/unpublish menu action', () {
    testWidgets(
      'the menu shows "Publish" for a private topo; tapping it opens a '
      'confirm dialog; cancelling leaves the wall private and un-dirty',
      (tester) async {
        final container = _makeContainer();
        final wallId = await _dbWork(
          tester,
          () => container
              .read(libraryCrudRepositoryProvider)
              .createTopo('Shareable Wall'),
        );

        await tester.pumpWidget(_wrap(container, const ToposScreen()));
        await _drain(tester);

        await tester.tap(find.byKey(Key('topo-menu-$wallId')));
        await tester.pumpAndSettle();

        expect(find.byKey(Key('topo-publish-$wallId')), findsOneWidget);
        expect(find.text('Publish'), findsOneWidget);
        expect(find.text('Unpublish'), findsNothing);

        await tester.tap(find.byKey(Key('topo-publish-$wallId')));
        await tester.pumpAndSettle();

        expect(find.text('Publish to Community?'), findsOneWidget);
        expect(
          find.byKey(Key('topo-publish-confirm-$wallId')),
          findsOneWidget,
          reason:
              'confirming publish must go through a dedicated confirm '
              'action, not fire straight off the menu tap',
        );

        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();

        final rawDb = container.read(appDatabaseProvider);
        final wall = await _dbWork(
          tester,
          () => (rawDb.select(
            rawDb.walls,
          )..where((t) => t.id.equals(wallId))).getSingle(),
        );
        expect(
          wall.visibility,
          'private',
          reason: 'cancelling the confirm dialog must not publish',
        );
        expect(wall.dirty, isFalse);
      },
    );

    testWidgets(
      'confirming the publish dialog calls publishTopo: the wall becomes '
      'shared, and the menu now shows "Unpublish"',
      (tester) async {
        final container = _makeContainer();
        final wallId = await _dbWork(
          tester,
          () => container
              .read(libraryCrudRepositoryProvider)
              .createTopo('Shareable Wall'),
        );

        await tester.pumpWidget(_wrap(container, const ToposScreen()));
        await _drain(tester);

        await tester.tap(find.byKey(Key('topo-menu-$wallId')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(Key('topo-publish-$wallId')));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(Key('topo-publish-confirm-$wallId')));
        await _drain(tester);

        final rawDb = container.read(appDatabaseProvider);
        final wall = await _dbWork(
          tester,
          () => (rawDb.select(
            rawDb.walls,
          )..where((t) => t.id.equals(wallId))).getSingle(),
        );
        expect(wall.visibility, 'shared');
        expect(wall.dirty, isTrue);

        // Re-open the menu: it should now offer "Unpublish", not "Publish".
        await tester.tap(find.byKey(Key('topo-menu-$wallId')));
        await tester.pumpAndSettle();

        expect(find.text('Unpublish'), findsOneWidget);
        expect(find.text('Publish'), findsNothing);
      },
    );

    testWidgets(
      'tapping Unpublish on an already-shared topo calls unpublishTopo '
      'directly (no confirm dialog) and the wall reverts to private',
      (tester) async {
        final container = _makeContainer();
        final wallId = await _dbWork(
          tester,
          () => container
              .read(libraryCrudRepositoryProvider)
              .createTopo('Shared Wall'),
        );
        await _dbWork(
          tester,
          () =>
              container.read(libraryCrudRepositoryProvider).publishTopo(wallId),
        );

        await tester.pumpWidget(_wrap(container, const ToposScreen()));
        await _drain(tester);

        await tester.tap(find.byKey(Key('topo-menu-$wallId')));
        await tester.pumpAndSettle();

        expect(find.text('Unpublish'), findsOneWidget);

        await tester.tap(find.byKey(Key('topo-publish-$wallId')));
        await _drain(tester);

        // No confirm dialog should have appeared for unpublish.
        expect(find.text('Publish to Community?'), findsNothing);

        final rawDb = container.read(appDatabaseProvider);
        final wall = await _dbWork(
          tester,
          () => (rawDb.select(
            rawDb.walls,
          )..where((t) => t.id.equals(wallId))).getSingle(),
        );
        expect(wall.visibility, 'private');
      },
    );
  });
}
