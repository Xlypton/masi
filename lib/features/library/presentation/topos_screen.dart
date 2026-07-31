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
import '../../backup/application/sync_orchestrator.dart';
import '../../community/data/community_repository.dart' show SharedTopo;
import '../../topo/presentation/photo_image.dart';
import '../../topo/presentation/photo_source_sheet.dart';
import '../../topo/presentation/topo_canvas_screen.dart'
    show captureWallGpsFromPhoto, gpsCaptureResultSnackBar;
import '../application/library_providers.dart';
import '../application/proximity_topos_provider.dart';
import '../data/library_crud_repository.dart';
import '../../../shared/presentation/masi_icon.dart';
import '../../../shared/presentation/masi_shimmer.dart';
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
                _ToposFilterBar(
                  searchController: _searchController,
                  isActive: filter.isActive,
                  onTap: () => _showToposFiltersSheet(context),
                ),
                Expanded(
                  child: asyncTopos.when(
                    data: (topos) {
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
                    loading: () =>
                        const Center(child: CircularProgressIndicator()),
                    error: (error, stackTrace) => Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('Something went wrong: $error'),
                          const SizedBox(height: 8),
                          ElevatedButton(
                            key: const Key('topos-retry'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: colors.accent,
                              foregroundColor: colors.onAccent,
                            ),
                            onPressed: () => ref.invalidate(toposProvider),
                            child: const Text('Retry'),
                          ),
                        ],
                      ),
                    ),
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
                child: Semantics(
                  label: 'New topo',
                  button: true,
                  child: const MasiIcon('add', size: 22),
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
  /// Deliberately defensive (try/catch + `debugPrint`, no rethrow) to match
  /// the rest of the app's style for picker/decode failures (see
  /// `topo_canvas_screen.dart`'s `_attachPhotoAndLoad`): a cancelled/failed
  /// picker or a corrupt image must never crash the Topos home.
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

      final repo = ref.read(libraryCrudRepositoryProvider);
      final wallId = await repo.createTopo(name);
      await repo.attachPhotoToWall(wallId, xfile, width, height);

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
    } finally {
      if (mounted) {
        setState(() => _creating = false);
      }
    }
  }
}
