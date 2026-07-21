import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../app/theme.dart';
import '../../../core/routes/route_styles.dart';
import '../../../shared/presentation/masi_icon.dart';
import '../../account/application/auth_providers.dart';
import '../../account/application/profile_providers.dart';
import '../../logbook/presentation/log_ascent_sheet.dart';
import '../../topo/presentation/route_legend.dart';
import '../../topo/presentation/topo_canvas_screen.dart';
import '../../library/application/library_providers.dart';
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

  /// Feature #15 Wave 3: navigates the CTA below to the app's sign-in
  /// surface (`AccountScreen`, mounted at `/account` — see
  /// `lib/app/router.dart`; there is no separate dedicated sign-in screen,
  /// it renders a magic-link form itself when signed out). `context.push`
  /// (not `.go`) matches every other cross-feature navigation in this
  /// screen's siblings (e.g. `community_feed_screen.dart`'s row taps) —
  /// pushed on top so "back" returns here rather than replacing this route.
  void _goToSignIn() => context.push('/account');

  @override
  Widget build(BuildContext context) {
    final wallId = widget.wallId;
    final colors = MasiColors.of(context);
    // Feature #15 Wave 3: a cold/signed-out visitor's local Drift is empty
    // for this wall — gate the whole screen on `wallReadyForDetailProvider`,
    // which (a) is an instant true for the already-local case (signed-in
    // owner, or a previously-hydrated visitor — see that provider's doc for
    // why it never touches Supabase in that path) and (b) triggers +awaits
    // the anon hydrator otherwise. Every provider below this point already
    // reads LOCAL Drift reactively, so once hydration lands they render with
    // zero further changes.
    final wallReady = ref.watch(wallReadyForDetailProvider(wallId));
    return wallReady.when(
      loading: () => _buildLoading(colors),
      error: (_, _) => _buildNotFound(context, colors),
      data: (ready) =>
          ready ? _buildDetail(context, wallId, colors) : _buildNotFound(context, colors),
    );
  }

  /// Shown while [wallReadyForDetailProvider] is still resolving (either the
  /// initial local-presence check, or the anon hydration fetch it triggered
  /// for a genuinely cold wall) — a plain centered spinner rather than a
  /// blank/empty screen.
  Widget _buildLoading(MasiColors colors) {
    return Scaffold(
      key: Key('community-detail-${widget.wallId}'),
      backgroundColor: colors.ground,
      body: const Center(
        child: CircularProgressIndicator(key: Key('community-detail-loading')),
      ),
    );
  }

  /// Shown once hydration has run and the wall STILL isn't local — the
  /// shared link doesn't point at a real, currently-shared topo (not found,
  /// or no longer `visibility == 'shared'`; anon RLS makes those two
  /// indistinguishable, see `SharedWallHydrator.ensureSharedWallLocal`'s
  /// doc). A graceful terminal state rather than a crash or an
  /// indefinitely-blank canvas — keeps this screen's own back affordance so
  /// a visitor isn't stranded.
  Widget _buildNotFound(BuildContext context, MasiColors colors) {
    return Scaffold(
      key: Key('community-detail-${widget.wallId}'),
      backgroundColor: colors.ground,
      body: SafeArea(
        child: Stack(
          children: [
            Center(
              key: const Key('community-detail-not-found'),
              child: Padding(
                padding: const EdgeInsets.all(MasiSpacing.lg),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    MasiIcon('warning', size: 32, color: colors.ink2),
                    const SizedBox(height: MasiSpacing.sm),
                    Text(
                      'Topo not found or no longer shared',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ],
                ),
              ),
            ),
            Positioned(
              top: MasiSpacing.sm,
              left: MasiSpacing.sm,
              child: IconButton(
                key: const Key('community-detail-back-button'),
                icon: MasiIcon('chevron_left'),
                tooltip: 'Back',
                color: colors.accent,
                onPressed: () => Navigator.of(context).maybePop(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDetail(BuildContext context, String wallId, MasiColors colors) {
    final likeCount = ref.watch(likeCountForWallProvider(wallId)).value ?? 0;
    final hasLiked = ref.watch(hasLikedWallProvider(wallId)).value ?? false;
    final comments =
        ref.watch(commentsForWallProvider(wallId)).value ?? const [];
    final routeEntries =
        ref.watch(routeEntriesForWallProvider(wallId)).value ?? const [];
    // Chrome-title fix: the collapsing header used to show no title at all
    // (just a back button), leaving the viewer with no way to tell which
    // topo they're looking at once they'd scrolled past its photo. Mirrors
    // topo_canvas_screen.dart's own `wallNameProvider` fallback: 'Topo'
    // both while still loading and if the wall genuinely has no name.
    final wallName = ref.watch(wallNameProvider(wallId));
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
    // Feature #15 Wave 3: a signed-out visitor (the whole point of the
    // anon-hydrated cold-load path above) can view but not like/comment —
    // `AuthSessionState.isSignedIn` is `email != null`, the same signal
    // `currentAuthorNameProvider` above already keys its 'Anonymous'
    // fallback off of.
    final isSignedIn =
        ref.watch(authStateProvider).asData?.value.isSignedIn ?? false;
    // Feature #15 Wave 3: a cold/signed-out visitor has no other way to see
    // whose topo this is (unlike the Feed, there's no already-loaded row to
    // fall back to) — resolve it the same way `community_feed_screen.dart`'s
    // `_FeedRow`/`_AscentFeedRow` do (`profileDisplayNameProvider`, same
    // "Unknown climber" fallback stance). `null`/empty collapses to nothing
    // rendered rather than a raw uid or an awkward empty byline.
    final ownerId = ref.watch(wallOwnerIdProvider(wallId)).value;
    final authorName = ownerId != null
        ? ref.watch(profileDisplayNameProvider(ownerId)).asData?.value
        : null;

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
                    titlePadding: const EdgeInsetsDirectional.only(
                      start: 56,
                      bottom: MasiSpacing.sm,
                      end: MasiSpacing.lg,
                    ),
                    title: Text(
                      title,
                      key: const Key('community-detail-title'),
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: colors.ink,
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
                  if (authorName != null && authorName.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: MasiSpacing.sm),
                      child: Text(
                        'by $authorName',
                        key: const Key('community-detail-author'),
                        style: Theme.of(context).textTheme.bodyMedium
                            ?.copyWith(color: colors.ink2),
                      ),
                    ),
                  if (isSignedIn)
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
                    )
                  else
                    // Feature #15 Wave 3: replaces BOTH the like button
                    // above and the comment composer below with a single
                    // CTA — a signed-out visitor (anon or otherwise) can
                    // still read the topo + existing comments, just not
                    // interact, so this is the one control shown in place
                    // of the two interactive ones.
                    _SignInToInteractCta(onTap: _goToSignIn),
                  const Divider(),
                  Text(
                    'Comments',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: MasiSpacing.sm),
                  if (comments.isEmpty)
                    Text(
                      'No comments yet — be the first',
                      key: const Key('community-comments-empty'),
                      style: Theme.of(
                        context,
                      ).textTheme.bodyMedium?.copyWith(color: colors.ink2),
                    )
                  else
                    for (final comment in comments)
                      _CommentRow(comment: comment),
                  const SizedBox(height: MasiSpacing.sm),
                  // Signed-out: no composer at all — the single CTA above
                  // (in the like row's slot) already covers "sign in to
                  // comment" too, per this section's own doc.
                  if (isSignedIn)
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
                        // Disabled/inert state for an empty/whitespace-only
                        // draft: rebuilt straight off the controller (rather
                        // than gated on comments-list state) so it reacts to
                        // every keystroke, not just a comment actually posting.
                        ValueListenableBuilder<TextEditingValue>(
                          valueListenable: _commentController,
                          builder: (context, value, _) {
                            final canSubmit = value.text.trim().isNotEmpty;
                            return IconButton(
                              key: const Key('community-comment-submit'),
                              tooltip: 'Post comment',
                              // D4: masi_send.svg doesn't exist in
                              // assets/icons/masi/ (only masi_send_check*) —
                              // keep the existing glyph per that assertion's
                              // fallback.
                              icon: MasiIcon(
                                'send_check',
                                color: canSubmit ? colors.accent : colors.ink2,
                              ),
                              onPressed: canSubmit ? _submitComment : null,
                            );
                          },
                        ),
                      ],
                    ),
                  const Divider(),
                  _buildRoutesSection(context, colors, routeEntries, isSignedIn),
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
  ///
  /// [isSignedIn] gates the per-route "Log ascent" button (a
  /// personal-logbook write) using the SAME `authStateProvider`-derived
  /// signal `build()` uses for the like button/comment composer above — a
  /// signed-out visitor must not be able to open the log-ascent sheet and
  /// save an ownerless ascent.
  Widget _buildRoutesSection(
    BuildContext context,
    MasiColors colors,
    List<RouteEntry> routeEntries,
    bool isSignedIn,
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
              subtitle:
                  (entry.route.styleTags.isEmpty &&
                          (entry.route.stars ?? 0) <= 0)
                      ? null
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (entry.route.styleTags.isNotEmpty)
                              Wrap(
                                spacing: 4,
                                runSpacing: 4,
                                children: [
                                  for (final tag in entry.route.styleTags)
                                    _RouteStyleTagChip(
                                      routeId: entry.dbId,
                                      tag: tag,
                                    ),
                                ],
                              ),
                            if ((entry.route.stars ?? 0) > 0)
                              Row(
                                key: Key('route-stars-${entry.dbId}'),
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  for (
                                    var i = 0;
                                    i < entry.route.stars!;
                                    i++
                                  )
                                    const Padding(
                                      padding: EdgeInsets.only(right: 1),
                                      child: MasiIcon('star_fill', size: 12),
                                    ),
                                ],
                              ),
                          ],
                        ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (entry.route.betaVideoUrl != null)
                    IconButton(
                      key: Key('route-beta-${entry.dbId}'),
                      tooltip: 'Watch beta video',
                      icon: MasiIcon('globe'),
                      onPressed: () =>
                          _launchBetaVideo(entry.route.betaVideoUrl!),
                    ),
                  // Signed-out: this personal-logbook action stays hidden —
                  // the same `_SignInToInteractCta` above already covers the
                  // "sign in to participate" affordance for a read-only
                  // visitor, so this doesn't add a second CTA in its place.
                  if (isSignedIn)
                    OutlinedButton(
                      key: Key('community-log-ascent-${entry.dbId}'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: colors.accent,
                        side: BorderSide(color: colors.accent),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(
                            MasiRadii.control,
                          ),
                        ),
                      ),
                      onPressed: () => _openLogAscentSheet(entry.dbId),
                      child: const Text('Log ascent'),
                    ),
                ],
              ),
            ),
      ],
    );
  }
}

/// Feature #15 Wave 3: the "Sign in to like & comment" CTA shown in place of
/// BOTH the like button and the comment composer for a signed-out visitor
/// (see `_CommunityTopoDetailScreenState.build`'s `isSignedIn` branch).
/// Stateless/non-const-friendly since it just needs a tap callback — no
/// screen-local state of its own.
class _SignInToInteractCta extends StatelessWidget {
  const _SignInToInteractCta({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    return Material(
      key: const Key('community-signin-cta'),
      color: colors.surface2,
      borderRadius: BorderRadius.circular(MasiRadii.control),
      child: InkWell(
        borderRadius: BorderRadius.circular(MasiRadii.control),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: MasiSpacing.md,
            vertical: MasiSpacing.sm,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              MasiIcon('lock', color: colors.accent),
              const SizedBox(width: MasiSpacing.sm),
              Text(
                'Sign in to like & comment',
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(color: colors.ink),
              ),
            ],
          ),
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
