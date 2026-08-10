/// One topo an admin deleted via `admin_delete_topo` that is still waiting on
/// an `admin_restore_topo` call — the row the "Removed" admin tab is built
/// from.
///
/// Built from a `moderation_log` entry (already filtered down by
/// [ModerationRemote]'s sibling seam,
/// `currentlyAdminDeletedWalls` in `admin_deletion_log_remote.dart`), not
/// from a live read of the wall itself. Deliberately carries no wall NAME:
/// `moderation_log` names only the wall id, and the wall's own row is not
/// reliably readable once it is deleted — `admin_delete_topo` flips
/// `wall_moderation.state` to `removed`, and the `walls` table's RLS never
/// carries an admin exemption for a foreign, non-shared row. Showing the id
/// plus when and why is the honest amount of information here, rather than a
/// best-effort name lookup that could go stale or simply fail.
class AdminDeletedTopo {
  const AdminDeletedTopo({
    required this.wallId,
    required this.deletedAt,
    this.reason,
    this.actorId,
  });

  /// Builds one from a raw, already-reduced `moderation_log` row, or null if
  /// unusable. Dropped rather than half-built, like every other admin
  /// surface in this feature (`DeletionRequest.fromRow`,
  /// `MaterialChange.fromRow`) — the decision this row leads to changes what
  /// is visible to the public, which is not the place to act on a row this
  /// code cannot fully read.
  static AdminDeletedTopo? fromRow(Map<String, dynamic> row) {
    final wallId = row['targetId'];
    final deletedAt = row['createdAt'];
    if (wallId is! String || wallId.isEmpty) return null;
    if (deletedAt is! int) return null;
    final reason = row['reason'];
    final actorId = row['actorId'];
    return AdminDeletedTopo(
      wallId: wallId,
      deletedAt: deletedAt,
      reason: reason is String && reason.trim().isNotEmpty ? reason : null,
      actorId: actorId is String && actorId.isNotEmpty ? actorId : null,
    );
  }

  final String wallId;

  /// Epoch ms — the instant `admin_delete_topo` stamped, which is also the
  /// exact instant [ModerationRemote.adminRestoreTopo] matches rows on. Not
  /// a fresh "now": rows the owner deleted themselves at some OTHER time stay
  /// deleted.
  final int deletedAt;

  /// Why the topo was taken down, if the admin gave one. Shown to the admin
  /// deciding whether to restore it — never to the public.
  final String? reason;

  /// Who deleted it. Currently unused by the UI (there is exactly one admin
  /// today), kept for when there is more than one.
  final String? actorId;
}
