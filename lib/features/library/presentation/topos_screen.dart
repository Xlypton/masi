import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart' show MapController, TileProvider;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:latlong2/latlong.dart';

import '../../../app/theme.dart';
import '../../../core/db/storage_durability_provider.dart';
import '../../../core/grades/grade_system.dart';
import '../../../core/location/location_service.dart';
import '../../../shared/filtering/grade_range_picker.dart';
import '../../../shared/filtering/style_filter_chips.dart';
import '../../account/application/auth_providers.dart';
import '../../account/application/email_initials.dart';
import '../../backup/application/reachability_providers.dart';
import '../../backup/application/sync_orchestrator.dart';
import '../../community/data/community_repository.dart' show SharedTopo;
import '../../topo/presentation/photo_image.dart';
import '../../topo/presentation/photo_source_sheet.dart';
import '../../topo/data/photo_write_exception.dart';
import '../../topo/presentation/topo_canvas_screen.dart'
    show
        captureWallGpsFromPhoto,
        gpsCaptureResultSnackBar,
        photoWriteFailureSnackBar;
import '../application/library_providers.dart';
import '../application/proximity_topos_provider.dart';
import '../data/library_crud_repository.dart';
import '../../../shared/presentation/masi_async_view.dart';
import '../../../shared/presentation/masi_icon.dart';
import '../../../shared/presentation/masi_loading_gate.dart';
import '../../../shared/presentation/masi_loading_indicator.dart';
import '../../../shared/presentation/masi_pending_button.dart';
import '../../../shared/presentation/masi_shimmer.dart';
import '../../../shared/presentation/masi_skeleton.dart';
import '../../../shared/presentation/sync_banner.dart';
import 'move_target_picker.dart';
import 'set_location_picker.dart';

// This screen's supporting private widgets/helpers are split across sibling
// `part` files by cohesion (row rendering, badges, filter bar/sheet, empty
// states, name dialogs) purely for file-size/readability — `part`/`part of`
// keeps them all in this ONE library, so every `_Foo` below stays exactly as
// library-private as it always was; nothing here is a public-API change.
// [ToposScreen] itself (the only symbol anything outside this library
// references) stays in this file, at its original path, per plan.
part 'topos_row.dart';
part 'topos_badges.dart';
part 'topos_filter.dart';
part 'topos_empty_states.dart';
part 'topos_dialogs.dart';
part 'topos_storage_banner.dart';

/// The new flat "photo-first" home (see DESIGN.md "Topos home"): every
/// non-deleted [db.Wall] rendered as a single "topo" row (thumbnail + name +
/// route count), with no Area/Sector hierarchy visible up front. That
/// hierarchy still exists underneath (every topo is secretly filed under a
/// hidden `__default__` Area/Sector, see
/// [LibraryCrudRepository.createTopo]) and remains reachable via the
/// trailing "Organize" action, which pushes `/areas`.
///
/// [photoSourcePicker] / [photoPicker] are injectable seams (defaulting to
/// the real [showPhotoSourceSheet] / [pickPhotoFrom]) so widget tests can
/// drive the "New topo" flow without touching the real camera/gallery UI.
///
/// [setLocationTileProvider] / [setLocationMapController] /
/// [setLocationLocationService] are the same kind of seam for every
/// `_TopoRow`'s "Set location" action (see `set_location_picker.dart`'s
/// `showSetLocationPicker`), threaded all the way down to
/// `_TopoRow._handleSetLocation` — production leaves all three null, letting
/// the picker build its own resilient tile provider/`MapController` and
/// read the real `locationServiceProvider`, exactly like `CommunityScreen`'s
/// identical `tileProvider`/`mapController` seams. A widget test that opens
/// the picker MUST inject `setLocationTileProvider` (a noop tile provider),
/// or the map would attempt a real network tile fetch under `flutter_test`.
///
/// A [ConsumerStatefulWidget] (rather than a stateless [ConsumerWidget])
/// so it can hold the [_creating] re-entrancy flag: without it, a fast
/// double-tap on "New topo" would fire two concurrent creation flows that
/// both read the same stale topo count and both push a route, stacking two
/// navigations and leaving a duplicate topo behind.
/// What the user is told when creating a topo failed for a reason with no
/// specific, actionable cause to name (UF-5). A genuine [PhotoWriteException]
/// is reported through `photoWriteFailureSnackBar` instead, which DOES have
/// something useful to say ("out of storage space").
///
/// Matches this feature's established house phrasing for a write that could
/// not be applied — `"Couldn't rename — please try again"`,
/// `"Couldn't delete — please try again"`, `"Couldn't move — please try
/// again"` (see `topos_row.dart` / `crud_list_scaffold.dart`) — so the whole
/// library speaks with one voice rather than growing a bespoke variant here.
const String _createFailedMessage =
    "Couldn't create the topo — please try again";

class ToposScreen extends ConsumerStatefulWidget {
  const ToposScreen({
    super.key,
    this.photoSourcePicker = showPhotoSourceSheet,
    this.photoPicker = pickPhotoFrom,
    this.setLocationTileProvider,
    this.setLocationMapController,
    this.setLocationLocationService,
  });

  final Future<ImageSource?> Function(BuildContext) photoSourcePicker;
  final Future<XFile?> Function(ImageSource) photoPicker;

  @visibleForTesting
  final TileProvider? setLocationTileProvider;

  @visibleForTesting
  final MapController? setLocationMapController;

  @visibleForTesting
  final LocationService? setLocationLocationService;

  @override
  ConsumerState<ToposScreen> createState() => _ToposScreenState();
}

class _ToposScreenState extends ConsumerState<ToposScreen> {
  /// Re-entrancy guard for [_handleNewTopo]: true for the whole duration of
  /// an in-flight "New topo" flow (source picker -> photo picker -> decode
  /// -> createTopo -> attachPhotoToWall -> navigate). While true, the
  /// button is disabled and a second tap is a no-op.
  bool _creating = false;

  /// True only for the part of [_handleNewTopo] that the APP is doing — from
  /// `createTopo` through the photo write, the GPS capture and the navigation.
  ///
  /// Not the same thing as [_creating], and the difference is the whole point.
  /// Most of that flow is spent waiting on the USER (the photo-source sheet,
  /// the OS photo picker, the name dialog), and a spinner running on the create
  /// button through all of that would be wrong twice over: it says "the app is
  /// busy" while the app is idle, and it says it from behind whichever modal
  /// the user is currently looking at. The tail is the real wait — a
  /// full-resolution photo write plus a GPS fix, seconds on a big image — and
  /// it used to be completely unannounced.
  bool _writing = false;

  /// Keyword search over the Topos home, mirroring
  /// `community_screen.dart`'s `_CommunityScreenState` search field: the
  /// controller backs the `topos-search-field` [TextField], and [_query] is
  /// its trimmed/lowercased text, updated only when it actually changes so
  /// unrelated rebuilds (e.g. a caret move) don't trigger extra work.
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
    // Seed the reachability verdict this screen renders (see `build`'s
    // `bannerKind`). `reachabilityProvider` is probe-on-demand — nothing
    // schedules it — so a screen that wants an answer has to ask at mount.
    // Deferred by a microtask because `ref.read(...)` on a notifier during
    // `initState` runs before the first frame, and `refresh()` never throws,
    // so this is safe to fire and forget.
    Future.microtask(() => ref.read(reachabilityProvider.notifier).refresh());
  }

  void _onSearchChanged() {
    final query = _searchController.text.trim().toLowerCase();
    if (query != _query) {
      setState(() => _query = query);
    }
  }

  @override
  void dispose() {
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    final asyncTopos = ref.watch(toposProvider);
    final proximityEntries = ref.watch(sortedByProximityToposProvider);
    final filter = ref.watch(toposFilterProvider);
    // L1 interlock (design doc §1a): the connection layer's verdict on
    // whether the local database can actually keep what we write. On web,
    // `WasmDatabase.open` silently degrades to an in-memory backend that
    // "doesn't store anything" — writes succeed, lists populate, and the
    // whole library is gone on the next page load. When that is the verdict,
    // creation is turned OFF and `_StorageWarningBanner` says so, rather than
    // letting the user record a topo into a store that will drop it. See
    // `lib/core/db/storage_durability_provider.dart`.
    final storage = ref.watch(storageDurabilityProvider);

    // Only an *actually loaded* topo list (AsyncData) is a safe source for
    // the "New topo" count; while still loading or errored there is no
    // trustworthy count to derive "Topo N+1" from, so the button must be
    // disabled rather than fall back to an empty list and mint "Topo 1"
    // over an existing topo. `storage.isEphemeral` is the third gate: it is
    // false while the verdict is still unknown (`probing`), so the interlock
    // only ever blocks on a KNOWN-bad backend.
    final loadedTopos = asyncTopos.asData?.value;
    final canCreate =
        loadedTopos != null && !_creating && !storage.isEphemeral;

    // Stage 3 (T2). Before this, EVERY sync/offline signal on this screen
    // lived inside the `proximityEntries.isEmpty` branch below, so the user
    // who had the most to lose — the one who HAS topos — was told nothing at
    // all. Offline at a crag they watch a list quietly fail to refresh and
    // conclude the app ate their work. The banner therefore renders here,
    // above the list, irrespective of how much is in it.
    //
    // `isKnownOffline`, never `!= online`: `Reachability.unknown` is the
    // pre-probe state, and treating it as offline flashes this banner for a
    // frame on every cold start (see `reachability_providers.dart`).
    final reachability = ref.watch(reachabilityProvider);
    final pullError = ref.watch(syncOrchestratorProvider).lastPullError;
    // The full-screen `_SyncErrorEmptyState` below already reports a pull
    // error — larger, and with its own Retry — whenever the library is
    // genuinely empty. Rendering the banner too would print the same
    // sentence twice on one screen, so the banner yields in exactly that
    // case. The OFFLINE banner never yields: no empty state says anything
    // about reachability, and "No topos yet" on its own is precisely what
    // reads as "your topos are gone".
    final emptyStateOwnsTheError =
        loadedTopos != null && proximityEntries.isEmpty && pullError != null;
    final SyncBannerKind? bannerKind = reachability.isKnownOffline
        ? SyncBannerKind.offline
        : (pullError != null && !emptyStateOwnsTheError)
        ? SyncBannerKind.syncFailed
        : null;

    // The account button shows initials once actually signed in with a
    // real (non-empty) email; any other state of the auth stream —
    // signed-out, still loading, or errored (e.g. Supabase never
    // initialized) — degrades to the generic person icon rather than
    // guessing, per `authStateProvider`'s doc comment.
    final authSession = ref.watch(authStateProvider).asData?.value;
    final signedInEmail =
        (authSession != null &&
            authSession.isSignedIn &&
            authSession.email!.isNotEmpty)
        ? authSession.email!
        : null;

    // NavShell's Scaffold now extends every branch's body full-bleed behind
    // its floating glass bottom bar (#51) — this screen's own `SafeArea`
    // below uses `bottom: false` so this REAL measured clearance (the bar's
    // occupied height, maxed with the device safe-area inset — see
    // `nav_shell.dart`'s doc) reaches here unconsumed, exactly like
    // `community_screen.dart`'s `CommunityMapScreen` already did pre-#51.
    // Folded into `_ToposList`'s scroll padding and the compact add button's
    // own bottom padding below so neither the last topo row nor the button
    // ends up hidden behind the bar.
    final bottomChromeInset = MediaQuery.of(context).padding.bottom;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Topos',
          style: Theme.of(context).textTheme.displaySmall,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        centerTitle: false,
        actions: [
          IconButton(
            key: const Key('topos-organize'),
            icon: MasiIcon('folder', color: colors.accent),
            tooltip: 'Organize',
            onPressed: () => context.push('/areas'),
          ),
          IconButton(
            key: const Key('topos-account-button'),
            icon: signedInEmail != null
                ? CircleAvatar(
                    key: const Key('topos-account-avatar'),
                    radius: 14,
                    backgroundColor: colors.accent,
                    foregroundColor: colors.onAccent,
                    child: Text(
                      emailInitials(signedInEmail),
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  )
                : MasiIcon('person', color: colors.accent),
            tooltip: 'Account',
            onPressed: () => context.push('/account'),
          ),
        ],
      ),
      // Full-bleed [Stack] (not a single [Column]) so the list fills the
      // ENTIRE body height and the compact add button floats OVER it as a
      // second layer, rather than sitting in its own row below an
      // [Expanded] list that stopped short of the bottom (device feedback:
      // "the plus button and the nav bar are still on their separate
      // background — let them float atop of the list"). Layer 1 is the
      // filter bar + full-height list (exactly the old `Column`, minus the
      // button); layer 2 is the button, [Positioned] bottom-right and
      // lifted above the floating glass nav bar by `bottomChromeInset`.
      body: Stack(
        children: [
          SafeArea(
            bottom: false,
            child: Column(
              children: [
                if (storage.isEphemeral)
                  _StorageWarningBanner(durability: storage),
                if (bannerKind != null)
                  SyncBanner(
                    kind: bannerKind,
                    detail: pullError,
                    // Nothing useful to press while genuinely offline; the
                    // honest advice is to wait for signal.
                    onRetry: bannerKind == SyncBannerKind.syncFailed
                        ? () => ref
                              .read(syncOrchestratorProvider.notifier)
                              .pullNow()
                        : null,
                  ),
                _ToposFilterBar(
                  searchController: _searchController,
                  isActive: filter.isActive,
                  onTap: () => _showToposFiltersSheet(context),
                ),
                Expanded(
                  child: MasiAsyncView<List<TopoRef>>(
                    value: asyncTopos,
                    onRetry: () => ref.invalidate(toposProvider),
                    errorMessage: "Couldn't load your topos",
                    // Row-shaped, not a spinner: this list's rows are a fixed
                    // 52 px thumbnail beside two text lines, and a skeleton
                    // that does not match that makes the whole list jump when
                    // the first frame of real data lands. See `_ToposSkeleton`
                    // for where the numbers come from.
                    skeleton: (context) =>
                        _ToposSkeleton(bottomInset: bottomChromeInset + 64),
                    data: (context, topos) {
                      // The proximity-sorted list (own + nearby community,
                      // nearest-first — see `sortedByProximityToposProvider`'s
                      // doc) is what actually renders; `topos` itself is only
                      // still needed here to gate the loading/error/empty
                      // states below on the OWN list specifically (community
                      // entries can never appear without a location fix, so
                      // `proximityEntries` degrades to exactly `topos` whenever
                      // no fix is available — see that provider's doc).
                      if (proximityEntries.isEmpty) {
                        // #72 P1 fix: a genuinely empty topos home can mean
                        // two very different things — a truly fresh
                        // account with nothing yet, or a fresh install
                        // whose own-rows pull actually failed (partially
                        // or fully — see `PullResult`'s doc). Before this,
                        // both looked identical: the same "No topos yet"
                        // prompt, no way to tell a real sync failure apart
                        // from an honestly-empty library, and no retry.
                        // `SyncOrchestratorState.lastPullError` (see its
                        // doc) distinguishes them; only the search/filter-
                        // narrowed empty states below are left untouched
                        // (there IS data in those cases).
                        final syncError = ref
                            .watch(syncOrchestratorProvider)
                            .lastPullError;
                        if (syncError != null) {
                          return _SyncErrorEmptyState(
                            message: syncError,
                            onRetry: () => ref
                                .read(syncOrchestratorProvider.notifier)
                                .pullNow(),
                          );
                        }
                        return _EmptyState(
                          onNewTopo: canCreate ? _handleNewTopo : null,
                        );
                      }
                      // Search narrows first, then the filter facets (mirrors
                      // `community_screen.dart`'s `_FeedView`), so the two stay
                      // independently diagnosable: a query that matches nothing
                      // shows the search-specific empty state even if the
                      // active filter would otherwise also exclude everything.
                      final query = _query;
                      final searchFiltered = query.isEmpty
                          ? proximityEntries
                          : proximityEntries
                                .where((e) => _matchesProximityQuery(e, query))
                                .toList();
                      if (searchFiltered.isEmpty) {
                        return const _SearchEmptyState();
                      }
                      // The grade/visibility/area facet filter only ever applied
                      // to the device's OWN topos (it reasons about
                      // `TopoRef.areaId`/`visibility`, neither of which a
                      // community-shared entry carries in the same shape) — a
                      // nearby community entry always passes it unfiltered.
                      final filtered = searchFiltered
                          .where(
                            (e) =>
                                e.source == ProximityTopoSource.community ||
                                filter.matches(e.ownTopo!),
                          )
                          .toList();
                      if (filtered.isEmpty) {
                        return const _FilteredEmptyState();
                      }
                      return _ToposList(
                        entries: filtered,
                        // The list now runs full-bleed behind the floating
                        // add button (see the `Positioned` button below), so
                        // its bottom padding must clear BOTH the floating nav
                        // bar (`bottomChromeInset`) AND the button itself
                        // (48 height + its own bottom margin) so the last row
                        // can still scroll fully into view instead of ending
                        // up permanently hidden under the button.
                        bottomInset: bottomChromeInset + 64,
                        setLocationTileProvider: widget.setLocationTileProvider,
                        setLocationMapController: widget.setLocationMapController,
                        setLocationLocationService:
                            widget.setLocationLocationService,
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          // The compact circular plus button (#49): a SECOND Stack layer,
          // floating bottom-right OVER the full-bleed list above (not a
          // sibling Column row below it, which is what left it "on its own
          // separate background" per device feedback) -- `Positioned` lifts
          // it above the floating glass nav bar by `bottomChromeInset`,
          // exactly like its old bottom padding did. Still an
          // [ElevatedButton] (not a `FloatingActionButton`) so its
          // `key`/`onPressed` and the disabled/enabled `ButtonStyle` colors
          // below -- asserted pixel-for-pixel by `topos_screen_test.dart`'s
          // contrast tests -- are untouched; only its PARENT changed (from a
          // Column-child Padding/Align to a Stack-child Positioned).
          Positioned(
            right: MasiSpacing.lg,
            bottom: MasiSpacing.lg + bottomChromeInset,
            child: SizedBox(
              width: 48,
              height: 48,
              child: ElevatedButton(
                key: const Key('topos-new-topo'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: colors.accent,
                  foregroundColor: colors.onAccent,
                  // Without these, Material's disabled-state fallback
                  // (onSurface @ ~38% alpha) takes over while the topos
                  // list is loading or a create is in-flight, reading as
                  // dark low-contrast text on the still-purple background.
                  // Keep the accent fill so the button doesn't visibly
                  // change shape/color, but dim the label just enough to
                  // read as "disabled" while staying legible.
                  disabledBackgroundColor: colors.accent,
                  disabledForegroundColor: colors.onAccent.withValues(
                    alpha: 0.7,
                  ),
                  padding: EdgeInsets.zero,
                  shape: const CircleBorder(),
                ),
                onPressed: canCreate ? _handleNewTopo : null,
                // No explicit `color`: `ButtonStyleButton` merges an
                // `IconTheme` from this button's own `foregroundColor`/
                // `disabledForegroundColor` above (falling back to
                // `foregroundColor` since no separate `iconColor` is
                // set), so the glyph inherits the SAME onAccent-enabled
                // / dimmed-disabled contrast the old `Text('New topo')`
                // had -- just on an icon instead of a label. Wrapped in
                // `Semantics` since the icon alone carries no accessible
                // label for VoiceOver/TalkBack -- the button's own `key`
                // is not a substitute.
                // While the create's TAIL is running (see `_writing`) the glyph
                // becomes the cue, in place: the button is a fixed 48×48, and
                // the inline indicator is 20 px, so nothing can reflow. Timing
                // is the shared gate's, so a create that somehow finishes
                // instantly still paints no spinner.
                child: MasiLoadingGate(
                  isLoading: _writing,
                  builder: (context, showSpinner) => showSpinner
                      ? MasiLoadingIndicator.inline(
                          // The gate already applied the delay and owns the
                          // hold — nesting a second one would stack to ~360 ms.
                          revealDelay: Duration.zero,
                          minVisible: Duration.zero,
                          color: colors.onAccent,
                          semanticLabel: 'Creating your topo',
                        )
                      : Semantics(
                          label: 'New topo',
                          button: true,
                          child: const MasiIcon('add', size: 22),
                        ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Photo-first "New topo" creation flow: pick a source, pick a photo,
  /// decode its pixel size, prompt for the new topo's name (see
  /// [_NewTopoNameDialog], prefilled with the `'Topo ${count + 1}'`
  /// default), create a wall with that name, attach the photo to it, then
  /// navigate straight into the canvas.
  ///
  /// The name prompt sits strictly BEFORE `createTopo` is ever called
  /// (#25): dismissing/cancelling it aborts the ENTIRE flow (early return,
  /// no wall/photo row created, no orphan state) rather than falling back
  /// to the default silently, so a user who backs out of naming their topo
  /// gets exactly nothing created, not a surprise "Topo N" they didn't ask
  /// for.
  ///
  /// Deliberately defensive (try/catch, no rethrow) to match the rest of the
  /// app's style for picker/decode failures (see `topo_canvas_screen.dart`'s
  /// `_attachPhotoAndLoad`): a cancelled/failed picker or a corrupt image must
  /// never crash the Topos home. Defensive, but no longer SILENT — see below.
  ///
  /// COMPENSATE AND NOTIFY, uniformly (UF-5). `createTopo` commits a wall
  /// before the photo is attached, so ANY attach failure strands an empty,
  /// photo-less topo on this screen. Every attach failure therefore runs the
  /// same two steps — soft-delete the orphan wall, then tell the user —
  /// rather than special-casing the quota one and letting the rest fall
  /// through to a `debugPrint` nobody can see. Only the WORDING varies:
  /// a [PhotoWriteException] (the L3 fix — the photo's bytes could not be
  /// stored, quota exhaustion above all) has a specific actionable cause and
  /// gets `photoWriteFailureSnackBar`; everything else gets
  /// [_createFailedMessage], because inventing a diagnosis for an FK violation
  /// or a locked database would be a guess dressed up as a fact. Either way
  /// the user is left with exactly nothing created, matching #25's abort
  /// semantics.
  ///
  /// The undo is BEST-EFFORT and cannot gate the message: it is a database
  /// write that can fail for the very reason the photo write just did (an
  /// exhausted origin quota), so it runs in its own try/catch and the SnackBar
  /// is shown unconditionally. In the rare case where the undo also fails the
  /// user keeps a visible, hand-deletable empty topo — strictly better than
  /// the silent orphan they used to get.
  ///
  /// Failures BEFORE any wall exists (the picker throwing, a corrupt image)
  /// have nothing to compensate but are still reported, via the outer
  /// catch-all. That catch-all is gated on a `topoCommitted` flag so it stays
  /// quiet once the topo genuinely exists and only the tail (the GPS SnackBar,
  /// `context.push`) failed — claiming "couldn't create the topo" about a topo
  /// sitting right there on screen would be worse than saying nothing.
  ///
  /// Guarded twice against a stale/absent topo count and against
  /// re-entrancy: it bails out (no-op) unless `toposProvider` currently
  /// holds real `AsyncData` (never invoked while loading/erroring — the
  /// button is disabled then too, but this guard makes it safe even if
  /// invoked programmatically), and it bails out if a previous invocation
  /// is still in flight (`_creating`), so a fast double-tap can only ever
  /// create one topo.
  Future<void> _handleNewTopo() async {
    if (_creating) return;
    if (ref.read(toposProvider).asData == null) return;

    // Belt-and-braces, same shape as the two guards above: both buttons that
    // reach this method are already disabled while the storage backend is
    // known non-durable, so this only fires for a programmatic call — but a
    // creation flow that writes into a store drift told us discards
    // everything must be impossible, not merely hard to trigger.
    if (ref.read(storageDurabilityProvider).isEphemeral) return;

    setState(() => _creating = true);
    // Tracks whether the wall+photo pair actually landed, so the catch-all
    // below can tell "nothing was created" apart from "everything was created
    // and then the tail (GPS SnackBar, navigation) tripped".
    var topoCommitted = false;
    try {
      final source = await widget.photoSourcePicker(context);
      if (source == null) return;

      final xfile = await widget.photoPicker(source);
      if (xfile == null) return;

      final bytes = await xfile.readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      int width;
      int height;
      try {
        final frame = await codec.getNextFrame();
        width = frame.image.width;
        height = frame.image.height;
        frame.image.dispose();
      } finally {
        codec.dispose();
      }

      // Re-read at creation time (rather than trusting a value captured
      // before the picker/decode awaits) so the count reflects the latest
      // loaded state; still guarded against a (unlikely) transition back
      // to loading/error mid-flow.
      final currentTopos = ref.read(toposProvider).asData?.value ?? const [];
      final count = currentTopos.length;
      final defaultName = 'Topo ${count + 1}';

      // Prompt for the name BEFORE anything is created (#25). Nothing
      // above this point has touched the database -- only the picked
      // `xfile` and the decoded width/height, both still just local
      // values -- so a `null` (cancelled/dismissed) result can return
      // early with zero cleanup required: no wall, no photo, no orphan
      // state.
      if (!mounted) return;
      final enteredName = await showDialog<String>(
        context: context,
        builder: (dialogContext) =>
            _NewTopoNameDialog(initialValue: defaultName),
      );
      if (enteredName == null) return;
      final trimmedName = enteredName.trim();
      // The dialog itself already disables its submit action while empty/
      // whitespace-only (see `_NewTopoNameDialog`'s `_canSubmit`), so this
      // is belt-and-suspenders: a non-null result should already be
      // non-empty, but fall back to the default rather than ever creating
      // a blank-named topo if that invariant is somehow violated.
      final name = trimmedName.isEmpty ? defaultName : trimmedName;

      // Everything the user had to supply is in hand; from here on the wait is
      // ours, so say so (see [_writing]).
      if (mounted) setState(() => _writing = true);

      final repo = ref.read(libraryCrudRepositoryProvider);
      final wallId = await repo.createTopo(name);
      // `createTopo` has ALREADY committed a wall by this point, so ANY attach
      // failure strands an empty, photo-less topo on this screen forever
      // unless it is compensated. Letting a throw reach the outer catch-all
      // below (which only debugPrints) produces the exact bug this whole fix
      // exists to prevent — so the compensate-and-notify below is deliberately
      // UNIFORM across exception types, not special-cased to the quota one.
      //
      // Only the WORDING varies. A PhotoWriteException (the L3 fix: the
      // browser refused the bytes, quota exhaustion above all, since originals
      // stay FULL resolution per decision D-5) has a specific, actionable
      // cause worth naming. Everything else — an FK violation, a locked or
      // closed database, a LibraryWriteLostException out of the insert's own
      // guard, a drift serialization error — has no actionable detail to offer
      // and gets this file's house phrasing instead. Claiming "out of storage
      // space" for those would be a guess presented as a diagnosis.
      try {
        await repo.attachPhotoToWall(wallId, xfile, width, height);
      } catch (attachError, attachStack) {
        debugPrint(
          'Failed to attach the new topo\'s photo: $attachError\n$attachStack',
        );
        // The cleanup is BEST-EFFORT and deliberately contained in its own
        // try/catch: `softDeleteWall` is itself a database write, and the two
        // ways it fails here are both realistic AND correlated with the
        // failure that got us here. (1) Quota — the browser origin whose quota
        // is exhausted is the SAME origin this delete writes into, so the very
        // condition that made `importPhoto` throw is the condition most likely
        // to make its compensation throw. (2) `_guardedCascadeAllowed` raises
        // LibraryWriteLostException(ownerIdentityUnknown) if auth drops to an
        // unknown-uid state between `createTopo` and the failed attach.
        //
        // Unguarded, either one escaped into the outer catch-all below, so the
        // user got the WORST of both outcomes at once: the empty photo-less
        // topo survived on the home screen AND they were told nothing
        // whatsoever. The message must never be contingent on its own cleanup
        // succeeding, so the SnackBar below is unconditional and this await
        // can no longer abort it.
        try {
          await repo.softDeleteWall(wallId);
        } catch (cleanupError, cleanupStack) {
          // Nothing further to attempt: retrying the same write into the same
          // exhausted/ownerless store would fail the same way. The leftover is
          // an empty, correctly-named topo the user can see and delete by hand
          // — visible and recoverable, unlike the silence this replaces.
          debugPrint(
            'Failed to undo the empty topo after a failed photo attach: '
            '$cleanupError\n$cleanupStack',
          );
        }
        if (!mounted) return;
        // Abort the flow here: no GPS capture, no navigation into a canvas
        // with nothing to show. The `finally` below still releases
        // `_creating`, so the user can retry immediately.
        ScaffoldMessenger.of(context).showSnackBar(
          attachError is PhotoWriteException
              ? photoWriteFailureSnackBar(attachError)
              : const SnackBar(content: Text(_createFailedMessage)),
        );
        return;
      }
      // Past this point the topo is fully committed (wall + photo row), so the
      // outer catch-all must NOT offer to have "not created" it — see there.
      topoCommitted = true;

      // Best-effort GPS capture: delegates to the SAME
      // `captureWallGpsFromPhoto` the topo canvas's own add/replace-photo
      // flow calls (`topo_canvas_screen.dart`'s `_attachPhotoAndLoad`), so
      // both flows share one implementation and present an identical
      // outcome to the user. This re-reads `xfile.path` from disk rather
      // than reusing the `bytes` already decoded above for the dimension
      // check -- a second, tiny file read that trades a negligible bit of
      // I/O for a single source of truth on the EXIF-wins/device-fallback/
      // never-clobber contract (see that function's doc). It never throws
      // -- including a `setWallCoordinates` DB-write failure, which it
      // isolates in its OWN try/catch -- so a coords failure can never be
      // caught by the outer try/catch below and abort the topo+photo
      // creation that already committed above, nor block the navigation
      // that follows.
      final gpsResult = await captureWallGpsFromPhoto(
        repo,
        wallId,
        xfile,
        locationService: ref.read(locationServiceProvider),
      );

      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(gpsCaptureResultSnackBar(gpsResult));
      context.push('/walls/$wallId');
    } catch (e, st) {
      debugPrint('Failed to create new topo: $e\n$st');
      // UF-5: this used to be debugPrint-ONLY, so every failure that is not
      // the attach step — the picker throwing, a corrupt image the codec
      // refuses, `createTopo` itself failing — left the user staring at an
      // unchanged Topos home with no idea their tap had failed. Silence is not
      // an acceptable outcome for a user-initiated action.
      //
      // Gated on `topoCommitted` because this catch-all also covers the tail
      // AFTER a fully successful creation (the GPS SnackBar, `context.push`):
      // saying "couldn't create the topo" there would be a plain lie about a
      // topo that exists and is visible. Those keep the debugPrint alone.
      if (mounted && !topoCommitted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text(_createFailedMessage)));
      }
    } finally {
      if (mounted) {
        setState(() {
          _creating = false;
          _writing = false;
        });
      }
    }
  }
}
