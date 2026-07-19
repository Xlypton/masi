import 'dart:ui';

import 'package:flutter/foundation.dart';

import '../../../core/grades/grade_system.dart';

/// The kind of marker rendered at a point on a [TopoRoute].
enum SymbolType { anchor, bolt, top, crux, rest }

/// A single marker (e.g. bolt, anchor) placed on a route, in percent space.
@immutable
class TopoSymbol {
  const TopoSymbol({required this.type, required this.position});

  final SymbolType type;
  final Offset position;

  TopoSymbol copyWith({SymbolType? type, Offset? position}) {
    return TopoSymbol(
      type: type ?? this.type,
      position: position ?? this.position,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is TopoSymbol &&
        other.type == type &&
        other.position == position;
  }

  @override
  int get hashCode => Object.hash(type, position);
}

/// An immutable, drawn climbing route: an ordered list of points plus any
/// symbols placed along it, expressed in percent space (coordinates
/// normalized to the image's width/height) so they stay valid regardless of
/// how the image is scaled or panned on screen.
@immutable
class TopoRoute {
  const TopoRoute({
    required this.id,
    required this.number,
    required this.points,
    this.symbols = const [],
    this.colorIndex = 0,
    this.visible = true,
    this.name,
    this.gradeSystem,
    this.gradeRaw,
    this.gradeSortKey,
    this.style,
    this.description,
    this.betaVideoUrl,
    this.styleTags = const [],
    this.stars,
  });

  final int id;
  final int number;
  final List<Offset> points;
  final List<TopoSymbol> symbols;
  final int colorIndex;
  final bool visible;

  /// Free-form display name for the route (e.g. "Le Toit"). Null if unset.
  final String? name;

  /// Which grading ladder [gradeRaw] belongs to. Null if no grade has been
  /// assigned yet.
  final GradeSystem? gradeSystem;

  /// The grade token as entered by the user (e.g. `'6a+'`, `'VII-'`), in
  /// [gradeSystem]'s notation. Null if no grade has been assigned yet.
  final String? gradeRaw;

  /// Precomputed shared-scale sort key for [gradeRaw] (see
  /// `core/grades/grade_system.dart`'s `gradeSortKey`), cached here so
  /// routes can be sorted/filtered by difficulty without recomputing it.
  /// Null if no grade has been assigned yet.
  final double? gradeSortKey;

  /// Free-form climbing style label, by convention one of `'sport'`,
  /// `'trad'`, `'boulder'` — not an enum, so new styles don't require a
  /// domain change. Null if unset.
  final String? style;

  /// Free-form route description/beta notes. Null if unset.
  final String? description;

  /// External beta-video URL (e.g. a YouTube/Instagram link). Null if
  /// unset. Not validated at the domain layer — see `RouteMetadataSheet`
  /// for the basic http(s) client-side check applied before this is set.
  final String? betaVideoUrl;

  /// This route's style tags (curated + custom, see
  /// `core/routes/route_styles.dart`). Empty (never null) when the route
  /// has no tags.
  final List<String> styleTags;

  /// 0-3 star quality rating. Null means unrated (distinct from `0`, an
  /// explicit "0 stars" rating).
  final int? stars;

  /// Returns a copy with the given fields replaced.
  ///
  /// Nullable-handling choice: non-metadata fields (`id`, `number`,
  /// `points`, `symbols`, `colorIndex`, `visible`) use the standard
  /// `newValue ?? this.field` pattern.
  ///
  /// Metadata fields (`name`, `gradeSystem`, `gradeRaw`, `gradeSortKey`,
  /// `style`, `description`, `betaVideoUrl`, `styleTags`, `stars`) each
  /// have an explicit set-sentinel flag (`nameSet`, `gradeSystemSet`,
  /// `gradeRawSet`, `setGradeSortKey`, `styleSet`, `descriptionSet`,
  /// `betaVideoUrlSet`, `styleTagsSet`, `starsSet`), mirroring the original
  /// `setGradeSortKey` design: when a sentinel is `true`, the corresponding
  /// value is used verbatim (including `null`, which clears the field).
  /// When `false` (the default for every sentinel), the usual
  /// `value ?? this.field` behavior applies, so existing call sites that
  /// don't pass a sentinel are unaffected. This lets [DrawController
  /// .setRouteMetadata] treat the metadata sheet's save as authoritative —
  /// an omitted/cleared field on the sheet actually clears it on the route
  /// — while every other caller keeps the old "null means unchanged"
  /// behavior.
  TopoRoute copyWith({
    int? id,
    int? number,
    List<Offset>? points,
    List<TopoSymbol>? symbols,
    int? colorIndex,
    bool? visible,
    String? name,
    bool nameSet = false,
    GradeSystem? gradeSystem,
    bool gradeSystemSet = false,
    String? gradeRaw,
    bool gradeRawSet = false,
    double? gradeSortKey,
    bool setGradeSortKey = false,
    String? style,
    bool styleSet = false,
    String? description,
    bool descriptionSet = false,
    String? betaVideoUrl,
    bool betaVideoUrlSet = false,
    List<String>? styleTags,
    bool styleTagsSet = false,
    int? stars,
    bool starsSet = false,
  }) {
    return TopoRoute(
      id: id ?? this.id,
      number: number ?? this.number,
      points: points ?? this.points,
      symbols: symbols ?? this.symbols,
      colorIndex: colorIndex ?? this.colorIndex,
      visible: visible ?? this.visible,
      name: nameSet ? name : (name ?? this.name),
      gradeSystem: gradeSystemSet ? gradeSystem : (gradeSystem ?? this.gradeSystem),
      gradeRaw: gradeRawSet ? gradeRaw : (gradeRaw ?? this.gradeRaw),
      gradeSortKey:
          setGradeSortKey ? gradeSortKey : (gradeSortKey ?? this.gradeSortKey),
      style: styleSet ? style : (style ?? this.style),
      description: descriptionSet ? description : (description ?? this.description),
      betaVideoUrl:
          betaVideoUrlSet ? betaVideoUrl : (betaVideoUrl ?? this.betaVideoUrl),
      styleTags: styleTagsSet ? (styleTags ?? const []) : (styleTags ?? this.styleTags),
      stars: starsSet ? stars : (stars ?? this.stars),
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is TopoRoute &&
        other.id == id &&
        other.number == number &&
        listEquals(other.points, points) &&
        listEquals(other.symbols, symbols) &&
        other.colorIndex == colorIndex &&
        other.visible == visible &&
        other.name == name &&
        other.gradeSystem == gradeSystem &&
        other.gradeRaw == gradeRaw &&
        other.gradeSortKey == gradeSortKey &&
        other.style == style &&
        other.description == description &&
        other.betaVideoUrl == betaVideoUrl &&
        listEquals(other.styleTags, styleTags) &&
        other.stars == stars;
  }

  @override
  int get hashCode => Object.hash(
        id,
        number,
        Object.hashAll(points),
        Object.hashAll(symbols),
        colorIndex,
        visible,
        name,
        gradeSystem,
        gradeRaw,
        gradeSortKey,
        style,
        description,
        betaVideoUrl,
        Object.hashAll(styleTags),
        stars,
      );
}

/// Number of distinct colors in the route palette; route colors cycle
/// through the palette as more routes are added.
const int kRoutePaletteLength = 8;

/// Maps a 1-based route [number] to a stable palette index, wrapping around
/// once the number exceeds [kRoutePaletteLength].
int routeColorIndexFor(int number) => (number - 1) % kRoutePaletteLength;
