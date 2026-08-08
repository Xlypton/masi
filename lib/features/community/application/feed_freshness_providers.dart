import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/database_provider.dart';
import '../../../core/db/settings_store.dart';
import '../../account/application/auth_providers.dart';
import '../domain/feed_freshness.dart';
import 'community_providers.dart';

/// When this device last looked at the Community Feed, for the current
/// account — `null` until it has looked once.
///
/// A `Notifier` rather than a `FutureProvider` because it is both read and
/// WRITTEN: `markSeen` stamps it, and the Feed tab's dot has to disappear in
/// the same frame. (`StateProvider` is banned in this codebase — Riverpod v3,
/// see CLAUDE.md.)
///
/// The initial read is asynchronous but the state is not: it starts `null`,
/// which reads as "no baseline yet" and therefore no dot, and settles to the
/// stored value a microtask later. That ordering is deliberate — the only way
/// to be wrong for that instant is to show NO dot when one was due, and a dot
/// that appears a frame late is invisible where a dot that flashes and
/// vanishes is not.
class FeedLastSeen extends Notifier<int?> {
  @override
  int? build() {
    // Re-reads on sign-in/sign-out, because the key is per-account.
    final uid = ref.watch(effectiveUidProvider);
    _load(uid);
    return null;
  }

  Future<void> _load(String? uid) async {
    final raw = await ref
        .read(settingsStoreProvider)
        .read(SettingsStore.feedLastSeenKey(uid));
    final parsed = raw == null ? null : int.tryParse(raw);
    // `int.tryParse`, not `int.parse`: this value round-trips through a TEXT
    // column that anything could in principle have written, and a corrupt
    // baseline must degrade to "never looked" rather than throwing during a
    // provider build.
    if (parsed != null) state = parsed;
  }

  /// Records that the user is looking at the feed right now.
  ///
  /// Writes local state FIRST and persists after: the dot must clear on the
  /// tap, not on the round trip to storage. A failed write costs one stale dot
  /// on the next cold start, which is not worth blocking the UI for.
  Future<void> markSeen() async {
    final now = ref.read(nowMsProvider)();
    state = now;
    final uid = ref.read(effectiveUidProvider);
    try {
      await ref
          .read(settingsStoreProvider)
          .write(SettingsStore.feedLastSeenKey(uid), '$now');
    } catch (_) {
      // Housekeeping. A device whose settings table cannot be written has
      // much louder problems than a nav dot, and this must never be able to
      // throw out of a tab tap.
    }
  }
}

final feedLastSeenProvider = NotifierProvider<FeedLastSeen, int?>(
  FeedLastSeen.new,
);

/// Whether the Feed tab should show its unseen dot right now.
///
/// Deliberately derived from the feed the user would ACTUALLY see —
/// [feedItemsProvider], the same union the Feed screen renders — rather than
/// from a separate count query. A dot that can disagree with the list it
/// points at is worse than no dot: the user taps, finds nothing new, and stops
/// trusting it.
///
/// Resolves to `false` while the feed is still loading and whenever it errors.
/// Both are "we do not know", and the honest rendering of "we do not know" is
/// no badge at all.
final feedHasUnseenProvider = Provider<bool>((ref) {
  final items = ref.watch(feedItemsProvider).asData?.value;
  if (items == null) return false;

  final newest = newestForeignArrival(
    items.map((item) => (at: item.feedArrivalMs, ownerId: item.ownerId)),
    ref.watch(effectiveUidProvider),
  );
  return feedHasUnseen(
    newestForeignAt: newest,
    lastSeenAt: ref.watch(feedLastSeenProvider),
  );
});
