import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../app/theme.dart';
import '../../../core/db/storage_durability_provider.dart';
import '../../../core/routes/route_styles.dart';
import '../../../shared/presentation/masi_icon.dart';
import '../../../shared/presentation/masi_loading_gate.dart';
import '../../../shared/presentation/masi_skeleton.dart';
import '../../account/application/auth_providers.dart';
import '../../logbook/presentation/log_ascent_sheet.dart';
import '../../topo/domain/topo_route.dart';
import '../../topo/presentation/canvas_chrome.dart';
import '../../topo/presentation/topo_canvas_screen.dart';
import '../../library/application/library_providers.dart';
import '../application/comments_providers.dart';
import '../application/community_topo_detail_providers.dart';
import '../application/likes_providers.dart';
import '../data/comments_repository.dart';
import 'community_shared.dart';

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

  /// Redesign: drives the collapsing header between its "hero" look (large
  /// white title over the photo, behind a gradient scrim) and its
  /// "collapsed" look (small title in `colors.ink` over a solid
  /// `colors.surface` app-bar background) — see [_onScroll].
  /// `FlexibleSpaceBar.title`'s own color is otherwise STATIC across the
  /// whole collapse animation (only its position/scale are framework-
  /// animated — see `FlexibleSpaceBar.build`'s `title` branch), so without
  /// this the title would have to pick one fixed color that stays legible
  /// on both a photo AND a solid theme surface — impossible with this app's
  /// light/dark `MasiColors` tokens (no single color reads well on both an
  /// arbitrary photo-with-scrim and a near-white/near-black surface).
  final _scrollController = ScrollController();
  bool _headerCollapsed = false;
  double _expandedHeight = 0;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  /// Flips [_headerCollapsed] once the header has scrolled (approximately)
  /// all the way to its pinned, collapsed strip — matching the same
  /// scroll-offset threshold (`expandedHeight - kToolbarHeight`) at which
  /// `FlexibleSpaceBar`'s own built-in background fade (see its `build`
  /// method: `background` fades to fully transparent over the last
  /// `kToolbarHeight` px of the collapse) finishes, so the title's color
  /// switch lines up with the background's own transition instead of
  /// visibly fighting it.
  void _onScroll() {
    if (_expandedHeight <= 0) return;
    final threshold = _expandedHeight - kToolbarHeight;
    final collapsed =
        _scrollController.hasClients && _scrollController.offset >= threshold;
    if (collapsed != _headerCollapsed) {
      setState(() => _headerCollapsed = collapsed);
    }
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _commentController.dispose();
    super.dispose();
  }

  /// The OPTIMISTIC liked state — what this device just did, shown
  /// immediately, until [hasLikedWallProvider] catches up. `null` means "no
  /// pending toggle; trust the provider".
  ///
  /// A like is deliberately the one action here that shows no spinner: it is a
  /// single reversible bit whose entire value is feeling instant, and a heart
  /// that greys out mid-tap reads as broken. Instant flip, rollback with a
  /// message if the write fails. See `AscentDetailScreen`'s identical field.
  bool? _likeOverride;

  /// In-flight guard for [_toggleLike] — without one, two quick taps ran two
  /// toggles against the same row.
  bool _likeInFlight = false;

  /// Bound on [_resolveAuthorName]'s wait. See that method.
  static const Duration _authorNameTimeout = Duration(seconds: 3);

  Future<void> _toggleLike() async {
    if (_likeInFlight) return;
    final wallId = widget.wallId;
    final current =
        _likeOverride ?? ref.read(hasLikedWallProvider(wallId)).value ?? false;
    _likeInFlight = true;
    // Instant feedback, before any await.
    setState(() => _likeOverride = !current);

    try {
      await ref.read(likesRepositoryProvider).toggleLike(wallId);
    } catch (error) {
      _likeInFlight = false;
      if (!mounted) return;
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
    // hasLikedWallProvider is a one-shot FutureProvider (LikesRepository
    // exposes no watchHasLiked), so it has to be refreshed by hand.
    // `refresh(.future)` rather than `invalidate`: the override may only be
    // dropped once the REFRESHED answer is in — an invalidated provider still
    // reports its stale value until then, which would flicker the heart back
    // through the pre-tap state.
    //
    // likeCountForWallProvider needs no nudge: it's a live StreamProvider that
    // re-emits once the write lands. The count is deliberately left to it
    // rather than hand-incremented — that is how a wrong number gets on screen.
    try {
      // ignore: unused_result
      await ref.refresh(hasLikedWallProvider(wallId).future);
    } catch (_) {
      // The write landed; a failed re-read is not worth telling anyone about.
    }
    _likeInFlight = false;
    if (mounted) setState(() => _likeOverride = null);
  }

  /// The `authorName` to stamp on a new comment, waiting out an auth state that
  /// has not resolved YET rather than stamping the fallback.
  ///
  /// [currentAuthorNameProvider] derives the name from [authStateProvider] and
  /// returns `'Anonymous'` whenever there is no email — which is correct for a
  /// signed-OUT user and wrong for a signed-in one whose auth stream simply has
  /// not emitted yet (it emits asynchronously, a microtask at best). The
  /// pre-existing `ref.watch` in [build] warms the provider, but warming is not
  /// waiting: a comment posted in this screen's first instants was still
  /// attributed to 'Anonymous', permanently, for a named user. Now the post
  /// button is a pending control, so this can simply wait.
  ///
  /// Bounded and total: a stream that errors (an uninitialized Supabase makes
  /// [authStateProvider] a permanent `AsyncError` — see `router.dart`'s doc) or
  /// never emits inside [_authorNameTimeout] falls through to exactly the old
  /// behaviour rather than blocking the post.
  Future<String> _resolveAuthorName() async {
    final auth = ref.read(authStateProvider);
    if (!auth.hasValue && !auth.hasError) {
      try {
        await ref.read(authStateProvider.future).timeout(_authorNameTimeout);
      } catch (_) {
        // Fall through: read whatever the provider says now.
      }
      if (!mounted) return 'Anonymous';
    }
    return ref.read(currentAuthorNameProvider);
  }

  Future<void> _submitComment() async {
    final body = _commentController.text.trim();
    if (body.isEmpty) return;
    final authorName = await _resolveAuthorName();
    if (!mounted) return;
    await ref
        .read(commentsRepositoryProvider)
        .addComment(wallId: widget.wallId, body: body, authorName: authorName);
    if (!mounted) return;
    _commentController.clear();
    FocusManager.instance.primaryFocus?.unfocus();
  }

  /// #41: best-effort external launch of a route's beta-video URL. Never
  /// throws — an unparseable URL or platform launch failure is swallowed,
  /// mirroring `route_legend.dart`'s identical `launchBetaVideo` helper
  /// (duplicated here rather than shared since this screen and
  /// `RouteLegend` are otherwise independent presentation modules).
  Future<void> _launchBetaVideo(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      // No in-app surface to report this to from here; swallow.
    }
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
  /// widget the app's own `/walls/:wallId` route hosts full-screen (that
  /// route now also accepts a `?readonly=1` query to render read-only) —
  /// but pushed directly via [Navigator], rather than through that
  /// go_router path, as a deliberate choice: routing through go_router
  /// here would change this header tap's back-nav/URL semantics (this
  /// screen's own address bar entry would be replaced by the canvas
  /// route's), which isn't wanted for a push that's really just "expand
  /// this same topo full-screen". `readOnly: true` is still hard-passed
  /// regardless, since a community topo may belong to someone else and
  /// must never become editable.
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
    final hasLiked =
        _likeOverride ?? ref.watch(hasLikedWallProvider(wallId)).value ?? false;
    // `hasValue` is tracked, not just the value: an empty list means "no
    // comments/routes" and a first load means "not known yet", and rendering
    // the former for the latter is what made this screen state, in writing,
    // that a topo had no comments before it had read them (see the gates in
    // `_buildComments`/`_buildRoutesSection`).
    final asyncComments = ref.watch(commentsForWallProvider(wallId));
    final comments = asyncComments.value ?? const <Comment>[];
    final asyncRoutes = ref.watch(routeEntriesForWallProvider(wallId));
    final routeEntries = asyncRoutes.value ?? const <RouteEntry>[];
    // Chrome-title fix: the collapsing header used to show no title at all
    // (just a back button), leaving the viewer with no way to tell which
    // topo they're looking at once they'd scrolled past its photo.
    //
    // 'Topo' is the fallback for a wall with no name AND for a failed read —
    // mirroring topo_canvas_screen.dart's own `wallNameProvider` fallback — but
    // NOT for a read still in flight. Loading is not the same as unknown: the
    // old `maybeWhen(orElse:)` collapsed the two, so a real topo's name landed
    // as a visible flash of the placeholder. A first load gets a title-shaped
    // skeleton instead (see the header's `title:` below).
    final wallName = ref.watch(wallNameProvider(wallId));
    final titleLoading = !wallName.hasValue && !wallName.hasError;
    final title = wallName.maybeWhen(
      data: (name) => (name == null || name.isEmpty) ? 'Topo' : name,
      orElse: () => 'Topo',
    );
    // Watched (not just read from _submitComment) so authStateProvider is
    // warmed from the very first build: authRepositoryProvider's
    // authStateChanges() stream emits its first value asynchronously (a
    // microtask, not synchronously) — if currentAuthorNameProvider were
    // only ever *read* lazily inside _submitComment, the very first
    // comment could race that microtask and see authStateProvider still
    // AsyncLoading (no email yet), silently falling back to 'Anonymous'
    // even for a signed-in user.
    ref.watch(currentAuthorNameProvider);

    // Storage interlock. A comment is a real row in the local database that
    // the outbox later pushes; written into a store that cannot keep it, it is
    // lost silently and never syncs.
    //
    // The LIKE button is deliberately NOT gated. It is reversible view state,
    // not authored content — blocking it makes browsing hostile for no
    // protective gain, and an un-synced like is not something a climber loses
    // work over. Same reasoning as the route-visibility toggle.
    final storageBlocked = storageBlockedNotice(
      ref.watch(storageDurabilityProvider),
    );

    final expandedHeight = MediaQuery.sizeOf(context).height * 0.48;
    // Captured for `_onScroll` (see that method's doc) — an ordinary field
    // write, not a `setState`, since it's just stashing a layout value for a
    // later scroll-callback read, not itself something that needs to
    // trigger a rebuild.
    _expandedHeight = expandedHeight;

    return Scaffold(
      key: Key('community-detail-$wallId'),
      body: SafeArea(
        child: CustomScrollView(
          controller: _scrollController,
          slivers: [
            // D1: the topo image as a fixed, COLLAPSING header (rolls up as
            // the body below scrolls) rather than the old fixed-height
            // SizedBox. `pinned: true` keeps a small collapsed strip (with
            // the back button below) always visible instead of the header
            // disappearing entirely.
            SliverAppBar(
              key: const Key('community-detail-header'),
              pinned: true,
              expandedHeight: expandedHeight,
              // Transparent while the photo (+ scrim) is still showing
              // through — so the header reads as one continuous surface
              // with the photo. Once collapsed (see `_headerCollapsed`),
              // solid `colors.surface` shows behind the now-small,
              // ink-colored title: standard collapsing-header behavior,
              // legible in both states.
              backgroundColor: _headerCollapsed
                  ? colors.surface
                  : Colors.transparent,
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
                    titlePadding: const EdgeInsetsDirectional.only(
                      start: 56,
                      bottom: MasiSpacing.md,
                      end: MasiSpacing.lg,
                    ),
                    // Redesign: a proper large-title hierarchy (titleLarge,
                    // bumped to w700) instead of the old cramped
                    // titleMedium overlaid directly on the photo with no
                    // scrim — legible over ANY photo thanks to the
                    // gradient scrim in `background` below, white while
                    // expanded and switching to `colors.ink` once
                    // collapsed onto the now-solid `colors.surface`
                    // app-bar background (see `_headerCollapsed`).
                    title: titleLoading
                        // Reserved at the real title's line height (titleLarge
                        // 22) and roughly a name's width, so the resolved name
                        // lands in the same place rather than shoving the
                        // header's layout around when it arrives.
                        ? const SizedBox(
                            key: Key('community-detail-title-skeleton'),
                            width: 160,
                            child: MasiSkeleton.line(width: 160),
                          )
                        : Text(
                            title,
                            key: const Key('community-detail-title'),
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleLarge
                                ?.copyWith(
                                  fontWeight: FontWeight.w700,
                                  color: _headerCollapsed
                                      ? colors.ink
                                      : Colors.white,
                                ),
                          ),
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
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          TopoCanvasScreen(
                            wallId: wallId,
                            readOnly: true,
                            embedded: true,
                            // ignore: invalid_use_of_visible_for_testing_member
                            debugInitialImageSize: widget.debugInitialImageSize,
                          ),
                          // Bottom-aligned gradient scrim: keeps the title
                          // (in its white, "over-the-photo" state) legible
                          // regardless of the underlying photo's own
                          // colors/contrast — transparent at the top so the
                          // photo itself still reads, darkening toward the
                          // bottom where the title sits.
                          DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                stops: const [0.5, 1.0],
                                colors: [
                                  Colors.black.withValues(alpha: 0),
                                  Colors.black.withValues(alpha: 0.55),
                                ],
                              ),
                            ),
                          ),
                        ],
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
                        icon: hasLiked
                            ? MasiIcon('heart_fill', color: colors.accent)
                            : MasiIcon('heart', color: colors.ink2),
                        onPressed: _toggleLike,
                      ),
                      Text(
                        '$likeCount',
                        key: const Key('community-like-count'),
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ],
                  ),
                  const SizedBox(height: MasiSpacing.sm),
                  const Divider(),
                  const SizedBox(height: MasiSpacing.xs),
                  Text(
                    'Comments',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: MasiSpacing.sm),
                  // Gated so the three states stay distinct: nothing at all
                  // for a read that resolves inside the reveal delay (the
                  // normal local case), a shaped placeholder for a slower one,
                  // and "no comments yet" ONLY once that is actually known.
                  MasiLoadingGate(
                    isLoading: !asyncComments.hasValue,
                    builder: (context, showSkeleton) {
                      if (showSkeleton) return const _CommentsSkeleton();
                      if (comments.isEmpty) {
                        return Text(
                          'No comments yet — be the first',
                          key: const Key('community-comments-empty'),
                          style: Theme.of(
                            context,
                          ).textTheme.bodyMedium?.copyWith(color: colors.ink2),
                        );
                      }
                      return Column(
                        // Stretch: these rows were direct children of the
                        // sliver list before, i.e. full width.
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final comment in comments)
                            _CommentRow(comment: comment),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: MasiSpacing.md),
                  if (storageBlocked != null)
                    // The composer is replaced rather than merely disabled: an
                    // inert text field with a greyed send glyph and nothing
                    // saying why is the dead-tap failure in a quieter costume.
                    Text(
                      storageBlocked,
                      key: const Key('community-comment-blocked'),
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall?.copyWith(color: colors.ink2),
                    )
                  else
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: TextField(
                          key: const Key('community-comment-field'),
                          controller: _commentController,
                          // Redesign: filled, rounded input matching the
                          // Community Feed's own search field style
                          // (`community_feed_screen.dart`) — a soft
                          // `surface2` fill with no harsh underline, rather
                          // than the bare default `InputDecoration`.
                          decoration: InputDecoration(
                            hintText: 'Add a comment',
                            filled: true,
                            fillColor: colors.surface2,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: MasiSpacing.lg,
                              vertical: MasiSpacing.md,
                            ),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(
                                MasiRadii.control,
                              ),
                              borderSide: BorderSide.none,
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(
                                MasiRadii.control,
                              ),
                              borderSide: BorderSide.none,
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(
                                MasiRadii.control,
                              ),
                              borderSide: BorderSide(
                                color: colors.accent,
                                width: 1.5,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: MasiSpacing.sm),
                      // Disabled/inert state for an empty/whitespace-only
                      // draft: rebuilt straight off the controller (rather
                      // than gated on comments-list state) so it reacts to
                      // every keystroke, not just a comment actually posting.
                      ValueListenableBuilder<TextEditingValue>(
                        valueListenable: _commentController,
                        builder: (context, value, _) {
                          final canSubmit = value.text.trim().isNotEmpty;
                          // Pending, not plain: posting awaits an author-name
                          // resolution and a Drift write, and an unguarded
                          // double tap posted the comment twice.
                          return PendingIconButton(
                            buttonKey: const Key('community-comment-submit'),
                            tooltip: 'Post comment',
                            icon: MasiIcon(
                              'send_fill',
                              color: canSubmit ? colors.accent : colors.ink2,
                            ),
                            onPressed: canSubmit ? _submitComment : null,
                            onError: (error, stackTrace) =>
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text(
                                      "Couldn't post your comment — please try again",
                                    ),
                                  ),
                                ),
                          );
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: MasiSpacing.lg),
                  const Divider(),
                  const SizedBox(height: MasiSpacing.sm),
                  _buildRoutesSection(
                    context,
                    colors,
                    routeEntries,
                    loading: !asyncRoutes.hasValue,
                  ),
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
    List<RouteEntry> routeEntries, {
    required bool loading,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          key: const Key('community-routes-section'),
          onTap: () => setState(() => _routesExpanded = !_routesExpanded),
          borderRadius: BorderRadius.circular(MasiRadii.control),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: MasiSpacing.sm),
            child: Row(
              children: [
                Text(
                  'Routes',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
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
        // Redesign: the routes used to render as a bare Column of
        // zero-padding ListTiles that visually ran into each other. Now a
        // single card (`colors.surface` + `MasiRadii.card` +
        // `kMasiAmbientShadow`, matching this app's other card surfaces —
        // see account_screen.dart's sign-in card) holds every route row,
        // with a hairline `separator` Divider BETWEEN rows (never after
        // the last) so no two rows ever visually merge.
        if (_routesExpanded)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: MasiSpacing.lg),
            decoration: BoxDecoration(
              color: colors.surface,
              borderRadius: BorderRadius.circular(MasiRadii.card),
              boxShadow: kMasiAmbientShadow,
            ),
            // Same three-state gate as the comments above: an empty card is
            // "this topo has no routes", which must not be what a read still
            // in flight looks like.
            child: MasiLoadingGate(
              isLoading: loading,
              builder: (context, showSkeleton) => showSkeleton
                  ? _RouteRowsSkeleton(colors: colors)
                  : Column(
                      children: [
                        for (var i = 0; i < routeEntries.length; i++) ...[
                          _buildRouteRow(context, colors, routeEntries[i]),
                          if (i != routeEntries.length - 1)
                            Divider(
                              height: 1,
                              thickness: 1,
                              color: colors.separator,
                            ),
                        ],
                      ],
                    ),
            ),
          ),
      ],
    );
  }

  /// One route row in the redesigned Routes card: a leading grade pill
  /// ([_GradeBadge], shown when [TopoRoute.gradeRaw] is set), the route's
  /// name/number ([_routeNameLabel] — [routeDisplayLabel]'s identical
  /// name-vs-number fallback, minus the `' • <grade>'` suffix now shown in
  /// the pill instead), its style-tag chips + star rating underneath, and
  /// right-aligned actions (beta-video + "Log ascent") — every existing
  /// key/behavior preserved exactly.
  Widget _buildRouteRow(
    BuildContext context,
    MasiColors colors,
    RouteEntry entry,
  ) {
    final route = entry.route;
    final grade = route.gradeRaw;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: MasiSpacing.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (grade != null) ...[
            _GradeBadge(grade: grade),
            const SizedBox(width: MasiSpacing.sm),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _routeNameLabel(route),
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: colors.ink,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (route.styleTags.isNotEmpty || (route.stars ?? 0) > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: MasiSpacing.xs),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (route.styleTags.isNotEmpty)
                          Wrap(
                            spacing: 4,
                            runSpacing: 4,
                            children: [
                              for (final tag in route.styleTags)
                                _RouteStyleTagChip(
                                  routeId: entry.dbId,
                                  tag: tag,
                                ),
                            ],
                          ),
                        if ((route.stars ?? 0) > 0)
                          Row(
                            key: Key('route-stars-${entry.dbId}'),
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              for (var i = 0; i < route.stars!; i++)
                                const Padding(
                                  padding: EdgeInsets.only(right: 1),
                                  child: MasiIcon('star_fill', size: 12),
                                ),
                            ],
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: MasiSpacing.sm),
          if (route.betaVideoUrl != null)
            // Pending: handing off to an external app is a platform round trip
            // that can take a beat, and a second tap while it ran launched the
            // URL twice.
            PendingIconButton(
              buttonKey: Key('route-beta-${entry.dbId}'),
              tooltip: 'Watch beta video',
              visualDensity: VisualDensity.compact,
              icon: MasiIcon('globe'),
              onPressed: () => _launchBetaVideo(route.betaVideoUrl!),
            ),
          OutlinedButton(
            key: Key('community-log-ascent-${entry.dbId}'),
            style: OutlinedButton.styleFrom(
              foregroundColor: colors.accent,
              side: BorderSide(color: colors.accent),
              padding: const EdgeInsets.symmetric(
                horizontal: MasiSpacing.md,
                vertical: MasiSpacing.xs,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(MasiRadii.control),
              ),
            ),
            onPressed: () => _openLogAscentSheet(entry.dbId),
            child: const Text('Log ascent'),
          ),
        ],
      ),
    );
  }
}

/// Placeholder for the comment thread's first load: two comments' worth of
/// author + body lines, at [_CommentRow]'s own geometry (its `vertical: xs`
/// padding, an author line at labelLarge 14 over a body line at bodyMedium 17).
///
/// Text slots are scaled by [MediaQuery.textScalerOf] for the same reason the
/// shared composites scale theirs — an unscaled skeleton only matches at the
/// default text size.
class _CommentsSkeleton extends StatelessWidget {
  const _CommentsSkeleton();

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    return Column(
      key: const Key('community-comments-skeleton'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < 2; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: MasiSpacing.xs),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                MasiSkeleton.textLine(
                  fontSize: scaler.scale(14),
                  widthFactor: 0.25,
                ),
                MasiSkeleton.textLine(
                  fontSize: scaler.scale(17),
                  widthFactor: i == 0 ? 0.8 : 0.55,
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Placeholder for the Routes card's first load: two rows' worth of grade pill
/// + route-name line, inside the card the real rows fill, with the same
/// hairline separator between them.
///
/// The trailing "Log ascent" button and the beta-video control are deliberately
/// NOT drawn — a shimmering control invites a tap on something that cannot be
/// tapped (the same rule [MasiSkeletonListRow] follows for its own trailing
/// icon buttons).
class _RouteRowsSkeleton extends StatelessWidget {
  const _RouteRowsSkeleton({required this.colors});

  final MasiColors colors;

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    return Column(
      key: const Key('community-routes-skeleton'),
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < 2; i++) ...[
          Padding(
            padding: const EdgeInsets.symmetric(vertical: MasiSpacing.md),
            child: Row(
              children: [
                // The leading `_GradeBadge` pill.
                const MasiSkeleton.box(
                  width: 34,
                  height: 22,
                  radius: MasiRadii.control,
                ),
                const SizedBox(width: MasiSpacing.sm),
                Expanded(
                  child: MasiSkeleton.textLine(
                    fontSize: scaler.scale(15),
                    widthFactor: i == 0 ? 0.55 : 0.4,
                  ),
                ),
              ],
            ),
          ),
          if (i == 0) Divider(height: 1, thickness: 1, color: colors.separator),
        ],
      ],
    );
  }
}

/// [routeDisplayLabel]'s identical name-vs-number fallback, minus the
/// trailing `' • <grade>'` suffix — the grade renders separately in this
/// screen's own leading [_GradeBadge] rather than appended to the name.
String _routeNameLabel(TopoRoute route) {
  final trimmedName = route.name?.trim();
  return (trimmedName != null && trimmedName.isNotEmpty)
      ? '${route.number}. $trimmedName'
      : 'Route ${route.number}';
}

/// Small leading grade pill for a route row in the redesigned Routes list —
/// a soft, theme-adaptive chip (`MasiColors.surface2` background, matching
/// `route_legend.dart`'s style-tag chips) with `accent`-tinted text, so the
/// grade reads at a glance before the route's full name/number. Deliberately
/// NOT `amethyst100` for the fill: that brand-ramp token is a fixed literal
/// in both light AND dark `MasiColors` (see theme.dart), so pairing it with
/// the theme-adaptive `accent` text color would give poor contrast in dark
/// mode (light lavender fill + light purple text).
class _GradeBadge extends StatelessWidget {
  const _GradeBadge({required this.grade});

  final String grade;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: MasiSpacing.sm,
        vertical: MasiSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: colors.surface2,
        borderRadius: BorderRadius.circular(MasiRadii.control),
      ),
      child: Text(
        grade,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
          color: colors.accent,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// A small, non-interactive display chip for one of a route's style tags
/// (see `core/routes/route_styles.dart`): a curated tag shows its curated
/// label; an arbitrary custom tag shows its raw stored string. Duplicated
/// from `route_legend.dart`'s identical private `_RouteStyleTagChip` since
/// this screen and `RouteLegend` are otherwise independent presentation
/// modules.
class _RouteStyleTagChip extends StatelessWidget {
  const _RouteStyleTagChip({required this.routeId, required this.tag});

  final String routeId;
  final String tag;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    final resolved = resolveStyleTag(tag);
    return Container(
      key: Key('route-styletag-$routeId-$tag'),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: colors.surface2,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        resolved.displayLabel,
        style: TextStyle(fontSize: 10, fontWeight: FontWeight.w500, color: colors.ink2),
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
