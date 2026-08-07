/// One recorded revision of a published topo (community editing phase 6a /
/// C-8).
///
/// The list form deliberately carries no payload. A snapshot is a few
/// kilobytes of JSON and a history screen wants dates and authors, not twenty
/// whole topos; the payload is fetched only when a version is actually being
/// restored.
library;

class TopoVersion {
  const TopoVersion({
    required this.id,
    required this.wallName,
    required this.routeCount,
    required this.createdAt,
    this.actorId,
    this.actorName,
  });

  final String id;

  /// The wall's name AS OF this version, which is the point — a rename is one
  /// of the changes worth seeing in a history.
  final String wallName;

  final int routeCount;

  /// When this version was opened, in epoch ms.
  ///
  /// Note this is the START of the editing session it represents, while its
  /// content is the state at the END of that session (see `snapshot_topo`'s
  /// coalescing). The gap is at most the coalescing window.
  final int createdAt;

  /// Null for the baseline versions written by the migration itself, which
  /// record how every already-published topo stood at the moment history
  /// started being kept. Nobody made that change, so nobody is credited.
  final String? actorId;

  /// The actor's display name, when they have a profile. Absent for a
  /// baseline row, and for an account that never set one.
  final String? actorName;

  factory TopoVersion.fromRow(Map<String, dynamic> row) => TopoVersion(
    id: row['id'] as String? ?? '',
    wallName: (row['wallName'] as String?)?.trim().isNotEmpty == true
        ? row['wallName'] as String
        : 'Untitled topo',
    routeCount: _asInt(row['routeCount']) ?? 0,
    createdAt: _asInt(row['createdAt']) ?? 0,
    actorId: row['actorId'] as String?,
    actorName: (row['actorName'] as String?)?.trim().isNotEmpty == true
        ? row['actorName'] as String
        : null,
  );

  DateTime get at => DateTime.fromMillisecondsSinceEpoch(createdAt);

  /// Who to credit. Falls back to "Someone" rather than to a raw uid: a uid is
  /// not a name, and printing one tells the reader nothing while exposing an
  /// identifier that has no business on screen.
  String get actorLabel =>
      actorName ?? (actorId == null ? 'Before history was kept' : 'Someone');

  static int? _asInt(Object? value) => switch (value) {
    final int v => v,
    final num v => v.toInt(),
    final String v => int.tryParse(v),
    _ => null,
  };
}

/// A one-line description of what a version changed, derived by comparing it
/// with the version immediately before it.
///
/// Deliberately computed from the LIST rows rather than by diffing payloads.
/// Two numbers and a name are enough to answer "is it worth looking at this
/// one", which is all a history list has to do, and it costs no extra fetch.
/// A real diff belongs on the screen that shows a single version, not on the
/// list of all of them.
class TopoVersionChange {
  const TopoVersionChange({
    required this.routesAdded,
    required this.routesRemoved,
    required this.renamedFrom,
  });

  final int routesAdded;
  final int routesRemoved;

  /// The previous name, when this version renamed the topo.
  final String? renamedFrom;

  static const TopoVersionChange none = TopoVersionChange(
    routesAdded: 0,
    routesRemoved: 0,
    renamedFrom: null,
  );

  bool get isEmpty =>
      routesAdded == 0 && routesRemoved == 0 && renamedFrom == null;

  /// [versions] must be newest-first, as the server returns them.
  ///
  /// The OLDEST entry gets [none]: there is nothing before it to compare
  /// against, and reporting its whole contents as "added" would describe the
  /// baseline snapshot as if somebody had just built the topo from nothing.
  static TopoVersionChange between(List<TopoVersion> versions, int index) {
    if (index < 0 || index >= versions.length - 1) return none;
    final now = versions[index];
    final before = versions[index + 1];
    final delta = now.routeCount - before.routeCount;
    return TopoVersionChange(
      routesAdded: delta > 0 ? delta : 0,
      routesRemoved: delta < 0 ? -delta : 0,
      renamedFrom: now.wallName == before.wallName ? null : before.wallName,
    );
  }

  /// Human summary, or null when nothing worth saying changed.
  ///
  /// A version with no visible change is not a bug — a description edit, a
  /// grade correction or a redrawn line all leave the route COUNT and the
  /// topo name alone. Saying nothing is more honest than inventing a
  /// difference this list cannot actually see.
  String? get summary {
    final parts = <String>[
      if (routesAdded > 0)
        '+$routesAdded route${routesAdded == 1 ? '' : 's'}',
      if (routesRemoved > 0)
        '−$routesRemoved route${routesRemoved == 1 ? '' : 's'}',
      if (renamedFrom != null) 'renamed from "$renamedFrom"',
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }
}
