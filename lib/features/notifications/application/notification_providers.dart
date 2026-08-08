import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/supabase_providers.dart';
import '../../../core/db/database_provider.dart';
import '../../account/application/auth_providers.dart';
import '../data/notifications_remote.dart';
import '../data/notifications_repository.dart';
import '../domain/app_notification.dart';

/// The cloud seam. Overridden in tests with an in-memory fake — never the real
/// one, which would touch the network.
final notificationsRemoteProvider = Provider<NotificationsRemote>(
  (ref) => SupabaseNotificationsRemote(ref.watch(supabaseClientProvider)),
);

/// Local reads and mirror writes.
final notificationsRepositoryProvider = Provider<NotificationsRepository>(
  (ref) => NotificationsRepository(ref.watch(appDatabaseProvider)),
);

/// The inbox, newest first — read from the LOCAL MIRROR, not from the network.
///
/// That is the whole reason there is a mirror. A climber standing at a crag
/// with no signal still sees what happened before they left, and the screen
/// paints instantly from cold instead of after a round trip.
/// [refreshNotifications] is what fills the mirror; nothing here fetches.
///
/// Emits an empty list while signed out. There is no inbox without an
/// identity, and an error there would put a red screen in front of somebody
/// whose only problem is that they have not signed in.
final notificationsProvider = StreamProvider<List<AppNotification>>((ref) {
  // §1c: the single local-data uid door — never `authStateProvider.asData`,
  // which reads null on AsyncError too.
  final uid = ref.watch(effectiveUidProvider);
  if (uid == null) return Stream.value(const <AppNotification>[]);
  return ref.watch(notificationsRepositoryProvider).watchAll(uid);
});

/// How many unread, for the badge.
///
/// From the mirror, for the same reason as [notificationsProvider], and
/// because a badge that needs the network is a badge that is absent exactly
/// when the app is slowest. A pull writes `readAt` into the mirror, so the
/// server's count reaches this the moment [refreshNotifications] returns —
/// which is why nothing here calls `unreadCount()` directly.
final unreadNotificationCountProvider = StreamProvider<int>((ref) {
  final uid = ref.watch(effectiveUidProvider);
  if (uid == null) return Stream.value(0);
  return ref.watch(notificationsRepositoryProvider).watchUnreadCount(uid);
});

/// Pulls the inbox and writes it to the mirror. Returns the rows written.
///
/// Called where the answer is about to be rendered — the screen mounting,
/// pull-to-refresh — rather than on a timer, matching how
/// `reachabilityProvider` is probed on demand rather than subscribed to.
/// Nothing in this app polls.
///
/// Lets the fetch's errors propagate. Unlike the moderation banners, which
/// decorate a screen that must open regardless, this IS the screen: an empty
/// list that silently meant "we could not ask" would read as "nothing has
/// happened", the one conclusion an inbox must never invite. The screen shows
/// the mirror underneath either way, so a failed refresh degrades to stale
/// rather than to blank.
Future<int> refreshNotifications(Ref ref, {int limit = 50}) => pullNotifications(
  uid: ref.read(effectiveUidProvider),
  remote: ref.read(notificationsRemoteProvider),
  repository: ref.read(notificationsRepositoryProvider),
  limit: limit,
);

/// [refreshNotifications] for a widget, which holds a [WidgetRef] rather than
/// a [Ref].
///
/// Unlike `refreshWallModerationFrom`, this does NOT swallow. That one
/// decorates a screen which must open regardless; this one IS the screen, and
/// its caller needs to be able to tell "nothing has happened" from "we could
/// not ask" — including when the throw comes from the provider READS rather
/// than the fetch (`supabaseClientProvider` raises if Supabase was never
/// initialised, which is early boot and every widget test that does not stand
/// up a fake).
Future<int> refreshNotificationsFrom(WidgetRef ref, {int limit = 50}) =>
    pullNotifications(
      uid: ref.read(effectiveUidProvider),
      remote: ref.read(notificationsRemoteProvider),
      repository: ref.read(notificationsRepositoryProvider),
      limit: limit,
    );

/// The collaborator-explicit half of [refreshNotifications].
///
/// Split out so tests can drive the pull with a `ProviderContainer` (which is
/// not a [Ref]) and with hand-built fakes, rather than standing up a widget
/// tree just to obtain one.
Future<int> pullNotifications({
  required String? uid,
  required NotificationsRemote remote,
  required NotificationsRepository repository,
  int limit = 50,
}) async {
  // Short-circuits before touching the network: signed out, there is no inbox
  // to ask about, and the RPC would refuse with a 42501 anyway.
  if (uid == null) return 0;
  final rows = await remote.fetch(limit: limit);
  return repository.upsertFromRemote(rows);
}

/// Marking notifications read.
///
/// Server first, mirror second, and never the other way round. The RPC is the
/// only thing that can write `readAt` — there is no update policy on the table
/// — so a local-first mark would show a cleared badge that the very next pull
/// silently refills. Writing the mirror only after the server confirms means
/// the badge is either right or unchanged, never briefly lying.
///
/// A service rather than a bare remote call from the widget, so the mirror
/// write cannot be forgotten at a call site: an entry that stays bold after
/// being read invites a second tap, and the user has no way to know the RPC is
/// idempotent.
class NotificationReadService {
  const NotificationReadService(this._ref);

  final Ref _ref;

  /// Marks one entry read. A no-op for an entry that already is — the RPC
  /// only ever moves `readAt` away from null, so "read at" stays the instant
  /// it was first seen rather than becoming "last tapped at".
  Future<void> markRead(String id) => _mark(ids: [id]);

  /// Marks everything read.
  Future<void> markAllRead() => _mark();

  Future<void> _mark({List<String>? ids}) async {
    final uid = _ref.read(effectiveUidProvider);
    if (uid == null) return;
    await _ref.read(notificationsRemoteProvider).markRead(ids: ids);
    // The server's clock decided the real instant, and this one is only ever
    // used to make the mirror stop counting the row as unread. The next pull
    // overwrites it with the authoritative value, so a few milliseconds of
    // skew here is invisible and costs nothing.
    await _ref
        .read(notificationsRepositoryProvider)
        .markReadLocally(
          uid,
          ids: ids,
          atMs: DateTime.now().millisecondsSinceEpoch,
        );
  }
}

final notificationReadServiceProvider = Provider<NotificationReadService>(
  NotificationReadService.new,
);
