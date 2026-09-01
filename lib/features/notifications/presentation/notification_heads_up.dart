import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../shared/presentation/masi_toast.dart';
import '../../account/application/auth_providers.dart';
import '../application/notification_providers.dart';
import '../domain/app_notification.dart';

/// Surfaces a notification that lands WHILE the app is open, as a toast.
///
/// **The gap this closes.** `NotificationRealtime` already keeps a live
/// subscription and pulls the moment somebody comments on your topo — but the
/// only thing that changed on screen was a number on a bell the user may not
/// be looking at. Push notifications cover the case where the app is closed;
/// between the two there was nothing at all for the case where it is open,
/// which is precisely when the app is best placed to say something.
///
/// Renders nothing ([SizedBox.shrink]); it exists for its listener. Mount it
/// somewhere that stays mounted for the whole signed-in session — `NavShell`,
/// the same place `notificationRealtimeProvider` is watched — because a
/// heads-up that only works while one particular tab is built is not a
/// heads-up.
///
/// ## What it deliberately does NOT do
///
///  - **It never announces the backlog.** The first list emission after
///    mounting (or after an identity change) is taken as the baseline and
///    passes silently. Without that, every cold start would fire a toast for
///    things that happened last week — which is how a notification system
///    teaches people to ignore it.
///  - **It stays quiet on the notification centre itself.** The user is
///    already looking at the list the entry is being added to; a toast over
///    it would be the app telling somebody something they can see.
///  - **It collapses a burst into one toast.** Five likes in a row is five
///    Realtime events, one refresh (`CoalescingRefresh`) and one thing worth
///    knowing.
class NotificationHeadsUp extends ConsumerStatefulWidget {
  const NotificationHeadsUp({super.key});

  @override
  ConsumerState<NotificationHeadsUp> createState() =>
      _NotificationHeadsUpState();
}

class _NotificationHeadsUpState extends ConsumerState<NotificationHeadsUp> {
  /// Ids this session has already accounted for. Replaced wholesale on every
  /// emission rather than accumulated, so it stays bounded by the size of the
  /// mirror instead of growing for the life of the session.
  Set<String> _seen = const {};

  /// The identity the baseline was taken for, or null while unprimed.
  ///
  /// Keyed by uid rather than a plain bool because signing out and back in as
  /// somebody else must re-baseline: their inbox is a different inbox, and
  /// inheriting the previous user's `_seen` would either announce their
  /// backlog or silence their first real notification.
  String? _primedForUid;

  void _onList(String? uid, List<AppNotification> list) {
    if (uid == null) {
      // Signed out: there is no inbox, and whatever is in `_seen` belongs to
      // whoever was signed in before.
      _seen = const {};
      _primedForUid = null;
      return;
    }

    final ids = {for (final n in list) n.id};
    if (_primedForUid != uid) {
      _primedForUid = uid;
      _seen = ids;
      return;
    }

    final arrived = [
      for (final n in list)
        if (n.isUnread && !_seen.contains(n.id)) n,
    ];
    _seen = ids;
    if (arrived.isEmpty || !mounted) return;
    if (_isOnNotificationCentre()) return;

    // The list is newest-first (`NotificationsRepository.watchAll`), so the
    // head is the one to name. Named from `AppNotification.actorName` — the
    // display name the RPC resolved — rather than through
    // `profileDisplayNameProvider` like the inbox rows do: that provider is
    // asynchronous, and a toast that has to wait on a profile read is a toast
    // that arrives after the moment it was about. `sentenceWith(null)` falls
    // back to "Someone", which is still a true sentence.
    final newest = arrived.first;
    final extra = arrived.length - 1;
    final message = extra == 0
        ? newest.sentenceWith(null)
        : '${newest.sentenceWith(null)} · $extra more';

    ScaffoldMessenger.of(context).showMasiToast(
      message,
      // Somebody liking your topo is neither a success nor a failure of
      // anything the user just did — it is news.
      kind: MasiToastKind.info,
      // A heads-up that cannot be acted on is an interruption. One tap goes
      // straight to the thing when there is exactly one, and to the inbox
      // when there are several — pushing one of five would be an arbitrary
      // choice made on the user's behalf.
      actionLabel: 'View',
      onAction: () {
        if (!mounted) return;
        final route = extra == 0 ? newest.route : null;
        context.push(route ?? '/notifications');
      },
    );
  }

  /// True while the notification centre is the top route.
  ///
  /// Reads the router's live configuration rather than a `GoRouterState.of`
  /// dependency: this widget lives in the shell, so `GoRouterState.of` would
  /// hand back the SHELL's state — which never changes when a sibling
  /// top-level route like `/notifications` is pushed above it.
  bool _isOnNotificationCentre() {
    final router = GoRouter.maybeOf(context);
    if (router == null) return false;
    return router.routerDelegate.currentConfiguration.uri.path ==
        '/notifications';
  }

  @override
  Widget build(BuildContext context) {
    final uid = ref.watch(effectiveUidProvider);
    ref.listen<AsyncValue<List<AppNotification>>>(notificationsProvider, (
      previous,
      next,
    ) {
      final list = next.asData?.value;
      if (list != null) _onList(uid, list);
    });
    return const SizedBox.shrink();
  }
}
