import '../../../core/grades/grade_system.dart';
import 'proximity_topos_provider.dart';

/// How many topos stay expanded as individual wall rows at the top of the
/// Topos home before the rest start collapsing into their Sector.
///
/// A COUNT, deliberately, not a distance cut-off. A fixed "walls within 2 km"
/// rule reads well at the crag and fails everywhere else: a climber sitting at
/// home 60 km from the nearest boulder would open the app to a screen of
/// nothing but area names, having lost the one thing the list is for. Keeping
/// the nearest few expanded regardless of how far away they actually are means
/// the top of the list always answers "what is closest to me", and the tiering
/// below it only ever affects the long tail that used to scroll forever.
///
/// Eight is roughly one phone screen of rows, so the collapse begins exactly
/// where the flat list used to stop being readable.
const int kExpandedWallCount = 8;

/// How many Sectors stay expanded as their own rows, below the expanded walls,
/// before the remaining Sectors collapse into their Area. Same reasoning as
/// [kExpandedWallCount], one level up.
const int kExpandedSectorCount = 4;

/// The fewest members a group needs before it is worth drawing as a group.
///
/// A Sector row standing in for ONE topo is strictly worse than that topo's own
/// row: same vertical space, less information, and an extra tap to reach the
/// thing. The same is true of an Area holding a single Sector. So a would-be
/// group under this size dissolves back into whatever it contained, and the
/// tier above it renders those members directly.
const int kMinGroupSize = 2;

/// Whether a [ToposGroupNode] stands for a Sector or an Area — the two tiers
/// the Topos home collapses into, in that order (walls fold into Sectors,
/// Sectors fold into Areas).
enum ToposGroupKind { sector, area }

/// One row of the tiered Topos home: either a single topo ([ToposWallNode]) or
/// a collapsed Sector/Area ([ToposGroupNode]).
sealed class ToposNode {
  const ToposNode({required this.rank});

  /// This node's position in the ORIGINAL entry list — for a group, the index
  /// of its earliest-appearing member.
  ///
  /// The single sort key for the whole tree, and the reason [buildToposTree]
  /// needs no separate with-a-fix / without-a-fix ordering branch. The input
  /// list arrives already sorted by [ProximityTopoEntry.distanceKm] when a
  /// location fix exists (nulls last — see `mergeAndSortByProximity`) and in
  /// each source's own newest-first order when it does not, so "earliest input
  /// index" means "nearest" in the first case and "newest" in the second, and
  /// sorting by it preserves whichever of those the caller actually has.
  final int rank;

  /// Every topo this node stands for: one entry for a wall, all of its
  /// members (flattened through any child Sectors) for a group.
  List<ProximityTopoEntry> get topos;
}

/// A single topo, rendered as an ordinary wall row — either one of the nearest
/// [kExpandedWallCount], or one that could not be grouped at all (no ancestor
/// Sector, or the only member of one — see [kMinGroupSize]).
final class ToposWallNode extends ToposNode {
  const ToposWallNode({required this.entry, required super.rank});

  final ProximityTopoEntry entry;

  @override
  List<ProximityTopoEntry> get topos => [entry];
}

/// A collapsed Sector or Area, summarizing the topos inside it.
///
/// The aggregates below are what the row actually shows, and they are all
/// derived from data the entries already carry — no extra query, and nothing
/// here can disagree with the wall rows the group expands into.
final class ToposGroupNode extends ToposNode {
  ToposGroupNode({
    required this.kind,
    required this.id,
    required this.name,
    required this.topos,
    this.children = const [],
    required super.rank,
  });

  final ToposGroupKind kind;

  /// The underlying Sector/Area id. Also this group's identity for the
  /// screen's expand/collapse state, so a group stays open across the rebuild
  /// that a sync pull or a distance refresh triggers.
  final String id;

  final String name;

  /// Every topo under this group, flattened — for an Area that means all of
  /// its Sectors' topos, not just directly-filed ones. Ordered nearest-first,
  /// inheriting the input list's order.
  @override
  final List<ProximityTopoEntry> topos;

  /// For an Area, its Sector nodes; always empty for a Sector, whose
  /// [topos] are its leaves. Expanding an Area reveals these, and expanding
  /// one of those reveals its topos.
  final List<ToposGroupNode> children;

  int get topoCount => topos.length;

  /// Total live routes across every topo inside — the figure a climber
  /// actually scans for when deciding whether a crag is worth the drive.
  int get routeCount {
    var total = 0;
    for (final topo in topos) {
      total += topo.routeCount;
    }
    return total;
  }

  /// The distinct difficulty bands spanned by everything inside, easiest
  /// first — rendered as the same colored dots a wall row uses, so one glance
  /// reads "this crag is 6a-ish" without expanding it.
  List<GradeBand> get bands =>
      gradeBandsFor([for (final topo in topos) ...topo.routeGradeKeys]);

  /// Distance to the NEAREST topo inside, or `null` when nothing inside has a
  /// known distance. The nearest member, never a centroid: a climber reading
  /// "4.2 km" off a crag wants to know how far the closest climbing is, and a
  /// centroid of a sprawling area would overstate that for every boulder on
  /// its near edge.
  double? get distanceKm {
    double? nearest;
    for (final topo in topos) {
      final distance = topo.distanceKm;
      if (distance == null) continue;
      if (nearest == null || distance < nearest) nearest = distance;
    }
    return nearest;
  }

  /// Up to [limit] readable thumbnails from the topos inside, nearest first —
  /// what the row tiles into its mosaic. Topos with no photo are skipped
  /// rather than drawn as gaps, so a group with one photographed topo among
  /// ten shows that one photo full-bleed instead of a mostly-empty grid.
  List<String> thumbnailPaths({int limit = 3}) {
    final paths = <String>[];
    for (final topo in topos) {
      final path = topo.thumbnailPath;
      if (path == null || path.isEmpty) continue;
      paths.add(path);
      if (paths.length == limit) break;
    }
    return paths;
  }
}

/// Builds the Topos home's distance-tiered tree: the nearest
/// [expandedWalls] topos as individual rows, then the next [expandedSectors]
/// Sectors as collapsed group rows, then everything beyond that collapsed a
/// tier further into Areas.
///
/// [entries] must already be in the order the caller wants read top-to-bottom
/// — nearest-first from `sortedByProximityToposProvider` when a fix exists,
/// each source's newest-first order when it does not. This function never
/// re-sorts by distance itself; it sorts by [ToposNode.rank], which preserves
/// whichever order it was handed (see that field's doc).
///
/// [hasFix] gates only the FIRST tier. Without a location fix "the nearest
/// eight" is not a fact the app has, so pinning eight arbitrary topos open and
/// calling them nearest would be a lie; the whole list tiers instead, which is
/// also the more organized reading and what the feature is for. Topos that
/// cannot be grouped at all still render as their own rows in that case, so a
/// fresh library filed entirely under the hidden `__default__` sentinel looks
/// exactly as it always did.
///
/// Pure and top-level — no `ref`, no I/O, no widget — so the tiering rules are
/// unit-testable directly, without a [ProviderContainer] or a pumped tree.
List<ToposNode> buildToposTree({
  required List<ProximityTopoEntry> entries,
  required bool hasFix,
  int expandedWalls = kExpandedWallCount,
  int expandedSectors = kExpandedSectorCount,
}) {
  if (entries.isEmpty) return const [];

  // A list that already fits is never tiered, fix or no fix.
  //
  // Grouping exists to tame a list too long to scan; applied to a short one it
  // is pure loss — a library of three topos collapsed to a single "3 topos"
  // row is one line of text and a screen of emptiness, and every topo now costs
  // a tap it did not cost before. This was visible the moment the feature first
  // ran signed-in: the whole Topos home was one Sector row.
  //
  // The threshold is [expandedWalls] because that is already the definition of
  // "as much as we are willing to show flat" — below it, tiering could not
  // shorten the list anyway, since every entry would have been expanded.
  if (entries.length <= expandedWalls) {
    return [
      for (var i = 0; i < entries.length; i++)
        ToposWallNode(entry: entries[i], rank: i),
    ];
  }

  final headCount = hasFix ? expandedWalls.clamp(0, entries.length) : 0;
  final nodes = <ToposNode>[
    for (var i = 0; i < headCount; i++)
      ToposWallNode(entry: entries[i], rank: i),
  ];

  // --- Tier 2: fold the tail into Sectors ---------------------------------
  //
  // Insertion order matters and is relied on twice below: `_grouped` preserves
  // it, so each bucket's member list stays in the input's nearest-first order
  // and the first index seen for a bucket is its earliest member's — i.e. its
  // rank. An entry with no nameable Sector is not groupable and drops straight
  // through to a wall row, keeping its own position.
  final loose = <ToposNode>[];
  final sectorBuckets = _grouped(
    entries: entries,
    from: headCount,
    keyOf: (entry) => entry.sectorId,
    nameOf: (entry) => entry.sectorName,
    onUngrouped: (entry, rank) =>
        loose.add(ToposWallNode(entry: entry, rank: rank)),
  );

  // A one-topo "Sector" is worse than the topo's own row (see kMinGroupSize),
  // so it dissolves back into one.
  final sectorNodes = <ToposGroupNode>[];
  for (final bucket in sectorBuckets) {
    if (bucket.entries.length < kMinGroupSize) {
      for (final entry in bucket.entries) {
        loose.add(ToposWallNode(entry: entry, rank: bucket.rank));
      }
      continue;
    }
    sectorNodes.add(
      ToposGroupNode(
        kind: ToposGroupKind.sector,
        id: bucket.id,
        name: bucket.name,
        topos: bucket.entries,
        rank: bucket.rank,
      ),
    );
  }
  sectorNodes.sort((a, b) => a.rank.compareTo(b.rank));

  // The nearest few Sectors stay as Sector rows; the rest go one tier further.
  final keptSectors = sectorNodes.take(expandedSectors).toList();
  final foldable = sectorNodes.skip(expandedSectors).toList();
  nodes.addAll(keptSectors);

  // --- Tier 3: fold the remaining Sectors into Areas ----------------------
  //
  // Keyed off the Area of each Sector's own members (a Sector node has no Area
  // field of its own, and every topo under one Sector shares an Area by
  // construction — a Sector belongs to exactly one Area). A Sector whose Area
  // is the hidden sentinel, or which is its Area's only foldable Sector, stays
  // a Sector row: see kMinGroupSize.
  final areaBuckets = <String, _AreaBucket>{};
  for (final sector in foldable) {
    final areaId = sector.topos.first.areaId;
    final areaName = sector.topos.first.areaName;
    if (areaId == null || areaName == null || areaName.isEmpty) {
      nodes.add(sector);
      continue;
    }
    (areaBuckets[areaId] ??= _AreaBucket(
      id: areaId,
      name: areaName,
      rank: sector.rank,
    )).sectors.add(sector);
  }
  for (final bucket in areaBuckets.values) {
    if (bucket.sectors.length < kMinGroupSize) {
      nodes.addAll(bucket.sectors);
      continue;
    }
    nodes.add(
      ToposGroupNode(
        kind: ToposGroupKind.area,
        id: bucket.id,
        name: bucket.name,
        topos: [for (final sector in bucket.sectors) ...sector.topos],
        children: bucket.sectors,
        rank: bucket.rank,
      ),
    );
  }

  nodes.addAll(loose);

  // One final sort by rank puts every tier back into the reading order the
  // input defined: the expanded head stays on top (its ranks are the smallest
  // by construction), and a nearby loose topo is never stranded below a
  // far-away Area just because it was classified later.
  nodes.sort((a, b) => a.rank.compareTo(b.rank));
  return nodes;
}

/// One Sector's accumulated members, in input order, plus the input index of
/// the earliest of them (its [ToposNode.rank]).
class _Bucket {
  _Bucket({required this.id, required this.name, required this.rank});

  final String id;
  final String name;
  final int rank;
  final List<ProximityTopoEntry> entries = [];
}

/// The Area-tier equivalent of [_Bucket], accumulating Sector NODES rather
/// than raw entries.
class _AreaBucket {
  _AreaBucket({required this.id, required this.name, required this.rank});

  final String id;
  final String name;
  final int rank;
  final List<ToposGroupNode> sectors = [];
}

/// Buckets `entries[from..]` by [keyOf], preserving input order within each
/// bucket and stamping each bucket's rank with its earliest member's index.
/// Entries whose key or name is missing/blank are handed to [onUngrouped]
/// instead — they cannot be named on a group row, so they are never folded
/// into one.
List<_Bucket> _grouped({
  required List<ProximityTopoEntry> entries,
  required int from,
  required String? Function(ProximityTopoEntry) keyOf,
  required String? Function(ProximityTopoEntry) nameOf,
  required void Function(ProximityTopoEntry entry, int rank) onUngrouped,
}) {
  final buckets = <String, _Bucket>{};
  for (var i = from; i < entries.length; i++) {
    final entry = entries[i];
    final key = keyOf(entry);
    final name = nameOf(entry);
    if (key == null || name == null || name.isEmpty) {
      onUngrouped(entry, i);
      continue;
    }
    (buckets[key] ??= _Bucket(id: key, name: name, rank: i)).entries.add(entry);
  }
  return buckets.values.toList();
}
