import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/supabase_providers.dart';
import '../data/duplicates_remote.dart';
import '../domain/nearby_topo.dart';
import 'report_providers.dart';

/// The cloud seam for duplicates. Overridden in tests with an in-memory fake —
/// never the real one, which would touch the network.
final duplicatesRemoteProvider = Provider<DuplicatesRemote>(
  (ref) => SupabaseDuplicatesRemote(ref.watch(supabaseClientProvider)),
);

/// A point to ask "what is already here?" about.
typedef NearbyQuery = ({double latitude, double longitude, String? excludeWallId});

/// Published topos within [kDuplicateRadiusM] of a point, nearest first.
///
/// `autoDispose`: this backs a sheet shown at one moment of one flow, and
/// holding the answer after it closes would mean a submitter who moved fifty
/// metres and tried again sees the old crag's topos.
///
/// Resolves to an EMPTY list on any failure rather than an error, matching
/// [DuplicatesRemote.nearby]'s contract. That is the deliberate direction here
/// and the opposite of `openReportsProvider`'s: this decorates a submission the
/// user has already decided to make, so a network blip must degrade to "we
/// couldn't check" and let them publish, never to a blocking error.
final nearbyToposProvider = FutureProvider.autoDispose
    .family<List<NearbyTopo>, NearbyQuery>((ref, query) async {
      final rows = await ref
          .watch(duplicatesRemoteProvider)
          .nearby(
            latitude: query.latitude,
            longitude: query.longitude,
            radiusM: kDuplicateRadiusM,
            excludeWallId: query.excludeWallId,
          );
      return [for (final row in rows) ?NearbyTopo.fromRow(row)];
    });

/// How close counts as "the same place", in metres (C-6.1's "~50 m").
///
/// Not tighter, because the coordinates being compared are EXIF positions from
/// phone cameras, which are routinely tens of metres out — a 10 m radius would
/// miss most genuine duplicates and teach submitters the check does not work.
/// Not looser, because at a dense bouldering area 100 m is several distinct
/// blocks and every submission would be met with a list of things it is not.
const double kDuplicateRadiusM = 50;

/// Linking two topos as the same place, and undoing it. Admin-only; the server
/// re-checks, so nothing here is a security boundary.
class AlternateService {
  const AlternateService(this._ref);

  final Ref _ref;

  /// Returns the id of the resulting group head — which is NOT necessarily
  /// [canonicalId]. If that topo was itself an alternate, the server flattens
  /// the link onto its own canonical, and a caller that assumed otherwise would
  /// render the wrong name in its confirmation.
  Future<String> link({
    required String duplicateId,
    required String canonicalId,
    String? note,
  }) async {
    final head = await _ref
        .read(duplicatesRemoteProvider)
        .link(
          duplicateId: duplicateId,
          canonicalId: canonicalId,
          note: note,
        );
    // The admin queue renders `alreadyLinked` per report, so it is stale the
    // moment this succeeds.
    _ref.invalidate(openReportsProvider);
    return head;
  }

  Future<void> unlink(String wallId) async {
    await _ref.read(duplicatesRemoteProvider).unlink(wallId);
    _ref.invalidate(openReportsProvider);
  }
}

final alternateServiceProvider = Provider<AlternateService>(
  AlternateService.new,
);
