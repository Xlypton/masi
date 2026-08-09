import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../../../shared/presentation/masi_async_view.dart';
import '../../../shared/presentation/masi_icon.dart';
import '../../../shared/presentation/masi_pending_icon_button.dart';
import '../../../shared/presentation/masi_skeleton.dart';
import '../../account/application/profile_providers.dart';
import '../../logbook/application/ascents_providers.dart';
import '../../logbook/data/ascents_repository.dart';
import '../../logbook/presentation/logbook_screen.dart' show styleLabel;
import '../application/ascent_detail_providers.dart';
import '../application/comments_providers.dart';
import '../application/community_topo_detail_providers.dart';
import '../application/likes_providers.dart';
import 'ascent_route_art_header.dart';
import 'comment_row.dart';
import 'mention_composer.dart';

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
  /// A [MentionComposerController], not a plain [TextEditingController]: the
  /// draft's tagged uids have to live exactly as long as its text, and be
  /// cleared with it.
  final _commentController = MentionComposerController();

  /// How long [_resolveAuthorName] is willing to wait for a display name that
  /// has not resolved yet. A bound, not a timing assumption: the provider
  /// normally answers in a microtask, and if it never does the comment still
  /// posts (see that method).
  static const Duration _authorNameTimeout = Duration(seconds: 3);

  /// The OPTIMISTIC liked state: what this device just did, shown immediately,
  /// until [hasLikedAscentProvider] has caught up with it. `null` means "no
  /// pending toggle — trust the provider".
  ///
  /// A like is the one action on this screen that must not show a spinner. It
  /// is a single reversible bit whose whole value is that it feels instant;
  /// a heart that greys out and spins for a round trip reads as broken, and
  /// the modern behaviour — flip now, roll back and say so if the write fails
  /// — is also the honest one here, because the write is a local Drift row that
  /// essentially always succeeds (sync pushes it later, on its own schedule).
  bool? _likeOverride;

  /// In-flight guard for [_toggleLike]. The like button had none, so two quick
  /// taps ran two toggles at one row.
  bool _likeInFlight = false;

  @override
  void dispose() {
    _commentController.dispose();
    super.dispose();
  }

  Future<void> _toggleLike() async {
    if (_likeInFlight) return;
    final ascentId = widget.ascentId;
    final current =
        _likeOverride ?? ref.read(hasLikedAscentProvider(ascentId)).value ?? false;
    _likeInFlight = true;
    // Instant feedback, before any await.
    setState(() => _likeOverride = !current);

    try {
      await ref.read(likesRepositoryProvider).toggleAscentLike(ascentId);
    } catch (error) {
      _likeInFlight = false;
      if (!mounted) return;
      // Roll the glyph back to whatever the provider says, and say so — an
      // optimistic update that silently reverts is worse than no update.
      setState(() => _likeOverride = null);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Couldn't save your like — please try again")),
      );
      return;
    }

    if (!mounted) {
      _likeInFlight = false;
      return;
    }
    // hasLikedAscentProvider is a one-shot FutureProvider (mirrors
    // hasLikedWallProvider — see CommunityTopoDetailScreen._toggleLike's
    // identical comment), so it has to be refreshed by hand. `refresh(.future)`
    // rather than `invalidate`: the override is only safe to drop once the
    // REFRESHED answer is in, and an invalidated provider still reports its
    // stale value until then — dropping the override any earlier flickers the
    // heart back through the pre-tap state.
    //
    // likeCountForAscentProvider needs no nudge at all: it's a live
    // StreamProvider that re-emits on its own once the write above lands. The
    // count is deliberately NOT part of the optimistic update — the glyph is
    // what the tap was about, and hand-incrementing a number that a stream is
    // about to correct is how a wrong count gets on screen.
    try {
      // The refreshed value itself is not needed here — what matters is that
      // the provider has caught up before the override is dropped.
      // ignore: unused_result
      await ref.refresh(hasLikedAscentProvider(ascentId).future);
    } catch (_) {
      // The write DID land; a failed re-read is not worth a message. Falling
      // through drops the override, so the provider's own state governs.
    }
    _likeInFlight = false;
    if (mounted) setState(() => _likeOverride = null);
  }

  /// The `authorName` to stamp on a new comment, waiting out a display name
  /// that has not resolved YET rather than treating it as absent.
  ///
  /// Per this ticket's spec, an ascent comment's authorship comes from the
  /// signed-in user's own PROFILE display name ([myDisplayNameProvider]) rather
  /// than `CommunityTopoDetailScreen`'s email-derived
  /// `currentAuthorNameProvider` — matching `LogAscentSheet._save`'s identical
  /// resolution for the same `Ascents.authorName` column. `null` is a legitimate
  /// answer (signed out, or no name set) and posts an unattributed comment.
  ///
  /// What was NOT legitimate was reading `.asData?.value` unconditionally: that
  /// is null for "hasn't answered yet" just as much as for "no name", and the
  /// provider resolves asynchronously (its uid comes from `authStateChanges()`),
  /// so a comment posted in the first instants of this screen was stored
  /// unattributed forever for a user who has a perfectly good name. The post
  /// button is a pending control now, so waiting costs a brief spinner instead.
  /// Every failure mode degrades to the old behaviour: on timeout or error, the
  /// comment posts with whatever is known by then.
  Future<String?> _resolveAuthorName() async {
    final resolved = ref.read(myDisplayNameProvider);
    if (resolved.hasValue) return resolved.value;
    try {
      return await ref
          .read(myDisplayNameProvider.future)
          .timeout(_authorNameTimeout);
    } catch (_) {
      return ref.read(myDisplayNameProvider).asData?.value;
    }
  }

  Future<void> _submitComment() async {
    final body = _commentController.text.trim();
    if (body.isEmpty) return;
    // Read BEFORE the await: `_resolveAuthorName` can wait seconds, and the
    // user is free to keep editing meanwhile — the uids stored have to be the
    // ones belonging to the body being posted.
    final mentionedUids = _commentController.mentionedUids;
    final authorName = await _resolveAuthorName();
    if (!mounted) return;
    await ref
        .read(commentsRepositoryProvider)
        .addAscentComment(
          ascentId: widget.ascentId,
          body: body,
          authorName: authorName,
          mentionedUids: mentionedUids,
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
        child: MasiAsyncView<SharedAscentEntry?>(
          value: asyncEntry,
          errorMessage: "Couldn't load this ascent",
          // Same call as the Feed/Map make: `sharedAscentsProvider` is a local
          // Drift stream, so its raw error object is not a sentence.
          showErrorDetail: false,
          onRetry: () => ref.invalidate(sharedAscentsProvider),
          skeleton: (context) => const _AscentDetailSkeleton(),
          data: (context, entry) {
            if (entry == null) {
              return _NotFoundState(colors: colors);
            }
            return _AscentDetailBody(
              entry: entry,
              commentController: _commentController,
              likedOverride: _likeOverride,
              onToggleLike: _toggleLike,
              onSubmitComment: _submitComment,
            );
          },
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
    required this.likedOverride,
    required this.onToggleLike,
    required this.onSubmitComment,
  });

  final SharedAscentEntry entry;
  final MentionComposerController commentController;

  /// The parent's optimistic liked state, winning over
  /// [hasLikedAscentProvider] while a toggle is in flight — see
  /// `_AscentDetailScreenState._likeOverride`.
  final bool? likedOverride;

  final Future<void> Function() onToggleLike;
  final Future<void> Function() onSubmitComment;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = MasiColors.of(context);
    final textTheme = Theme.of(context).textTheme;
    final ascentId = entry.ascentId;

    final likeCount =
        ref.watch(likeCountForAscentProvider(ascentId)).value ?? 0;
    final hasLiked =
        likedOverride ?? ref.watch(hasLikedAscentProvider(ascentId)).value ?? false;
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
        // The subject of the screen, first: the line this climber actually
        // did, on the rock they did it on. Collapses to nothing when the art
        // cannot be resolved, so an ascent without a picture reads exactly as
        // this screen always did — see [AscentRouteArtHeader].
        AscentRouteArtHeader(
          key: Key('ascent-detail-route-art-$ascentId'),
          wallId: entry.wallId,
          routeNumber: entry.routeNumber,
        ),
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
          for (final comment in comments)
            CommentRow(comment: comment, keyPrefix: 'ascent-detail-comment'),
        const SizedBox(height: MasiSpacing.sm),
        // Above the field, not below it: on a phone the composer sits just
        // over the keyboard, so a list hung underneath would open behind it.
        MentionSuggestions(
          controller: commentController,
          keyPrefix: 'ascent-detail-comment',
          participantUids: {
            // Whoever logged the ascent, plus everyone who has said something
            // about it — the people a comment here is plausibly aimed at.
            if (entry.ownerId != null) entry.ownerId!,
            for (final comment in comments)
              if (comment.ownerId != null) comment.ownerId!,
          },
        ),
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
                // Pending, not plain: posting awaits a display-name resolution
                // and a Drift write, and an unguarded double tap wrote the
                // comment twice.
                return PendingIconButton(
                  buttonKey: const Key('ascent-detail-comment-submit'),
                  tooltip: 'Post comment',
                  icon: MasiIcon(
                    'send_check',
                    color: canSubmit ? colors.accent : colors.ink2,
                  ),
                  onPressed: canSubmit ? onSubmitComment : null,
                  onError: (error, stackTrace) =>
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text("Couldn't post your comment — please try again"),
                        ),
                      ),
                );
              },
            ),
          ],
        ),
      ],
    );
  }
}

/// The first-load placeholder for [_AscentDetailBody], shaped from that
/// widget's own geometry: the same `MasiSpacing.lg` padding, then its four
/// header lines at their real font sizes (climber 17 → route 24 → wall 17 →
/// style/date 15), the 48 px like row, the divider and the "Comments" heading.
///
/// Text slots are scaled by [MediaQuery.textScalerOf] for the same reason the
/// shared composites do it: an unscaled skeleton matches at the default text
/// size and lands short of the real content at every larger one, bringing back
/// the jump for exactly the users least able to absorb it.
///
/// Deliberately does NOT reserve the route-art square that
/// [AscentRouteArtHeader] draws above the climber's name: whether there is a
/// picture at all is not known until the ascent has loaded and its wall's photo
/// has resolved, so a square here would be a promise this skeleton cannot keep
/// — and collapsing it afterwards is a bigger jump than the one it was meant to
/// prevent. The header brings its own loading slot once it knows it has
/// something to show.
///
/// Non-scrollable and inert (a placeholder must not be draggable or tappable),
/// but laid out in a [ListView] so it CLIPS rather than overflowing if a very
/// large text scale makes it taller than the screen.
class _AscentDetailSkeleton extends StatelessWidget {
  const _AscentDetailSkeleton();

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    return IgnorePointer(
      child: ListView(
        key: const Key('ascent-detail-skeleton'),
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.all(MasiSpacing.lg),
        children: [
          // The climber's name (titleMedium 17).
          MasiSkeleton.textLine(fontSize: scaler.scale(17), widthFactor: 0.4),
          const SizedBox(height: MasiSpacing.sm),
          // The route title (headlineSmall 24) + its grade.
          MasiSkeleton.textLine(fontSize: scaler.scale(24), widthFactor: 0.65),
          const SizedBox(height: 2),
          // The wall name (bodyMedium 17).
          MasiSkeleton.textLine(fontSize: scaler.scale(17), widthFactor: 0.35),
          const SizedBox(height: 2),
          // "<style> · <date>" (titleSmall 15).
          MasiSkeleton.textLine(fontSize: scaler.scale(15), widthFactor: 0.5),
          const SizedBox(height: MasiSpacing.md),
          // The like row: the heart's glyph and its count, in the 48 px slot
          // the real row's IconButton gives it. The button's hit box is not
          // drawn — a shimmering control invites a tap that does nothing.
          const SizedBox(
            height: 48,
            child: Row(
              children: [
                SizedBox(
                  width: 48,
                  child: Center(child: MasiSkeleton.circle(diameter: 22)),
                ),
                MasiSkeleton.box(width: 14, height: 11, radius: 5.5),
              ],
            ),
          ),
          const Divider(),
          // The "Comments" heading (titleMedium 17).
          MasiSkeleton.textLine(fontSize: scaler.scale(17), widthFactor: 0.3),
        ],
      ),
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
