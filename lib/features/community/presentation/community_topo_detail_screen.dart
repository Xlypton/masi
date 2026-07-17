import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../../../shared/presentation/masi_icon.dart';
import '../../logbook/presentation/log_ascent_sheet.dart';
import '../../topo/presentation/route_legend.dart';
import '../../topo/presentation/topo_canvas_screen.dart';
import '../application/comments_providers.dart';
import '../application/community_topo_detail_providers.dart';
import '../application/likes_providers.dart';
import '../data/comments_repository.dart';

/// Read-only detail view for a single shared ("community") topo: a
/// collapsing header showing the wall's photo + route overlays (tap it to
/// open the full interactive, still-`readOnly` canvas — see
/// [_openFullCanvas]), plus this feature's social surface: like/unlike, a
/// comment thread, and a collapsible "Routes" section with a "log ascent"
/// affordance per route.
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
  /// (gesture-disabled) [TopoCanvasScreen] used for the collapsing header's
  /// static preview — see [TopoCanvasScreen.debugInitialImageSize]'s doc
  /// for why a widget test can't drive the real image decode. Also threaded
  /// through to the full-screen canvas [_openFullCanvas] pushes. Always
  /// null in production.
  @visibleForTesting
  final Size? debugInitialImageSize;

  @override
  ConsumerState<CommunityTopoDetailScreen> createState() =>
      _CommunityTopoDetailScreenState();
}

class _CommunityTopoDetailScreenState
    extends ConsumerState<CommunityTopoDetailScreen> {
  final _commentController = TextEditingController();

  /// D3: the Routes section's own expand/collapse state — defaults to
  /// expanded (matches [LegendExpandedController]'s own view-mode default),
  /// toggled by tapping its header (keyed `community-routes-section`).
  bool _routesExpanded = true;

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
      builder: (_) => LogAscentSheet(
        routeId: routeId,
        wallId: widget.wallId,
        keyPrefix: 'community',
      ),
    );
    // #20a keyboard-dismiss fix (same rationale as
    // topo_canvas_screen.dart's `_openMetadataSheet`): LogAscentSheet's own
    // `_save` already unfocuses before popping itself, but a swipe-down/scrim
    // dismissal bypasses `_save` entirely and pops the sheet's route
    // directly. Unfocusing here, unconditionally once this
    // `showModalBottomSheet` future resolves (by WHATEVER means the sheet
    // closed), is this screen's own belt-and-suspenders backstop so the
    // keyboard is never left stranded no matter how the sheet was dismissed.
    if (!context.mounted) return;
    FocusManager.instance.primaryFocus?.unfocus();
  }

  /// D2: tapping the collapsing header pushes the SAME [TopoCanvasScreen]
  /// widget the app's own `/walls/:wallId` route hosts full-screen — but
  /// pushed directly (rather than through that go_router path, which has
  /// no `readOnly` variant) so this stays `readOnly: true`: a community
  /// topo may belong to someone else, so it must never become editable.
  void _openFullCanvas() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TopoCanvasScreen(
          wallId: widget.wallId,
          readOnly: true,
          // ignore: invalid_use_of_visible_for_testing_member
          debugInitialImageSize: widget.debugInitialImageSize,
        ),
      ),
    );
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
        child: CustomScrollView(
          slivers: [
            // D1: the topo image as a fixed, COLLAPSING header (rolls up as
            // the body below scrolls) rather than the old fixed-height
            // SizedBox. `pinned: true` keeps a small collapsed strip (with
            // the back button below) always visible instead of the header
            // disappearing entirely.
            SliverAppBar(
              key: const Key('community-detail-header'),
              pinned: true,
              expandedHeight: MediaQuery.sizeOf(context).height * 0.48,
              backgroundColor: colors.ground,
              surfaceTintColor: Colors.transparent,
              elevation: 0,
              // This screen owns its own back affordance (rather than the
              // embedded canvas's — see below) since that embedded copy is
              // deliberately made gesture-inert.
              automaticallyImplyLeading: false,
              leading: IconButton(
                key: const Key('community-detail-back-button'),
                icon: MasiIcon('chevron_left'),
                tooltip: 'Back',
                color: colors.accent,
                onPressed: () => Navigator.of(context).maybePop(),
              ),
              // D2 fix: the tap target used to live INSIDE
              // `FlexibleSpaceBar.background` itself (an opaque
              // GestureDetector wrapping the IgnorePointer'd canvas) — that
              // threaded it through FlexibleSpaceBar's own internal
              // Positioned/Opacity plumbing (see `_FlexibleSpaceBarState`'s
              // collapse-mode math in the framework source), which ties its
              // hit-testable box to that machinery rather than to this
              // header's own plain box, and — per this regression's own
              // proof (see D2's test) — could leave taps landing on nothing.
              // Hoisted out here instead: the decorative `FlexibleSpaceBar`
              // and the tap-catching `GestureDetector` are now plain
              // SIBLINGS in this `Stack`, `fit: StackFit.expand` forcing
              // both to the header's exact box. The `GestureDetector` is the
              // LAST child (frontmost — hit-tested first), `Positioned.fill`
              // + `opaque` + no child of its own to defer to, so a tap
              // anywhere in the header resolves to it directly rather than
              // depending on anything the decorative layer beneath is doing.
              flexibleSpace: Stack(
                fit: StackFit.expand,
                children: [
                  FlexibleSpaceBar(
                    collapseMode: CollapseMode.pin,
                    background: IgnorePointer(
                      // NON-interactive: the embedded TopoCanvasScreen's own
                      // pan/zoom (InteractiveViewer) and tap-to-select would
                      // otherwise win the gesture arena over this
                      // CustomScrollView's own scroll drag, "eating" the
                      // scroll gesture entirely. IgnorePointer removes this
                      // whole subtree from hit-testing, so pointer events
                      // fall through to (a) the opaque GestureDetector above
                      // (D2) and (b) the ancestor Scrollable's drag
                      // recognizer for anything beyond tap-slop (D1) — the
                      // same arena-resolution every tappable row inside an
                      // ordinary scrollable list already relies on.
                      //
                      // Ghost-chevron fix: the embedded screen used to still
                      // PAINT its own top chrome pill (wall name + a
                      // `chevron_left` back button) and floating route
                      // legend — purely decorative once IgnorePointer made
                      // them inert, but the back chevron looked identical to
                      // a REAL back button while tapping the header actually
                      // goes forward into the full canvas (via the
                      // GestureDetector below), a misleading affordance. Also
                      // a visible symptom of legendExpandedProvider/
                      // drawControllerProvider being app-lifetime globals
                      // shared with whatever full-screen canvas is
                      // simultaneously live (see TopoCanvasScreen.embedded's
                      // doc). `embedded: true` suppresses both — this
                      // screen's own `community-detail-back-button` above is
                      // the only FUNCTIONAL back control, and this header
                      // never showed its own route legend anyway (the
                      // "Routes" section below does that job).
                      child: TopoCanvasScreen(
                        wallId: wallId,
                        readOnly: true,
                        embedded: true,
                        // ignore: invalid_use_of_visible_for_testing_member
                        debugInitialImageSize: widget.debugInitialImageSize,
                      ),
                    ),
                  ),
                  Positioned.fill(
                    child: GestureDetector(
                      key: const Key('community-detail-open-canvas'),
                      behavior: HitTestBehavior.opaque,
                      onTap: _openFullCanvas,
                      child: const SizedBox.expand(),
                    ),
                  ),
                ],
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.all(MasiSpacing.lg),
              sliver: SliverList(
                delegate: SliverChildListDelegate([
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
                  Text(
                    'Comments',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
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
                        // D4: masi_send.svg doesn't exist in
                        // assets/icons/masi/ (only masi_send_check*) — keep
                        // the existing glyph per that assertion's fallback.
                        icon: MasiIcon('send_check'),
                        onPressed: _submitComment,
                      ),
                    ],
                  ),
                  const Divider(),
                  _buildRoutesSection(context, colors, routeEntries),
                ]),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// D3: the "Routes" header + per-route Log-ascent list as a collapsible
  /// section (default expanded). The header row itself is both the section's
  /// identity (`community-routes-section`) and its toggle tap target;
  /// per-route rows keep their pre-existing `community-log-ascent-<dbId>`
  /// keys/behavior untouched.
  Widget _buildRoutesSection(
    BuildContext context,
    MasiColors colors,
    List<RouteEntry> routeEntries,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          key: const Key('community-routes-section'),
          onTap: () => setState(() => _routesExpanded = !_routesExpanded),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: MasiSpacing.xs),
            child: Row(
              children: [
                Text('Routes', style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                MasiIcon(
                  _routesExpanded ? 'chevron_up' : 'chevron_down',
                  size: 20,
                  color: colors.ink2,
                ),
              ],
            ),
          ),
        ),
        if (_routesExpanded) const SizedBox(height: MasiSpacing.sm),
        if (_routesExpanded)
          for (final entry in routeEntries)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(routeDisplayLabel(entry.route)),
              trailing: OutlinedButton(
                key: Key('community-log-ascent-${entry.dbId}'),
                onPressed: () => _openLogAscentSheet(entry.dbId),
                child: const Text('Log ascent'),
              ),
            ),
      ],
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
