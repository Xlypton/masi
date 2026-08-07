import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/supabase_providers.dart';
import '../data/topo_versions_remote.dart';
import '../domain/topo_version.dart';

/// The cloud read/write seam for version history. Overridden in tests with an
/// in-memory fake — never the real one, which would touch the network.
final topoVersionsRemoteProvider = Provider<TopoVersionsRemote>(
  (ref) => SupabaseTopoVersionsRemote(ref.watch(supabaseClientProvider)),
);

/// One topo's recorded history, newest first.
///
/// Deliberately NOT best-effort, unlike most reads in this feature: an error
/// surfaces as an error. An empty history list is a factual claim ("nothing
/// has ever changed here"), so rendering one because the request failed would
/// state something false about the very thing a reader opened this screen to
/// check.
///
/// `autoDispose`: history is consulted occasionally and on purpose. Keeping a
/// cached copy per wall for the life of the app would hold snapshots nobody is
/// looking at, and a stale history is worse than a re-fetch.
final topoVersionsProvider = FutureProvider.autoDispose
    .family<List<TopoVersion>, String>((ref, wallId) async {
      final rows = await ref
          .watch(topoVersionsRemoteProvider)
          .fetchVersions(wallId);
      return [for (final row in rows) TopoVersion.fromRow(row)];
    });

/// Restores a version and refreshes the list.
///
/// Errors propagate: a revert that silently failed would leave an admin
/// believing a vandalised topo had been repaired, which is the single worst
/// outcome this whole phase is built to avoid.
class TopoVersionService {
  const TopoVersionService(this._ref);

  final Ref _ref;

  /// Returns how many routes the restored snapshot carried.
  Future<int> revert({
    required String wallId,
    required String versionId,
  }) async {
    final routes = await _ref
        .read(topoVersionsRemoteProvider)
        .revert(wallId: wallId, versionId: versionId);
    // The revert itself writes a version (the server snapshots before
    // overwriting), so the list the admin is looking at is stale the instant
    // this returns.
    _ref.invalidate(topoVersionsProvider(wallId));
    return routes;
  }
}

final topoVersionServiceProvider = Provider<TopoVersionService>(
  TopoVersionService.new,
);
