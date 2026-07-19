/// Curated + custom climbing style tags for routes, plus (de)serialization
/// helpers for storing a route's tag list in a single Drift TEXT column.
///
/// This file has NO Flutter UI dependency (no `material.dart` /
/// `widgets.dart`) so it can be used from any layer, including tests and
/// non-UI code, mirroring `lib/core/grades/grade_system.dart`.
///
/// A route may carry MULTIPLE style tags (e.g. `dyno` + `crimpy` +
/// `juggy`). The tag set is "curated + custom": [kCuratedRouteStyles] is a
/// predefined list with stable `key`s used for storage/filtering, but a
/// route's tag list may also contain arbitrary user-typed custom strings
/// that aren't in the curated list — those still round-trip and display,
/// just without a curated [RouteStyle.label]/icon.
library;

import 'dart:convert';

/// A single curated climbing style descriptor.
///
/// [key] is the stable, lowercase identifier used for storage (in the
/// serialized tag list) and filtering — it must never change once shipped,
/// since existing stored routes reference it. [label] is the human-facing
/// display string. [iconName] is the bare MasiIcon asset name (e.g.
/// `'dyno'` for `assets/icons/masi/masi_dyno.svg`) and is only set when a
/// matching asset is confirmed to exist; otherwise it is `null` and callers
/// should render a plain text chip instead of an icon.
class RouteStyle {
  final String key;
  final String label;
  final String? iconName;

  const RouteStyle({required this.key, required this.label, this.iconName});

  @override
  String toString() => 'RouteStyle($key)';
}

/// The curated climbing style set, in display order.
///
/// None of these currently have a confirmed matching MasiIcon asset under
/// `assets/icons/masi/` (checked against the existing SVG listing), so
/// every [RouteStyle.iconName] here is `null` — callers render these as
/// plain text/label chips. Add an `iconName` only once a matching
/// `masi_<name>.svg` asset actually exists.
const List<RouteStyle> kCuratedRouteStyles = [
  RouteStyle(key: 'dyno', label: 'Dyno'),
  RouteStyle(key: 'crimpy', label: 'Crimpy'),
  RouteStyle(key: 'juggy', label: 'Juggy'),
  RouteStyle(key: 'slabby', label: 'Slabby'),
  RouteStyle(key: 'overhang', label: 'Overhang'),
  RouteStyle(key: 'technical', label: 'Technical'),
  RouteStyle(key: 'powerful', label: 'Powerful'),
  RouteStyle(key: 'sloper', label: 'Sloper'),
  RouteStyle(key: 'pinchy', label: 'Pinchy'),
  RouteStyle(key: 'mantle', label: 'Mantle'),
  RouteStyle(key: 'dihedral', label: 'Dihedral'),
  RouteStyle(key: 'dynamic', label: 'Dynamic'),
  RouteStyle(key: 'static', label: 'Static'),
  RouteStyle(key: 'endurance', label: 'Endurance'),
  RouteStyle(key: 'balancey', label: 'Balancey'),
  RouteStyle(key: 'compression', label: 'Compression'),
  RouteStyle(key: 'heel-hook', label: 'Heel Hook'),
  RouteStyle(key: 'toe-hook', label: 'Toe Hook'),
];

/// Looks up a curated style by its stable [key] (case-sensitive; stored
/// keys are always produced lowercase by [encodeStyleTags]/normalization
/// below). Returns `null` when [key] is not a curated style — including
/// arbitrary custom tags, which is the expected/normal case for those.
RouteStyle? curatedStyleForKey(String key) {
  for (final style in kCuratedRouteStyles) {
    if (style.key == key) return style;
  }
  return null;
}

/// Normalizes a single raw tag for storage/comparison: trims surrounding
/// whitespace and lowercases it (curated keys are already lowercase;
/// custom tags are folded to lowercase too so filtering/de-dup is
/// case-insensitive and consistent).
String _normalizeTag(String raw) => raw.trim().toLowerCase();

/// Encodes a route's style [tags] into a single storage string (a JSON
/// array of strings) for a Drift TEXT column.
///
/// Each tag is trimmed and lowercased; empty tags (after trimming) are
/// dropped; duplicates are removed case-insensitively, keeping the FIRST
/// occurrence's position, so input order is otherwise preserved. An empty
/// resulting list still encodes as `'[]'` (never as an empty string), so
/// [decodeStyleTags] can round-trip it losslessly.
String encodeStyleTags(List<String> tags) {
  final seen = <String>{};
  final cleaned = <String>[];
  for (final raw in tags) {
    final normalized = _normalizeTag(raw);
    if (normalized.isEmpty) continue;
    if (!seen.add(normalized)) continue;
    cleaned.add(normalized);
  }
  return jsonEncode(cleaned);
}

/// Decodes a stored style-tags string (as produced by [encodeStyleTags])
/// back into a list of tag strings.
///
/// Never throws: `null`, empty, or malformed/non-JSON-array input all
/// return `const []`. Defensive against future/foreign data too — any
/// decoded element that isn't a string is skipped rather than throwing.
List<String> decodeStyleTags(String? stored) {
  if (stored == null || stored.trim().isEmpty) return const [];
  try {
    final decoded = jsonDecode(stored);
    if (decoded is! List) return const [];
    return [for (final e in decoded) if (e is String) e];
  } catch (_) {
    return const [];
  }
}

/// A single decoded style tag paired with its curated definition (if any).
///
/// Used for display: `style` is non-null for a curated tag (render its
/// icon/label), and `null` for a custom tag (render [raw] as a plain-text
/// chip instead).
class ResolvedRouteStyle {
  final RouteStyle? style;
  final String raw;

  const ResolvedRouteStyle({required this.style, required this.raw});

  /// True when this tag is a curated style (i.e. [style] is non-null).
  bool get isCurated => style != null;

  /// The label to display: the curated [RouteStyle.label] when curated,
  /// otherwise the raw stored string itself.
  String get displayLabel => style?.label ?? raw;
}

/// Splits a single stored tag string into its curated [RouteStyle] (or
/// `null` if it's a custom tag) paired with the raw stored string, for
/// display as a chip.
///
/// This is a pure lookup over one already-decoded tag; callers typically
/// map this over the result of [decodeStyleTags].
ResolvedRouteStyle resolveStyleTag(String tag) {
  return ResolvedRouteStyle(style: curatedStyleForKey(tag), raw: tag);
}
