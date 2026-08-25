import 'dart:convert';
import 'dart:ui';

import 'package:flutter/foundation.dart';

import '../../../core/grades/grade_system.dart';
import '../domain/guidebook_import.dart';

/// Decodes the guidebook-import payload.
///
/// Every function here treats its input as hostile. The payload is written by
/// a language model reading a photograph of a book page, so it can be
/// truncated, malformed, or confidently wrong in any field. The contract is
/// that a bad payload **degrades** — fields drop to `null`, routes become
/// unplaced, warnings accumulate — and only a payload that cannot be
/// identified at all is rejected outright.

/// The outcome of a decode attempt.
@immutable
sealed class ImportDecodeResult {
  const ImportDecodeResult();
}

/// The payload was understood. [import] may still carry warnings.
@immutable
class ImportDecoded extends ImportDecodeResult {
  const ImportDecoded(this.import);

  final GuidebookImport import;
}

/// The payload could not be identified as a guidebook import at all, so
/// nothing was decoded and nothing should be written.
@immutable
class ImportRejected extends ImportDecodeResult {
  const ImportRejected(this.message);

  /// Shown to the user verbatim, so it must read as an explanation rather
  /// than a parser error.
  final String message;
}

/// Decodes a deep link's `?d=` parameter: base64url-encoded UTF-8 JSON.
///
/// Accepts both base64 alphabets and tolerates missing `=` padding, because
/// the encoder is a language model writing a URL by hand and both are common.
ImportDecodeResult decodeGuidebookImportLink(String encoded) {
  final trimmed = encoded.trim();
  if (trimmed.isEmpty) {
    return const ImportRejected('That import link is empty.');
  }
  final String jsonText;
  try {
    jsonText = utf8.decode(base64.decode(base64.normalize(trimmed)));
  } on FormatException {
    return const ImportRejected(
      "That import link is damaged — it may have been cut short when it was "
      "copied. Try pasting the import text instead.",
    );
  }
  return decodeGuidebookImportJson(jsonText);
}

/// Decodes raw JSON text, as pasted into the import box.
ImportDecodeResult decodeGuidebookImportJson(String jsonText) {
  final trimmed = jsonText.trim();
  if (trimmed.isEmpty) {
    return const ImportRejected('There is nothing to import yet.');
  }
  final Object? parsed;
  try {
    parsed = jsonDecode(trimmed);
  } on FormatException {
    return const ImportRejected(
      "That doesn't look like import text. Copy the whole reply from your "
      "chat app, including the opening and closing braces.",
    );
  }
  if (parsed is! Map<String, Object?>) {
    return const ImportRejected(
      "That import text is the wrong shape — it should start with '{'.",
    );
  }
  return decodeGuidebookImportMap(parsed);
}

/// Decodes an already-parsed JSON object.
ImportDecodeResult decodeGuidebookImportMap(Map<String, Object?> map) {
  final version = map['v'];
  if (version is! int) {
    return const ImportRejected(
      "That import text is missing its version marker, so it can't be read "
      'safely. Ask your chat app to generate it again.',
    );
  }
  if (version != kImportPayloadVersion) {
    return ImportRejected(
      'That import was made for a different version of Masi (v$version, this '
      'app reads v$kImportPayloadVersion). Update the app, or ask your chat '
      'app to generate it again.',
    );
  }

  final rawRoutes = map['routes'];
  if (rawRoutes is! List || rawRoutes.isEmpty) {
    return const ImportRejected(
      "No routes were found in that import. The chat app may not have been "
      'able to read the page.',
    );
  }

  final warnings = <ImportWarning>[];

  final gradeSystem = _gradeSystem(map['gradeSystem'], warnings);
  final boulder = _text(
    map['boulder'],
    cap: kMaxImportedNameChars,
    field: 'boulder name',
    warnings: warnings,
  );

  var entries = rawRoutes;
  if (entries.length > kMaxImportedRoutes) {
    warnings.add(
      ImportWarning(
        kind: ImportWarningKind.tooManyRoutes,
        detail:
            'The import listed ${entries.length} routes; only the first '
            '$kMaxImportedRoutes were kept.',
      ),
    );
    entries = entries.sublist(0, kMaxImportedRoutes);
  }

  final routes = <ImportedRoute>[];
  for (final entry in entries) {
    if (entry is! Map<String, Object?>) {
      warnings.add(
        ImportWarning(
          kind: ImportWarningKind.droppedRoute,
          detail: 'One entry in the list was not a route and was skipped.',
          routeNumber: routes.length + 1,
        ),
      );
      continue;
    }
    // Numbering is positional, not payload-supplied: the book's own numbers
    // may skip, repeat, or restart per sector, and `RouteRepository` keys
    // routes on `(photoId, number)`, so a duplicate would overwrite a sibling.
    routes.add(_route(entry, routes.length + 1, gradeSystem, warnings));
  }

  if (routes.isEmpty) {
    return const ImportRejected(
      'None of the entries in that import could be read as routes.',
    );
  }

  return ImportDecoded(
    GuidebookImport(
      boulder: boulder,
      gradeSystem: gradeSystem,
      routes: List.unmodifiable(routes),
      warnings: List.unmodifiable(warnings),
    ),
  );
}

ImportedRoute _route(
  Map<String, Object?> map,
  int number,
  GradeSystem? system,
  List<ImportWarning> warnings,
) {
  final name = _text(
    map['name'],
    cap: kMaxImportedNameChars,
    field: 'name',
    warnings: warnings,
    routeNumber: number,
  );
  final gradeRaw = _text(
    map['gradeRaw'],
    cap: kMaxImportedNameChars,
    field: 'grade',
    warnings: warnings,
    routeNumber: number,
  );
  final description = _text(
    map['description'],
    cap: kMaxImportedDescriptionChars,
    field: 'description',
    warnings: warnings,
    routeNumber: number,
  );
  final positionHint = _text(
    map['positionHint'],
    cap: kMaxImportedHintChars,
    field: 'position hint',
    warnings: warnings,
    routeNumber: number,
  );

  // Only judge the grade when a ladder is known. With no system the token is
  // carried untouched and re-judged when the review sheet's dropdown lands —
  // warning here would flag every route on a page whose system the model
  // simply failed to name.
  if (system != null && gradeRaw != null && !isValidGrade(system, gradeRaw)) {
    warnings.add(
      ImportWarning(
        kind: ImportWarningKind.invalidGrade,
        detail: "'$gradeRaw' is not a ${system.name} grade, so it was left "
            'blank.',
        routeNumber: number,
      ),
    );
  }

  final points = _points(map['points'], number, warnings);

  return ImportedRoute(
    number: number,
    name: name,
    gradeRaw: gradeRaw,
    stars: _stars(map['stars']),
    description: description,
    positionHint: positionHint,
    points: points,
  );
}

/// Parses the polyline, or returns empty for "unplaced".
///
/// A non-finite coordinate voids the whole line rather than just its own
/// point: a NaN means the model was not actually reading a position, so the
/// neighbouring points are not trustworthy either, and a silently-repaired
/// line is worse than an honestly absent one. Out-of-range but finite
/// coordinates are merely clamped — those are a model overshooting the frame,
/// which is a correctable near-miss rather than nonsense.
List<Offset> _points(
  Object? raw,
  int number,
  List<ImportWarning> warnings,
) {
  void unplaced(String why) {
    warnings.add(
      ImportWarning(
        kind: ImportWarningKind.unplacedGeometry,
        detail: why,
        routeNumber: number,
      ),
    );
  }

  if (raw == null) {
    unplaced('No line was given, so this route is yours to draw.');
    return const [];
  }
  if (raw is! List) {
    unplaced("The line couldn't be read, so this route is yours to draw.");
    return const [];
  }

  var pairs = raw;
  if (pairs.length > kMaxImportedPoints) {
    warnings.add(
      ImportWarning(
        kind: ImportWarningKind.tooManyPoints,
        detail: 'The line had ${pairs.length} points; only the first '
            '$kMaxImportedPoints were kept.',
        routeNumber: number,
      ),
    );
    pairs = pairs.sublist(0, kMaxImportedPoints);
  }

  final points = <Offset>[];
  var clamped = false;
  for (final pair in pairs) {
    if (pair is! List || pair.length < 2) {
      unplaced("The line couldn't be read, so this route is yours to draw.");
      return const [];
    }
    final x = pair[0];
    final y = pair[1];
    if (x is! num || y is! num || !x.isFinite || !y.isFinite) {
      unplaced("The line's position didn't make sense, so this route is "
          'yours to draw.');
      return const [];
    }
    final cx = x.toDouble().clamp(0.0, 1.0);
    final cy = y.toDouble().clamp(0.0, 1.0);
    if (cx != x.toDouble() || cy != y.toDouble()) clamped = true;
    points.add(Offset(cx, cy));
  }

  if (points.length < 2) {
    unplaced('The line had too few points, so this route is yours to draw.');
    return const [];
  }
  if (clamped) {
    warnings.add(
      ImportWarning(
        kind: ImportWarningKind.clampedPoint,
        detail: 'Part of the line fell outside the photo and was pulled back '
            'onto it.',
        routeNumber: number,
      ),
    );
  }
  return List.unmodifiable(points);
}

GradeSystem? _gradeSystem(Object? raw, List<ImportWarning> warnings) {
  if (raw is String) {
    final needle = raw.trim().toLowerCase();
    for (final system in GradeSystem.values) {
      if (system.name == needle) return system;
    }
    // 'font'/'fontainebleau' are what a model reading a bouldering guide is
    // most likely to write; the ladder itself is the French one.
    if (needle == 'font' || needle == 'fontainebleau') {
      return GradeSystem.french;
    }
  }
  warnings.add(
    const ImportWarning(
      kind: ImportWarningKind.unknownGradeSystem,
      detail: "The grading system wasn't clear from the page — pick it below "
          'and the grades will fill in.',
    ),
  );
  return null;
}

int? _stars(Object? raw) {
  if (raw is! num || !raw.isFinite) return null;
  final rounded = raw.round();
  if (rounded < 0 || rounded > 3) return null;
  return rounded;
}

String? _text(
  Object? raw, {
  required int cap,
  required String field,
  required List<ImportWarning> warnings,
  int? routeNumber,
}) {
  if (raw is! String) return null;
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  if (trimmed.length <= cap) return trimmed;
  warnings.add(
    ImportWarning(
      kind: ImportWarningKind.truncatedText,
      detail: 'The $field was longer than $cap characters and was shortened.',
      routeNumber: routeNumber,
    ),
  );
  return trimmed.substring(0, cap);
}
