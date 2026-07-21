import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/supabase_providers.dart';
import '../../../core/db/database_provider.dart';
import '../../backup/application/backup_providers.dart';
import '../../backup/data/sync_remote.dart';
import '../../topo/data/photo_files.dart';
import '../data/shared_wall_hydrator.dart';

/// The [SharedWallRemote] the anon shared-wall hydration path (Feature #15
/// Wave 2) talks to.
///
/// Defaults to the real [SupabaseSharedWallRemote] wired to the shared
/// [supabaseClientProvider] — same pattern as `syncRemoteProvider`/
/// `backupRemoteProvider` (unguarded: reading this before `Supabase
/// .initialize` has run throws, exactly like those two). Override this in
/// tests with an in-memory fake (see
/// `test/features/community/data/shared_wall_hydrator_test.dart`'s
/// `FakeSharedWallRemote`) so nothing ever hits the real network.
final sharedWallRemoteProvider = Provider<SharedWallRemote>(
  (ref) => SupabaseSharedWallRemote(ref.watch(supabaseClientProvider)),
);

/// The [SharedWallHydrator] Wave 3's shareable-topo-landing UI awaits via
/// [ensureSharedWallLocalProvider] below. Wired to the app-wide database,
/// backup repository (for its LWW import machinery, reused rather than
/// reinvented), the anon [sharedWallRemoteProvider], and the platform photo
/// store. Overridable wholesale in tests (or piecemeal via its upstream
/// providers).
final sharedWallHydratorProvider = Provider<SharedWallHydrator>(
  (ref) => SharedWallHydrator(
    db: ref.watch(appDatabaseProvider),
    backupRepository: ref.watch(backupRepositoryProvider),
    remote: ref.watch(sharedWallRemoteProvider),
    photoFiles: PhotoFiles(),
  ),
);

/// Ensures wall [wallId] is hydrated into local Drift + the local photo
/// store (see [SharedWallHydrator.ensureSharedWallLocal] for the fast
/// no-op/idempotence/anon-safety guarantees), exposed as a `.family` so
/// Wave 3's landing screen can `ref.watch(ensureSharedWallLocalProvider(
/// wallId))` and get `AsyncLoading`/`AsyncData`/`AsyncError` states for
/// free. `autoDispose` so a visitor navigating away from the landing page
/// doesn't keep this cached forever — a later visit re-runs the (idempotent,
/// fast-no-op-when-already-local) check rather than trusting a stale result.
final ensureSharedWallLocalProvider = FutureProvider.autoDispose.family<void, String>(
  (ref, wallId) => ref.watch(sharedWallHydratorProvider).ensureSharedWallLocal(wallId),
);
