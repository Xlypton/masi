import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme.dart';
import '../../../shared/presentation/masi_async_view.dart';
import '../../../shared/presentation/masi_icon.dart';
import '../../account/application/profile_providers.dart';
import '../application/notification_providers.dart';
import '../domain/app_notification.dart';
import 'push_toggle.dart';

/// The notification centre: what other people did to your work.
///
/// Reads the LOCAL MIRROR and refreshes it on mount, rather than rendering the
/// fetch directly. That ordering is the whole offline story — the list paints
/// from cold, a failed refresh leaves the previous contents standing instead
/// of blanking the screen, and a climber with no signal still sees what
/// happened before they left.
///
/// Every entry is tappable through to the thing it is about. An inbox that
/// tells you something happened and then makes you go and find it is a to-do
/// list, not a notification.
class NotificationsScreen extends ConsumerStatefulWidget {
  const NotificationsScreen({super.key});

  @override
  ConsumerState<NotificationsScreen> createState() =>
      _NotificationsScreenState();
}

class _NotificationsScreenState extends ConsumerState<NotificationsScreen> {
  /// Set when the refresh failed AND we have nothing mirrored to show. Kept
  /// separate from the list's own AsyncValue because the two failures mean
  /// different things: the list stream is local Drift and effectively cannot
  /// fail, while this one means "we could not ask the server", which is worth
  /// saying out loud rather than rendering as an empty inbox.
  Object? _refreshError;

  @override
  void initState() {
    super.initState();
    // Nothing polls in this app — a screen that wants a fresh answer asks for
    // one at the moment it is about to render it.
    Future.microtask(_refresh);
  }

  Future<void> _refresh() async {
    try {
      await refreshNotificationsFrom(ref);
      if (mounted) setState(() => _refreshError = null);
    } catch (error) {
      // Deliberately does NOT clear the list. The mirror is still the truth as
      // of the last successful pull, and stale-with-a-warning beats blank.
      if (mounted) setState(() => _refreshError = error);
    }
  }

  Future<void> _markAllRead() async {
    try {
      await ref.read(notificationReadServiceProvider).markAllRead();
    } catch (_) {
      if (!mounted) return;
      // Said out loud rather than swallowed: the badge is still there, and a
      // user who tapped "Mark all read" and saw nothing change would assume
      // the app is broken rather than that the network is.
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("Couldn't mark those read")));
    }
  }

  @override
  Widget build(BuildContext context) {
    final unread = ref.watch(unreadNotificationCountProvider).value ?? 0;

    return Scaffold(
      key: const Key('notifications-screen'),
      appBar: AppBar(
        title: Text(
          'Notifications',
          style: Theme.of(context).textTheme.displaySmall,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        centerTitle: false,
        actions: [
          // Only when there is something to mark. A control that does nothing
          // is worse than an absent one: it teaches the user that tapping
          // things here has no effect.
          if (unread > 0)
            TextButton(
              key: const Key('notifications-mark-all'),
              onPressed: _markAllRead,
              child: const Text('Mark all read'),
            ),
        ],
      ),
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            const PushToggle(),
            Expanded(child: _buildList()),
          ],
        ),
      ),
    );
  }

  Widget _buildList() {
    return RefreshIndicator(
      onRefresh: _refresh,
      child: MasiAsyncView<List<AppNotification>>(
        value: ref.watch(notificationsProvider),
        errorMessage: "Couldn't load your notifications",
        showErrorDetail: false,
        onRetry: _refresh,
        skeleton: (context) => const Center(
          child: Padding(
            padding: EdgeInsets.all(MasiSpacing.xxl),
            child: CircularProgressIndicator(),
          ),
        ),
        data: (context, list) => list.isEmpty
            ? _NotificationsEmpty(refreshFailed: _refreshError != null)
            : _NotificationsList(list: list),
      ),
    );
  }
}

/// Two different empty states, because they are two different facts.
///
/// "Nothing yet" and "we could not ask" look identical on screen and mean
/// opposite things, and conflating them is the exact failure the moderation
/// queues are also careful about: a list that silently renders empty on a
/// failed call says "nothing has happened", which is precisely the conclusion
/// an inbox must never invite.
class _NotificationsEmpty extends StatelessWidget {
  const _NotificationsEmpty({required this.refreshFailed});

  final bool refreshFailed;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    // A ListView, not a Center: an empty state inside a RefreshIndicator has
    // to be scrollable or pull-to-refresh does not work on it.
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: MasiSpacing.xxl * 2),
      children: [
        Center(
          child: Column(
            children: [
              MasiIcon(
                refreshFailed ? 'cloud_rain' : 'flash',
                size: 40,
                color: colors.ink3,
              ),
              const SizedBox(height: MasiSpacing.md),
              Text(
                refreshFailed
                    ? "Couldn't check for new activity"
                    : 'Nothing yet',
                key: Key(
                  refreshFailed
                      ? 'notifications-empty-offline'
                      : 'notifications-empty',
                ),
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(color: colors.ink2),
              ),
              const SizedBox(height: MasiSpacing.xs),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: MasiSpacing.xxl,
                ),
                child: Text(
                  refreshFailed
                      ? 'Pull down to try again'
                      : "When somebody comments on, tags you in or likes your "
                            'work, it shows up here',
                  textAlign: TextAlign.center,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: colors.ink3),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _NotificationsList extends StatelessWidget {
  const _NotificationsList({required this.list});

  final List<AppNotification> list;

  @override
  Widget build(BuildContext context) => ListView.builder(
    padding: const EdgeInsets.only(bottom: MasiSpacing.xxl),
    itemCount: list.length,
    itemBuilder: (context, i) => _NotificationRow(notification: list[i]),
  );
}

/// One entry, as a sentence.
///
/// A [ConsumerWidget] so it can resolve the actor's name through
/// [profileDisplayNameProvider] — the same live door every other author name
/// in the app goes through, so renaming yourself repaints every mention of you
/// at once. Never renders [AppNotification.actorId]; an unresolvable actor
/// reads "Someone", which is a true sentence, where a uid is not a sentence at
/// all.
class _NotificationRow extends ConsumerWidget {
  const _NotificationRow({required this.notification});

  final AppNotification notification;

  Future<void> _open(BuildContext context, WidgetRef ref) async {
    // Read first, THEN navigate. Marking is a network call, and awaiting it
    // before opening would put a stall between the tap and the screen for a
    // piece of bookkeeping the user does not care about. Its failure is
    // swallowed for the same reason: the next tap re-marks it, and refusing to
    // open the topo because a read receipt did not send would be absurd.
    final route = notification.route;
    if (route != null) context.push(route);
    try {
      await ref.read(notificationReadServiceProvider).markRead(notification.id);
    } catch (_) {
      // Intentionally silent — see above.
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = MasiColors.of(context);
    final textTheme = Theme.of(context).textTheme;
    final n = notification;

    final actorId = n.actorId;
    final resolved = actorId == null
        ? null
        : ref.watch(profileDisplayNameProvider(actorId)).asData?.value;

    final detail = n.detail;

    return InkWell(
      key: Key('notification-row-${n.id}'),
      onTap: () => _open(context, ref),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: MasiSpacing.lg,
          vertical: MasiSpacing.md,
        ),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: colors.separator)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // The unread marker is a dot in the gutter, not a bold row or a
            // tinted background: an inbox where most entries are unread would
            // otherwise be a wall of emphasis, which emphasises nothing.
            SizedBox(
              width: MasiSpacing.md,
              child: n.isUnread
                  ? Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Container(
                        key: Key('notification-unread-${n.id}'),
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: colors.accent,
                          shape: BoxShape.circle,
                        ),
                      ),
                    )
                  : null,
            ),
            const SizedBox(width: MasiSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    n.sentenceWith(resolved),
                    style: textTheme.bodyMedium?.copyWith(
                      color: colors.ink,
                      fontWeight: n.isUnread
                          ? FontWeight.w600
                          : FontWeight.w400,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (detail != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      detail,
                      key: Key('notification-detail-${n.id}'),
                      style: textTheme.bodySmall?.copyWith(color: colors.ink2),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: MasiSpacing.sm),
            Text(
              notificationAge(n.createdAt, now: DateTime.now()),
              style: textTheme.bodySmall?.copyWith(color: colors.ink3),
            ),
          ],
        ),
      ),
    );
  }
}
