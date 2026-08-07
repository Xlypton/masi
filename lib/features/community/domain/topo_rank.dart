import '../data/community_repository.dart';

/// How good a topo is, from signals already collected (community editing
/// phase 8c / C-6.3, and the answer to Open Question 3).
///
/// ## Why this is not a star rating
///
/// The alternative on the table was a per-topo star scale so readers could pick
/// the better of two topos of the same boulder. §C-6.3 argues against it and
/// this implements that argument: **routes already carry `stars` for climb
/// quality**, and a second star widget on a page that already shows stars means
/// the wrong thing to a climber — "3 stars" would read as "mediocre boulder"
/// when it was meant as "mediocre drawing of a good boulder". That is not a
/// labelling problem; it is two different subjects wearing the same symbol.
///
/// So this ranks by what people already do: like it, climb it, comment on it,
/// and confirm it matches the rock. §8 of the plan lists "a second rating
/// scale" under *what I would not build*, and nothing here adds one.
///
/// ## Where it is used, and where it is deliberately NOT
///
/// It orders a PLACE — which of several topos of the same boulder heads the
/// card, and in what order the rest are offered (§C-6.2, "ordered by rank").
/// That is the whole of its remit.
///
/// **It does not reorder the feed.** The feed stays newest-first. A ranking
/// that silently decides what every reader sees, from a formula nobody can
/// inspect, is a far larger product change than §C-6 asks for — and it would
/// bury a good new topo under an old popular one, which is precisely wrong on
/// the day somebody develops a new crag. Ordering two drawings of the SAME rock
/// is a question with a defensible answer; ordering the whole world is not.
///
/// ## What it cannot see
///
/// Two of §C-6.3's signals are missing, and the reasons are worth keeping
/// rather than quietly fixing later:
///
///  * **The author's trust level is not used.** `trust_level(uid)` exists but
///    is exposed only for the CALLER (`my_trust()`). Publishing every author's
///    standing so a feed could weight by it would turn an internal moderation
///    threshold into a public reputation score — a much bigger social decision
///    than a sort order, and not one §C-6 asked for.
///  * **Ascent count is a floor, not a total** — see
///    [SharedTopo.ascentCount]. The undercount runs the same direction for
///    every topo, so it is sound to order by and unsound to display.
///
/// "Description" from §C-6.3's completeness list is absent for a duller reason:
/// walls have no description column. Completeness is routes, grades, and GPS.
class TopoRank implements Comparable<TopoRank> {
  const TopoRank._({
    required this.wallId,
    required this.engagement,
    required this.completeness,
    required this.freshness,
  });

  /// Scores [topo] as of [nowMs] (needed only by the verification decay).
  factory TopoRank.of(SharedTopo topo, {required int nowMs}) {
    // Engagement SATURATES rather than accumulating. A topo with 400 likes and
    // no routes must not outrank a complete topo with three: the question being
    // answered is "which drawing of this boulder should I look at first", and a
    // drawing with no lines on it is not an answer however popular the photo
    // is. A saturating curve rather than a hard cap so the signal stays
    // strictly monotonic — the 500th like still counts for something, just
    // almost nothing — and so `_kMaxEngagement` can sit BELOW what a finished
    // topo earns from completeness alone, which is what makes that sentence
    // true rather than aspirational.
    final raw =
        _floored(topo.likeCount) * _kLikeWeight +
        _floored(topo.ascentCount) * _kAscentWeight +
        _floored(topo.commentCount) * _kCommentWeight;
    final engagement = _kMaxEngagement * (raw / (raw + _kEngagementHalf));

    var completeness = 0.0;
    if (topo.routeCount > 0) {
      completeness +=
          _kHasRoutes + _capped(topo.routeCount, _kMaxRoutes) * _kRouteWeight;
    }
    if (topo.routeGradeKeys.isNotEmpty) completeness += _kHasGrades;
    if (topo.hasCoordinates) completeness += _kHasCoordinates;

    // A verification decays rather than counting forever. "Somebody stood here
    // and said this matches the rock" is a statement about a moment; rock
    // changes, bolts get replaced, and a five-year-old confirmation is close to
    // no confirmation at all (C-10).
    var freshness = 0.0;
    final verifiedAt = topo.lastVerifiedAt;
    if (verifiedAt != null) {
      final ageDays = (nowMs - verifiedAt) / _kMsPerDay;
      final remaining =
          ((_kVerificationWindowDays - ageDays) / _kVerificationWindowDays)
              .clamp(0.0, 1.0);
      freshness = _kVerified * remaining;
    }

    return TopoRank._(
      wallId: topo.wallId,
      engagement: engagement,
      completeness: completeness,
      freshness: freshness,
    );
  }

  final String wallId;

  /// Likes, ascents, comments — what other people did with it.
  final double engagement;

  /// Routes, grades, coordinates — whether it is actually finished.
  final double completeness;

  /// How recently somebody confirmed it matches the rock.
  final double freshness;

  double get score => engagement + completeness + freshness;

  /// Descending by score, then ascending by wall id.
  ///
  /// The id tiebreak is not cosmetic: two freshly-published, identically-empty
  /// topos score exactly the same, and without a total order the card heading a
  /// group would flip between them on every rebuild.
  @override
  int compareTo(TopoRank other) {
    final byScore = other.score.compareTo(score);
    return byScore != 0 ? byScore : wallId.compareTo(other.wallId);
  }

  @override
  String toString() =>
      'TopoRank($wallId, score: ${score.toStringAsFixed(1)}, '
      'engagement: ${engagement.toStringAsFixed(1)}, '
      'completeness: ${completeness.toStringAsFixed(1)}, '
      'freshness: ${freshness.toStringAsFixed(1)})';

  static double _capped(int value, int cap) =>
      (value < 0 ? 0 : (value > cap ? cap : value)).toDouble();

  /// Negative counts cannot happen from the query, but a hand-built
  /// [SharedTopo] or a future schema change could produce one, and a negative
  /// score would sort a topo below "no information at all".
  static double _floored(int value) => value < 0 ? 0 : value.toDouble();

  static const _kMsPerDay = 86400000;

  // Engagement. An ascent is worth more than a like because it costs more to
  // produce: somebody climbed the thing and came back to log it. The whole term
  // asymptotes to `_kMaxEngagement`, reaching half of it at `_kEngagementHalf`
  // raw points — roughly ten likes, or three ascents and a comment.
  static const _kLikeWeight = 2.0;
  static const _kAscentWeight = 3.0;
  static const _kCommentWeight = 1.0;
  static const _kMaxEngagement = 40.0;
  static const _kEngagementHalf = 30.0;

  // Completeness. Having ANY routes is the big step — that is the difference
  // between a topo and a photograph of a cliff — so most of the weight sits in
  // the flat bonus rather than in the count. The ceiling here (75) is above
  // `_kMaxEngagement` on purpose: no amount of popularity can carry an empty
  // photo past a finished topo.
  static const _kHasRoutes = 30.0;
  static const _kRouteWeight = 1.0;
  static const _kMaxRoutes = 20;
  static const _kHasGrades = 15.0;
  static const _kHasCoordinates = 10.0;

  // Freshness. Linear decay to zero over a year rather than a true half-life:
  // an exponential tail would keep a decade-old verification faintly ahead of
  // none at all, which is not a distinction worth making.
  static const _kVerified = 20.0;
  static const _kVerificationWindowDays = 365.0;
}
