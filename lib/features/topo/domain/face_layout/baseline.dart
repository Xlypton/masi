import 'dart:convert';
import 'dart:math' as math;

/// A point on the layout plane.
///
/// The plane is metres **east** ([x]) and **north** ([y]) of the owning
/// wall's anchor (`Walls.latitude`/`Walls.longitude`, itself captured from
/// the first photo's EXIF GPS). Metres rather than pixels or a normalised box
/// because the whole point of the plane is that a photo's GPS fix can be
/// projected onto a line drawn in it; a normalised space would need a
/// separate similarity fit before any GPS number meant anything.
///
/// A wall with **no** GPS anywhere still gets a baseline — synthesised as a
/// plain segment or ring (see `baseline_synthesis.dart`). Its units are then
/// arbitrary-but-consistent: nothing metric is ever compared against it,
/// because there is no GPS to compare, and only the ORDER of faces along it
/// is read. That is deliberate — decision §3's "the ordered filmstrip alone
/// is a valid topo" falls out of it rather than being special-cased.
class LayoutPoint {
  const LayoutPoint(this.x, this.y);

  final double x;
  final double y;

  LayoutPoint operator +(LayoutPoint o) => LayoutPoint(x + o.x, y + o.y);
  LayoutPoint operator -(LayoutPoint o) => LayoutPoint(x - o.x, y - o.y);
  LayoutPoint operator *(double k) => LayoutPoint(x * k, y * k);

  double get length => math.sqrt(x * x + y * y);

  double distanceTo(LayoutPoint o) => (this - o).length;

  double dot(LayoutPoint o) => x * o.x + y * o.y;

  /// This vector scaled to unit length, or `null` when it has no direction.
  /// Nullable rather than returning a zero/arbitrary vector so a caller can
  /// never silently treat "no direction" as "pointing east".
  LayoutPoint? get normalized {
    final l = length;
    if (l == 0 || !l.isFinite) return null;
    return LayoutPoint(x / l, y / l);
  }

  bool get isFinite => x.isFinite && y.isFinite;

  @override
  bool operator ==(Object other) =>
      other is LayoutPoint && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);

  @override
  String toString() =>
      'LayoutPoint(${x.toStringAsFixed(2)}, ${y.toStringAsFixed(2)})';
}

/// Where a projection landed on a baseline.
typedef BaselineProjection = ({double t, double distance});

/// The semantic baseline: the rock's footprint as a polyline, plus whether
/// that polyline closes on itself.
///
/// [closed] is the ONLY thing that distinguishes a boulder from a wall in
/// this model, which is why no part of the UI ever asks the question — the
/// contributor closes a stroke or does not, exactly as they would with any
/// polygon tool (design 4b: "no topology control exists"). Everything
/// downstream — cyclic vs clamped parameterisation, ring vs strip rendering,
/// whether face 7 is adjacent to face 1 — reads it from here.
class Baseline {
  /// Builds a baseline from [points], dropping consecutive duplicates.
  ///
  /// Duplicates are dropped rather than tolerated because a zero-length
  /// segment has no tangent, and a tangent of `null` in the middle of a
  /// stroke would have to be special-cased by every renderer instead of once
  /// here.
  factory Baseline(List<LayoutPoint> points, {bool closed = false}) {
    final cleaned = <LayoutPoint>[];
    for (final p in points) {
      if (!p.isFinite) continue;
      if (cleaned.isNotEmpty && cleaned.last.distanceTo(p) < _epsilon) continue;
      cleaned.add(p);
    }
    // A closed stroke whose last point IS its first would otherwise carry a
    // duplicate vertex and a zero-length closing segment.
    if (closed &&
        cleaned.length > 1 &&
        cleaned.first.distanceTo(cleaned.last) < _epsilon) {
      cleaned.removeLast();
    }
    return Baseline._(
      List<LayoutPoint>.unmodifiable(cleaned),
      // Two points cannot enclose anything; a "closed" 2-point stroke would
      // parameterise as an out-and-back, which reads as a loop to every
      // caller and is not one.
      closed && cleaned.length >= 3,
    );
  }

  const Baseline._(this.points, this.closed);

  static const double _epsilon = 1e-9;

  /// Current on-disk shape of [encode]. Bumped only if the shape changes;
  /// [decode] refuses anything it does not recognise rather than guessing.
  static const int schemaVersion = 1;

  final List<LayoutPoint> points;

  /// True when the last point joins back to the first — a boulder or a ring
  /// rather than a wall strip.
  final bool closed;

  /// A baseline with no geometry at all. Distinct from `null`: a wall whose
  /// stroke could not be synthesised still has *a* baseline object to render
  /// nothing from, and [isDegenerate] says so.
  static const Baseline empty = Baseline._(<LayoutPoint>[], false);

  /// True when this baseline cannot position anything — fewer than two
  /// points, or every point in the same place.
  bool get isDegenerate => points.length < 2 || totalLength <= _epsilon;

  /// Number of segments, counting the closing one when [closed].
  int get segmentCount =>
      points.length < 2 ? 0 : (closed ? points.length : points.length - 1);

  LayoutPoint _vertex(int i) => points[i % points.length];

  /// Length of each segment, in the same order as [segmentCount].
  List<double> get segmentLengths => [
    for (var i = 0; i < segmentCount; i++)
      _vertex(i).distanceTo(_vertex(i + 1)),
  ];

  double get totalLength {
    var sum = 0.0;
    for (final l in segmentLengths) {
      sum += l;
    }
    return sum;
  }

  /// Brings [t] into range: **wrapped** for a closed baseline (t=1.2 is the
  /// same place as t=0.2), **clamped** for an open one.
  ///
  /// This single method is why nothing downstream has to branch on [closed]
  /// to do arithmetic on positions.
  double normalizeT(double t) {
    if (!t.isFinite) return 0;
    if (!closed) return t.clamp(0.0, 1.0);
    final wrapped = t % 1.0;
    return wrapped < 0 ? wrapped + 1.0 : wrapped;
  }

  /// Shortest signed step from [a] to [b] along the line, in `t` units.
  ///
  /// On a closed baseline that is the shorter way round, so the result is in
  /// [-0.5, 0.5]; on an open one it is plain `b - a`.
  double signedDelta(double a, double b) {
    final d = normalizeT(b) - normalizeT(a);
    if (!closed) return d;
    if (d > 0.5) return d - 1.0;
    if (d < -0.5) return d + 1.0;
    return d;
  }

  /// The point at arc-length fraction [t].
  LayoutPoint pointAt(double t) {
    if (points.isEmpty) return const LayoutPoint(0, 0);
    if (isDegenerate) return points.first;
    final target = normalizeT(t) * totalLength;
    var travelled = 0.0;
    final lengths = segmentLengths;
    for (var i = 0; i < lengths.length; i++) {
      final segment = lengths[i];
      if (segment <= _epsilon) continue;
      if (travelled + segment >= target || i == lengths.length - 1) {
        final local = ((target - travelled) / segment).clamp(0.0, 1.0);
        final a = _vertex(i);
        final b = _vertex(i + 1);
        return a + (b - a) * local;
      }
      travelled += segment;
    }
    return points.last;
  }

  /// Unit tangent at [t], pointing along increasing `t`, or `null` on a
  /// degenerate baseline.
  LayoutPoint? tangentAt(double t) {
    if (isDegenerate) return null;
    final target = normalizeT(t) * totalLength;
    var travelled = 0.0;
    final lengths = segmentLengths;
    for (var i = 0; i < lengths.length; i++) {
      final segment = lengths[i];
      if (segment <= _epsilon) continue;
      if (travelled + segment >= target || i == lengths.length - 1) {
        return (_vertex(i + 1) - _vertex(i)).normalized;
      }
      travelled += segment;
    }
    return null;
  }

  /// Unit normal at [t] — the tangent turned 90° left (towards +y from +x).
  ///
  /// Which SIDE of the line a thumbnail sits on is chosen by the caller from
  /// this plus the object's orientation (see `LayoutOrientation`); the normal
  /// itself carries no opinion about inside and outside.
  LayoutPoint? normalAt(double t) {
    final tangent = tangentAt(t);
    if (tangent == null) return null;
    return LayoutPoint(-tangent.y, tangent.x);
  }

  /// Nearest position on the line to [p], as `t` plus the distance to it.
  ///
  /// This is how a GPS fix becomes a position along the rock (§5 step 3b) and
  /// how a thumbnail drag snaps back onto the stroke.
  BaselineProjection project(LayoutPoint p) {
    if (points.isEmpty) return (t: 0.0, distance: double.infinity);
    if (isDegenerate) {
      return (t: 0.0, distance: points.first.distanceTo(p));
    }
    final lengths = segmentLengths;
    final total = totalLength;
    var travelled = 0.0;
    var bestT = 0.0;
    var bestDistance = double.infinity;
    for (var i = 0; i < lengths.length; i++) {
      final segment = lengths[i];
      if (segment > _epsilon) {
        final a = _vertex(i);
        final b = _vertex(i + 1);
        final ab = b - a;
        final local = (((p - a).dot(ab)) / (segment * segment)).clamp(0.0, 1.0);
        final foot = a + ab * local;
        final distance = foot.distanceTo(p);
        if (distance < bestDistance) {
          bestDistance = distance;
          bestT = (travelled + local * segment) / total;
        }
      }
      travelled += segment;
    }
    return (t: normalizeT(bestT), distance: bestDistance);
  }

  /// Length-weighted centre of the stroke.
  ///
  /// Weighted by segment length rather than a plain vertex average so a
  /// hand-drawn stroke with a cluster of points in one corner — which is what
  /// a slow finger produces — does not drag the centre into that corner.
  /// The centre decides inward-vs-outward orientation, so a wrong one flips
  /// which side of the line every thumbnail renders on.
  LayoutPoint get centroid {
    if (points.isEmpty) return const LayoutPoint(0, 0);
    if (isDegenerate) return points.first;
    var sum = const LayoutPoint(0, 0);
    var weight = 0.0;
    final lengths = segmentLengths;
    for (var i = 0; i < lengths.length; i++) {
      final l = lengths[i];
      if (l <= _epsilon) continue;
      final mid = (_vertex(i) + _vertex(i + 1)) * 0.5;
      sum = sum + mid * l;
      weight += l;
    }
    if (weight <= _epsilon) return points.first;
    return sum * (1 / weight);
  }

  /// The stroke's bounding box, as `(minX, minY, maxX, maxY)`.
  ({double minX, double minY, double maxX, double maxY}) get bounds {
    if (points.isEmpty) return (minX: 0.0, minY: 0.0, maxX: 0.0, maxY: 0.0);
    var minX = points.first.x, maxX = points.first.x;
    var minY = points.first.y, maxY = points.first.y;
    for (final p in points) {
      minX = math.min(minX, p.x);
      maxX = math.max(maxX, p.x);
      minY = math.min(minY, p.y);
      maxY = math.max(maxY, p.y);
    }
    return (minX: minX, minY: minY, maxX: maxX, maxY: maxY);
  }

  /// Longest edge of [bounds] — the stroke's scale, used to turn absolute
  /// snap/closure distances into proportional ones.
  double get extent {
    final b = bounds;
    return math.max(b.maxX - b.minX, b.maxY - b.minY);
  }

  /// A copy with [closed] set — the ring-closure gesture's whole effect on
  /// the data.
  Baseline withClosed(bool value) => Baseline(points, closed: value);

  /// Ramer–Douglas–Peucker simplification with [tolerance] in plane units.
  ///
  /// Run on hand-drawn strokes before storing: a finger produces hundreds of
  /// points, every one of which would ride the sync engine's full-row re-push
  /// (decision D-4) on every future edit to any other column of the wall.
  Baseline simplified(double tolerance) {
    if (points.length <= 2 || tolerance <= 0) return this;
    final keep = List<bool>.filled(points.length, false);
    keep[0] = true;
    keep[points.length - 1] = true;
    _simplifyRange(0, points.length - 1, tolerance, keep);
    return Baseline(
      [for (var i = 0; i < points.length; i++) if (keep[i]) points[i]],
      closed: closed,
    );
  }

  void _simplifyRange(int first, int last, double tolerance, List<bool> keep) {
    if (last <= first + 1) return;
    final a = points[first];
    final b = points[last];
    final ab = b - a;
    final abLength = ab.length;
    var worst = -1.0;
    var worstIndex = -1;
    for (var i = first + 1; i < last; i++) {
      final p = points[i];
      final double distance;
      if (abLength <= _epsilon) {
        distance = p.distanceTo(a);
      } else {
        distance = ((p - a).x * ab.y - (p - a).y * ab.x).abs() / abLength;
      }
      if (distance > worst) {
        worst = distance;
        worstIndex = i;
      }
    }
    if (worst <= tolerance || worstIndex < 0) return;
    keep[worstIndex] = true;
    _simplifyRange(first, worstIndex, tolerance, keep);
    _simplifyRange(worstIndex, last, tolerance, keep);
  }

  Map<String, Object?> toJson() => {
    'v': schemaVersion,
    'closed': closed,
    // Rounded to the millimetre. A GPS fix is good to metres at best, a
    // finger to less, so further digits are noise that costs sync bytes on
    // every push.
    'pts': [
      for (final p in points)
        [_round(p.x), _round(p.y)],
    ],
  };

  static double _round(double v) => (v * 1000).roundToDouble() / 1000;

  /// Serialises to the string stored in `Walls.baselineJson`.
  String encode() => jsonEncode(toJson());

  /// Parses what [encode] wrote, or `null` for absent/unparseable/foreign
  /// data.
  ///
  /// Never throws. A baseline is a hint about how photos are arranged, and
  /// the app is fully usable without one, so a corrupt value degrades to "no
  /// baseline yet" — which auto-synthesis then fills in — rather than taking
  /// out the topo screen.
  static Baseline? decode(String? source) {
    if (source == null || source.isEmpty) return null;
    try {
      final decoded = jsonDecode(source);
      if (decoded is! Map) return null;
      if (decoded['v'] != schemaVersion) return null;
      final raw = decoded['pts'];
      if (raw is! List) return null;
      final parsed = <LayoutPoint>[];
      for (final entry in raw) {
        if (entry is! List || entry.length < 2) return null;
        final x = entry[0];
        final y = entry[1];
        if (x is! num || y is! num) return null;
        final point = LayoutPoint(x.toDouble(), y.toDouble());
        if (!point.isFinite) return null;
        parsed.add(point);
      }
      if (parsed.length < 2) return null;
      return Baseline(parsed, closed: decoded['closed'] == true);
    } catch (_) {
      return null;
    }
  }

  @override
  String toString() =>
      'Baseline(${points.length} pts, closed: $closed, '
      'length: ${totalLength.toStringAsFixed(1)})';
}
