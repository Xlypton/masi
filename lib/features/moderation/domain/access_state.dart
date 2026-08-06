/// Access and closure state for a crag, sector or individual topo
/// (community editing phase 2 / R-2).
///
/// Modelled on theCrag's approach (COMMUNITY_PLAN.md §3.6): a state plus a
/// reason, inheriting down the Area → Sector → Wall hierarchy, with their
/// stated philosophy of *modelling reality* — a closed crag must still be
/// findable and prominently marked closed, because hiding it entirely just
/// sends climbers exploring.
library;

enum AccessState {
  /// Explicitly confirmed open. Distinct from "nothing stated": someone has
  /// actually checked, which is worth showing on a crag with a history of
  /// closures.
  open,

  /// Open with conditions — a seasonal restriction, a permit, an approach
  /// that crosses private land.
  restricted,

  /// Closed. Still findable and still fully documented, deliberately.
  closed,

  /// Not to be published at all: a nesting site, a culturally significant
  /// place, land whose owner has asked for it not to be listed. This is the
  /// ONLY state that removes a topo from public view, and the server enforces
  /// that inside `is_wall_public()` — this enum cannot.
  sensitive;

  /// How restrictive each state is. Higher wins when resolving a hierarchy.
  int get severity => switch (this) {
    AccessState.open => 1,
    AccessState.restricted => 2,
    AccessState.closed => 3,
    AccessState.sensitive => 4,
  };

  /// Parses a raw stored value; `null` for absent or unrecognised.
  ///
  /// An unknown string resolves to [closed] rather than to null, because the
  /// failure it guards against is asymmetric: reading a future
  /// `'closed_seasonally'` as "nothing stated" would show a climber an open
  /// crag that somebody had marked shut. Over-restricting is an
  /// inconvenience; under-restricting is the thing this whole feature exists
  /// to prevent.
  static AccessState? fromWire(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    return switch (raw) {
      'open' => AccessState.open,
      'restricted' => AccessState.restricted,
      'closed' => AccessState.closed,
      'sensitive' => AccessState.sensitive,
      _ => AccessState.closed,
    };
  }

  String get wire => name;

  /// Whether this state should be surfaced to a climber at all. "Nothing
  /// stated" and a bare "open" are not worth a banner; anything else is.
  bool get warrantsNotice => severity >= AccessState.restricted.severity;
}

/// One level of the hierarchy's access information, paired so a resolved
/// result can say WHERE the restriction came from.
class AccessLevel {
  const AccessLevel({
    required this.state,
    required this.note,
    required this.sourceLabel,
  });

  final AccessState? state;
  final String? note;

  /// Human label for the level this came from — "Csobánka" (the area),
  /// "Main Wall" (the sector), or the topo's own name. Shown in the banner so
  /// "Closed" on a topo the user did not restrict is attributable rather than
  /// mysterious.
  final String sourceLabel;
}

/// The effective access state for a topo, after inheritance.
class ResolvedAccess {
  const ResolvedAccess({this.state, this.note, this.sourceLabel});

  final AccessState? state;
  final String? note;
  final String? sourceLabel;

  /// Nothing stated anywhere in the chain.
  static const ResolvedAccess none = ResolvedAccess();

  bool get warrantsNotice => state?.warrantsNotice ?? false;

  /// Picks the MOST RESTRICTIVE level in the chain, and carries that level's
  /// note and source with it.
  ///
  /// Most-restrictive-wins rather than nearest-wins: a wall marked `open`
  /// beneath an area marked `closed` must read as closed. The alternative
  /// would let one stale wall-level note override a landowner's closure of
  /// the whole crag — and the note that matters is the one explaining the
  /// restriction, not the one explaining its absence.
  ///
  /// Ties go to the level given FIRST, so callers pass most-specific-first
  /// (wall, then sector, then area) and a wall's own note wins over an
  /// identically-severe inherited one.
  static ResolvedAccess resolve(List<AccessLevel> levels) {
    AccessLevel? best;
    for (final level in levels) {
      final state = level.state;
      if (state == null) continue;
      if (best == null || state.severity > best.state!.severity) {
        best = level;
      }
    }
    if (best == null) return none;
    return ResolvedAccess(
      state: best.state,
      note: best.note,
      sourceLabel: best.sourceLabel,
    );
  }
}
