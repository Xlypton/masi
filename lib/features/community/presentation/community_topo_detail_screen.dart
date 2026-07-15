import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../../logbook/application/ascents_providers.dart';
import '../../logbook/data/ascents_repository.dart';
import '../../topo/presentation/topo_canvas_screen.dart';
import '../application/comments_providers.dart';
import '../application/community_topo_detail_providers.dart';
import '../application/likes_providers.dart';
import '../data/comments_repository.dart';

/// Read-only detail view for a single shared ("community") topo: the wall's
/// photo/routes/legend (via an embedded, `readOnly: true`
/// [TopoCanvasScreen] — see that flag's doc for exactly what it hides),
/// plus this feature's social surface: like/unlike, a comment thread, and a
/// "log ascent" affordance per route.
///
/// Reached from `CommunityScreen`'s feed rows and map markers, which
/// `context.push('/community/topo/$wallId')`.
class CommunityTopoDetailScreen extends ConsumerStatefulWidget {
  const CommunityTopoDetailScreen({
    super.key,
    required this.wallId,
    @visibleForTesting this.debugInitialImageSize,
  });

  /// The wall (topo) being viewed.
  final String wallId;

  /// TEST-ONLY seam, threaded straight through to the embedded
  /// [TopoCanvasScreen] — see [TopoCanvasScreen.debugInitialImageSize]'s doc
  /// for why a widget test can't drive the real image decode. Always null
  /// in production.
  @visibleForTesting
  final Size? debugInitialImageSize;

  @override
  ConsumerState<CommunityTopoDetailScreen> createState() =>
      _CommunityTopoDetailScreenState();
}

class _CommunityTopoDetailScreenState
    extends ConsumerState<CommunityTopoDetailScreen> {
  final _commentController = TextEditingController();

  @override
  void dispose() {
    _commentController.dispose();
    super.dispose();
  }

  Future<void> _toggleLike() async {
    await ref.read(likesRepositoryProvider).toggleLike(widget.wallId);
    if (!mounted) return;
    // hasLikedWallProvider is a one-shot FutureProvider (LikesRepository
    // exposes no watchHasLiked) — invalidate it so the heart glyph reflects
    // the toggle immediately. likeCountForWallProvider needs no such nudge:
    // it's a live StreamProvider that re-emits on its own once the write
    // above lands.
    ref.invalidate(hasLikedWallProvider(widget.wallId));
  }

  Future<void> _submitComment() async {
    final body = _commentController.text.trim();
    if (body.isEmpty) return;
    final authorName = ref.read(currentAuthorNameProvider);
    await ref
        .read(commentsRepositoryProvider)
        .addComment(wallId: widget.wallId, body: body, authorName: authorName);
    if (!mounted) return;
    _commentController.clear();
    FocusManager.instance.primaryFocus?.unfocus();
  }

  Future<void> _openLogAscentSheet(String routeId) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _LogAscentSheet(wallId: widget.wallId, routeId: routeId),
    );
    // #20a keyboard-dismiss fix (same rationale as
    // topo_canvas_screen.dart's `_openMetadataSheet`): _LogAscentSheet's own
    // `_save` already unfocuses before popping itself, but a swipe-down/scrim
    // dismissal bypasses `_save` entirely and pops the sheet's route
    // directly. Unfocusing here, unconditionally once this
    // `showModalBottomSheet` future resolves (by WHATEVER means the sheet
    // closed), is this screen's own belt-and-suspenders backstop so the
    // keyboard is never left stranded no matter how the sheet was dismissed.
    if (!context.mounted) return;
    FocusManager.instance.primaryFocus?.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final wallId = widget.wallId;
    final colors = MasiColors.of(context);
    final likeCount = ref.watch(likeCountForWallProvider(wallId)).value ?? 0;
    final hasLiked = ref.watch(hasLikedWallProvider(wallId)).value ?? false;
    final comments =
        ref.watch(commentsForWallProvider(wallId)).value ?? const [];
    final routeEntries =
        ref.watch(routeEntriesForWallProvider(wallId)).value ?? const [];
    // Watched (not just read from _submitComment) so authStateProvider is
    // warmed from the very first build: authRepositoryProvider's
    // authStateChanges() stream emits its first value asynchronously (a
    // microtask, not synchronously) — if currentAuthorNameProvider were
    // only ever *read* lazily inside _submitComment, the very first
    // comment could race that microtask and see authStateProvider still
    // AsyncLoading (no email yet), silently falling back to 'Anonymous'
    // even for a signed-in user.
    ref.watch(currentAuthorNameProvider);

    return Scaffold(
      key: Key('community-detail-$wallId'),
      body: SafeArea(
        child: Column(
          children: [
            // The read-only canvas: photo + routes + floating route legend,
            // every editing affordance hidden/disabled (see
            // TopoCanvasScreen.readOnly's doc). Also doubles as this
            // screen's own back navigation — its back chevron pops this
            // route the same as an AppBar's would.
            SizedBox(
              height: MediaQuery.sizeOf(context).height * 0.48,
              child: TopoCanvasScreen(
                wallId: wallId,
                readOnly: true,
                // `debugInitialImageSize` is `@visibleForTesting` on
                // TopoCanvasScreen because ITS author only anticipated test
                // callers — but this screen's own `debugInitialImageSize`
                // (also `@visibleForTesting`, see this class's field doc)
                // exists specifically to thread through to this exact
                // parameter, so a widget test can seed the embedded
                // canvas's image size without a real decode. Silencing the
                // lint here is a deliberate, narrow passthrough, not an
                // accident (mirrors `ar_overlay_painter.dart`'s identical
                // use of this same ignore).
                // ignore: invalid_use_of_visible_for_testing_member
                debugInitialImageSize: widget.debugInitialImageSize,
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(MasiSpacing.lg),
                children: [
                  Row(
                    children: [
                      IconButton(
                        key: const Key('community-like-button'),
                        tooltip: hasLiked ? 'Unlike' : 'Like',
                        icon: Icon(
                          hasLiked ? Icons.favorite : Icons.favorite_border,
                          color: hasLiked ? colors.accent : colors.ink2,
                        ),
                        onPressed: _toggleLike,
                      ),
                      Text(
                        '$likeCount',
                        key: const Key('community-like-count'),
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ],
                  ),
                  const Divider(),
                  Text('Comments', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: MasiSpacing.sm),
                  for (final comment in comments) _CommentRow(comment: comment),
                  const SizedBox(height: MasiSpacing.sm),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          key: const Key('community-comment-field'),
                          controller: _commentController,
                          decoration: const InputDecoration(
                            hintText: 'Add a comment',
                          ),
                        ),
                      ),
                      const SizedBox(width: MasiSpacing.sm),
                      IconButton(
                        key: const Key('community-comment-submit'),
                        tooltip: 'Post comment',
                        icon: const Icon(Icons.send),
                        onPressed: _submitComment,
                      ),
                    ],
                  ),
                  const Divider(),
                  Text('Routes', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: MasiSpacing.sm),
                  for (final entry in routeEntries)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        entry.route.gradeRaw != null
                            ? 'Route ${entry.route.number} • ${entry.route.gradeRaw}'
                            : 'Route ${entry.route.number}',
                      ),
                      trailing: OutlinedButton(
                        key: Key('community-log-ascent-${entry.dbId}'),
                        onPressed: () => _openLogAscentSheet(entry.dbId),
                        child: const Text('Log ascent'),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CommentRow extends StatelessWidget {
  const _CommentRow({required this.comment});

  final Comment comment;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    return Padding(
      key: Key('community-comment-${comment.id}'),
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

/// Small modal sheet for logging an ascent of one route: an [AscentStyle]
/// picker, an optional notes field, and a save action that stamps
/// `climbedAt` to "now" (no date picker — matches the ticket's "date
/// defaulting to now" spec).
class _LogAscentSheet extends ConsumerStatefulWidget {
  const _LogAscentSheet({required this.wallId, required this.routeId});

  final String wallId;
  final String routeId;

  @override
  ConsumerState<_LogAscentSheet> createState() => _LogAscentSheetState();
}

class _LogAscentSheetState extends ConsumerState<_LogAscentSheet> {
  AscentStyle _style = AscentStyle.redpoint;
  final _notesController = TextEditingController();

  @override
  void dispose() {
    _notesController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final notes = _notesController.text.trim();
    await ref
        .read(ascentsRepositoryProvider)
        .logAscent(
          routeId: widget.routeId,
          wallId: widget.wallId,
          climbedAt: DateTime.now(),
          style: _style,
          notes: notes.isEmpty ? null : notes,
        );
    if (mounted) {
      FocusManager.instance.primaryFocus?.unfocus();
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: const Key('community-log-ascent-sheet'),
      padding: EdgeInsets.only(
        left: MasiSpacing.lg,
        right: MasiSpacing.lg,
        top: MasiSpacing.lg,
        bottom: MediaQuery.viewInsetsOf(context).bottom + MasiSpacing.lg,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Log ascent', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: MasiSpacing.md),
          Wrap(
            spacing: MasiSpacing.sm,
            children: [
              for (final style in AscentStyle.values)
                ChoiceChip(
                  key: Key('community-ascent-style-${style.name}'),
                  label: Text(style.name),
                  selected: _style == style,
                  onSelected: (_) => setState(() => _style = style),
                ),
            ],
          ),
          const SizedBox(height: MasiSpacing.md),
          TextField(
            key: const Key('community-ascent-notes'),
            controller: _notesController,
            decoration: const InputDecoration(hintText: 'Notes (optional)'),
          ),
          const SizedBox(height: MasiSpacing.md),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              key: const Key('community-ascent-save'),
              onPressed: _save,
              child: const Text('Save'),
            ),
          ),
        ],
      ),
    );
  }
}
