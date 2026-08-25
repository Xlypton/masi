import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:masi/app/theme.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/core/grades/grade_system.dart';
import 'package:masi/features/import/data/guidebook_import_applier.dart';
import 'package:masi/features/import/presentation/guidebook_import_sheet.dart';
import 'package:masi/features/topo/data/route_repository.dart';

/// Drives the sheet the way a user does — paste the chat app's reply, look at
/// what it says, tap Add — against a real in-memory database, so "it imported"
/// means rows exist rather than a callback fired.
void main() {
  const wallId = 'wall-1';
  const photoId = 'photo-1';

  late AppDatabase db;
  late RouteRepository routes;
  var clock = 1000;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    routes = RouteRepository(db, nowMs: () => clock++);

    await db.into(db.areas).insert(
          AreasCompanion.insert(
            id: 'area-1',
            createdAt: clock,
            updatedAt: clock,
            name: 'Fontainebleau',
          ),
        );
    await db.into(db.sectors).insert(
          SectorsCompanion.insert(
            id: 'sector-1',
            createdAt: clock,
            updatedAt: clock,
            areaId: 'area-1',
            name: 'Cul de Chien',
            sortOrder: 0,
          ),
        );
    await db.into(db.walls).insert(
          WallsCompanion.insert(
            id: wallId,
            createdAt: clock,
            updatedAt: clock,
            sectorId: 'sector-1',
            name: 'The Boulder',
            sortOrder: 0,
          ),
        );
    await db.into(db.photos).insert(
          PhotosCompanion.insert(
            id: photoId,
            createdAt: clock,
            updatedAt: clock,
            wallId: wallId,
            localPath: '/p.jpg',
            kind: 'original',
            width: 4032,
            height: 3024,
          ),
        );
  });

  tearDown(() async => db.close());

  const goodPayload = '''
{"v":1,"boulder":"Cul de Chien","gradeSystem":"french","routes":[
  {"name":"Le Toit","gradeRaw":"6a+","stars":2,
   "points":[[0.2,0.9],[0.3,0.1]]},
  {"name":"La Marie-Rose","gradeRaw":"6a","positionHint":"centre of the face"}
]}''';

  ImportApplyResult? applied;

  Future<void> openSheet(WidgetTester tester) async {
    applied = null;
    // The default 800x600 test surface is shorter than this sheet, which puts
    // its buttons outside the render tree and makes every tap miss. Use a
    // phone-shaped viewport instead of scrolling in each test.
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [routeRepositoryProvider.overrideWithValue(routes)],
        child: MaterialApp(
          theme: MasiTheme.light,
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () async {
                    applied = await showGuidebookImportSheet(
                      context,
                      wallId: wallId,
                      photoId: photoId,
                    );
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Future<void> paste(WidgetTester tester, String text) async {
    await tester.enterText(find.byKey(const Key('import-paste-field')), text);
    await tester.tap(find.byKey(const Key('import-read')));
    await tester.pumpAndSettle();
  }

  group('reading the reply', () {
    testWidgets('it opens on the instructions, not the review', (tester) async {
      await openSheet(tester);

      expect(find.byKey(const Key('guidebook-import-sheet')), findsOneWidget);
      expect(find.byKey(const Key('import-paste-field')), findsOneWidget);
      expect(find.byKey(const Key('import-apply')), findsNothing);
    });

    testWidgets('a good reply moves to the review', (tester) async {
      await openSheet(tester);
      await paste(tester, goodPayload);

      expect(find.text('Cul de Chien'), findsOneWidget);
      expect(find.text('Le Toit'), findsOneWidget);
      expect(find.text('La Marie-Rose'), findsOneWidget);
      expect(find.text('2 routes · 1 to draw'), findsOneWidget);
    });

    testWidgets('prose instead of JSON is refused readably, in place',
        (tester) async {
      await openSheet(tester);
      await paste(tester, 'Sure! Here are the routes on that page:');

      // Still on the paste step, with an explanation rather than a stack trace.
      expect(find.byKey(const Key('import-apply')), findsNothing);
      expect(find.textContaining("doesn't look like import text"), findsOneWidget);
    });

    testWidgets('a future payload version is refused', (tester) async {
      await openSheet(tester);
      await paste(tester, '{"v":99,"routes":[{"name":"x"}]}');

      expect(find.byKey(const Key('import-apply')), findsNothing);
      expect(find.textContaining('different version'), findsOneWidget);
    });
  });

  group('the review tells the truth about what will happen', () {
    testWidgets('an unplaced route is marked "to draw"', (tester) async {
      await openSheet(tester);
      await paste(tester, goodPayload);

      expect(find.text('to draw'), findsOneWidget);
      expect(find.text('centre of the face'), findsOneWidget,
          reason: "the model's position hint helps the user draw it");
    });

    testWidgets('a grade the ladder cannot read is struck through, not hidden',
        (tester) async {
      await openSheet(tester);
      await paste(
        tester,
        '{"v":1,"gradeSystem":"french","routes":[{"name":"R","gradeRaw":"V7"}]}',
      );

      // Showing the unreadable token is the signal that the dropdown is wrong.
      final grade = tester.widget<Text>(find.text('V7'));
      expect(grade.style?.decoration, TextDecoration.lineThrough);
    });

    testWidgets('changing the ladder re-reads every grade', (tester) async {
      await openSheet(tester);
      await paste(
        tester,
        '{"v":1,"routes":[{"name":"R","gradeRaw":"VII-"}]}',
      );

      // No system named, so nothing resolves yet.
      expect(
        tester.widget<Text>(find.text('VII-')).style?.decoration,
        TextDecoration.lineThrough,
      );

      await tester.tap(find.byKey(const Key('import-grade-system')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('UIAA').last);
      await tester.pumpAndSettle();

      // Now it reads, and is no longer struck through.
      expect(
        tester.widget<Text>(find.text('VII-')).style?.decoration,
        isNot(TextDecoration.lineThrough),
      );
    });

    testWidgets('problems are listed, advisories are not', (tester) async {
      await openSheet(tester);
      await paste(
        tester,
        '{"v":1,"gradeSystem":"french","routes":['
        '{"name":"A","gradeRaw":"9z"},'
        '{"name":"B"}]}',
      );

      // A is a problem (bad grade); B is merely undrawn, which is the prompt
      // working as intended and must not be dressed up as an error.
      expect(find.byKey(const Key('import-problems')), findsOneWidget);
      expect(find.text('1 thing to check'), findsOneWidget);
    });
  });

  group('applying', () {
    testWidgets('Add writes the routes and reports what it did',
        (tester) async {
      await openSheet(tester);
      await paste(tester, goodPayload);

      expect(find.text('Add 2 routes'), findsOneWidget);
      await tester.tap(find.byKey(const Key('import-apply')));
      await tester.pumpAndSettle();

      expect(applied, isNotNull);
      expect(applied!.added, 2);
      expect(applied!.placed, 1);
      expect(applied!.unplaced, 1);

      final stored = await routes.loadRoutes(wallId, photoId);
      expect(stored.map((r) => r.name), ['Le Toit', 'La Marie-Rose']);
      expect(stored.first.gradeRaw, '6a+');
      expect(stored.first.gradeSystem, GradeSystem.french);
      expect(stored.last.points, isEmpty);
    });

    testWidgets('the chosen ladder is what gets written', (tester) async {
      await openSheet(tester);
      await paste(tester, goodPayload);

      // The user overrides French to "No grades".
      await tester.tap(find.byKey(const Key('import-grade-system')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('No grades').last);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('import-apply')));
      await tester.pumpAndSettle();

      final stored = await routes.loadRoutes(wallId, photoId);
      expect(stored.every((r) => r.gradeRaw == null), isTrue);
      expect(stored.map((r) => r.name), ['Le Toit', 'La Marie-Rose'],
          reason: 'dropping grades must not drop the routes');
    });

    testWidgets('backing out of the review writes nothing', (tester) async {
      await openSheet(tester);
      await paste(tester, goodPayload);
      await tester.tap(find.byKey(const Key('import-back')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('import-paste-field')), findsOneWidget);
      expect(await routes.loadRoutes(wallId, photoId), isEmpty);
    });

    testWidgets('dismissing the sheet writes nothing', (tester) async {
      await openSheet(tester);
      await paste(tester, goodPayload);

      Navigator.of(tester.element(find.byKey(const Key('import-apply')))).pop();
      await tester.pumpAndSettle();

      expect(applied, isNull);
      expect(await routes.loadRoutes(wallId, photoId), isEmpty);
    });
  });
}
