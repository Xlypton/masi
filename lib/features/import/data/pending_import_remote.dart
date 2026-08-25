import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/guidebook_import.dart';
import 'guidebook_import_codec.dart';

/// One guidebook import queued by the MCP server, waiting to be reviewed.
class PendingImport {
  const PendingImport({
    required this.id,
    required this.wallId,
    required this.photoId,
    required this.createdAt,
    required this.import,
  });

  final String id;
  final String wallId;
  final String photoId;
  final DateTime createdAt;

  /// The decoded payload. Decoded on the CLIENT with the same
  /// `decodeGuidebookImportMap` a pasted import uses — the server stores the
  /// model's JSON verbatim and validates nothing, so this is the only place
  /// its verdict is formed, and both entry paths therefore behave identically.
  final GuidebookImport import;
}

/// Reads and retires the pending imports the MCP server writes.
///
/// Every query here is RLS-scoped by the signed-in user's own token; the
/// `ownerId` filters below are narrowing, not the security boundary.
class PendingImportRemote {
  const PendingImportRemote(this._client);

  final SupabaseClient _client;

  static const _table = 'guidebook_imports';

  /// Unconsumed imports for [wallId], newest first.
  ///
  /// A payload the decoder rejects outright is **skipped**, not surfaced. There
  /// is nothing the user could do with "an import arrived but is unreadable" —
  /// they did not write it and cannot fix it — so a broken row must not sit on
  /// the canvas advertising itself forever. It stays in the table, unconsumed,
  /// where it can be inspected.
  Future<List<PendingImport>> pendingFor(String wallId, String uid) async {
    final rows = await _client
        .from(_table)
        .select()
        .eq('ownerId', uid)
        .eq('wallId', wallId)
        .isFilter('consumedAt', null)
        .order('createdAt', ascending: false);

    final result = <PendingImport>[];
    for (final row in rows) {
      final map = Map<String, dynamic>.from(row as Map);
      final payload = map['payload'];
      if (payload is! Map) continue;

      final decoded = decodeGuidebookImportMap(
        Map<String, Object?>.from(payload),
      );
      if (decoded is! ImportDecoded) continue;

      result.add(
        PendingImport(
          id: map['id'] as String,
          wallId: map['wallId'] as String,
          photoId: map['photoId'] as String,
          createdAt: DateTime.fromMillisecondsSinceEpoch(
            (map['createdAt'] as num?)?.toInt() ?? 0,
          ),
          import: decoded.import,
        ),
      );
    }
    return result;
  }

  /// Marks [id] dealt with, whether it was applied or dismissed.
  ///
  /// Consumed rather than deleted so a second device does not re-offer an
  /// import this one already handled.
  Future<void> markConsumed(String id) async {
    await _client
        .from(_table)
        .update({'consumedAt': DateTime.now().millisecondsSinceEpoch})
        .eq('id', id);
  }
}
