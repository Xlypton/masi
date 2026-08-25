import 'package:flutter_test/flutter_test.dart';
import 'package:masi/core/grades/grade_system.dart';
import 'package:masi/features/import/data/guidebook_import_codec.dart';
import 'package:masi/features/import/domain/guidebook_import.dart';
import 'package:masi/features/import/domain/guidebook_import_prompt.dart';

/// The prompt is the entire interface between the user's chat subscription and
/// this app — Masi never calls a model — so the example it shows must be
/// something the production decoder actually accepts. These tests exist to
/// make the prompt and the parser fail together rather than drift apart.
void main() {
  group("the prompt's worked example is really valid", () {
    late GuidebookImport import;

    setUp(() {
      final result =
          decodeGuidebookImportJson(kGuidebookImportPromptExample);
      expect(
        result,
        isA<ImportDecoded>(),
        reason: result is ImportRejected
            ? 'The example shown to the user is rejected by the real '
                'decoder: ${result.message}'
            : null,
      );
      import = (result as ImportDecoded).import;
    });

    test('it decodes to the boulder and routes it appears to show', () {
      expect(import.boulder, 'Cul de Chien');
      expect(import.gradeSystem, GradeSystem.french);
      expect(import.routes, hasLength(2));
      expect(import.routes.map((r) => r.name), ['Le Toit', 'La Marie-Rose']);
    });

    test('its grades resolve onto the ladder', () {
      for (final route in import.routes) {
        expect(
          route.resolvedGradeRaw(import.gradeSystem),
          isNotNull,
          reason: '${route.name} shows a grade the app would silently drop',
        );
      }
    });

    test('it demonstrates both a placed and an unplaced route', () {
      // The example teaches the most important rule in the prompt — omit
      // `points` rather than guess — so it has to actually show both shapes.
      expect(import.hasAnyGeometry, isTrue);
      expect(import.unplacedRoutes, hasLength(1));
      expect(import.unplacedRoutes.single.name, 'La Marie-Rose');
    });

    test('its example line is inside the photo and ordered bottom to top', () {
      final placed = import.routes.firstWhere((r) => r.isPlaced);
      for (final p in placed.points) {
        expect(p.dx, inInclusiveRange(0.0, 1.0));
        expect(p.dy, inInclusiveRange(0.0, 1.0));
      }
      // y grows downward, so a bottom-to-top line has decreasing y. If the
      // example contradicted the prose above it, models would copy the
      // example.
      final ys = placed.points.map((p) => p.dy).toList();
      expect(
        ys,
        orderedEquals(ys.toList()..sort((a, b) => b.compareTo(a))),
        reason: 'the example line must run bottom to top, as the prompt says',
      );
    });

    test('it trips no repair paths — a clean example must parse cleanly', () {
      // Advisory warnings are excluded on purpose: the example deliberately
      // shows a route with no line, so `unplacedGeometry` here is the prompt
      // teaching its most important rule, not the decoder repairing damage.
      expect(
        import.problems,
        isEmpty,
        reason: 'the example the user is shown should not itself trip any '
            "of the decoder's repair paths",
      );
      expect(
        import.warnings.where((w) => w.isAdvisory),
        hasLength(1),
        reason: 'the one unplaced route is expected news, not a problem',
      );
    });
  });

  group('the prompt states the rules that make placement work', () {
    test('it embeds the example verbatim', () {
      expect(kGuidebookImportPrompt, contains(kGuidebookImportPromptExample));
    });

    test('it asks for both images', () {
      expect(kGuidebookImportPrompt, contains('TWO images'));
      expect(kGuidebookImportPrompt, contains('MY OWN photo'));
    });

    test('it pins coordinates to the user\'s photo, not the book', () {
      // The single most important instruction: coordinates read off the
      // book's own picture are meaningless on a photo taken from a different
      // angle, and every line placed that way lands wrong.
      expect(kGuidebookImportPrompt, contains('NOT the guidebook'));
    });

    test('it tells the model to omit a line rather than guess', () {
      expect(kGuidebookImportPrompt, contains('OMIT'));
      expect(kGuidebookImportPrompt, contains('Do not guess'));
    });

    test('it names the version and both grade ladders', () {
      expect(kGuidebookImportPrompt, contains('"v"'));
      for (final system in GradeSystem.values) {
        expect(
          kGuidebookImportPrompt,
          contains('"${system.name}"'),
          reason: 'the prompt must offer every ladder the decoder accepts',
        );
      }
    });

    test('it asks for bare JSON, since the paste box parses strictly', () {
      expect(kGuidebookImportPrompt, contains('no markdown fences'));
    });
  });
}
