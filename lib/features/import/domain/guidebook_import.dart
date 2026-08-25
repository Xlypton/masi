import 'dart:ui';

import 'package:flutter/foundation.dart';

import '../../../core/grades/grade_system.dart';
import '../../topo/domain/topo_route.dart';

/// The payload version this build understands. A payload carrying any other
/// value is rejected outright rather than partially read — see
/// `data/guidebook_import_codec.dart`.
const int kImportPayloadVersion = 1;

/// Caps applied to a decoded payload. These exist because the payload is
/// authored by a language model reading a photograph of a book page: it is
/// untrusted input in the ordinary sense, and every one of these limits has a
/// matching warning so a clipped import is visible rather than silent.
const int kMaxImportedRoutes = 60;
const int kMaxImportedPoints = 64;
const int kMaxImportedNameChars = 120;
const int kMaxImportedDescriptionChars = 2000;
const int kMaxImportedHintChars = 200;

/// Why the decoder altered or dropped something it was given.
///
/// A warning is never fatal — the import still applies. It exists so the
/// review screen can show the user *what the model got wrong*, which is the
/// difference between "these grades are missing" and silently importing a
/// boulder whose grades are quietly absent.
enum ImportWarningKind {
  /// `gradeSystem` was absent or not one of [GradeSystem]'s members. Every
  /// grade is held unparsed until the user picks a system in the review sheet.
  unknownGradeSystem,

  /// `gradeRaw` was not a member of the chosen system's ladder, so it was
  /// dropped to `null` rather than stored as an unrecognizable token.
  invalidGrade,

  /// The route arrived with no usable polyline (absent, non-finite, or fewer
  /// than two points), so it is created unplaced for the user to draw.
  unplacedGeometry,

  /// A coordinate fell outside `0.0..1.0` and was clamped onto the photo.
  clampedPoint,

  /// A text field exceeded its cap and was truncated.
  truncatedText,

  /// A route entry was not a JSON object at all and was skipped.
  droppedRoute,

  /// The payload carried more than [kMaxImportedRoutes] routes; the surplus
  /// was discarded.
  tooManyRoutes,

  /// The polyline carried more than [kMaxImportedPoints] points; the surplus
  /// was discarded.
  tooManyPoints,
}

/// One thing the decoder changed about the model's payload.
@immutable
class ImportWarning {
  const ImportWarning({
    required this.kind,
    required this.detail,
    this.routeNumber,
  });

  final ImportWarningKind kind;

  /// Human-readable specifics, e.g. `"'7Z+' is not a French grade"`. Shown
  /// verbatim in the review sheet.
  final String detail;

  /// The 1-based [ImportedRoute.number] this concerns, or `null` when the
  /// warning is about the payload as a whole.
  final int? routeNumber;

  /// Whether this is expected, normal news rather than something the model
  /// got wrong.
  ///
  /// [ImportWarningKind.unplacedGeometry] is the only advisory kind: the
  /// prompt explicitly tells the model to omit a line it cannot place, so an
  /// unplaced route is the design working, not a defect. The review sheet
  /// shows advisory warnings as "you'll draw these" and the rest as "check
  /// these" — collapsing the two would make a clean import of a hard-to-match
  /// page look like a page full of errors.
  bool get isAdvisory => kind == ImportWarningKind.unplacedGeometry;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ImportWarning &&
        other.kind == kind &&
        other.detail == detail &&
        other.routeNumber == routeNumber;
  }

  @override
  int get hashCode => Object.hash(kind, detail, routeNumber);

  @override
  String toString() =>
      'ImportWarning(${kind.name}, route: $routeNumber, $detail)';
}

/// A single route as read off a guidebook page, before it becomes a
/// [TopoRoute] on a specific photo.
///
/// Geometry is optional by design: [points] is empty when the model could not
/// place the line, and the route is then created unplaced for the user to
/// draw. Placed and unplaced routes take the same code path — the only
/// difference is whether [points] has anything in it.
@immutable
class ImportedRoute {
  const ImportedRoute({
    required this.number,
    this.name,
    this.gradeRaw,
    this.stars,
    this.description,
    this.positionHint,
    this.points = const [],
  });

  /// 1-based, assigned by the decoder in payload order. The payload's own
  /// `number` is deliberately ignored: it is the book's numbering, which may
  /// skip, repeat, or restart, and route identity here is positional.
  final int number;

  final String? name;

  /// The grade token exactly as the model wrote it (trimmed and capped), or
  /// `null` if it gave none. **Untrusted and unvalidated.**
  ///
  /// It cannot be validated at decode time, because validity depends on the
  /// ladder and the model frequently cannot name which ladder the book uses.
  /// Dropping every grade in that case would make the user retype the whole
  /// page, so the token is carried as-is and judged against the chosen system
  /// by [resolvedGradeRaw] — which re-runs whenever the review sheet's
  /// dropdown changes.
  final String? gradeRaw;

  /// `0..3`, or `null` for unrated.
  final int? stars;

  final String? description;

  /// The model's prose account of where the line sits on the rock, e.g.
  /// `"leftmost, up the obvious arête"`. Shown while the user draws or
  /// corrects this route. Never persisted onto [TopoRoute] — it is scaffolding
  /// for the import, not route metadata.
  final String? positionHint;

  /// The line in percent space (`0.0..1.0` on both axes, matching
  /// [TopoRoute.points]). Empty means unplaced.
  final List<Offset> points;

  /// Whether the model supplied a usable line. A single point is not a line,
  /// so the threshold is two.
  bool get isPlaced => points.length >= 2;

  /// [gradeRaw] normalized onto [system]'s ladder, or `null` when there is no
  /// grade, no system, or the token is not a member of that ladder.
  ///
  /// This is the only way a grade is allowed to reach a [TopoRoute]: an
  /// unrecognized token becomes `null` rather than being stored verbatim,
  /// because a grade the ladder does not contain cannot be sorted, filtered,
  /// or banded, and would read as real everywhere it appeared.
  String? resolvedGradeRaw(GradeSystem? system) {
    final raw = gradeRaw;
    if (system == null || raw == null) return null;
    if (!isValidGrade(system, raw)) return null;
    return normalizeGrade(system, raw);
  }

  /// The shared-scale sort key for [resolvedGradeRaw], or `null`.
  ///
  /// **Always computed, never read from the payload.** A model-supplied sort
  /// key would silently corrupt every difficulty sort, filter, and grade band
  /// in the app while looking perfectly valid — and unlike a wrong grade,
  /// nothing on screen would ever reveal it.
  double? resolvedGradeSortKey(GradeSystem? system) {
    final resolved = resolvedGradeRaw(system);
    if (resolved == null) return null;
    // Safe: `resolvedGradeRaw` returned non-null only after `isValidGrade`,
    // and `gradeSortKey` throws exactly when that check would have failed.
    return gradeSortKey(system!, resolved);
  }

  /// Converts to the domain route that gets persisted, with [system] the
  /// import-wide grading ladder chosen in the review sheet.
  ///
  /// [as] overrides the persisted route number, defaulting to this route's
  /// own [number]. The applier passes an offset value so an import lands
  /// *after* the routes already on the photo rather than overwriting them —
  /// see `GuidebookImportApplier.apply`. The colour index follows the final
  /// number, so an appended import keeps cycling the palette rather than
  /// restarting it and repeating a neighbour's colour.
  ///
  /// `style` is hardcoded to `'boulder'`: this feature imports bouldering
  /// guidebook pages, and `TopoRoute.style` is free-form by design (see its
  /// doc), so a wrong guess here is user-correctable in the metadata sheet.
  TopoRoute toTopoRoute({required int id, GradeSystem? system, int? as}) {
    final resolved = resolvedGradeRaw(system);
    final finalNumber = as ?? number;
    return TopoRoute(
      id: id,
      number: finalNumber,
      points: List.unmodifiable(points),
      colorIndex: routeColorIndexFor(finalNumber),
      name: name,
      gradeSystem: resolved == null ? null : system,
      gradeRaw: resolved,
      gradeSortKey: resolvedGradeSortKey(system),
      description: description,
      stars: stars,
      style: 'boulder',
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ImportedRoute &&
        other.number == number &&
        other.name == name &&
        other.gradeRaw == gradeRaw &&
        other.stars == stars &&
        other.description == description &&
        other.positionHint == positionHint &&
        listEquals(other.points, points);
  }

  @override
  int get hashCode => Object.hash(
        number,
        name,
        gradeRaw,
        stars,
        description,
        positionHint,
        Object.hashAll(points),
      );
}

/// A whole guidebook page, decoded and validated.
@immutable
class GuidebookImport {
  const GuidebookImport({
    required this.routes,
    this.boulder,
    this.gradeSystem,
    this.warnings = const [],
  });

  /// The boulder/wall name as read off the page, or `null`.
  final String? boulder;

  /// The grading ladder for the whole import.
  ///
  /// Per-import rather than per-route on purpose: a guidebook uses one system
  /// throughout, models frequently cannot name which, and one correctable
  /// dropdown beats N independently-wrong guesses. `null` means the model
  /// did not say and the user must choose before grades can be applied.
  final GradeSystem? gradeSystem;

  final List<ImportedRoute> routes;

  /// Everything the decoder changed about the model's payload, in the order
  /// it was noticed.
  final List<ImportWarning> warnings;

  /// Warnings that mean the model got something wrong, excluding the expected
  /// news that a route needs drawing. See [ImportWarning.isAdvisory].
  Iterable<ImportWarning> get problems =>
      warnings.where((w) => !w.isAdvisory);

  /// Routes the model could not place, which the user will draw by hand.
  Iterable<ImportedRoute> get unplacedRoutes =>
      routes.where((r) => !r.isPlaced);

  /// Whether any route arrived with a usable line.
  bool get hasAnyGeometry => routes.any((r) => r.isPlaced);

  GuidebookImport copyWith({
    String? boulder,
    bool boulderSet = false,
    GradeSystem? gradeSystem,
    bool gradeSystemSet = false,
    List<ImportedRoute>? routes,
    List<ImportWarning>? warnings,
  }) {
    return GuidebookImport(
      boulder: boulderSet ? boulder : (boulder ?? this.boulder),
      gradeSystem:
          gradeSystemSet ? gradeSystem : (gradeSystem ?? this.gradeSystem),
      routes: routes ?? this.routes,
      warnings: warnings ?? this.warnings,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is GuidebookImport &&
        other.boulder == boulder &&
        other.gradeSystem == gradeSystem &&
        listEquals(other.routes, routes) &&
        listEquals(other.warnings, warnings);
  }

  @override
  int get hashCode => Object.hash(
        boulder,
        gradeSystem,
        Object.hashAll(routes),
        Object.hashAll(warnings),
      );
}
