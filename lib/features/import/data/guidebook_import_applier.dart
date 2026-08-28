import 'package:flutter/foundation.dart';

import '../../../core/grades/grade_system.dart';
import '../../topo/data/route_repository.dart';
import '../domain/guidebook_import.dart';

/// What an [GuidebookImportApplier.apply] call actually wrote.
///
/// Reported back so the review screen can say something true and specific
/// ("8 routes added, 3 still need drawing") instead of a bare success toast.
@immutable
class ImportApplyResult {
  const ImportApplyResult({
    required this.added,
    required this.placed,
    required this.unplaced,
    required this.graded,
    required this.firstNumber,
  });

  /// How many routes were written.
  final int added;

  /// Of those, how many arrived with a line already drawn.
  final int placed;

  /// Of those, how many the user still has to draw.
  final int unplaced;

  /// How many came away with a grade that resolved onto the ladder.
  final int graded;

  /// The route number the import started at. Greater than 1 when the photo
  /// already had routes on it — see [GuidebookImportApplier.apply].
  final int firstNumber;

  /// Whether the import landed on a photo that already had routes.
  bool get appended => firstNumber > 1;

  @override
  String toString() => 'ImportApplyResult(added: $added, placed: $placed, '
      'unplaced: $unplaced, graded: $graded, firstNumber: $firstNumber)';
}

/// Writes a decoded [GuidebookImport] onto a specific wall photo.
class GuidebookImportApplier {
  const GuidebookImportApplier(this._routes);

  final RouteRepository _routes;

  /// Writes every route in [import] onto [photoId], numbered consecutively
  /// **after every climb already on the wall**.
  ///
  /// Appending rather than starting at 1 is a safety property, not a
  /// convenience. [RouteRepository.upsertRoute] identifies a route by
  /// `(wallId, number)`, so importing five routes numbered from 1 onto a wall
  /// that already carried three hand-drawn ones would fold the import into
  /// those three — silently renaming and regrading work the user spent far
  /// longer on than the import saved. Numbering after the wall's existing
  /// maximum makes an import purely additive.
  ///
  /// The cost of that choice is that applying the same import twice writes
  /// the routes twice. That is the right trade: a double import is visible
  /// immediately and deleted in a few taps, whereas overwritten routes are
  /// neither. The review screen is what guards against the double tap.
  ///
  /// [system] is the grading ladder chosen in the review sheet, which may
  /// differ from [GuidebookImport.gradeSystem] when the model got it wrong or
  /// could not tell. Grades that do not resolve onto it are written as no
  /// grade at all rather than as an unrecognizable token — see
  /// [ImportedRoute.resolvedGradeRaw].
  ///
  /// Routes with no line are written too, with an empty point list. Both the
  /// painter and the hit-test already skip empty polylines, and persisting
  /// them is what keeps the imported names and grades from evaporating on a
  /// page reload before the user has had a chance to draw them.
  Future<ImportApplyResult> apply({
    required GuidebookImport import,
    required String wallId,
    required String photoId,
    GradeSystem? system,
  }) async {
    // Numbered above every climb on the WALL, not just the ones drawn on
    // this photo. Since v16 a number identifies a climb across the whole rock,
    // so restarting per photo would hand an imported route the number of an
    // existing climb — and `upsertRoute` would read that as "the same climb,
    // drawn again over here" and quietly fold the import into it, renaming
    // somebody's route from a guidebook page. Wall-wide numbering makes an
    // import what it is: new climbs.
    final existing = await _routes.routeDbIdsByNumber(wallId);
    final base = existing.keys.fold<int>(0, (max, n) => n > max ? n : max);

    var placed = 0;
    var unplaced = 0;
    var graded = 0;

    for (var i = 0; i < import.routes.length; i++) {
      final imported = import.routes[i];
      final number = base + i + 1;
      final route = imported.toTopoRoute(id: number, system: system, as: number);

      await _routes.upsertRoute(wallId, photoId, route);

      if (imported.isPlaced) {
        placed++;
      } else {
        unplaced++;
      }
      if (route.gradeRaw != null) graded++;
    }

    return ImportApplyResult(
      added: import.routes.length,
      placed: placed,
      unplaced: unplaced,
      graded: graded,
      firstNumber: base + 1,
    );
  }
}
