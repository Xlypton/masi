/// Community facts (community editing, phase 4 / R-1).
///
/// The layer that is deliberately NOT gated behind the owner's approval. The
/// topo — the photo, the drawn line, the prose — is the author's work and they
/// curate it. The grade, whether the drawing matches the rock, and whether
/// there is a loose block over the belay are facts about the world, and every
/// platform surveyed in `COMMUNITY_PLAN.md` §3 treats them as community-owned.
///
/// Pure and import-free apart from the grade ladder, so all of it is testable
/// without a database, a network, or a widget.
library;

import '../../../core/grades/grade_system.dart';

// ---------------------------------------------------------------------------
// Hazards
// ---------------------------------------------------------------------------

/// How serious a reported hazard is.
enum HazardSeverity {
  /// Worth knowing, not dangerous. "The first bolt is high."
  note,

  /// Take care. "Loose flake at the third clip, don't pull outwards."
  caution,

  /// Could hurt you. "Bolt 2 spins. Do not fall on it."
  danger;

  /// Parses a raw server string.
  ///
  /// An unrecognised value resolves to [danger] — the OPPOSITE direction to
  /// `ModerationState.fromWire`, and deliberately so. There, an unknown state
  /// must fail closed to avoid presenting unreviewed content as approved;
  /// here, an unknown severity must fail LOUD, because the failure mode of
  /// under-displaying a safety warning is somebody getting hurt. A client
  /// running against a newer server that has invented a severity it cannot
  /// interpret shows the warning at full volume rather than quietly demoting
  /// it to a note.
  static HazardSeverity fromWire(String? raw) => switch (raw) {
    'note' => HazardSeverity.note,
    'caution' => HazardSeverity.caution,
    _ => HazardSeverity.danger,
  };

  String get wire => name;

  /// Ordering for "the worst thing reported here". Higher is more serious.
  int get rank => switch (this) {
    HazardSeverity.note => 0,
    HazardSeverity.caution => 1,
    HazardSeverity.danger => 2,
  };

  /// Whether this warrants interrupting the user rather than sitting in a list.
  bool get isUrgent => this == HazardSeverity.danger;
}

/// A hazard reported on a topo, or on one route of it.
class HazardReport {
  const HazardReport({
    required this.id,
    required this.wallId,
    required this.routeId,
    required this.authorId,
    required this.severity,
    required this.body,
    required this.createdAt,
    this.resolvedAt,
    this.resolvedBy,
  });

  final String id;
  final String wallId;

  /// `null` for a hazard about the whole topo (the approach, the descent, the
  /// belay) rather than one specific line.
  final String? routeId;

  final String authorId;
  final HazardSeverity severity;
  final String body;
  final int createdAt;
  final int? resolvedAt;

  /// Who marked it resolved — the reporter withdrawing it and the topo owner
  /// saying it is dealt with are very different claims, and a resolution with
  /// nobody's name on it is not a record of anything.
  final String? resolvedBy;

  bool get isResolved => resolvedAt != null;

  /// Whether [uid] may mark this resolved. Mirrors the `resolve_hazard` RPC's
  /// own check so the button can be hidden rather than failing on tap; the
  /// server re-checks, so a client that lies to itself gains nothing.
  ///
  /// Note what is absent: there is no `canDelete` for the topo owner. They
  /// cannot delete a hazard report on their own topo, which is the entire
  /// point of the split (C-12 — safety content is never silently removed).
  bool canResolve({required String? uid, required String? wallOwnerId}) {
    if (uid == null) return false;
    return authorId == uid || wallOwnerId == uid;
  }
}

/// The one-line answer to "is there anything I should know before I get on
/// this?", derived from every hazard on a topo.
class HazardSummary {
  const HazardSummary({
    required this.worst,
    required this.unresolvedCount,
    required this.resolvedCount,
  });

  /// Severity of the most serious UNRESOLVED hazard, or `null` if there is
  /// nothing outstanding.
  final HazardSeverity? worst;

  final int unresolvedCount;
  final int resolvedCount;

  bool get hasUnresolved => unresolvedCount > 0;

  /// Whether anything at all has ever been reported. Distinct from
  /// [hasUnresolved]: "three hazards, all resolved" is a meaningfully
  /// different — and more reassuring — statement than "nothing reported",
  /// and collapsing them would erase the history the resolve-don't-delete
  /// rule exists to preserve.
  bool get hasAny => unresolvedCount > 0 || resolvedCount > 0;

  static HazardSummary of(Iterable<HazardReport> hazards) {
    HazardSeverity? worst;
    var unresolved = 0;
    var resolved = 0;
    for (final h in hazards) {
      if (h.isResolved) {
        resolved++;
        continue;
      }
      unresolved++;
      if (worst == null || h.severity.rank > worst.rank) worst = h.severity;
    }
    return HazardSummary(
      worst: worst,
      unresolvedCount: unresolved,
      resolvedCount: resolved,
    );
  }
}

// ---------------------------------------------------------------------------
// Grade opinions
// ---------------------------------------------------------------------------

/// One person's view of what a route goes at.
class GradeOpinion {
  const GradeOpinion({
    required this.id,
    required this.routeId,
    required this.authorId,
    required this.system,
    required this.raw,
    required this.sortKey,
    required this.createdAt,
  });

  final String id;
  final String routeId;
  final String authorId;
  final GradeSystem system;
  final String raw;

  /// Position on the shared cross-system scale (see [gradeSortKey]). Stored
  /// rather than recomputed so a French and a UIAA opinion on the same route
  /// are directly comparable without the reader knowing either ladder.
  final double sortKey;

  final int createdAt;
}

/// How many independent opinions are needed before the app will state a
/// community grade at all.
///
/// Three, not one or two. One opinion rendered as "the community says" would
/// let a single passer-by appear to overrule the first ascensionist; two that
/// disagree are not a consensus, they are a disagreement. Below this the count
/// is still shown — "2 opinions" is useful, "the consensus is 7a (n=1)" is a
/// lie with a number attached.
const int kMinOpinionsForConsensus = 3;

/// What the community reckons, next to what the author said.
///
/// The author's grade stays authoritative for display and for filtering
/// (`COMMUNITY_IMPL.md` §1.6); this renders beside it. Nothing here ever
/// rewrites the route.
class GradeConsensus {
  const GradeConsensus({
    required this.count,
    required this.sortKey,
    required this.spread,
    required this.authorSortKey,
  });

  final int count;

  /// Median shared-scale value, or `null` when [count] is below
  /// [kMinOpinionsForConsensus].
  final double? sortKey;

  /// Distance between the softest and hardest opinion, on the shared scale.
  /// A wide spread is itself the interesting fact — "opinions vary from 6b to
  /// 7a" tells a climber more than any single number could.
  final double spread;

  /// The author's own grade, for comparison. `null` if the route is ungraded.
  final double? authorSortKey;

  bool get hasConsensus => sortKey != null;

  /// Whether the community's median sits more than one full ladder step from
  /// the author's grade — the threshold at which it is worth drawing the
  /// reader's attention rather than quietly showing two near-identical numbers.
  bool get disagreesWithAuthor {
    final mine = sortKey;
    final theirs = authorSortKey;
    if (mine == null || theirs == null) return false;
    return (mine - theirs).abs() > 1.0;
  }

  /// Renders the consensus on [system]'s ladder — the nearest token to the
  /// median. Cross-system by construction: three UIAA opinions can be read
  /// back as a French grade, because they were stored on the shared scale.
  ///
  /// `null` when there is no consensus to render.
  String? displayGrade(GradeSystem system) {
    final median = sortKey;
    if (median == null) return null;
    final ladder = gradeOptions(system);
    String? best;
    double? bestDistance;
    for (final token in ladder) {
      final distance = (gradeSortKey(system, token) - median).abs();
      if (bestDistance == null || distance < bestDistance) {
        bestDistance = distance;
        best = token;
      }
    }
    return best;
  }

  /// Computes the consensus from [opinions].
  ///
  /// The median, not the mean. A mean lets one sandbagger drag the number for
  /// everyone — post a 5a opinion on a 7a and the average moves; the median
  /// does not notice. This is the standard robustness argument and it matters
  /// more here than usual, because grade opinions are exactly the surface a
  /// troll finds cheapest to abuse.
  ///
  /// With an even number of opinions the HARDER of the two middle values wins,
  /// rather than averaging them. Averaging would invent a value nobody stated
  /// and land between ladder tokens; picking the harder side is the
  /// conservative direction, since a climber surprised by a route being harder
  /// than advertised is in more trouble than one who finds it easier.
  static GradeConsensus of(
    Iterable<GradeOpinion> opinions, {
    double? authorSortKey,
  }) {
    final keys = [for (final o in opinions) o.sortKey]..sort();
    if (keys.isEmpty) {
      return GradeConsensus(
        count: 0,
        sortKey: null,
        spread: 0,
        authorSortKey: authorSortKey,
      );
    }
    return GradeConsensus(
      count: keys.length,
      sortKey: keys.length < kMinOpinionsForConsensus
          ? null
          : keys[keys.length ~/ 2],
      spread: keys.last - keys.first,
      authorSortKey: authorSortKey,
    );
  }
}

// ---------------------------------------------------------------------------
// Verifications
// ---------------------------------------------------------------------------

/// "I was there, and the topo matches the rock" — or it does not.
class TopoVerification {
  const TopoVerification({
    required this.id,
    required this.wallId,
    required this.authorId,
    required this.accurate,
    required this.createdAt,
    this.note,
  });

  final String id;
  final String wallId;
  final String authorId;
  final bool accurate;
  final String? note;
  final int createdAt;
}

/// Aggregate confidence in a topo's accuracy.
class VerificationSummary {
  const VerificationSummary({
    required this.accurateCount,
    required this.inaccurateCount,
  });

  final int accurateCount;
  final int inaccurateCount;

  int get total => accurateCount + inaccurateCount;

  /// Whether anyone has said the topo does NOT match the rock. Surfaced even
  /// when heavily outvoted: one credible "the line is drawn on the wrong
  /// crack" is worth reading regardless of how many people confirmed the rest.
  bool get isDisputed => inaccurateCount > 0;

  static VerificationSummary of(Iterable<TopoVerification> verifications) {
    var accurate = 0;
    var inaccurate = 0;
    for (final v in verifications) {
      if (v.accurate) {
        accurate++;
      } else {
        inaccurate++;
      }
    }
    return VerificationSummary(
      accurateCount: accurate,
      inaccurateCount: inaccurate,
    );
  }
}
