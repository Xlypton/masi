import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme.dart';
import '../../../shared/presentation/masi_icon.dart';
import '../application/notification_providers.dart';

/// The way into the notification centre, with its unread count on it.
///
/// Public (not private to the Feed screen) because the entry point is likely
/// to want a second home later — the account screen is the obvious one — and a
/// badge whose count rule lives in two places will eventually disagree with
/// itself.
///
/// The glyph is `flash`, which is a lightning bolt. There is no bell in
/// `assets/icons/masi/`, and inventing one would mean adding an asset the
/// designer has not drawn; of what is actually there, the lightning bolt is
/// the only glyph that reads as "activity" rather than as a specific kind of
/// activity. `comment` would have been wrong for a like, `heart` wrong for a
/// comment, and `info` reads as help.
class NotificationBell extends ConsumerWidget {
  const NotificationBell({super.key});

  /// Above this the badge reads "a lot" rather than a number, which is the
  /// only thing a two-digit count in a 16-px circle can honestly convey.
  static const int maxBadgeCount = 9;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = MasiColors.of(context);
    // `.value ?? 0` and not `.when`: an unresolved count means "we do not know
    // yet", and the honest render of that is an un-badged icon rather than a
    // spinner where a button belongs.
    final unread = ref.watch(unreadNotificationCountProvider).value ?? 0;

    return IconButton(
      key: const Key('notifications-button'),
      tooltip: unread > 0 ? 'Notifications ($unread unread)' : 'Notifications',
      onPressed: () => context.push('/notifications'),
      icon: Stack(
        clipBehavior: Clip.none,
        children: [
          // `accent`, not `ink`: this is a trailing bar action, and DESIGN.md
          // ("Navigation — large title") gives those accent glyphs. It used
          // to be `ink`, which made the one interactive thing in the bar the
          // only glyph that did not look interactive.
          MasiIcon('flash', color: colors.accent),
          if (unread > 0)
            Positioned(
              // Up and to the right of the glyph's own box, so the badge does
              // not sit on top of the icon it is annotating.
              top: -4,
              right: -6,
              child: Container(
                key: const Key('notifications-badge'),
                // 18, up from 16: the legibility ring below eats 1.5px a
                // side, and "9+" at the Caption size does not fit what is
                // left of a 16px pill.
                padding: const EdgeInsets.symmetric(horizontal: 4),
                constraints: const BoxConstraints(minWidth: 18),
                height: 18,
                decoration: BoxDecoration(
                  color: colors.accent,
                  borderRadius: BorderRadius.circular(8),
                  // A ring in the bar's own ground so the badge reads as a
                  // badge wherever it lands on the glyph beneath it — the
                  // same treatment `NavShell`'s unseen dot uses, and for the
                  // same reason.
                  border: Border.all(color: colors.ground, width: 1.5),
                ),
                child: Center(
                  child: Text(
                    unread > maxBadgeCount ? '$maxBadgeCount+' : '$unread',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: colors.onAccent,
                      fontWeight: FontWeight.w700,
                      height: 1,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
