import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../../../shared/presentation/masi_icon.dart';
import '../../account/application/profile_providers.dart';
import '../../logbook/data/ascents_repository.dart';
import '../../logbook/presentation/logbook_screen.dart' show styleLabel;
import '../application/ascent_detail_providers.dart';
import '../application/comments_providers.dart';
import '../application/community_topo_detail_providers.dart';
import '../application/likes_providers.dart';
import '../data/comments_repository.dart';

/// Read-only detail view for a single shared ("community") ascent log
/// (Feature #12, public opt-in ascent logs): the climber's resolved display
/// name, the route/grade/wall/style/date it was logged against, any notes/
/// gradeOpinion the climber left, and this feature's social surface —
/// like/unlike + a comment thread. Mirrors `CommunityTopoDetailScreen`'s
/// like/comment patterns (see that screen's own class doc) but scoped to an
/// ascent instead of a wall, with no topo canvas/header to embed.
///
/// Reached by `context.push`ing `/community/ascent/<id>` — see
/// `app/router.dart`.
class AscentDetailScreen extends ConsumerStatefulWidget {
  const AscentDetailScreen({super.key, required this.ascentId});

  /// The shared ascent log being viewed.
  final String ascentId;

  @override
  ConsumerState<AscentDetailScreen> createState() =>
      _AscentDetailScreenState();
}

class _AscentDetailScreenState extends ConsumerState<AscentDetailScreen> {
  final _commentController = TextEditingController();

  @override
  void dispose() {
    _commentController.dispose();
    super.dispose();
  }

  Future<void> _toggleLike() async {
    await ref.read(likesRepositoryProvider).toggleAscentLike(widget.ascentId);
    if (!mounted) return;
    // hasLikedAscentProvider is a one-shot FutureProvider (mirrors
    // hasLikedWallProvider — see CommunityTopoDetailScreen._toggleLike's
    // identical comment) — invalidate it so the heart glyph flips right
    // away. likeCountForAscentProvider needs no such nudge: it's a live
    // StreamProvider that re-emits on its own once the write above lands.
    ref.invalidate(hasLikedAscentProvider(widget.ascentId));
  }

  Future<void> _submitComment() async {
    final body = _commentController.text.trim();
    if (body.isEmpty) return;
    // Per this ticket's spec: an ascent comment's authorship is stamped from
    // the signed-in user's own PROFILE display name (`myDisplayNameProvider`)
    // rather than `CommunityTopoDetailScreen`'s email-derived
    // `currentAuthorNameProvider` — matches `LogAscentSheet._save`'s
    // identical `authorName` resolution for the same `Ascents.authorName`
    // column. `null` while signed out / no name set — the comment posts with
    // no author name rather than falling back to a stale "Anonymous" here.
    final authorName = ref.read(myDisplayNameProvider).asData?.value;
    await ref
        .read(commentsRepositoryProvider)
        .addAscentComment(
          ascentId: widget.ascentId,
          body: body,
          authorName: authorName,
        );
    if (!mounted) return;
    _commentController.clear();
    FocusManager.instance.primaryFocus?.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final ascentId = widget.ascentId;
    final colors = MasiColors.of(context);
    // Watched (not just read from _submitComment) so authStateProvider is
    // warmed from the very first build — mirrors
    // CommunityTopoDetailScreen.build's identical currentAuthorNameProvider
    // warm-up comment: myDisplayNameProvider's underlying authStateChanges()
    // stream emits its first value asynchronously (a microtask), so a
    // comment posted before that first emission would otherwise resolve a
    // stale/absent name.
    ref.watch(myDisplayNameProvider);
    final asyncEntry = ref.watch(ascentDetailProvider(ascentId));

    return Scaffold(
      key: Key('ascent-detail-$ascentId'),
      appBar: AppBar(
        leading: IconButton(
          key: const Key('ascent-detail-back-button'),
          icon: MasiIcon('chevron_left'),
          tooltip: 'Back',
          color: colors.accent,
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: const Text('Ascent'),
      ),
      body: SafeArea(
        child: asyncEntry.when(
          data: (entry) {
            if (entry == null) {
              return _NotFoundState(colors: colors);
            }
            return _AscentDetailBody(
              entry: entry,
              commentController: _commentController,
              onToggleLike: _toggleLike,
              onSubmitComment: _submitComment,
            );
          },
          loading: () => const Center(
            key: Key('ascent-detail-loading'),
            child: CircularProgressIndicator(),
          ),
          error: (error, stackTrace) => Center(
            child: Text(
              'Something went wrong: $error',
              key: const Key('ascent-detail-error'),
            ),
          ),
        ),
      ),
    );
  }
}

/// The body once [ascentDetailProvider] has resolved a real
/// [SharedAscentEntry]: header info + like row + comment thread. A separate
/// [ConsumerWidget] (rather than inlined in the parent's `build`) so its own
/// `ref.watch`es of the like/comment/profile-name family providers only
/// rebuild this subtree, not the outer Scaffold/AppBar.
class _AscentDetailBody extends ConsumerWidget {
  const _AscentDetailBody({
    required this.entry,
    required this.commentController,
    required this.onToggleLike,
    required this.onSubmitComment,
  });

  final SharedAscentEntry entry;
  final TextEditingController commentController;
  final Future<void> Function() onToggleLike;
  final Future<void> Function() onSubmitComment;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = MasiColors.of(context);
    final textTheme = Theme.of(context).textTheme;
    final ascentId = entry.ascentId;

    final likeCount =
        ref.watch(likeCountForAscentProvider(ascentId)).value ?? 0;
    final hasLiked = ref.watch(hasLikedAscentProvider(ascentId)).value ?? false;
    final comments =
        ref.watch(commentsForAscentProvider(ascentId)).value ?? const [];

    // #18/#12: resolve the climber's synced display name the same way
    // `_FeedRow` (community_screen.dart) resolves a shared topo's owner —
    // `null` ownerId, no profile row yet, or an empty name all collapse to
    // the same "Unknown climber" fallback; the raw uid must never render.
    final ownerId = entry.ownerId;
    final climberName = ownerId != null
        ? ref.watch(profileDisplayNameProvider(ownerId)).asData?.value
        : null;
    final climberLabel = (climberName != null && climberName.isNotEmpty)
        ? climberName
        : 'Unknown climber';

    final routeName = entry.routeName;
    final routeTitle = (routeName != null && routeName.isNotEmpty)
        ? routeName
        : 'Route ${entry.routeNumber ?? '?'}';

    final notes = entry.notes;
    final gradeOpinion = entry.gradeOpinion;

    return ListView(
      key: const Key('ascent-detail-body'),
      padding: const EdgeInsets.all(MasiSpacing.lg),
      children: [
        Text(
          climberLabel,
          key: const Key('ascent-detail-climber-name'),
          style: textTheme.titleMedium,
        ),
        const SizedBox(height: MasiSpacing.sm),
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Flexible(
              child: Text(
                routeTitle,
                key: const Key('ascent-detail-route-title'),
                style: textTheme.headlineSmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (entry.gradeLabel != null) ...[
              const SizedBox(width: MasiSpacing.xs),
              Text(
                entry.gradeLabel!,
                key: const Key('ascent-detail-grade-label'),
                style: textTheme.titleMedium?.copyWith(color: colors.ink2),
              ),
            ],
          ],
        ),
        const SizedBox(height: 2),
        Text(
          entry.wallName,
          key: const Key('ascent-detail-wall-name'),
          style: textTheme.bodyMedium?.copyWith(color: colors.ink2),
        ),
        const SizedBox(height: 2),
        Text(
          '${styleLabel(entry.style)} · ${_formatDate(entry.climbedAt)}',
          key: const Key('ascent-detail-style-date'),
          style: textTheme.titleSmall?.copyWith(color: colors.ink2),
        ),
        if (notes != null && notes.isNotEmpty) ...[
          const SizedBox(height: MasiSpacing.sm),
          Text(
            notes,
            key: const Key('ascent-detail-notes'),
            style: textTheme.bodyMedium,
          ),
        ],
        if (gradeOpinion != null && gradeOpinion.isNotEmpty) ...[
          const SizedBox(height: MasiSpacing.xs),
          Text(
            'Grade opinion: $gradeOpinion',
            key: const Key('ascent-detail-grade-opinion'),
            style: textTheme.bodySmall?.copyWith(color: colors.ink3),
          ),
        ],
        const SizedBox(height: MasiSpacing.md),
        Row(
          children: [
            IconButton(
              key: const Key('ascent-detail-like-button'),
              tooltip: hasLiked ? 'Unlike' : 'Like',
              icon: hasLiked
                  ? MasiIcon('heart_fill', color: colors.accent)
                  : MasiIcon('heart', color: colors.ink2),
              onPressed: onToggleLike,
            ),
            Text(
              '$likeCount',
              key: const Key('ascent-detail-like-count'),
              style: textTheme.titleMedium,
            ),
          ],
        ),
        const Divider(),
        Text('Comments', style: textTheme.titleMedium),
        const SizedBox(height: MasiSpacing.sm),
        if (comments.isEmpty)
          Text(
            'No comments yet — be the first',
            key: const Key('ascent-detail-comments-empty'),
            style: textTheme.bodyMedium?.copyWith(color: colors.ink2),
          )
        else
          for (final comment in comments) _AscentCommentRow(comment: comment),
        const SizedBox(height: MasiSpacing.sm),
        Row(
          children: [
            Expanded(
              child: TextField(
                key: const Key('ascent-detail-comment-field'),
                controller: commentController,
                decoration: const InputDecoration(hintText: 'Add a comment'),
              ),
            ),
            const SizedBox(width: MasiSpacing.sm),
            // Disabled/inert for an empty/whitespace-only draft — rebuilt
            // straight off the controller (mirrors
            // CommunityTopoDetailScreen's identical submit-button pattern)
            // so it reacts to every keystroke.
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: commentController,
              builder: (context, value, _) {
                final canSubmit = value.text.trim().isNotEmpty;
                return IconButton(
                  key: const Key('ascent-detail-comment-submit'),
                  tooltip: 'Post comment',
                  icon: MasiIcon(
                    'send_check',
                    color: canSubmit ? colors.accent : colors.ink2,
                  ),
                  onPressed: canSubmit ? onSubmitComment : null,
                );
              },
            ),
          ],
        ),
      ],
    );
  }
}

/// Shown when [ascentDetailProvider] has finished loading but found no
/// matching [SharedAscentEntry] — e.g. this device hasn't synced the ascent
/// down yet, or it was un-shared/deleted after the link was created.
class _NotFoundState extends StatelessWidget {
  const _NotFoundState({required this.colors});

  final MasiColors colors;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(MasiSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            MasiIcon('logbook', size: 40, color: colors.ink3),
            const SizedBox(height: MasiSpacing.md),
            Text(
              'Ascent not found',
              key: const Key('ascent-detail-not-found'),
              textAlign: TextAlign.center,
              style: textTheme.titleMedium?.copyWith(color: colors.ink2),
            ),
            const SizedBox(height: MasiSpacing.sm),
            Text(
              'This ascent may not have synced to this device yet, or is no '
              'longer shared.',
              textAlign: TextAlign.center,
              style: textTheme.bodyMedium?.copyWith(color: colors.ink3),
            ),
          ],
        ),
      ),
    );
  }
}

/// A single comment row — duplicated from `CommunityTopoDetailScreen`'s
/// identical private `_CommentRow` (that class's copy is library-private to
/// its own file, and this screen and that one are otherwise independent
/// presentation modules — same duplication convention as this screen's
/// sibling `_RouteStyleTagChip`/`launchBetaVideo` elsewhere in this feature).
class _AscentCommentRow extends StatelessWidget {
  const _AscentCommentRow({required this.comment});

  final Comment comment;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    return Padding(
      key: Key('ascent-detail-comment-${comment.id}'),
      padding: const EdgeInsets.symmetric(vertical: MasiSpacing.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            comment.authorName ?? 'Anonymous',
            style: Theme.of(
              context,
            ).textTheme.labelLarge?.copyWith(color: colors.ink),
          ),
          Text(comment.body, style: Theme.of(context).textTheme.bodyMedium),
        ],
      ),
    );
  }
}

const List<String> _monthAbbreviations = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// Formats [date] as e.g. `'Jul 1, 2026'` — duplicated from
/// `logbook_screen.dart`'s identical private `_formatDate` (that copy is
/// library-private to its own file). Converts to local time first
/// (`toLocal()`): `Ascent.climbedAt` is stored as UTC, so extracting
/// month/day/year directly off it would show the UTC calendar day rather
/// than the viewer's local day.
String _formatDate(DateTime date) {
  final local = date.toLocal();
  return '${_monthAbbreviations[local.month - 1]} ${local.day}, '
      '${local.year}';
}
