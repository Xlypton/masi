/// An owner asking permission to delete a topo that has been public.
///
/// Deleting a published (or taken-down) topo needs an admin to agree — the
/// ten-day withdrawal protects READERS, this protects THE RECORD (§3.3: never
/// destroy something people have logged ascents against).
///
/// Approving does not delete anything. It grants permission; the owner still
/// performs the deletion. That split keeps the destructive act with the person
/// whose work it is, and means an admin's mis-tap costs nobody their topo.
class DeletionRequest {
  const DeletionRequest({
    required this.id,
    required this.wallId,
    required this.wallName,
    required this.requesterId,
    this.requesterName,
    this.reason,
    required this.routeCount,
    required this.ascentCount,
    required this.createdAt,
  });

  /// Builds one from a raw `deletion_requests_queue` row, or null if unusable.
  ///
  /// Dropped rather than half-built, like every other admin surface here. The
  /// decision this row leads to is permanent destruction of somebody's work,
  /// which is the last place to render a half-known record.
  static DeletionRequest? fromRow(Map<String, dynamic> row) {
    final id = row['id'];
    final wallId = row['wallId'];
    final createdAt = row['createdAt'];
    if (id is! String || id.isEmpty) return null;
    if (wallId is! String || wallId.isEmpty) return null;
    if (createdAt is! int) return null;
    final name = row['wallName'];
    return DeletionRequest(
      id: id,
      wallId: wallId,
      wallName: name is String && name.trim().isNotEmpty ? name : 'Untitled',
      requesterId: switch (row['requesterId']) {
        final String v when v.isNotEmpty => v,
        _ => '',
      },
      requesterName: _text(row['requesterName']),
      reason: _text(row['reason']),
      routeCount: _count(row['routeCount']),
      ascentCount: _count(row['ascentCount']),
      createdAt: createdAt,
    );
  }

  static String? _text(Object? v) => switch (v) {
    final String s when s.trim().isNotEmpty => s,
    _ => null,
  };

  static int _count(Object? v) => switch (v) {
    final int n when n > 0 => n,
    final num n when n > 0 => n.toInt(),
    _ => 0,
  };

  final String id;
  final String wallId;
  final String wallName;
  final String requesterId;
  final String? requesterName;

  /// Why they want it gone, if they said. Optional by design — a required
  /// reason would mostly produce "because I want to", and the numbers below
  /// carry more decision weight than the sentence does.
  final String? reason;

  final int routeCount;

  /// How many climbers logged an ascent on this topo. **The number that
  /// decides this**, and the reason §3.3 exists at all: routes can be
  /// re-drawn, but somebody's record of a climb they did cannot.
  final int ascentCount;

  final int createdAt;

  String get requesterLabel => requesterName ?? 'Unknown owner';

  /// True when other people's climbing records are attached to this topo, so
  /// approving is not just about the owner's own work any more.
  bool get costsOthers => ascentCount > 0;

  /// "4 routes · 11 ascents logged" — assembled here rather than in the widget
  /// so the queue and the confirmation sheet cannot describe the same request
  /// differently. Ascents come last because they are what the eye should stop
  /// on, and they are stated even at zero: "no ascents logged" is the fact that
  /// makes an approval easy, and leaving it out would make its absence
  /// ambiguous.
  String get stakes {
    final routes = routeCount == 1 ? '1 route' : '$routeCount routes';
    final ascents = switch (ascentCount) {
      0 => 'no ascents logged',
      1 => '1 ascent logged',
      final n => '$n ascents logged',
    };
    return '$routes · $ascents';
  }
}
