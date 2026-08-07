import 'package:supabase_flutter/supabase_flutter.dart';

/// The cloud seam for duplicate topos (community editing phase 8b / C-6).
///
/// Three unrelated-looking calls that are one feature: find what is already
/// here, and — once a human has decided two topos are the same place — record
/// the link. Nothing here can delete, hide or downrank a topo, and nothing
/// should ever be added that can: §C-6 opens by ruling out resolution by
/// deletion, and §3.3 makes "never destroy something people have logged ascents
/// against" a constraint on every phase rather than a phase of its own.
///
/// A SEPARATE seam from `ReportsRemote` even though the duplicate REPORT flows
/// through that one, for the reason `ModerationRemote`'s doc gives: reports are
/// private complaints, and alternates are public structure that a signed-out
/// reader is entitled to see. Merging them would mean one fake in tests having
/// to pretend to understand both.
abstract class DuplicatesRemote {
  /// Published topos within [radiusM] of a point, nearest first, at most ten.
  ///
  /// Returns only topos the caller could already see: the server filters every
  /// row through `is_wall_public`, so this can never reveal a pending, private
  /// or withdrawn wall — which matters, because the natural caller is somebody
  /// standing at a crag about to publish, and the natural coordinates are the
  /// EXIF position of a photo of somebody else's project.
  ///
  /// Never throws — an empty list on any failure. This decorates a submission
  /// the user has already decided to make; a network blip must not be able to
  /// block publishing.
  Future<List<Map<String, dynamic>>> nearby({
    required double latitude,
    required double longitude,
    double radiusM,
    String? excludeWallId,
  });

  /// The alternate links among [wallIds] — `{wallId, canonicalId}` rows.
  ///
  /// RLS only returns a link when BOTH ends are public, so an unpaired result
  /// means "not linked, as far as you may know" rather than "not linked".
  /// Best-effort like [nearby]: a feed that cannot group is a feed that shows
  /// every topo separately, which is what it did before this phase.
  Future<List<Map<String, dynamic>>> alternatesFor(Set<String> wallIds);

  /// Records that [duplicateId] is the same place as [canonicalId], and
  /// returns the id of the group's head.
  ///
  /// Admin-only, enforced server-side; throws otherwise. The returned head is
  /// not necessarily [canonicalId] — if that topo was itself an alternate, the
  /// link is flattened onto ITS canonical, because the no-chains invariant is
  /// what lets a client group a feed in one pass.
  Future<String> link({
    required String duplicateId,
    required String canonicalId,
    String? note,
  });

  /// Detaches one topo from its group. Takes the ALTERNATE, never the head:
  /// unlinking a head would silently dissolve a group somebody else built.
  Future<void> unlink(String wallId);
}

class SupabaseDuplicatesRemote implements DuplicatesRemote {
  SupabaseDuplicatesRemote(this._client);

  final SupabaseClient _client;

  /// Chunk size for the `IN` filter — same reasoning as
  /// `SupabaseModerationRemote._chunkSize`: PostgREST puts the id list in the
  /// query string, so an unbounded list fails as an opaque 414.
  static const int _chunkSize = 100;

  @override
  Future<List<Map<String, dynamic>>> nearby({
    required double latitude,
    required double longitude,
    double radiusM = 50,
    String? excludeWallId,
  }) async {
    try {
      final rows = await _client.rpc<dynamic>(
        'nearby_published_topos',
        params: {
          'lat': latitude,
          'lng': longitude,
          'radius_m': radiusM,
          'exclude_wall': excludeWallId,
        },
      );
      if (rows is! List) return const [];
      return [for (final row in rows) Map<String, dynamic>.from(row as Map)];
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<List<Map<String, dynamic>>> alternatesFor(Set<String> wallIds) async {
    if (wallIds.isEmpty) return const [];
    final ids = wallIds.toList(growable: false);
    final rows = <Map<String, dynamic>>[];
    try {
      for (var i = 0; i < ids.length; i += _chunkSize) {
        final chunk = ids.sublist(
          i,
          i + _chunkSize > ids.length ? ids.length : i + _chunkSize,
        );
        final response = await _client
            .from('topo_alternates')
            .select('wallId,canonicalId')
            .inFilter('wallId', chunk);
        for (final row in response) {
          rows.add(Map<String, dynamic>.from(row));
        }
      }
    } catch (_) {
      // A partial result from an earlier chunk is still returned: grouping some
      // of the feed beats grouping none, and the caller merges rather than
      // replaces.
      return rows;
    }
    return rows;
  }

  @override
  Future<String> link({
    required String duplicateId,
    required String canonicalId,
    String? note,
  }) async {
    final result = await _client.rpc<dynamic>(
      'link_alternate',
      params: {
        'duplicate_id': duplicateId,
        'canonical_id': canonicalId,
        'note': note,
      },
    );
    return result is String ? result : canonicalId;
  }

  @override
  Future<void> unlink(String wallId) =>
      _client.rpc<dynamic>('unlink_alternate', params: {'wall_id': wallId});
}
