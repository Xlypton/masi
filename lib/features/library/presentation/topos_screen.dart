import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart' show MapController, TileProvider;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:latlong2/latlong.dart';

import '../../../app/theme.dart';
import '../../../core/grades/grade_system.dart';
import '../../../core/location/location_service.dart';
import '../../../shared/filtering/grade_range_picker.dart';
import '../../../shared/filtering/style_filter_chips.dart';
import '../../account/application/auth_providers.dart';
import '../../account/application/email_initials.dart';
import '../../community/data/community_repository.dart' show SharedTopo;
import '../../topo/presentation/photo_image.dart';
import '../../topo/presentation/photo_source_sheet.dart';
import '../../topo/presentation/topo_canvas_screen.dart'
    show captureWallGpsFromPhoto, gpsCaptureResultSnackBar;
import '../application/library_providers.dart';
import '../application/proximity_topos_provider.dart';
import '../data/library_crud_repository.dart';
import '../../../shared/presentation/masi_icon.dart';
import 'move_target_picker.dart';
import 'set_location_picker.dart';

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
    // Only an *actually loaded* topo list (AsyncData) is a safe source for
    // the "New topo" count; while still loading or errored there is no
    // trustworthy count to derive "Topo N+1" from, so the button must be
    // disabled rather than fall back to an empty list and mint "Topo 1"
    // over an existing topo.
    final loadedTopos = asyncTopos.asData?.value;
    final canCreate = loadedTopos != null && !_creating;

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
            key: const Key('home-community-button'),
            icon: MasiIcon('compass', color: colors.accent),
            tooltip: 'Community',
            onPressed: () => context.push('/community'),
          ),
          IconButton(
            key: const Key('home-logbook-button'),
            icon: MasiIcon('logbook', color: colors.accent),
            tooltip: 'Logbook',
            onPressed: () => context.push('/logbook'),
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

/// Whether [topo] matches keyword [query] (already trimmed/lowercased): its
/// name, top grade label, or area name contains it. Mirrors
/// `community_screen.dart`'s `_FeedView`'s name-only search, but widened to
/// also match [TopoRef.topGradeLabel] / [TopoRef.areaName] so a "keyword"
/// like a grade ("7a") or an area ("Squamish") also narrows the list, not
/// just the topo's own name.
bool _matchesQuery(TopoRef topo, String query) {
  if (topo.name.toLowerCase().contains(query)) return true;
  final grade = topo.topGradeLabel;
  if (grade != null && grade.toLowerCase().contains(query)) return true;
  final area = topo.areaName;
  if (area != null && area.toLowerCase().contains(query)) return true;
  return false;
}

/// Like [_matchesQuery], but over a [ProximityTopoEntry] — an own entry
/// delegates straight to [_matchesQuery] against its [ProximityTopoEntry.
/// ownTopo]; a community entry (no [TopoRef.areaId]/`topGradeLabel` in the
/// same shape) matches on its name and, when present, its
/// [SharedTopo.topGradeLabel].
bool _matchesProximityQuery(ProximityTopoEntry entry, String query) {
  final own = entry.ownTopo;
  if (own != null) return _matchesQuery(own, query);
  if (entry.name.toLowerCase().contains(query)) return true;
  final grade = entry.communityTopo?.topGradeLabel;
  if (grade != null && grade.toLowerCase().contains(query)) return true;
  return false;
}

/// Search field + filter trigger shown in the body, above the topos list
/// (see [ToposScreen.build]): a [Row] holding the `topos-search-field`
/// [TextField] (mirrors `community_screen.dart`'s `_FeedView` search field:
/// same hint text and prefix icon) alongside the `topos-filter-button` icon
/// button -- same key, [Icons.tune] icon, `topos-filter-active-indicator`
/// badge, and [_showToposFiltersSheet] behavior as before. The filter
/// trigger was relocated out of the AppBar's trailing actions: with a fifth
/// action there (this button alongside Organize/Community/Logbook/Account),
/// the "Topos" title itself was truncating to "Top…" at normal text scale.
class _ToposFilterBar extends StatelessWidget {
  const _ToposFilterBar({
    required this.searchController,
    required this.isActive,
    required this.onTap,
  });

  final TextEditingController searchController;
  final bool isActive;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        MasiSpacing.lg,
        MasiSpacing.xs,
        MasiSpacing.sm,
        0,
      ),
      child: Row(
        children: [
          Expanded(
            // `ValueListenableBuilder` (not a bare `TextField`) so the
            // clear ('x') suffix can appear/disappear as the controller's
            // text goes non-empty/empty, without this whole bar needing to
            // become stateful -- `TextEditingController` is itself a
            // `ValueListenable<TextEditingValue>`.
            child: ValueListenableBuilder<TextEditingValue>(
              valueListenable: searchController,
              builder: (context, value, _) {
                return TextField(
                  key: const Key('topos-search-field'),
                  controller: searchController,
                  decoration: InputDecoration(
                    hintText: 'Search topos',
                    prefixIcon: Padding(
                      padding: const EdgeInsets.only(left: 12, right: 8),
                      child: MasiIcon('search', size: 20, color: colors.ink3),
                    ),
                    prefixIconConstraints: const BoxConstraints(
                      minWidth: 0,
                      minHeight: 0,
                    ),
                    suffixIcon: value.text.isEmpty
                        ? null
                        : IconButton(
                            key: const Key('topos-search-clear'),
                            icon: MasiIcon(
                              'close',
                              size: 16,
                              color: colors.ink3,
                            ),
                            tooltip: 'Clear search',
                            onPressed: searchController.clear,
                          ),
                    suffixIconConstraints: const BoxConstraints(
                      minWidth: 0,
                      minHeight: 0,
                    ),
                    filled: true,
                    fillColor: colors.surface2,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: BorderSide(color: colors.separator),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: BorderSide(color: colors.separator),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: BorderSide(color: colors.accent, width: 1.5),
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(width: MasiSpacing.sm),
          if (isActive)
            Padding(
              padding: const EdgeInsets.only(right: MasiSpacing.xs),
              child: Text(
                'Filters active',
                style: textTheme.labelMedium?.copyWith(color: colors.accent),
              ),
            ),
          IconButton(
            key: const Key('topos-filter-button'),
            icon: MasiIcon(
              isActive ? 'filter_active' : 'filter',
              color: colors.accent,
            ),
            tooltip: 'Filters',
            onPressed: onTap,
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({this.onNewTopo});

  /// Wired straight to `_ToposScreenState._handleNewTopo`, gated on the
  /// SAME `canCreate` guard the floating `topos-new-topo` button uses (see
  /// `ToposScreen.build`) -- `null` while the topos list hasn't finished
  /// loading yet or a create is already in flight, which this button
  /// renders as visually disabled rather than omitted, mirroring the
  /// floating button's own disabled treatment.
  final VoidCallback? onNewTopo;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    return Center(
      key: const Key('topos-empty-state'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'No topos yet',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(color: colors.ink2),
          ),
          const SizedBox(height: MasiSpacing.md),
          ElevatedButton(
            key: const Key('topos-empty-new-topo'),
            style: ElevatedButton.styleFrom(
              backgroundColor: colors.accent,
              foregroundColor: colors.onAccent,
            ),
            onPressed: onNewTopo,
            child: const Text('New topo'),
          ),
        ],
      ),
    );
  }
}

/// Shown instead of [_EmptyState] when there ARE topos but every one of them
/// was excluded by the active [ToposFilter] (see [applyToposFilter]) --
/// distinct from "no topos yet" so the user isn't misled into thinking their
/// library is empty when it's just the filter hiding everything.
class _FilteredEmptyState extends StatelessWidget {
  const _FilteredEmptyState();

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    return Center(
      key: const Key('topos-filtered-empty-state'),
      child: Text(
        'No topos match your filters',
        style: Theme.of(
          context,
        ).textTheme.titleMedium?.copyWith(color: colors.ink2),
      ),
    );
  }
}

/// Shown instead of [_EmptyState] / [_FilteredEmptyState] when there ARE
/// topos but the `topos-search-field` keyword query (see
/// [ToposScreen.build]'s [_matchesQuery] narrowing, checked BEFORE the
/// [ToposFilter] facets) excludes every one of them -- distinct from both
/// other empty states, mirroring `community_screen.dart`'s `_FeedView`
/// three-way split, so a user who typed a query that matches nothing sees a
/// message about their search specifically, not a generic/misleading one.
class _SearchEmptyState extends StatelessWidget {
  const _SearchEmptyState();

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    return Center(
      key: const Key('topos-search-empty-state'),
      child: Text(
        'No topos match your search',
        style: Theme.of(
          context,
        ).textTheme.titleMedium?.copyWith(color: colors.ink2),
      ),
    );
  }
}

/// Opens the Topos-home Filters sheet (see [_ToposFiltersSheet]) from the
/// `topos-filter-button` app-bar action.
Future<void> _showToposFiltersSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) => const _ToposFiltersSheet(),
  );
}

/// The Topos-home Filters sheet: a [GradeRangePicker], a visibility
/// segmented control (All/Shared/Private), and an area multi-select (every
/// real area from [areasProvider] plus an explicit "Unfiled" option mapping
/// to [ToposFilter.unfiledAreaId]), with a Clear action that resets
/// [toposFilterProvider] back to its default (inactive) value.
///
/// Purely a thin view over [toposFilterProvider]: every interaction writes
/// straight through to the shared [ToposFilterController], so the
/// underlying Topos list (watched by [ToposScreen], which stays mounted
/// underneath this modal sheet) updates live while the sheet is still open.
class _ToposFiltersSheet extends ConsumerWidget {
  const _ToposFiltersSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = MasiColors.of(context);
    final textTheme = Theme.of(context).textTheme;
    final filter = ref.watch(toposFilterProvider);
    final controller = ref.read(toposFilterProvider.notifier);
    final areas = ref.watch(areasProvider).asData?.value ?? const <AreaRef>[];

    return SafeArea(
      child: Container(
        padding: const EdgeInsets.all(MasiSpacing.lg),
        decoration: BoxDecoration(
          color: colors.surface,
          // `MasiRadii.large` (not `.card`) per DESIGN.md's radius token
          // table: a full-screen modal sheet's top corners use the larger
          // radius, `.card` is reserved for in-list row surfaces.
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(MasiRadii.large),
          ),
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      'Filters',
                      style: textTheme.titleLarge,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  TextButton(
                    key: const Key('topos-filter-clear'),
                    onPressed: controller.clear,
                    child: const Text('Clear'),
                  ),
                ],
              ),
              const SizedBox(height: MasiSpacing.md),
              GradeRangePicker(
                value: filter.grade,
                onChanged: controller.setGrade,
              ),
              const SizedBox(height: MasiSpacing.md),
              Text(
                'Visibility',
                style: textTheme.titleSmall?.copyWith(color: colors.ink2),
              ),
              const SizedBox(height: MasiSpacing.xs),
              _VisibilitySegmented(
                value: filter.visibility,
                onChanged: controller.setVisibility,
              ),
              const SizedBox(height: MasiSpacing.md),
              Text(
                'Area',
                style: textTheme.titleSmall?.copyWith(color: colors.ink2),
              ),
              const SizedBox(height: MasiSpacing.xs),
              Wrap(
                spacing: MasiSpacing.sm,
                runSpacing: MasiSpacing.sm,
                children: [
                  FilterChoiceChip(
                    key: const Key('topos-filter-area-unfiled'),
                    label: 'Unfiled',
                    selected: filter.areaIds.contains(
                      ToposFilter.unfiledAreaId,
                    ),
                    onPressed: () =>
                        controller.toggleArea(ToposFilter.unfiledAreaId),
                  ),
                  for (final area in areas)
                    FilterChoiceChip(
                      key: Key('topos-filter-area-${area.id}'),
                      label: area.name,
                      selected: filter.areaIds.contains(area.id),
                      onPressed: () => controller.toggleArea(area.id),
                    ),
                ],
              ),
              const SizedBox(height: MasiSpacing.lg),
            ],
          ),
        ),
      ),
    );
  }
}

/// A [ToposVisibilityFilter] segmented toggle (All/Shared/Private) for
/// [_ToposFiltersSheet], visually mirroring [GradeRangePicker]'s
/// `CupertinoSlidingSegmentedControl` (that widget's own segment-label
/// helper is private to its file, so this replicates rather than imports
/// it). Purely controlled: [value] is the current selection, [onChanged]
/// fires with the new value on every tap.
class _VisibilitySegmented extends StatelessWidget {
  const _VisibilitySegmented({required this.value, required this.onChanged});

  final ToposVisibilityFilter value;
  final ValueChanged<ToposVisibilityFilter> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    return CupertinoSlidingSegmentedControl<ToposVisibilityFilter>(
      key: const Key('topos-filter-visibility'),
      groupValue: value,
      backgroundColor: colors.surface2,
      thumbColor: colors.accent,
      children: {
        ToposVisibilityFilter.all: _FilterSegmentLabel(
          key: const Key('topos-filter-visibility-all'),
          label: 'All',
          selected: value == ToposVisibilityFilter.all,
          colors: colors,
        ),
        ToposVisibilityFilter.shared: _FilterSegmentLabel(
          key: const Key('topos-filter-visibility-shared'),
          label: 'Shared',
          selected: value == ToposVisibilityFilter.shared,
          colors: colors,
        ),
        ToposVisibilityFilter.private: _FilterSegmentLabel(
          key: const Key('topos-filter-visibility-private'),
          label: 'Private',
          selected: value == ToposVisibilityFilter.private,
          colors: colors,
        ),
      },
      onValueChanged: (next) {
        if (next != null) onChanged(next);
      },
    );
  }
}

/// A label used inside [_VisibilitySegmented]'s `CupertinoSlidingSegmentedControl`
/// `children` map, carrying the caller-supplied [Key] so tests can target
/// each segment directly.
class _FilterSegmentLabel extends StatelessWidget {
  const _FilterSegmentLabel({
    super.key,
    required this.label,
    required this.selected,
    required this.colors,
  });

  final String label;
  final bool selected;
  final MasiColors colors;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        vertical: MasiSpacing.xs,
        horizontal: MasiSpacing.sm,
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: selected ? colors.onAccent : colors.ink2,
        ),
      ),
    );
  }
}

/// The proximity-sorted Topos-home list (see `sortedByProximityToposProvider`
/// / [ToposScreen.build]): each [ProximityTopoEntry] renders as either an
/// own [_TopoRow] ([ProximityTopoEntry.source] `own`) or a nearby
/// [_CommunityProximityRow] (`community`), nearest-first — [entries] is
/// already filtered/sorted by the caller.
class _ToposList extends StatelessWidget {
  const _ToposList({
    required this.entries,
    this.bottomInset = 0,
    this.setLocationTileProvider,
    this.setLocationMapController,
    this.setLocationLocationService,
  });

  final List<ProximityTopoEntry> entries;

  /// Extra bottom clearance (the floating bottom bar's occupied height —
  /// see `ToposScreen.build`'s `bottomChromeInset`) folded into this list's
  /// own bottom padding so its last row scrolls clear of the bar instead of
  /// ending up hidden behind it (#51). Defaults to 0 so any other caller
  /// (none currently) still gets the old, un-padded behavior.
  final double bottomInset;
  final TileProvider? setLocationTileProvider;
  final MapController? setLocationMapController;
  final LocationService? setLocationLocationService;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: EdgeInsets.fromLTRB(
        MasiSpacing.lg,
        MasiSpacing.md,
        MasiSpacing.lg,
        MasiSpacing.md + bottomInset,
      ),
      itemCount: entries.length,
      separatorBuilder: (context, index) =>
          const SizedBox(height: MasiSpacing.sm),
      itemBuilder: (context, index) {
        final entry = entries[index];
        if (entry.source == ProximityTopoSource.own) {
          return _TopoRow(
            topo: entry.ownTopo!,
            distanceKm: entry.distanceKm,
            setLocationTileProvider: setLocationTileProvider,
            setLocationMapController: setLocationMapController,
            setLocationLocationService: setLocationLocationService,
          );
        }
        return _CommunityProximityRow(entry: entry);
      },
    );
  }
}

class _TopoRow extends ConsumerWidget {
  const _TopoRow({
    required this.topo,
    this.distanceKm,
    this.setLocationTileProvider,
    this.setLocationMapController,
    this.setLocationLocationService,
  });

  final TopoRef topo;

  /// Great-circle distance (km) from the device's current position, when
  /// available — see [ProximityTopoEntry.distanceKm]'s doc. `null` (no
  /// location fix, or this topo has no coordinates) renders nothing extra;
  /// existing callers that never pass this (every pre-proximity test) are
  /// unaffected either way.
  final double? distanceKm;
  final TileProvider? setLocationTileProvider;
  final MapController? setLocationMapController;
  final LocationService? setLocationLocationService;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = MasiColors.of(context);
    final textTheme = Theme.of(context).textTheme;
    final routeCount = topo.routeCount;
    final bands = gradeBandsFor(topo.routeGradeKeys);

    return Material(
      key: Key('topo-item-${topo.wallId}'),
      color: colors.surface,
      borderRadius: BorderRadius.circular(MasiRadii.card),
      child: InkWell(
        borderRadius: BorderRadius.circular(MasiRadii.card),
        onTap: () => context.push('/walls/${topo.wallId}'),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: MasiSpacing.md,
            vertical: MasiSpacing.sm,
          ),
          child: Row(
            children: [
              _Thumbnail(path: topo.thumbnailPath),
              const SizedBox(width: MasiSpacing.md),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      topo.name,
                      style: textTheme.titleMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Wrap(
                      spacing: MasiSpacing.xs,
                      runSpacing: 2,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        if (bands.isNotEmpty)
                          _GradeBandDots(wallId: topo.wallId, bands: bands),
                        Text(
                          '$routeCount route${routeCount == 1 ? '' : 's'}',
                          style: textTheme.titleSmall?.copyWith(
                            color: colors.ink2,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        _VisibilityBadge(
                          wallId: topo.wallId,
                          isShared: topo.visibility == 'shared',
                        ),
                        if (distanceKm != null)
                          Text(
                            '${distanceKm!.toStringAsFixed(1)} km',
                            key: Key('topo-distance-${topo.wallId}'),
                            style: textTheme.titleSmall?.copyWith(
                              color: colors.ink2,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              IconButton(
                key: Key('topo-menu-${topo.wallId}'),
                icon: MasiIcon('more_horiz', color: colors.ink3),
                tooltip: 'More',
                onPressed: () => _showMenu(context, ref, topo),
              ),
              MasiIcon('chevron_right', color: colors.ink3),
            ],
          ),
        ),
      ),
    );
  }

  /// The `topo-menu-<wallId>` row action sheet -- an iOS-style
  /// [CupertinoActionSheet] (mirrors `crud_list_scaffold.dart`'s delete
  /// confirm sheet idiom) rather than a Material [PopupMenuButton], per
  /// DESIGN.md's iOS-idiom bar. Every action keeps its PRE-EXISTING key
  /// (`topo-rename-<wallId>`, `topo-move-<wallId>`, etc.) so this is a pure
  /// presentation swap -- no test-facing key/behavior changed other than
  /// the surface itself.
  ///
  /// "Show on map" stays visually muted (and its `onPressed` a no-op)
  /// rather than omitted when [topo] has no coordinates, exactly like the
  /// old `PopupMenuItem`'s `enabled: false` did -- [CupertinoActionSheetAction]
  /// has no built-in disabled state (`onPressed` is non-nullable), so the
  /// muted style + no-op callback recreate it. "Set location"/"Edit
  /// location" stays always-enabled either way (see its own doc below).
  Future<void> _showMenu(
    BuildContext context,
    WidgetRef ref,
    TopoRef topo,
  ) async {
    final colors = MasiColors.of(context);
    final textTheme = Theme.of(context).textTheme;
    final isShared = topo.visibility == 'shared';
    final hasCoords = topo.latitude != null && topo.longitude != null;

    final action = await showCupertinoModalPopup<String>(
      context: context,
      // See `crud_list_scaffold.dart`'s identical `_handleDelete` comment:
      // the default barrier is too weak to fully obscure this screen's own
      // bottom-pinned accent-filled add button bleeding through the gap
      // between the action group and the Cancel button.
      barrierColor: Colors.black45,
      builder: (sheetContext) => CupertinoActionSheet(
        actions: [
          CupertinoActionSheetAction(
            key: Key('topo-rename-${topo.wallId}'),
            onPressed: () => Navigator.of(sheetContext).pop('rename'),
            child: const Text('Rename'),
          ),
          CupertinoActionSheetAction(
            key: Key('topo-move-${topo.wallId}'),
            onPressed: () => Navigator.of(sheetContext).pop('move'),
            child: const Text('Move to…'),
          ),
          CupertinoActionSheetAction(
            key: Key('topo-publish-${topo.wallId}'),
            onPressed: () => Navigator.of(
              sheetContext,
            ).pop(isShared ? 'unpublish' : 'publish'),
            child: Text(isShared ? 'Unpublish' : 'Publish'),
          ),
          // Enabled only when the wall actually has coordinates (from
          // EXIF/device GPS capture at photo-attach time — see
          // `setWallCoordinates`); a located topo pushes straight into
          // `/community`'s Map tab, focused on this wall (see
          // `_handleShowOnMap`). Rather than omitting the action entirely
          // when unlocated, it stays visible but muted with a "No location
          // set" hint and a no-op `onPressed`, so a user isn't left
          // wondering why the action is missing.
          CupertinoActionSheetAction(
            key: Key('topo-show-on-map-${topo.wallId}'),
            onPressed: hasCoords
                ? () => Navigator.of(sheetContext).pop('show-on-map')
                : () {},
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Show on map',
                  style: hasCoords
                      ? null
                      : TextStyle(color: colors.ink3),
                ),
                if (!hasCoords)
                  Text(
                    'No location set',
                    style: textTheme.labelSmall?.copyWith(
                      color: colors.ink3,
                    ),
                  ),
              ],
            ),
          ),
          // Always enabled -- unlike "Show on map" above, a topo can be
          // GIVEN a location whether or not it has one already, so this
          // action is never muted; the label just flips to "Edit location"
          // once coordinates exist, so the menu reads as "add" vs "change"
          // appropriately.
          CupertinoActionSheetAction(
            key: Key('topo-set-location-${topo.wallId}'),
            onPressed: () => Navigator.of(sheetContext).pop('set-location'),
            child: Text(hasCoords ? 'Edit location' : 'Set location'),
          ),
          CupertinoActionSheetAction(
            key: Key('topo-delete-${topo.wallId}'),
            isDestructiveAction: true,
            onPressed: () => Navigator.of(sheetContext).pop('delete'),
            child: Text('Delete', style: TextStyle(color: colors.gradeHard)),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(sheetContext).pop(),
          child: const Text('Cancel'),
        ),
      ),
    );

    if (!context.mounted || action == null) return;
    switch (action) {
      case 'rename':
        await _handleRename(context, ref, topo);
      case 'move':
        await _handleMove(context, ref, topo);
      case 'publish':
        await _handlePublish(context, ref, topo);
      case 'unpublish':
        await _handleUnpublish(ref, topo);
      case 'show-on-map':
        _handleShowOnMap(context, topo);
      case 'set-location':
        await _handleSetLocation(context, ref, topo);
      case 'delete':
        await _handleDelete(context, ref, topo);
    }
  }

  Future<void> _handleRename(
    BuildContext context,
    WidgetRef ref,
    TopoRef topo,
  ) async {
    final newName = await showDialog<String>(
      context: context,
      builder: (dialogContext) => _TopoNameDialog(initialValue: topo.name),
    );
    if (newName == null) return;
    await ref
        .read(libraryCrudRepositoryProvider)
        .renameWall(topo.wallId, newName);
  }

  /// "Move to…" flow: resolves [topo]'s destination-sector candidates
  /// (this device's own, non-default sectors across every area — see
  /// [LibraryCrudRepository.listOwnSectors]'s doc for why FOREIGN sectors
  /// are never offered — minus [topo]'s CURRENT sector, resolved via
  /// [LibraryCrudRepository.wallSectorId] since [TopoRef] itself carries no
  /// `sectorId`), labels each candidate `"AreaName › SectorName"` (area
  /// names come from the unfiltered [LibraryCrudRepository.listAreas] purely
  /// for display — a sector's own ownership, not its area's, gates whether
  /// it's offered), shows [showMoveTargetPicker], and on a selection calls
  /// [LibraryCrudRepository.moveWall] followed by a confirmation [SnackBar].
  /// A no-op if the sheet is dismissed without a selection.
  Future<void> _handleMove(
    BuildContext context,
    WidgetRef ref,
    TopoRef topo,
  ) async {
    final repo = ref.read(libraryCrudRepositoryProvider);
    final myUid = ref.read(authStateProvider).asData?.value.uid;
    final currentSectorId = await repo.wallSectorId(topo.wallId);
    final areas = await repo.listAreas();
    final areaNames = {for (final area in areas) area.id: area.name};
    final ownSectors = await repo.listOwnSectors(myUid);
    final candidates = ownSectors
        .where((sector) => sector.id != currentSectorId)
        .toList();
    if (!context.mounted) return;

    final targetSectorId = await showMoveTargetPicker(
      context,
      title: 'Move "${topo.name}" to…',
      keyPrefix: 'move-target-sector',
      emptyMessage: 'No other sectors available',
      options: [
        for (final sector in candidates)
          MoveTargetOption(
            id: sector.id,
            label: '${areaNames[sector.areaId] ?? 'Unknown'} › ${sector.name}',
          ),
      ],
    );
    if (targetSectorId == null) return;

    try {
      await repo.moveWall(topo.wallId, targetSectorId);
    } catch (e, st) {
      debugPrint('Failed to move topo: $e\n$st');
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Couldn't move — please try again")),
      );
      return;
    }
    if (!context.mounted) return;

    final targetSector = candidates.firstWhere((s) => s.id == targetSectorId);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Moved to ${targetSector.name}')),
    );
  }

  /// Publishes [topo] to Community after an explicit confirm (this is the
  /// one-way-feeling, "everyone can see this" action, so — mirroring
  /// [_handleDelete]'s confirm-then-act shape — it asks first rather than
  /// firing straight off the menu tap). [_handleUnpublish] (the reverse
  /// direction) needs no such confirmation.
  ///
  /// An iOS-style [CupertinoActionSheet] (mirrors `crud_list_scaffold.dart`'s
  /// delete-confirm idiom and this row's own [_handleDelete] below) rather
  /// than a Material [AlertDialog], per DESIGN.md's iOS-idiom bar.
  Future<void> _handlePublish(
    BuildContext context,
    WidgetRef ref,
    TopoRef topo,
  ) async {
    final confirmed = await showCupertinoModalPopup<bool>(
      context: context,
      barrierColor: Colors.black45,
      builder: (sheetContext) => CupertinoActionSheet(
        title: const Text('Publish to Community?'),
        message: Text(
          '"${topo.name}" will become visible to everyone in Community. '
          'You can unpublish it again at any time.',
        ),
        actions: [
          CupertinoActionSheetAction(
            key: Key('topo-publish-confirm-${topo.wallId}'),
            onPressed: () => Navigator.of(sheetContext).pop(true),
            child: const Text('Publish'),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(sheetContext).pop(false),
          child: const Text('Cancel'),
        ),
      ),
    );
    if (confirmed == true) {
      await ref.read(libraryCrudRepositoryProvider).publishTopo(topo.wallId);
    }
  }

  Future<void> _handleUnpublish(WidgetRef ref, TopoRef topo) {
    return ref.read(libraryCrudRepositoryProvider).unpublishTopo(topo.wallId);
  }

  /// Pushes straight into `/community`'s Map tab, centered/zoomed on
  /// [topo] (see `CommunityScreen`'s `initialTab`/`focusWallId` and
  /// `_MapView`'s `focusWallId` doc). Only ever reachable when the menu
  /// item is enabled (i.e. [topo] has coordinates) — see this row's
  /// `itemBuilder`.
  void _handleShowOnMap(BuildContext context, TopoRef topo) {
    context.push('/community?tab=map&focus=${topo.wallId}');
  }

  /// "Set location"/"Edit location" flow: opens [showSetLocationPicker]
  /// centered on [topo]'s existing coordinates when it has any (`null`
  /// otherwise -- the picker itself decides what to do with an absent
  /// `initial`), and on a non-null pick writes it via
  /// [LibraryCrudRepository.setWallCoordinates]. Mirrors [_handleMove]'s
  /// shape: await a value-returning picker, bail on a null (cancelled)
  /// result, then write through the real repo inside a try/catch that
  /// surfaces a confirmation/error [SnackBar], with `mounted` guards across
  /// every await.
  Future<void> _handleSetLocation(
    BuildContext context,
    WidgetRef ref,
    TopoRef topo,
  ) async {
    final initial = (topo.latitude != null && topo.longitude != null)
        ? LatLng(topo.latitude!, topo.longitude!)
        : null;

    final picked = await showSetLocationPicker(
      context,
      initial: initial,
      tileProvider: setLocationTileProvider,
      controller: setLocationMapController,
      locationService: setLocationLocationService,
    );
    if (picked == null) return;
    if (!context.mounted) return;

    try {
      await ref
          .read(libraryCrudRepositoryProvider)
          .setWallCoordinates(topo.wallId, picked.latitude, picked.longitude);
    } catch (e, st) {
      debugPrint('Failed to set topo location: $e\n$st');
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Couldn't save location — please try again")),
      );
      return;
    }
    if (!context.mounted) return;

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Location saved')));
  }

  /// An iOS-style [CupertinoActionSheet] confirm (mirrors
  /// `crud_list_scaffold.dart`'s identical delete-confirm sheet: a single
  /// destructive action rendered in `MasiColors.gradeHard`, per DESIGN.md's
  /// Buttons spec, plus a Cancel button) rather than a Material
  /// [AlertDialog].
  Future<void> _handleDelete(
    BuildContext context,
    WidgetRef ref,
    TopoRef topo,
  ) async {
    final colors = MasiColors.of(context);
    final confirmed = await showCupertinoModalPopup<bool>(
      context: context,
      barrierColor: Colors.black45,
      builder: (sheetContext) => CupertinoActionSheet(
        title: const Text('Delete?'),
        message: Text('Delete "${topo.name}"? This cannot be undone.'),
        actions: [
          CupertinoActionSheetAction(
            key: Key('topo-delete-confirm-${topo.wallId}'),
            isDestructiveAction: true,
            onPressed: () => Navigator.of(sheetContext).pop(true),
            child: Text('Delete', style: TextStyle(color: colors.gradeHard)),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(sheetContext).pop(false),
          child: const Text('Cancel'),
        ),
      ),
    );
    if (confirmed == true) {
      await ref.read(libraryCrudRepositoryProvider).softDeleteWall(topo.wallId);
    }
  }
}

/// A nearby COMMUNITY topo's row in the proximity-sorted Topos-home list
/// (see `_ToposList`/`sortedByProximityToposProvider`) -- visually mirrors
/// [_TopoRow] (same 52x52 thumbnail) but marked with a `_CommunitySharedBadge`
/// instead of [_VisibilityBadge] (a community entry is never "mine" to
/// publish/unpublish/rename/delete -- there is no menu at all), and taps
/// straight into the read-only `/community/topo/<wallId>` detail rather than
/// this device's own topo canvas.
class _CommunityProximityRow extends StatelessWidget {
  const _CommunityProximityRow({required this.entry});

  final ProximityTopoEntry entry;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    final textTheme = Theme.of(context).textTheme;
    final SharedTopo topo = entry.communityTopo!;
    final wallId = entry.wallId;

    return Material(
      key: Key('topo-item-community-$wallId'),
      color: colors.surface,
      borderRadius: BorderRadius.circular(MasiRadii.card),
      child: InkWell(
        borderRadius: BorderRadius.circular(MasiRadii.card),
        onTap: () => context.push('/community/topo/$wallId'),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: MasiSpacing.md,
            vertical: MasiSpacing.sm,
          ),
          child: Row(
            children: [
              _Thumbnail(path: topo.thumbnailPath),
              const SizedBox(width: MasiSpacing.md),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      topo.name,
                      style: textTheme.titleMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Wrap(
                      spacing: MasiSpacing.xs,
                      runSpacing: 2,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        _CommunitySharedBadge(wallId: wallId),
                        if (entry.distanceKm != null)
                          Text(
                            '${entry.distanceKm!.toStringAsFixed(1)} km',
                            key: Key('topo-distance-$wallId'),
                            style: textTheme.titleSmall?.copyWith(
                              color: colors.ink2,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              MasiIcon('chevron_right', color: colors.ink3),
            ],
          ),
        ),
      ),
    );
  }
}

/// Compact badge marking a Topos-home row as a nearby COMMUNITY topo (not
/// one of this device's own) -- the Topos-home-side counterpart of
/// `community_screen.dart`'s `_OwnBadge` (which marks the reverse case, an
/// own topo shown inside the Community feed).
class _CommunitySharedBadge extends StatelessWidget {
  const _CommunitySharedBadge({required this.wallId});

  final String wallId;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    final textTheme = Theme.of(context).textTheme;

    return Semantics(
      label: 'Shared by the community',
      child: Container(
        key: Key('topo-shared-badge-$wallId'),
        padding: const EdgeInsets.symmetric(
          horizontal: MasiSpacing.xs,
          vertical: 2,
        ),
        decoration: BoxDecoration(
          color: colors.surface2,
          borderRadius: BorderRadius.circular(MasiRadii.control),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            MasiIcon('compass', size: 12, color: colors.ink3),
            const SizedBox(width: 2),
            Flexible(
              child: Text(
                'Shared',
                style: textTheme.labelSmall?.copyWith(
                  color: colors.ink3,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Row of small colored dots shown in a topo row's subtitle (see DESIGN.md
/// "Topos home"), one per distinct [GradeBand] present across the topo's
/// routes ([bands], already deduplicated and ordered easiest-to-hardest by
/// [gradeBandsFor]) -- replaces the old single hardest-grade pill so a topo
/// with, say, both a 5a and a 7a route visibly reads as spanning two bands
/// rather than showing only its hardest. Placed before the "N routes" text;
/// omitted entirely by the caller when a topo has no graded routes.
class _GradeBandDots extends StatelessWidget {
  const _GradeBandDots({required this.wallId, required this.bands});

  final String wallId;
  final List<GradeBand> bands;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    return Semantics(
      label: 'Grade bands present: ${bands.map((b) => b.name).join(', ')}',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < bands.length; i++)
            Padding(
              padding: EdgeInsets.only(
                right: i == bands.length - 1 ? 0 : MasiSpacing.xs,
              ),
              child: Container(
                key: Key('topo-grade-dot-$wallId-${bands[i].name}'),
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: _colorForGradeBand(colors, bands[i]),
                  shape: BoxShape.circle,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Compact badge marking a topo row's publish state — "Published" (accent
/// fill) for a topo shared to Community, or a muted "Private" otherwise —
/// so the Topos home reads as a clear division between community-visible
/// and owner-only topos. Placed inside the row's grade/route-count [Wrap]
/// (rather than the trailing icon cluster) so it wraps safely alongside
/// them at large text scales instead of widening the [Row] and risking the
/// overflow this row was JUST fixed for; text stays a single short word
/// with a matching icon, never flexible.
class _VisibilityBadge extends StatelessWidget {
  const _VisibilityBadge({required this.wallId, required this.isShared});

  final String wallId;
  final bool isShared;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    final textTheme = Theme.of(context).textTheme;
    final label = isShared ? 'Published' : 'Private';
    // `ink2` (not `ink3`) for the Private variant: `ink3` read as
    // low-contrast against `surface2` (DESIGN.md review) -- `ink2` is the
    // same tone every other secondary-metadata piece in this row (route
    // count, distance) already uses.
    final foreground = isShared ? colors.onAccent : colors.ink2;
    final background = isShared ? colors.accent : colors.surface2;

    return Semantics(
      label: isShared ? 'Published to Community' : 'Private, not shared',
      child: Container(
        key: Key('topo-visibility-badge-$wallId'),
        padding: const EdgeInsets.symmetric(
          horizontal: MasiSpacing.xs,
          vertical: 2,
        ),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(MasiRadii.control),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            MasiIcon(
              isShared ? 'globe' : 'lock',
              size: 12,
              color: foreground,
            ),
            const SizedBox(width: 2),
            // `Flexible` (not a bare `Text`) is required here: a `Row`
            // gives non-flexible children an UNBOUNDED main-axis
            // constraint, so without it `maxLines`/`overflow: ellipsis`
            // never engage and the badge overflows its `Wrap` slot at
            // large text scales (regression -- see the "AppBar Organize
            // action + _TopoRow" test this badge sits alongside).
            Flexible(
              child: Text(
                label,
                style: textTheme.labelSmall?.copyWith(
                  color: foreground,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Maps a [GradeBand] to its display color using the [MasiColors] grade
/// tokens (never a hard-coded hex — see DESIGN.md's grade-band table, which
/// these tokens mirror).
Color _colorForGradeBand(MasiColors colors, GradeBand band) {
  switch (band) {
    case GradeBand.beginner:
      return colors.gradeBeginner;
    case GradeBand.intermediate:
      return colors.gradeIntermediate;
    case GradeBand.advanced:
      return colors.gradeAdvanced;
    case GradeBand.hard:
      return colors.gradeHard;
    case GradeBand.elite:
      return colors.gradeElite;
  }
}

/// 52x52 rounded thumbnail: the topo's most recent `kind:'original'` photo
/// when it has one and its bytes are readable, else an amethyst gradient
/// placeholder. [PhotoImage]'s `placeholder` covers every way that can fail
/// (no path at all, a decode error, or — on web — bytes not found/not yet
/// loaded from IndexedDB) so no path ever surfaces a broken-image icon.
class _Thumbnail extends StatelessWidget {
  const _Thumbnail({required this.path});

  final String? path;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    final radius = BorderRadius.circular(10);
    final thumbnailPath = path;

    final child = thumbnailPath == null
        ? _GradientFallback(colors: colors)
        : PhotoImage(
            thumbnailPath,
            width: 52,
            height: 52,
            fit: BoxFit.cover,
            placeholder: () => _GradientFallback(colors: colors),
          );

    return ClipRRect(
      borderRadius: radius,
      child: SizedBox(width: 52, height: 52, child: child),
    );
  }
}

class _GradientFallback extends StatelessWidget {
  const _GradientFallback({required this.colors});

  final MasiColors colors;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [colors.amethyst300, colors.amethyst500],
        ),
      ),
    );
  }
}

/// Prompts for the new topo's name -- shown by `_handleNewTopo` after a
/// photo is picked/decoded and strictly BEFORE `createTopo` is ever called
/// (#25), prefilled with the `'Topo ${count + 1}'` default so accepting
/// without typing anything reproduces the old auto-numbered behavior.
///
/// Mirrors `crud_list_scaffold.dart`'s `_NameDialog` / this file's own
/// [_TopoNameDialog] (controller, disabled submit while empty/whitespace,
/// `onSubmitted`) but is a DISTINCT class with its OWN keys
/// (`topo-name-field` / `topo-name-submit`, per plan #25) rather than
/// reusing `crud-name-field` / `crud-name-submit`: unlike the rename
/// dialog (which only ever replaces this screen's own body), this one is
/// the tail end of the "New topo" flow, which pushes a route once it
/// resolves -- giving it distinct keys avoids any ambiguity for a test (or
/// future caller) that might end up with both a name prompt and a rename
/// dialog reachable in the same widget tree.
///
/// Cancelling/dismissing (Cancel button, barrier tap, back gesture) pops
/// `null` -- the default `showDialog` behavior for an unhandled dismissal
/// -- which `_handleNewTopo` treats as "abort the entire creation flow":
/// no wall, no photo, no orphan state of any kind.
class _NewTopoNameDialog extends StatefulWidget {
  const _NewTopoNameDialog({required this.initialValue});

  final String initialValue;

  @override
  State<_NewTopoNameDialog> createState() => _NewTopoNameDialogState();
}

class _NewTopoNameDialogState extends State<_NewTopoNameDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialValue,
  );
  late bool _canSubmit = _controller.text.trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
  }

  void _onChanged() {
    final canSubmit = _controller.text.trim().isNotEmpty;
    if (canSubmit != _canSubmit) {
      setState(() => _canSubmit = canSubmit);
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _controller.text.trim();
    if (name.isEmpty) return;
    FocusManager.instance.primaryFocus?.unfocus();
    Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return AlertDialog(
      title: Text('Name this topo', style: textTheme.titleLarge),
      content: TextField(
        key: const Key('topo-name-field'),
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(hintText: 'Name'),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () {
            FocusManager.instance.primaryFocus?.unfocus();
            Navigator.of(context).pop();
          },
          child: const Text('Cancel'),
        ),
        TextButton(
          key: const Key('topo-name-submit'),
          onPressed: _canSubmit ? _submit : null,
          child: const Text('Create'),
        ),
      ],
    );
  }
}

/// Mirrors `crud_list_scaffold.dart`'s `_NameDialog` (controller, disabled
/// submit while empty/whitespace, `onSubmitted`) for the rename flow. Not
/// reused directly: that class is library-private to `crud_list_scaffold.dart`.
/// Reuses its `crud-name-field` / `crud-name-submit` keys, which is safe
/// because only one such dialog is ever on screen at a time.
class _TopoNameDialog extends StatefulWidget {
  const _TopoNameDialog({required this.initialValue});

  final String initialValue;

  @override
  State<_TopoNameDialog> createState() => _TopoNameDialogState();
}

class _TopoNameDialogState extends State<_TopoNameDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialValue,
  );
  late bool _canSubmit = _controller.text.trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
  }

  void _onChanged() {
    final canSubmit = _controller.text.trim().isNotEmpty;
    if (canSubmit != _canSubmit) {
      setState(() => _canSubmit = canSubmit);
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _controller.text.trim();
    if (name.isEmpty) return;
    FocusManager.instance.primaryFocus?.unfocus();
    Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Rename topo'),
      content: TextField(
        key: const Key('crud-name-field'),
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(hintText: 'Name'),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () {
            FocusManager.instance.primaryFocus?.unfocus();
            Navigator.of(context).pop();
          },
          child: const Text('Cancel'),
        ),
        TextButton(
          key: const Key('crud-name-submit'),
          onPressed: _canSubmit ? _submit : null,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
