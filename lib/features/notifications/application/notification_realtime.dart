import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/config/supabase_providers.dart';
import '../../account/application/auth_providers.dart';
import 'coalescing_refresh.dart';
import 'notification_providers.dart';

/// Keeps a Realtime subscription open so a notification lands while the user is
/// looking at the app, instead of on the next pull.
///
/// **Why this exists at all.** Everything else in this app is pull-on-demand —
/// nothing polls, by design. That is right for topos and moderation state,
/// which the user goes looking for. It is wrong for an inbox: the whole point
/// of a badge is that it appears without being asked for, and a badge that only
/// updates when you open the screen it is attached to has nothing to tell you
/// by the time you see it.
///
/// **It does not trust the payload.** A Postgres change event carries the new
/// row, and writing that straight into the mirror would be the obvious thing to
/// do. It would also be a second, subtly different ingest path: the RPC returns
/// the actor's resolved display name, the raw row carries only `actorId`, so
/// rows arriving this way would render as "Someone" until a pull replaced them.
/// The event is used only as a NUDGE — it triggers the same
/// [refreshNotifications] the screen uses, so there is exactly one way a
/// notification reaches the mirror.
///
/// **The filter is not the security boundary.** RLS applies to Realtime, so the
/// server would refuse to send another user's rows regardless. Filtering on
/// `recipientId` server-side just avoids waking every client for every insert.
///
/// Degrades to nothing, loudly in debug and silently in release, when Supabase
/// is unavailable: this is an accelerator on top of a pull that still works.
class NotificationRealtime extends Notifier<bool> {
  RealtimeChannel? _channel;

  /// Built lazily on the first nudge, because it closes over [ref] and the
  /// `Notifier`'s `ref` is not available at field-initialiser time.
  CoalescingRefresh? _refresh;

  @override
  bool build() {
    // Re-subscribes on every identity change. The channel is keyed by uid, so
    // signing out tears the old one down and signing in as somebody else does
    // not inherit it.
    final uid = ref.watch(effectiveUidProvider);

    ref.onDispose(_teardown);

    if (uid == null) return false;

    final SupabaseClient client;
    try {
      client = ref.watch(supabaseClientProvider);
    } catch (error) {
      // No Supabase at all — early boot, or any widget test that has not stood
      // up a fake. The pull path is unaffected.
      debugPrint('masi/notifications: realtime unavailable: $error');
      return false;
    }

    try {
      _channel = client
          .channel('masi:notifications:$uid')
          .onPostgresChanges(
            event: PostgresChangeEvent.insert,
            schema: 'public',
            table: 'notifications',
            filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq,
              column: 'recipientId',
              value: uid,
            ),
            callback: (_) => _nudge(),
          )
          .subscribe();
      return true;
    } catch (error) {
      debugPrint('masi/notifications: realtime subscribe failed: $error');
      return false;
    }
  }

  /// Pulls, coalescing bursts.
  ///
  /// Somebody liking five of your topos in a row is five events and one thing
  /// worth knowing. Without a guard each would start its own fetch, and they
  /// would race to write the same mirror rows.
  ///
  /// The guard used to be a bare `if (_refreshInFlight) return;`, which is
  /// leading-edge only: an insert arriving after the refresh had read the
  /// server but before it completed was DISCARDED, not coalesced, and the
  /// badge lagged until the user opened a screen. [CoalescingRefresh] keeps
  /// the leading edge (a badge must not wait out a debounce) and adds the
  /// trailing run that "coalescing" actually means.
  void _nudge() {
    (_refresh ??= CoalescingRefresh(
      () => refreshNotifications(ref),
      onError: (error) =>
          debugPrint('masi/notifications: realtime refresh failed: $error'),
    )).schedule();
  }

  void _teardown() {
    final channel = _channel;
    _channel = null;
    if (channel == null) return;
    try {
      unawaited(channel.unsubscribe());
    } catch (_) {
      // Disposal is best-effort. A channel that cannot be unsubscribed (the
      // socket is already gone, most likely) must not throw out of a provider
      // teardown and take the widget tree with it.
    }
  }
}

/// Live notification delivery. Watch it somewhere always-mounted — see
/// `NavShell` — because a subscription only exists while something is watching
/// this provider, exactly like `syncOrchestratorProvider`.
final notificationRealtimeProvider = NotifierProvider<NotificationRealtime, bool>(
  NotificationRealtime.new,
);
