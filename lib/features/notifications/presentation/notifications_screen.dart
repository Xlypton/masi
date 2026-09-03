import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme.dart';
import '../../../shared/presentation/bottom_safe_inset.dart';
import '../../../shared/presentation/masi_async_view.dart';
import '../../../shared/presentation/masi_avatar.dart';
import '../../../shared/presentation/masi_icon.dart';
import '../../../shared/presentation/masi_toast.dart';
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
///
/// **Shape (reworked).** The list is a grouped inset list — DESIGN.md's
/// "Topos home" pattern, which is the same pattern every other list in this
/// app uses — under `Today` / `This week` / `Earlier` headings, rather than
/// one undifferentiated run of full-bleed rows. Two things drove that:
///  - An inbox is scanned for "is this still current?" before it is read for
///    "what is it?", and an unheaded list makes that question unanswerable
///    without doing the age arithmetic on every row.
///  - Every entry now leads with the ACTOR'S FACE (badged with what they
///    did), because a notification is a thing a person did — the previous
///    row led with an unread dot in an otherwise empty gutter, which spent
///    the most valuable column on the least informative field.
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
      ScaffoldMessenger.of(context).showMasiToast("Couldn't mark those read", kind: MasiToastKind.error);
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
            Padding(
              padding: const EdgeInsets.only(right: MasiSpacing.sm),
              child: TextButton(
                key: const Key('notifications-mark-all'),
                onPressed: _markAllRead,
                child: const Text('Mark all read'),
              ),
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
    final textTheme = Theme.of(context).textTheme;
    // A ListView, not a Center: an empty state inside a RefreshIndicator has
    // to be scrollable or pull-to-refresh does not work on it.
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: MasiSpacing.xxl * 2),
      children: [
        Center(
          child: Column(
            children: [
              // The glyph sits on a faint amethyst disc rather than floating
              // loose in the middle of the screen — the same treatment the
              // kind badges below use, so an empty inbox still looks like it
              // belongs to the screen that fills it.
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  color: colors.accent.withValues(alpha: 0.10),
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child: MasiIcon(
                    refreshFailed ? 'cloud_rain' : 'flash',
                    size: 32,
                    color: refreshFailed ? colors.ink3 : colors.accent,
                  ),
                ),
              ),
              const SizedBox(height: MasiSpacing.lg),
              Text(
                refreshFailed
                    ? "Couldn't check for new activity"
                    : 'Nothing yet',
                key: Key(
                  refreshFailed
                      ? 'notifications-empty-offline'
                      : 'notifications-empty',
                ),
                style: textTheme.titleMedium?.copyWith(color: colors.ink),
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
                  style: textTheme.bodySmall?.copyWith(color: colors.ink3),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// One line of the flattened inbox — a section heading, or an entry with the
/// two flags that tell it where it sits in its card group.
///
/// Flattened rather than rendered as a `Column` of sections inside a
/// `ListView` so the list stays ONE lazily-built scrollable: the same reason
/// `topos_screen.dart` flattens its tier tree instead of nesting real
/// widgets.
sealed class _InboxLine {
  const _InboxLine();
}

class _HeadingLine extends _InboxLine {
  const _HeadingLine(this.bucket, {required this.isFirst});
  final NotificationAgeBucket bucket;

  /// The first heading needs less space above it than the ones that follow a
  /// card — otherwise the list opens with a hole under the nav bar.
  final bool isFirst;
}

class _EntryLine extends _InboxLine {
  const _EntryLine(
    this.notification, {
    required this.isFirst,
    required this.isLast,
  });
  final AppNotification notification;

  /// Which corners this row rounds, and whether it draws a separator under
  /// itself — a card group is drawn by its rows, not by a wrapper, because a
  /// wrapper would have to build all of its children eagerly.
  final bool isFirst;
  final bool isLast;
}

/// Flattens [list] into headings and entries. Pure and separately testable;
/// the clock arrives as [now] for the same reason [notificationBucket] takes
/// one.
List<_InboxLine> _buildInboxLines(
  List<AppNotification> list, {
  required DateTime now,
}) {
  final lines = <_InboxLine>[];
  for (final section in groupNotificationsByAge(list, now: now)) {
    lines.add(_HeadingLine(section.bucket, isFirst: lines.isEmpty));
    for (var i = 0; i < section.items.length; i++) {
      lines.add(
        _EntryLine(
          section.items[i],
          isFirst: i == 0,
          isLast: i == section.items.length - 1,
        ),
      );
    }
  }
  return lines;
}

class _NotificationsList extends ConsumerWidget {
  const _NotificationsList({required this.list});

  final List<AppNotification> list;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Read once per build rather than per row: two rows either side of
    // midnight must not disagree about which day it is.
    final lines = _buildInboxLines(list, now: DateTime.now());
    return ListView.builder(
      // The parent's `body: SafeArea(bottom: false, ...)` deliberately does
      // NOT consume the bottom edge (see that screen's doc), so
      // `MediaQuery.paddingOf(context).bottom` here is still the real,
      // unconsumed device value — 0 in a standalone iOS PWA. `masiBottomInset`
      // adds the standalone floor on top of the existing `MasiSpacing.xxl`
      // breathing room so the last row doesn't land flush on the home
      // indicator.
      padding: EdgeInsets.only(
        bottom: MasiSpacing.xxl + masiBottomInset(context, ref),
      ),
      itemCount: lines.length,
      itemBuilder: (context, i) => switch (lines[i]) {
        final _HeadingLine h => _SectionHeading(
          bucket: h.bucket,
          isFirst: h.isFirst,
        ),
        final _EntryLine e => _NotificationRow(
          notification: e.notification,
          isFirst: e.isFirst,
          isLast: e.isLast,
        ),
      },
    );
  }
}

/// `TODAY` / `THIS WEEK` / `EARLIER`.
///
/// DESIGN.md's Caption style — 12/w500, +0.4 tracking, uppercased at the
/// render site exactly as that spec says to.
class _SectionHeading extends StatelessWidget {
  const _SectionHeading({required this.bucket, required this.isFirst});

  final NotificationAgeBucket bucket;
  final bool isFirst;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        MasiSpacing.lg + MasiSpacing.xs,
        isFirst ? MasiSpacing.lg : MasiSpacing.xl,
        MasiSpacing.lg,
        MasiSpacing.sm,
      ),
      child: Text(
        bucket.label.toUpperCase(),
        key: Key('notifications-heading-${bucket.name}'),
        style: Theme.of(
          context,
        ).textTheme.labelSmall?.copyWith(color: colors.ink3),
      ),
    );
  }
}

/// The width of a row's leading actor slot — the avatar plus the badge that
/// overhangs it. Named because the inset separator has to start exactly where
/// the text does, and two hand-copied numbers drift apart the first time
/// either changes.
const double _avatarSlot = 44;

/// One entry, as a sentence.
///
/// A [ConsumerWidget] so it can resolve the actor's name through
/// [profileDisplayNameProvider] — the same live door every other author name
/// in the app goes through, so renaming yourself repaints every mention of you
/// at once. Never renders [AppNotification.actorId]; an unresolvable actor
/// reads "Someone", which is a true sentence, where a uid is not a sentence at
/// all.
class _NotificationRow extends ConsumerWidget {
  const _NotificationRow({
    required this.notification,
    required this.isFirst,
    required this.isLast,
  });

  final AppNotification notification;
  final bool isFirst;
  final bool isLast;

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
    final avatarUrl = actorId == null
        ? null
        : ref.watch(profileAvatarUrlProvider(actorId)).asData?.value;

    final detail = n.detail;
    const radius = Radius.circular(MasiRadii.card);
    final shape = BorderRadius.only(
      topLeft: isFirst ? radius : Radius.zero,
      topRight: isFirst ? radius : Radius.zero,
      bottomLeft: isLast ? radius : Radius.zero,
      bottomRight: isLast ? radius : Radius.zero,
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: MasiSpacing.lg),
      child: Material(
        // An unread row is washed with a whisper of accent rather than set in
        // bold across the whole card: an inbox where most entries are unread
        // would otherwise be a wall of emphasis, which emphasises nothing.
        // Blended into `surface` instead of layered as a translucent overlay
        // so the row is opaque — a semi-transparent row over the scaffold
        // would darken as the list scrolled past the ground behind it.
        color: n.isUnread
            ? Color.alphaBlend(
                colors.accent.withValues(alpha: 0.07),
                colors.surface,
              )
            : colors.surface,
        borderRadius: shape,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: Key('notification-row-${n.id}'),
          onTap: () => _open(context, ref),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: MasiSpacing.md,
                  vertical: MasiSpacing.md,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _ActorBadge(
                      kind: n.kind,
                      avatarUrl: avatarUrl,
                      displayName: n.labelWith(resolved),
                    ),
                    const SizedBox(width: MasiSpacing.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            n.sentenceWith(resolved),
                            style: textTheme.bodySmall?.copyWith(
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
                              style: textTheme.labelMedium?.copyWith(
                                color: colors.ink2,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(width: MasiSpacing.sm),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          notificationAge(n.createdAt, now: DateTime.now()),
                          style: textTheme.labelMedium?.copyWith(
                            color: colors.ink3,
                          ),
                        ),
                        if (n.isUnread) ...[
                          const SizedBox(height: MasiSpacing.sm),
                          Container(
                            key: Key('notification-unread-${n.id}'),
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              color: colors.accent,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              // Inset past the avatar, iOS-style, so the rule reads as "these
              // rows belong together" rather than as a line cutting the card
              // in half. Drawn as a row of its own rather than as the
              // container's bottom border, which is what a `Border` cannot
              // inset.
              if (!isLast)
                Padding(
                  padding: const EdgeInsets.only(
                    left: MasiSpacing.md + _avatarSlot + MasiSpacing.md,
                  ),
                  child: Container(height: 1, color: colors.separator),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The actor's face with a small glyph saying what they did.
///
/// Both halves matter and neither is redundant: the avatar answers "who", the
/// badge answers "what", and the sentence beside them is the thing a screen
/// reader gets. A row with only a kind glyph makes every comment look the
/// same; a row with only a face makes a like indistinguishable from an edit
/// proposal at a glance.
///
/// [MasiAvatar] already degrades a missing/unloadable picture to initials and
/// then to a person glyph, so nothing here needs its own fallback.
class _ActorBadge extends StatelessWidget {
  const _ActorBadge({
    required this.kind,
    required this.avatarUrl,
    required this.displayName,
  });

  final NotificationKind kind;
  final String? avatarUrl;
  final String displayName;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    // The badge is `accent` on the app's own surface, not a per-kind colour
    // ramp: DESIGN.md spends colour on grade bands and reserves saturated
    // amethyst for action, and four differently-coloured badges in one list
    // would read as four severities where there is only one — "somebody did
    // something".
    return SizedBox(
      width: _avatarSlot,
      height: _avatarSlot,
      // The badge deliberately overhangs the avatar's circle; the default
      // `hardEdge` would shave it.
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          MasiAvatar(
            avatarUrl: avatarUrl,
            email: null,
            displayName: displayName,
            radius: 20,
          ),
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                color: colors.accent,
                shape: BoxShape.circle,
                // A ring in the row's own fill so the badge stays legible
                // wherever it lands on the avatar underneath.
                border: Border.all(color: colors.surface, width: 2),
              ),
              child: Center(
                child: MasiIcon(
                  notificationKindGlyph(kind),
                  size: 11,
                  color: colors.onAccent,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
