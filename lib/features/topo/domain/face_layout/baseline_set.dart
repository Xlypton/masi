import 'dart:convert';
import 'dart:math' as math;

import 'package:masi/features/topo/domain/face_layout/baseline.dart';

/// Every rock a wall holds, as one drawing.
///
/// A [Baseline] is ONE stroke — one rock's footprint. A crag bay is often not
/// one rock: two boulders a few metres apart, a slab beside the arête, a
/// block that fell off the wall. Before this there was no way to say that;
/// the contributor either drew one line around everything (claiming the gap
/// is climbable rock) or gave up and left the guess in place.
///
/// So the wall's stored stroke became a stroke *set*. Everything below that —
/// arc length, projection, ring-vs-strip, cyclic `t` — stays exactly as it
/// was, per stroke, which is deliberate: that geometry is the delicate part
/// of this feature and it is not touched here. This type only says which
/// strokes exist and which one a thing belongs to.
class BaselineSet {
  const BaselineSet._(this.strokes);

  /// Builds a set from [strokes], dropping any that cannot position anything.
  factory BaselineSet(List<Baseline> strokes) => BaselineSet._(
    List<Baseline>.unmodifiable([
      for (final stroke in strokes)
        if (!stroke.isDegenerate) stroke,
    ]),
  );

  /// One rock, the ordinary case.
  factory BaselineSet.one(Baseline stroke) => BaselineSet([stroke]);

  static const BaselineSet empty = BaselineSet._(<Baseline>[]);

  final List<Baseline> strokes;

  bool get isEmpty => strokes.isEmpty;
  bool get isNotEmpty => strokes.isNotEmpty;
  int get length => strokes.length;

  /// The first rock, or [Baseline.empty] when there is none.
  ///
  /// Everything that predates multiple rocks reads this, and for the
  /// single-rock wall — which is nearly all of them — it is the whole
  /// drawing.
  Baseline get primary => strokes.isEmpty ? Baseline.empty : strokes.first;

  Baseline? at(int index) =>
      index >= 0 && index < strokes.length ? strokes[index] : null;

  /// Which rock a point in the plane is nearest to, or -1 when there is none.
  ///
  /// This is how a photo dragged across the drawing decides which rock it now
  /// belongs to, and how a GPS fix picks its rock without anyone being asked.
  int nearestStrokeTo(LayoutPoint point) {
    var best = -1;
    var bestDistance = double.infinity;
    for (var i = 0; i < strokes.length; i++) {
      final distance = strokes[i].project(point).distance;
      if (distance < bestDistance) {
        bestDistance = distance;
        best = i;
      }
    }
    return best;
  }

  /// A pin, packed into the ONE number the photo row has room for.
  ///
  /// `photos.layoutPinnedT` is a single `REAL`, and naming a rock as well as
  /// a place on it needs two. The integer part is the rock, the fraction is
  /// the place: rock 2, three-quarters along, is `2.75`.
  ///
  /// The alternative was a second column, which means a drift migration on
  /// every installed database plus an `ALTER TABLE` on a live, shared
  /// Postgres — and schema drift between the two is this project's worst
  /// recurring bug class. A number that already exists, whose old values
  /// (`0.0 <= t <= 1.0`) still mean exactly what they always meant, costs
  /// none of that.
  ///
  /// [unpack] is the other half, and the two guarantees that make this safe
  /// live there: a single-rock wall never reinterprets an old pin, and a
  /// packed value can never land exactly on the next rock's zero.
  static double pack(int stroke, double t) {
    final safe = t.isFinite ? t.clamp(0.0, _tCeiling) : 0.0;
    return stroke.clamp(0, 9999) + safe;
  }

  /// The rock and the place on it that [pack] wrote.
  ///
  /// [strokeCount] is what makes this lossless for everything drawn before
  /// rocks could be plural: with one rock the value is passed through
  /// untouched, so a legacy pin of exactly `1.0` still means "the far end of
  /// the wall" rather than "the start of rock 1".
  static ({int stroke, double t}) unpack(double packed, int strokeCount) {
    if (!packed.isFinite) return (stroke: 0, t: 0);
    if (strokeCount <= 1) return (stroke: 0, t: packed);
    final stroke = packed.floor().clamp(0, math.max(0, strokeCount - 1)).toInt();
    return (stroke: stroke, t: packed - packed.floor());
  }

  /// One under a whole number, so [pack] can never produce a value that
  /// [unpack] would read as the NEXT rock's start.
  static const double _tCeiling = 0.999999;

  /// Serialises to the string stored in `Walls.baselineJson`.
  ///
  /// A single rock is written in the EXACT legacy shape — one baseline
  /// object, no wrapper. That is not tidiness: the column is synced, so an
  /// older build of the app reads back what this one writes, and for the
  /// overwhelmingly common single-rock wall it must find something it
  /// understands. Only a wall that genuinely has several rocks gets the
  /// wrapper, and an older build degrades to "no stroke yet" for it, which
  /// re-synthesises a guess rather than showing nothing.
  String encode() {
    if (strokes.isEmpty) return '';
    if (strokes.length == 1) return strokes.first.encode();
    return jsonEncode({
      'v': Baseline.schemaVersion,
      'strokes': [for (final stroke in strokes) stroke.toJson()],
    });
  }

  /// Parses what [encode] wrote — in either shape — or `null` for
  /// absent/unparseable/foreign data. Never throws, for the same reason
  /// [Baseline.decode] does not: a drawing is a hint, and the app is fully
  /// usable without one.
  static BaselineSet? decode(String? source) {
    if (source == null || source.isEmpty) return null;

    // The legacy shape first: it is what nearly every row holds.
    final single = Baseline.decode(source);
    if (single != null) return BaselineSet([single]);

    try {
      final decoded = jsonDecode(source);
      if (decoded is! Map) return null;
      final raw = decoded['strokes'];
      if (raw is! List || raw.isEmpty) return null;
      final parsed = <Baseline>[];
      for (final entry in raw) {
        final stroke = Baseline.decodeJson(entry);
        if (stroke == null) return null;
        parsed.add(stroke);
      }
      final set = BaselineSet(parsed);
      return set.isEmpty ? null : set;
    } catch (_) {
      return null;
    }
  }

  @override
  String toString() => 'BaselineSet(${strokes.length} strokes)';
}
