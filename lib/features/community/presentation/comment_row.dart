import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../../../shared/presentation/masi_avatar.dart';
import '../../../shared/presentation/masi_dialogs.dart';
import '../../../shared/presentation/masi_icon.dart';
import '../../account/application/auth_providers.dart';
import '../../account/application/profile_providers.dart';
import '../../moderation/application/moderation_providers.dart';
import '../../moderation/domain/admin_delete_policy.dart';
import '../data/comments_repository.dart';
import '../domain/comment_mentions.dart';

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
  const CommentRow({super.key, required this.comment, required this.keyPrefix});

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

    // Admin "delete any feed item" surface (moderation), read exactly like
    // every other admin gate in this app: `isAdminProvider` fails closed
    // (false while loading, false on error), and `isSignedIn` is checked
    // SEPARATELY per `admin_delete_policy.dart`'s own doc for why. A comment
    // has no restore path — only a topo does — so the only two outcomes
    // `adminContentAction` can hand back here are `hidden` and `delete`.
    final isAdmin = ref.watch(isAdminProvider).asData?.value ?? false;
    final isSignedIn = ref.watch(effectiveUidProvider) != null;
    final showAdminDelete =
        adminContentAction(isAdmin: isAdmin, isSignedIn: isSignedIn) ==
        AdminContentAction.delete;

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
                _CommentBody(comment: comment, colors: colors),
              ],
            ),
          ),
          // Admin-only, appended as a THIRD row child rather than folded into
          // any padding/sizing already here — a non-admin (nearly every
          // reader) must see this exact row, unchanged, since this widget's
          // whole point (see the class doc, "one widget for both threads") is
          // one shared identity line rather than two screens quietly
          // diverging.
          if (showAdminDelete)
            IconButton(
              key: Key('$keyPrefix-${comment.id}-admin-delete'),
              tooltip: 'Delete comment',
              visualDensity: VisualDensity.compact,
              icon: MasiIcon('delete', size: 18, color: colors.gradeHard),
              onPressed: () => _delete(context, ref),
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

  /// Confirms, then deletes THIS comment via the admin path (moderation).
  ///
  /// [AdminDeleteService.deleteComment] is the real authority check — see
  /// that class's doc — this button only decided whether to draw itself at
  /// all. No re-entrancy guard beyond [showMasiConfirm]'s own modal barrier:
  /// it already blocks a second tap from landing before the first resolves,
  /// which is what keeps this a plain [ConsumerWidget] rather than one that
  /// has to grow State just to hold an in-flight flag (see the class doc's
  /// note on why this stayed a `ConsumerWidget`).
  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final commentId = comment.id;
    final confirmed = await showMasiConfirm(
      context,
      title: 'Delete this comment?',
      message: 'It disappears for everyone. This cannot be undone.',
      confirmLabel: 'Delete',
      confirmKey: Key('$keyPrefix-$commentId-admin-delete-confirm'),
    );
    if (!confirmed || !context.mounted) return;

    // Captured after the confirm has resolved and `context.mounted` has
    // already been re-checked, not any earlier — mirrors the placement
    // `CommunityTopoDetailScreen._openAdminDeleteSheet` and
    // `AscentDetailScreen._openAdminDeleteSheet` use around this exact RPC.
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await ref
          .read(adminDeleteServiceProvider)
          .deleteComment(commentId: commentId);
      if (!context.mounted) return;
      messenger?.showSnackBar(const SnackBar(content: Text('Comment deleted')));
    } catch (error) {
      // Loud, not silent — an admin who believes a delete went through when
      // it did not is worse off than one who was told it failed.
      if (!context.mounted) return;
      messenger?.showSnackBar(
        SnackBar(content: Text("Couldn't delete that comment. $error")),
      );
    }
  }
}

/// What the comment says, with any tagged climbers drawn in the accent colour
/// and under their CURRENT name.
///
/// The same argument as the identity line above, one level down: the `@Bogi`
/// sitting in [Comment.body] is text frozen at write time, so it is the uid
/// list that says who was tagged and `profiles.displayName` that says what they
/// are called today. [parseCommentBodySpans] does the matching (and carries the
/// reasoning for how a uid is tied to a place in the text); this widget only
/// paints the result.
///
/// A comment that tags nobody — nearly all of them — is rendered by the plain
/// [Text] path, not a one-child [Text.rich]. Not a micro-optimisation: a
/// `Text.rich` has no `data`, so `find.text(body)` stops matching it, and the
/// existing thread tests (and anything else looking for a comment by its words)
/// would have gone quietly blind.
class _CommentBody extends ConsumerWidget {
  const _CommentBody({required this.comment, required this.colors});

  final Comment comment;
  final MasiColors colors;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final textTheme = Theme.of(context).textTheme;
    final uids = comment.mentionedUids;
    if (uids.isEmpty) {
      return Text(comment.body, style: textTheme.bodyMedium);
    }

    // Resolved up front, into a map, so `displayNameOf` stays a pure lookup:
    // `ref.watch` inside the parse callback would subscribe (or not) depending
    // on which branch the matcher happened to take.
    final liveNames = <String, String?>{
      for (final uid in uids)
        uid: ref.watch(profileDisplayNameProvider(uid)).asData?.value,
    };
    final spans = parseCommentBodySpans(
      body: comment.body,
      mentionedUids: uids,
      displayNameOf: (uid) => liveNames[uid],
    );
    if (!spans.any((span) => span.isMention)) {
      // Tagged uids, but nothing in the text they could be tied to — the body
      // was edited down, or the data arrived odd. Plain text, same as above.
      return Text(comment.body, style: textTheme.bodyMedium);
    }

    return Text.rich(
      TextSpan(
        children: [
          for (final span in spans)
            TextSpan(
              text: span.text,
              style: span.isMention
                  ? TextStyle(color: colors.accent, fontWeight: FontWeight.w600)
                  : null,
            ),
        ],
      ),
      style: textTheme.bodyMedium,
    );
  }
}
