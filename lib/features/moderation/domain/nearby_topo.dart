/// A published topo that already exists near a given point (community editing
/// phase 8b / C-6.1).
///
/// The point of the type is the point of the phase: §C-6 rules out resolving
/// duplicates by deletion or by refusing the second submission, so the only
/// cheap intervention left is telling the submitter what is already there
/// **before** they submit. "Many duplicates stop right there" — and a duplicate
/// that is never created costs nobody a moderation decision, a merge, or an
/// argument about whose photo is better.
///
/// Everything here comes from `nearby_published_topos`, which filters each row
/// through `is_wall_public`. So a [NearbyTopo] is never news: it names
/// something the reader could already have found in the feed.
class NearbyTopo {
  const NearbyTopo({
    required this.wallId,
    required this.name,
    required this.distanceM,
    this.ownerId,
    this.ownerName,
    this.photoId,
    this.routeCount = 0,
    this.createdAt = 0,
  });

  final String wallId;
  final String name;

  /// Great-circle metres from the query point. Computed server-side, so two
  /// clients never disagree about whether something is "here".
  final double distanceM;

  final String? ownerId;
  final String? ownerName;

  /// The newest live photo on that topo, or null. Carried so a caller CAN show
  /// a thumbnail when the bytes happen to be on this device — never as a
  /// promise that it can.
  final String? photoId;

  final int routeCount;
  final int createdAt;

  /// Rounded to something a person can act on rather than to a precision the
  /// underlying GPS does not have. Phone EXIF coordinates are routinely tens of
  /// metres out, so "18 m" and "23 m" are the same claim — both mean "this is
  /// probably the same rock".
  String get distanceLabel {
    if (distanceM < 1) return 'same spot';
    if (distanceM < 1000) return '${distanceM.round()} m away';
    return '${(distanceM / 1000).toStringAsFixed(1)} km away';
  }

  String get ownerLabel => ownerName?.trim().isNotEmpty == true
      ? ownerName!.trim()
      : 'Another climber';

  /// Returns null for a row missing the two fields that make it meaningful.
  /// Skipped rather than defaulted: an unnamed topo at an unknown distance is
  /// not something a submitter can compare their own against.
  static NearbyTopo? fromRow(Map<String, dynamic> row) {
    final wallId = row['wallId'] as String?;
    final distance = _asDouble(row['distanceM']);
    if (wallId == null || wallId.isEmpty || distance == null) return null;
    final name = (row['name'] as String?)?.trim();
    return NearbyTopo(
      wallId: wallId,
      name: name == null || name.isEmpty ? 'Untitled topo' : name,
      distanceM: distance,
      ownerId: row['ownerId'] as String?,
      ownerName: row['ownerName'] as String?,
      photoId: row['photoId'] as String?,
      routeCount: _asInt(row['routeCount']) ?? 0,
      createdAt: _asInt(row['createdAt']) ?? 0,
    );
  }

  static double? _asDouble(Object? value) => switch (value) {
    final double v => v,
    final num v => v.toDouble(),
    final String v => double.tryParse(v),
    _ => null,
  };

  static int? _asInt(Object? value) => switch (value) {
    final int v => v,
    final num v => v.toInt(),
    final String v => int.tryParse(v),
    _ => null,
  };
}
