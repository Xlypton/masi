import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/supabase_providers.dart';
import '../../account/application/auth_providers.dart';
import '../data/pending_import_remote.dart';

final pendingImportRemoteProvider = Provider<PendingImportRemote>(
  (ref) => PendingImportRemote(ref.watch(supabaseClientProvider)),
);

/// Guidebook imports queued by the MCP server for one wall.
///
/// A `FutureProvider`, deliberately not a stream: an import arrives while the
/// user is in a different app entirely (their chat app), so there is no moment
/// during which a live subscription would be watched. The canvas refreshes this
/// when it mounts and when the user asks, which is when the answer can actually
/// be seen.
///
/// Fails **soft**: signed out, offline, or a rejecting backend all resolve to an
/// empty list rather than an error. This drives an optional affordance on a
/// screen whose real job is drawing, and a red banner there would punish the
/// user for a feature they may never use.
final pendingImportsProvider =
    FutureProvider.family<List<PendingImport>, String>((ref, wallId) async {
  final uid = ref.watch(effectiveUidProvider);
  if (uid == null) return const [];
  try {
    return await ref.watch(pendingImportRemoteProvider).pendingFor(wallId, uid);
  } catch (_) {
    return const [];
  }
});
