import '../../../core/db/app_database.dart' as db;
import '../../../core/grades/grade_system.dart';
import '../domain/community_facts.dart';

/// Local reads and mirror writes over the three community-fact tables
/// (community editing, phase 4 / R-1).
///
/// Reads come from the local mirror so a hazard warning renders from cold and
/// offline like every other read in this local-first app. Writes go straight
/// to the server through `CommunityFactsRemote` and are mirrored here only
/// once the server has confirmed them — there is no local-first write path and
/// deliberately no outbox (decision D-4). See `GradeOpinionRows` in
/// `tables.dart` for the full argument.
class CommunityFactsRepository {
  CommunityFactsRepository(this._db);

  final db.AppDatabase _db;

  // --- Hazards ------------------------------------------------------------

  /// Every hazard on [wallId], most serious unresolved first.
  ///
  /// Resolved reports are included rather than filtered out. That is the point
  /// of resolve-instead-of-delete: "three hazards, all dealt with" is a
  /// genuinely different — and more reassuring — statement than "nothing ever
  /// reported", and a reader is entitled to tell them apart.
  Stream<List<HazardReport>> watchHazards(String wallId) {
    final query = _db.select(_db.topoHazardRows)
      ..where((t) => t.wallId.equals(wallId));
    return query.watch().map((rows) {
      final hazards = rows.map(_toHazard).toList()
        ..sort((a, b) {
          if (a.isResolved != b.isResolved) return a.isResolved ? 1 : -1;
          final bySeverity = b.severity.rank.compareTo(a.severity.rank);
          if (bySeverity != 0) return bySeverity;
          return b.createdAt.compareTo(a.createdAt);
        });
      return hazards;
    });
  }

  /// The one-line "anything I should know?" for [wallId].
  Stream<HazardSummary> watchHazardSummary(String wallId) =>
      watchHazards(wallId).map(HazardSummary.of);

  /// Who owns [wallId], or null if this device has never pulled that wall.
  ///
  /// Needed by the hazard list to decide whether to offer a Resolve control.
  /// A UI hint only: the `resolve_hazard` RPC re-checks ownership server-side,
  /// so a device with a stale or missing wall row costs the user a hidden
  /// button, never unauthorised access.
  Stream<String?> watchWallOwner(String wallId) {
    final query = _db.select(_db.walls)..where((t) => t.id.equals(wallId));
    return query.watchSingleOrNull().map((row) => row?.ownerId);
  }

  // --- Grade opinions -----------------------------------------------------

  /// Every grade opinion on [routeId].
  Stream<List<GradeOpinion>> watchOpinions(String routeId) {
    final query = _db.select(_db.gradeOpinionRows)
      ..where((t) => t.routeId.equals(routeId));
    return query.watch().map(
      (rows) => [for (final row in rows) ?_toOpinion(row)],
    );
  }

  /// The community's view of [routeId], next to the author's own grade.
  Stream<GradeConsensus> watchConsensus(
    String routeId, {
    double? authorSortKey,
  }) => watchOpinions(
    routeId,
  ).map((o) => GradeConsensus.of(o, authorSortKey: authorSortKey));

  // --- Verifications ------------------------------------------------------

  Stream<List<TopoVerification>> watchVerifications(String wallId) {
    final query = _db.select(_db.topoVerificationRows)
      ..where((t) => t.wallId.equals(wallId));
    return query.watch().map((rows) => rows.map(_toVerification).toList());
  }

  Stream<VerificationSummary> watchVerificationSummary(String wallId) =>
      watchVerifications(wallId).map(VerificationSummary.of);

  // --- Mirror writes ------------------------------------------------------

  /// Replaces the local mirror for exactly the rows present in [facts].
  ///
  /// Scoped to what the fetch returned rather than wholesale, for the same
  /// reason `ModerationRepository.upsertFromRemote` is: a fetch only covers
  /// the walls the caller asked about, so clearing anything else would discard
  /// facts about topos that simply were not in this batch.
  ///
  /// A malformed row is skipped rather than throwing — one bad row from a
  /// future server version must not abort the whole import.
  Future<int> upsertFromRemote(
    Map<String, List<Map<String, dynamic>>> facts,
  ) async {
    var written = 0;
    await _db.transaction(() async {
      for (final row in facts['hazards'] ?? const []) {
        final id = row['id'];
        final wallId = row['wallId'];
        final severity = row['severity'];
        final body = row['body'];
        if (id is! String || id.isEmpty) continue;
        if (wallId is! String || wallId.isEmpty) continue;
        if (severity is! String || body is! String) continue;
        await _db
            .into(_db.topoHazardRows)
            .insertOnConflictUpdate(
              db.TopoHazardRow(
                id: id,
                wallId: wallId,
                routeId: row['routeId'] as String?,
                authorId: row['authorId'] as String? ?? '',
                severity: severity,
                body: body,
                resolvedAt: _asInt(row['resolvedAt']),
                resolvedBy: row['resolvedBy'] as String?,
                createdAt: _asInt(row['createdAt']) ?? 0,
              ),
            );
        written++;
      }

      for (final row in facts['verifications'] ?? const []) {
        final id = row['id'];
        final wallId = row['wallId'];
        final accurate = row['accurate'];
        if (id is! String || id.isEmpty) continue;
        if (wallId is! String || wallId.isEmpty) continue;
        if (accurate is! bool) continue;
        await _db
            .into(_db.topoVerificationRows)
            .insertOnConflictUpdate(
              db.TopoVerificationRow(
                id: id,
                wallId: wallId,
                authorId: row['authorId'] as String? ?? '',
                accurate: accurate,
                note: row['note'] as String?,
                createdAt: _asInt(row['createdAt']) ?? 0,
              ),
            );
        written++;
      }

      for (final row in facts['opinions'] ?? const []) {
        final id = row['id'];
        final routeId = row['routeId'];
        final system = row['gradeSystem'];
        final raw = row['gradeRaw'];
        if (id is! String || id.isEmpty) continue;
        if (routeId is! String || routeId.isEmpty) continue;
        if (system is! String || raw is! String) continue;
        await _db
            .into(_db.gradeOpinionRows)
            .insertOnConflictUpdate(
              db.GradeOpinionRow(
                id: id,
                routeId: routeId,
                authorId: row['authorId'] as String? ?? '',
                gradeSystem: system,
                gradeRaw: raw,
                gradeSortKey: _asDouble(row['gradeSortKey']),
                createdAt: _asInt(row['createdAt']) ?? 0,
              ),
            );
        written++;
      }
    });
    return written;
  }

  /// Mirrors one server-confirmed hazard locally, so the reporter sees their
  /// own report immediately rather than waiting for the next pull.
  Future<void> mirrorHazard(Map<String, dynamic> row) =>
      upsertFromRemote({'hazards': [row]});

  Future<void> mirrorVerification(Map<String, dynamic> row) =>
      upsertFromRemote({'verifications': [row]});

  Future<void> mirrorOpinion(Map<String, dynamic> row) =>
      upsertFromRemote({'opinions': [row]});

  /// Drops a locally-mirrored grade opinion, after the server accepted the
  /// delete.
  Future<void> dropOpinion(String id) =>
      (_db.delete(_db.gradeOpinionRows)..where((t) => t.id.equals(id))).go();

  /// Drops every locally-mirrored fact. Called on sign-out, so a second
  /// account on the same device does not inherit the first one's cache.
  Future<void> clear() async {
    await _db.delete(_db.topoHazardRows).go();
    await _db.delete(_db.topoVerificationRows).go();
    await _db.delete(_db.gradeOpinionRows).go();
  }

  // --- Mapping ------------------------------------------------------------

  static HazardReport _toHazard(db.TopoHazardRow row) => HazardReport(
    id: row.id,
    wallId: row.wallId,
    routeId: row.routeId,
    authorId: row.authorId,
    severity: HazardSeverity.fromWire(row.severity),
    body: row.body,
    createdAt: row.createdAt,
    resolvedAt: row.resolvedAt,
    resolvedBy: row.resolvedBy,
  );

  static TopoVerification _toVerification(db.TopoVerificationRow row) =>
      TopoVerification(
        id: row.id,
        wallId: row.wallId,
        authorId: row.authorId,
        accurate: row.accurate,
        note: row.note,
        createdAt: row.createdAt,
      );

  /// `null` when the stored system is one this build does not know.
  ///
  /// Dropping the opinion is the right failure here, and it is the opposite
  /// choice to the one hazards make. A grade on an unknown ladder cannot be
  /// placed on the shared scale at all, so including it would mean inventing a
  /// position for it and letting that invention move the median. Silently
  /// having one fewer opinion is a smaller error than a fabricated one.
  static GradeOpinion? _toOpinion(db.GradeOpinionRow row) {
    final system = GradeSystem.values
        .where((s) => s.name == row.gradeSystem)
        .firstOrNull;
    if (system == null) return null;

    // Prefer the server's stored sort key; recompute only if it is missing,
    // and drop the opinion if the grade is not on this build's ladder either.
    var sortKey = row.gradeSortKey;
    if (sortKey == null) {
      if (!isValidGrade(system, row.gradeRaw)) return null;
      sortKey = gradeSortKey(system, row.gradeRaw);
    }

    return GradeOpinion(
      id: row.id,
      routeId: row.routeId,
      authorId: row.authorId,
      system: system,
      raw: row.gradeRaw,
      sortKey: sortKey,
      createdAt: row.createdAt,
    );
  }

  /// PostgREST returns `bigint` as an `int`, but a JSON round trip through a
  /// fake or a future server change could hand back a `num`/`String`. Coerce
  /// defensively rather than letting an `as int` cast throw mid-import.
  static int? _asInt(Object? value) => switch (value) {
    final int v => v,
    final num v => v.toInt(),
    final String v => int.tryParse(v),
    _ => null,
  };

  static double? _asDouble(Object? value) => switch (value) {
    final double v => v,
    final num v => v.toDouble(),
    final String v => double.tryParse(v),
    _ => null,
  };
}
