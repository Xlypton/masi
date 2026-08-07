import '../data/community_repository.dart';
import 'topo_rank.dart';

/// Which topos are the same PLACE (community editing phase 8b / C-6.2).
///
/// Built from `topo_alternates` rows — one per non-canonical wall, pointing at
/// the canonical one. The server maintains the invariant this type depends on:
/// **a canonical is never itself an alternate**, so resolving a group is one
/// lookup and never a recursive walk. [canonicalFor] still collapses one level
/// of chain defensively, because a client that loops forever on unexpected data
/// is a worse failure than one that groups slightly wrong.
class AlternateGroups {
  const AlternateGroups(this._canonicalByWall);

  const AlternateGroups.empty() : _canonicalByWall = const {};

  /// wallId → canonicalId, for NON-canonical walls only. A canonical wall is
  /// absent from this map, which is what makes "am I a head?" a lookup miss
  /// rather than a self-referencing row to filter out everywhere.
  final Map<String, String> _canonicalByWall;

  bool get isEmpty => _canonicalByWall.isEmpty;

  /// The head of [wallId]'s group, or [wallId] itself when it heads its own.
  String canonicalFor(String wallId) {
    final first = _canonicalByWall[wallId];
    if (first == null || first == wallId) return wallId;
    // One extra hop, then stop. The server guarantees there is no second one;
    // this is the guard for the day that stops being true.
    final second = _canonicalByWall[first];
    return second == null || second == first || second == wallId
        ? first
        : second;
  }

  /// Parses `{wallId, canonicalId}` rows. Rows missing either end, or naming
  /// themselves, are skipped rather than throwing — the same discipline every
  /// other remote import in this app applies, and one malformed row must not
  /// cost the whole feed its grouping.
  static AlternateGroups fromRows(List<Map<String, dynamic>> rows) {
    final map = <String, String>{};
    for (final row in rows) {
      final wallId = row['wallId'];
      final canonicalId = row['canonicalId'];
      if (wallId is! String || wallId.isEmpty) continue;
      if (canonicalId is! String || canonicalId.isEmpty) continue;
      if (wallId == canonicalId) continue;
      map[wallId] = canonicalId;
    }
    return AlternateGroups(map);
  }
}

/// One card in the feed: a place, and every topo of it this reader can see.
class TopoGroup {
  const TopoGroup({required this.head, this.alternates = const []});

  /// The topo shown on the card.
  final SharedTopo head;

  /// The rest of the group, best first. Empty for the overwhelming majority of
  /// cards — most places have exactly one topo, and this type collapses to a
  /// wrapper around [head] in that case.
  final List<SharedTopo> alternates;

  /// How many topos this card stands for, including [head].
  int get count => alternates.length + 1;

  bool get isGrouped => alternates.isNotEmpty;

  /// Every topo in the group, best first.
  List<SharedTopo> get all => [head, ...alternates];
}

/// Collapses [topos] into one entry per place, preserving the input's order.
///
/// Three decisions worth stating, because all three are visible to readers:
///
/// **The head is the best-ranked member, not the canonical.** The canonical is
/// an identity for the place — the admin who linked them recorded that these
/// are the same boulder, not which drawing of it is better, and there is no
/// reason to think the first one submitted is the good one. Ranking picks the
/// card; the link only decides who is in the running (see [TopoRank]).
///
/// **A group forms only from topos actually present.** If a filter, a
/// permission or an un-pulled mirror leaves the canonical out of [topos], the
/// remaining members still group under the best of themselves rather than
/// scattering into unrelated cards. The count on the card is therefore "topos
/// of this place that you can see", which is the only count a client can
/// honestly render.
///
/// **The card sits where its FIRST member sat.** The feed is newest-first, so a
/// place appears at the position of its newest topo. Grouping must not be able
/// to move a card up the feed — that would make linking two topos an act with
/// ranking consequences, and an admin resolving a duplicate report is not
/// deciding what people see first.
List<TopoGroup> groupTopos(
  List<SharedTopo> topos,
  AlternateGroups links, {
  required int nowMs,
}) {
  // Fast path, and it is the normal one: with no links at all this is a map
  // over the list, so grouping costs a feed with no duplicates nothing.
  if (links.isEmpty) {
    return [for (final topo in topos) TopoGroup(head: topo)];
  }

  final buckets = <String, List<SharedTopo>>{};
  final keyOrder = <String>[];
  for (final topo in topos) {
    // Keyed by the canonical whether or not it is PRESENT. That is what makes
    // a group whose head was filtered out still cohere: two alternates of an
    // absent canonical share a key and stay one card, rather than scattering
    // into unrelated rows exactly when the reader is on a filtered view.
    final key = links.canonicalFor(topo.wallId);
    final bucket = buckets[key];
    if (bucket == null) {
      keyOrder.add(key);
      buckets[key] = [topo];
    } else {
      bucket.add(topo);
    }
  }

  final groups = <TopoGroup>[];
  for (final key in keyOrder) {
    final members = buckets[key]!;
    if (members.length == 1) {
      groups.add(TopoGroup(head: members.single));
      continue;
    }
    final ranked = [...members]
      ..sort(
        (a, b) =>
            TopoRank.of(a, nowMs: nowMs).compareTo(TopoRank.of(b, nowMs: nowMs)),
      );
    groups.add(TopoGroup(head: ranked.first, alternates: ranked.sublist(1)));
  }
  return groups;
}
