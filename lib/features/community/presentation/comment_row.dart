import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../../../shared/presentation/masi_avatar.dart';
import '../../account/application/profile_providers.dart';
import '../data/comments_repository.dart';

/// One comment in a thread: the author's picture and name beside what they
/// said.
///
/// **One widget for both threads.** The topo thread
/// (`CommunityTopoDetailScreen`) and the ascent thread (`AscentDetailScreen`)
/// each carried their own library-private copy of this row, and the second
/// one's doc said as much — it was "duplicated from `CommunityTopoDetailScreen`'s
/// identical private `_CommentRow`". Two copies of a row that renders an
/// identity is exactly the shape that lets the same person appear under two
/// different names depending on which screen you are looking at, so the copies
/// are now one widget parameterised by [keyPrefix].
///
/// **Where the name comes from, and why not `authorName`.** [Comment.authorName]
/// is a text snapshot stamped at write time from the author's email local-part.
/// It is frozen: someone who set a real display name, or changed it, kept
/// showing up in old threads under whatever their address happened to look
/// like the day they typed. So the name is resolved LIVE from
/// `profiles.displayName` via [profileDisplayNameProvider], and `authorName`
/// is demoted to a fallback for the rows that pre-date profiles or whose
/// author's profile has not been pulled yet.
///
/// The fallback chain never surfaces a raw uid — that is the one thing an
/// identity line must not leak, and it is the same rule `_FeedRow` and
/// `_AscentFeedRow` already follow. In order: the live display name, the
/// stamped `authorName`, then `'Anonymous'`.
class CommentRow extends ConsumerWidget {
  const CommentRow({
    super.key,
    required this.comment,
    required this.keyPrefix,
  });

  final Comment comment;

  /// Prefixes this row's widget key as `<keyPrefix>-<comment id>`. The two
  /// threads use different prefixes (`community-comment` and
  /// `ascent-detail-comment`) and both are asserted on by existing tests, so
  /// they stay caller-supplied rather than being unified here.
  final String keyPrefix;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = MasiColors.of(context);
    final textTheme = Theme.of(context).textTheme;
    final ownerId = comment.ownerId;

    // A signed-out author (`ownerId == null`) has no profile row to resolve
    // against — there is no uid to key one by — so both lookups are skipped
    // entirely rather than asked for a name they cannot have.
    final liveName = ownerId == null
        ? null
        : ref.watch(profileDisplayNameProvider(ownerId)).asData?.value;
    final avatarUrl = ownerId == null
        ? null
        : ref.watch(profileAvatarUrlProvider(ownerId)).asData?.value;

    final name = _firstNonEmpty(liveName, comment.authorName) ?? 'Anonymous';

    return Padding(
      key: Key('$keyPrefix-${comment.id}'),
      padding: const EdgeInsets.symmetric(vertical: MasiSpacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MasiAvatar(
            key: Key('$keyPrefix-${comment.id}-avatar'),
            avatarUrl: avatarUrl,
            // Deliberately no email: a thread knows who wrote a comment, and
            // has no business knowing their address. `displayName` carries the
            // initials fallback instead — see [MasiAvatar.displayName].
            email: null,
            displayName: name,
            radius: 16,
          ),
          const SizedBox(width: MasiSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  name,
                  style: textTheme.labelLarge?.copyWith(color: colors.ink),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(comment.body, style: textTheme.bodyMedium),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The first of [values] that holds something after trimming, or `null`.
  /// Trimmed, not just null-checked: a `displayName` of `'   '` is a name
  /// nobody can read, and must fall through to the next candidate rather than
  /// render as a blank identity line.
  static String? _firstNonEmpty(String? a, String? b) {
    for (final value in [a, b]) {
      if (value != null && value.trim().isNotEmpty) return value;
    }
    return null;
  }
}
