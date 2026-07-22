import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart' show MapController, TileProvider;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:latlong2/latlong.dart';

import 'package:masi/app/theme.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/core/platform/ar_support.dart';
import 'package:masi/core/location/location_service.dart';
import 'package:masi/features/library/application/library_providers.dart';
import 'package:masi/features/library/data/library_crud_repository.dart';
import 'package:masi/features/library/presentation/set_location_picker.dart';
import 'package:masi/features/logbook/presentation/log_ascent_sheet.dart';
import 'package:masi/features/topo/application/draw_controller.dart';
import 'package:masi/features/topo/application/rock_highlight_controller.dart';
import 'package:masi/features/topo/data/image_dimensions.dart';
import 'package:masi/features/topo/data/photo_repository.dart';
import 'package:masi/features/topo/domain/topo_route.dart';
import 'package:masi/features/topo/presentation/canvas_chrome.dart';
import 'package:masi/features/topo/presentation/photo_strip.dart';
import 'package:masi/features/topo/presentation/photo_source_sheet.dart';
import 'package:masi/features/topo/presentation/route_legend.dart';
import 'package:masi/features/topo/presentation/route_metadata_sheet.dart';
import 'package:masi/features/topo/presentation/symbol_palette_bar.dart';
import 'package:masi/features/topo/presentation/topo_canvas.dart';
import 'package:masi/features/topo/presentation/topo_canvas_gps.dart';
import 'package:masi/features/topo/presentation/topo_canvas_photo_ops.dart';
import 'package:masi/shared/presentation/masi_icon.dart';

// Split out of this god-file (pure refactor, zero behavior change): GPS
// capture helpers moved to `topo_canvas_gps.dart`, and the selected-image
// provider + photo-attach helpers moved to `topo_canvas_photo_ops.dart`.
// Re-exported here so every existing importer of this file (e.g.
// `topos_screen.dart`'s `show captureWallGpsFromPhoto,
// gpsCaptureResultSnackBar`, and this feature's own tests) keeps resolving
// with no edit required on their end.
export 'topo_canvas_gps.dart';
export 'topo_canvas_photo_ops.dart';

// Theme-follow fix: the canvas backdrop used to be a hardcoded near-black
// (`_kCanvasBackdrop = Color(0xFF121316)`) regardless of the app's
// light/dark theme. The Scaffold below now uses `colors.ground` — the same
// theme-derived token the empty-state placeholder ([_buildEmptyState]) has
// always used — so the canvas follows the theme like every other screen.

class TopoCanvasScreen extends ConsumerStatefulWidget {
  const TopoCanvasScreen({
    super.key,
    required this.wallId,
    this.readOnly = false,
    this.embedded = false,
    @visibleForTesting this.debugInitialImageSize,
    @visibleForTesting this.setLocationTileProvider,
    @visibleForTesting this.setLocationMapController,
    @visibleForTesting this.setLocationLocationService,
  });

  /// The wall this canvas is bound to (from the `/walls/:wallId` route).
  /// Routes/photos loaded and attached by this screen are always scoped to
  /// this wall — see [loadWallOriginalPhoto] and [_attachPhotoAndLoad].
  final String wallId;

  /// When `true`, this screen renders strictly as a viewer: the photo,
  /// routes, and floating [RouteLegend] show exactly as they would
  /// otherwise, but every editing affordance is hidden AND its handler
  /// short-circuits (belt-and-suspenders — see e.g. [_pickImage],
  /// [_openMetadataSheet], [_handleCommitRoute]): the mode toggle, the draw
  /// toolbar cluster (undo/redo/clear/commit), the symbol palette, the
  /// capture/replace-photo FAB, and the route-metadata-edit glyph.
  /// [DrawMode] can never become
  /// [DrawMode.draw] in this mode (there is no surviving control that
  /// flips it — see [_topTrailingActions]) — pan/zoom and tap-to-select
  /// (view mode's own, non-mutating gestures) stay fully enabled.
  ///
  /// Backs `CommunityTopoDetailScreen`, which embeds this screen (readOnly)
  /// as its own top section for viewing someone else's shared topo.
  /// Defaults to `false`, which preserves every pre-existing behavior of
  /// this screen exactly (no gate added below ever fires for an existing
  /// call site) — see this class's regression-guard tests.
  final bool readOnly;

  /// When `true`, this screen additionally suppresses its own floating
  /// chrome: the top [GlassChrome] pill (wall-name title + the
  /// `topo-back-button` back chevron, plus the symbol palette/photo strip
  /// that would otherwise share that band) and the floating
  /// [RouteLegend] overlay (both its expanded card and its collapsed chip)
  /// are not painted at all. The photo itself and its route overlays
  /// ([TopoCanvas]/`TopoPainter`) are UNAFFECTED — they render exactly as
  /// they would with `embedded: false`.
  ///
  /// This exists for `CommunityTopoDetailScreen`'s collapsing-header
  /// preview, which embeds a gesture-inert (`IgnorePointer`-wrapped) copy of
  /// this screen purely to show the photo/routes: that embed used to still
  /// PAINT this screen's own back chevron (`topo-back-button`) and route
  /// legend even though neither was reachable (`IgnorePointer` swallows all
  /// pointer events for that subtree) — a ghost back button that looks
  /// identical to a real one, but tapping the header opens the full canvas
  /// FORWARD rather than going back, which read as a misleading affordance.
  /// `embedded: true` removes both purely-decorative pieces so only the
  /// photo/routes preview remains; the header's own real back button
  /// (`community-detail-back-button`) is unaffected — it lives outside this
  /// widget entirely.
  ///
  /// Independent of [readOnly]: the full-screen canvas
  /// `CommunityTopoDetailScreen._openFullCanvas` pushes is still `readOnly:
  /// true` but leaves `embedded` at its default `false`, so it keeps
  /// showing its normal top pill + legend chrome — only the collapsing
  /// header's embedded preview goes chromeless.
  ///
  /// Defaults to `false`, which preserves every pre-existing call site's
  /// behavior exactly (no gate added below ever fires unless a caller opts
  /// in) — see this class's regression-guard tests.
  final bool embedded;

  /// TEST-ONLY seam: when non-null, [_TopoCanvasScreenState.build] uses this
  /// as the resolved natural image size for whatever photo path ends up
  /// selected, instead of deriving it from the selected photo's persisted
  /// [PhotoRef.width]/[PhotoRef.height] (see [build]'s own doc for why a
  /// real codec decode is never driven here — it hangs under fake-async in a
  /// widget test) — see the "Reaching the topo canvas in tests" note in the
  /// project CLAUDE.md.
  ///
  /// Always null in production (the default), so this changes no production
  /// behavior: [build] only reads it, never sets it, and every other
  /// production path (the stored-size lookup, reframing) is untouched.
  @visibleForTesting
  final Size? debugInitialImageSize;

  /// Test-injectable seams for [showSetLocationPicker], invoked by
  /// [_TopoCanvasScreenState._handleEditLocation] (the canvas's own
  /// "Edit location"/"Set location" button — see `topo-edit-location-button`
  /// in [_TopoCanvasScreenState._topTrailingActions]). Mirror
  /// `topos_screen.dart`'s identically-named `ToposScreen` fields exactly —
  /// same rationale: production (every real route to this screen) leaves
  /// all three `null`, letting the picker build its own real tile
  /// provider/`MapController` and read the real `locationServiceProvider`
  /// internally; a widget test can inject fakes (a no-network tile
  /// provider, a directly-inspectable `MapController`, a canned
  /// [LocationService]) instead.
  @visibleForTesting
  final TileProvider? setLocationTileProvider;

  @visibleForTesting
  final MapController? setLocationMapController;

  @visibleForTesting
  final LocationService? setLocationLocationService;

  @override
  ConsumerState<TopoCanvasScreen> createState() => _TopoCanvasScreenState();
}

class _TopoCanvasScreenState extends ConsumerState<TopoCanvasScreen> {
  final TransformationController _transformationController =
      TransformationController();

  /// A stable identity for [TopoCanvas] across this screen's whole lifetime,
  /// handed down through [TopoCanvasBody] (see [_buildCanvasArea]).
  ///
  /// Historical note (full-bleed canvas rework): [TopoCanvasBody.build] used
  /// to branch between a [Column] (not zoomed) and a [Stack] (zoomed) at the
  /// same logical position — different [Widget] runtime types at that
  /// slot — which needed this [GlobalKey] so Flutter could match the old
  /// [TopoCanvas] `Element` to the new one across that structural change
  /// rather than tearing down and remounting a brand new
  /// `TopoCanvas`/`_TopoCanvasState` (silently discarding the user's own
  /// zoom/pan) every time the zoomed-in state flipped. [RouteLegend] is now
  /// PERMANENTLY a floating overlay (see [TopoCanvasBody.build]) — there is
  /// no more Column<->Stack toggle, so [TopoCanvas] never restructures at
  /// all — but this key is kept regardless: it costs nothing, and it's a
  /// cheap guard against a future edit reintroducing a structural toggle
  /// above [TopoCanvas] and silently losing this identity-preservation
  /// property again. Created ONCE here (a field of this long-lived `State`,
  /// not of [TopoCanvasBody] — which is itself a brand new object every
  /// rebuild, so a key stored there would be equally short-lived and defeat
  /// the whole point).
  final GlobalKey _canvasKey = GlobalKey();

  /// The natural size of the currently selected image, derived directly
  /// from its persisted [PhotoRef.width]/[PhotoRef.height] (see [build] —
  /// no codec decode is ever run to learn this). Null while the matching
  /// [PhotoRef] hasn't shown up in [wallOriginalsProvider] yet (e.g. a
  /// freshly-picked photo whose `attachPhotoToWall` write is still in
  /// flight), during which [_buildCanvasArea] shows a brief loading spinner.
  Size? _imageSize;

  /// The image path [_imageSize] was last successfully derived for, so a
  /// rebuild that doesn't change the selected photo (and already found its
  /// stored size) doesn't needlessly re-scan [wallOriginalsProvider]'s list.
  /// Deliberately left NOT-equal-to the current path (see [build]) whenever
  /// the matching [PhotoRef] isn't resolvable yet, so the next rebuild
  /// (which the live [wallOriginalsProvider] watch triggers once the row
  /// lands) retries instead of getting stuck with a stale null forever.
  String? _resolvedForPath;

  /// The wallId [_loadInitialPhotoForWall] has already run (or is running)
  /// for, so a rebuild never re-triggers the initial load for the same wall.
  /// [TopoCanvasScreen.wallId] is effectively fixed for the lifetime of a
  /// given route/widget instance (a new wallId means a new route, hence a
  /// new widget), so this is set once in [initState] and never changes.
  String? _loadedWallId;

  @override
  void initState() {
    super.initState();
    // Deferred via Future.microtask (Riverpod's own documented fix for this
    // exact situation — see the "Tried to modify a provider while the
    // widget tree was building" error it raises otherwise): loadWallOriginalPhoto
    // now calls DrawController.beginPhotoSwitch synchronously, as its very
    // first step (see that function's unconditional-reset doc), and
    // Notifier.state= synchronously notifies listeners — which Riverpod
    // disallows while ANY widget in the tree (not just this one) is still
    // building, initState included. A microtask runs only after the current
    // synchronous call stack — which, for a widget mounting, covers the
    // ENTIRE build phase for the whole tree — unwinds, so by the time this
    // fires the tree is guaranteed done building and the reset is safe.
    //
    // This means this widget's own FIRST build can still observe the
    // previous wall's leftover `selectedImageProvider`/`drawControllerProvider`
    // state for that one frame (the reset lands a microtask later, on the
    // rebuild it triggers) — but that's an imperceptible, one-microtask-turn
    // window, not "however long the DB query in loadOriginal takes" (the
    // PREVIOUS window, when the only reset was `beforeLoadForWall`, which
    // never ran at all for a photo-less wall). No user input is possible in
    // that window, so it does not reopen the wrong-wall-commit bug this fix
    // closes.
    Future.microtask(() {
      // Bug fix ("editor remains open" / "if I open the topo again it's the
      // same"): DrawController.beginPhotoSwitch deliberately leaves
      // DrawState.mode untouched (it's a tool/UI choice, not per-photo
      // state — see that method's doc), and drawControllerProvider itself
      // is a single app-lifetime global, not scoped per wall/screen. So
      // without this, leaving a PREVIOUS wall in draw mode (e.g. the user
      // backed out mid-draw without hitting the mode toggle) meant EVERY
      // topo opened after that — including reopening the very same one —
      // started in draw mode, with the undo/redo/cancel/commit cluster
      // already covering the route legend before the user did anything.
      // Forcing view mode here, once per fresh screen mount (this widget is
      // itself recreated per wallId — see the class doc), makes "opens in
      // view mode" an invariant of opening a topo, not a leftover of
      // whatever the previously-viewed wall was doing.
      _resetToViewMode();
      _loadInitialPhotoForWall(widget.wallId);
    });
  }

  /// Forces [DrawState.mode] back to [DrawMode.view]. See [initState]'s doc
  /// for why this must run once per fresh screen mount (and again from
  /// [didUpdateWidget] on a wallId change) rather than relying on
  /// [DrawController.beginPhotoSwitch], which deliberately preserves mode
  /// across an in-screen photo swap.
  void _resetToViewMode() {
    ref.read(drawControllerProvider(widget.wallId).notifier).setMode(DrawMode.view);
    // Bug fix (stale collapsed legend leaking across walls): legendExpandedProvider
    // is, like drawControllerProvider, a single app-lifetime global rather than
    // scoped per wall/screen. The `ref.listen` in build() only resets it via
    // setForMode when DrawMode actually TRANSITIONS — but if the user manually
    // collapsed the legend (header chevron) while already in view mode, mode
    // never changes on a fresh mount (it's already DrawMode.view), so that
    // listener never fires and the collapsed state would otherwise leak into
    // every subsequently opened wall. Unconditionally re-asserting the
    // view-mode default here, once per fresh mount, closes that the same way
    // setMode(DrawMode.view) above closes it for draw mode.
    ref.read(legendExpandedProvider(widget.wallId).notifier).setForMode(DrawMode.view);
  }

  /// Defensive re-entry point for [widget.wallId] changing on an EXISTING
  /// [_TopoCanvasScreenState] (rather than the normal case: a new wallId
  /// getting its own fresh widget/state via `context.push`'s unique keys —
  /// see [TopoCanvasScreen]'s class doc). Not currently reachable through
  /// this app's navigation, but if that ever changes (e.g. a switch to
  /// `context.go` re-using this route), skipping this would leave
  /// [_loadedWallId] pointing at the OLD wall forever, so
  /// [_loadInitialPhotoForWall] would silently no-op for the new one and the
  /// screen would keep showing the previous wall's photo/routes — exactly
  /// the cross-wall leak [loadWallOriginalPhoto]'s unconditional reset
  /// otherwise closes. Resetting [_loadedWallId] here lets that guard fire
  /// again for the new wallId.
  @override
  void didUpdateWidget(TopoCanvasScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.wallId != oldWidget.wallId) {
      _loadedWallId = null;
      // Deferred the same way as initState's call — see its doc for why a
      // direct, synchronous call here would hit Riverpod's "modify a
      // provider while the widget tree was building" guard (didUpdateWidget
      // is itself a build-lifecycle callback). Also resets to view mode,
      // same rationale as initState (see _resetToViewMode's doc).
      Future.microtask(() {
        _resetToViewMode();
        _loadInitialPhotoForWall(widget.wallId);
      });
    }
  }

  @override
  void dispose() {
    _transformationController.dispose();
    super.dispose();
  }

  /// Invokes [DrawController.commitRoute] and, if it actually committed a
  /// new route (it no-ops when there are fewer than 2 current points — see
  /// that method's doc), switches back to [DrawMode.view] and opens
  /// [RouteMetadataSheet] for that route so its name/grade/style/description
  /// can be filled in right away.
  ///
  /// The new route is the last entry in [DrawState.routes]: `commitRoute`
  /// always appends, never inserts, so "highest number" and "last in the
  /// list" agree.
  ///
  /// Bug fix ("after finishing the edit and saving it the editor remains
  /// open, overlaying the bottom"): committing used to leave [DrawState.mode]
  /// at [DrawMode.draw], so the undo/redo/cancel/commit cluster (only shown
  /// in draw mode — see [_buildBottomChrome]) stayed on screen, covering
  /// [RouteLegend], even though the user was done editing. The ✓ button is
  /// the natural "I'm finished with this route" action, so committing now
  /// also returns the canvas to view mode.
  Future<void> _handleCommitRoute() async {
    if (widget.readOnly) return;
    final notifier = ref.read(drawControllerProvider(widget.wallId).notifier);
    final countBefore = ref.read(drawControllerProvider(widget.wallId)).routes.length;
    await notifier.commitRoute();
    if (!mounted) return;

    final routes = ref.read(drawControllerProvider(widget.wallId)).routes;
    if (routes.length <= countBefore) return;

    notifier.setMode(DrawMode.view);
    await _openMetadataSheet(routes.last);
  }

  /// Opens [RouteMetadataSheet] as a modal bottom sheet for [route],
  /// pre-filling its fields from [route]'s current metadata.
  Future<void> _openMetadataSheet(TopoRoute route) async {
    if (widget.readOnly) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => RouteMetadataSheet(
        wallId: widget.wallId,
        routeId: route.id,
        initial: route,
      ),
    );
    // #20a keyboard-dismiss fix: RouteMetadataSheet's own Save/Cancel/`_pop`
    // already unfocus before popping themselves (see that file), but a
    // modal bottom sheet can ALSO be dismissed by the user swiping it down
    // or tapping the scrim — both pop the sheet's route directly via the
    // Navigator/framework, bypassing RouteMetadataSheet's `_pop` entirely.
    // Unfocusing here, unconditionally once this `showModalBottomSheet`
    // future resolves (by WHATEVER means the sheet closed), is this
    // screen's own belt-and-suspenders backstop for those paths, so the
    // keyboard is never left stranded no matter how the sheet was
    // dismissed.
    FocusManager.instance.primaryFocus?.unfocus();
  }

  /// Opens [LogAscentSheet] for the route whose [TopoRoute.id] (a
  /// locally-reassigned sequential int — see that field's doc, and
  /// [RouteLegend.onLogAscent]'s doc for why [RouteLegend] itself can only
  /// ever hand back this int) is [routeId].
  ///
  /// [AscentsRepository.logAscent] needs the route's real, persisted DB row
  /// id instead (a stable uuid `TopoRoute.id` is NOT — see
  /// `RouteRepository`'s class doc), so this resolves it via
  /// [RouteRepository.routeDbIdsByNumber], keyed by the route's stable
  /// [TopoRoute.number] — the exact same resolution
  /// `routeEntriesForWallProvider` already does for the community detail
  /// screen's own log-ascent button (see that provider's doc).
  ///
  /// If the route can't be resolved to a persisted row — either it's
  /// already gone from [DrawState.routes] (e.g. a race with a concurrent
  /// delete) or it's a just-committed route whose `commitRoute`
  /// fire-and-forget write hasn't landed yet (or failed, see that method's
  /// doc) — this shows a [SnackBar] rather than silently doing nothing:
  /// without it, the button looked broken with zero feedback.
  Future<void> _openLogAscentSheet(int routeId) async {
    if (widget.readOnly) return;
    final drawState = ref.read(drawControllerProvider(widget.wallId));
    final routes = drawState.routes;
    TopoRoute? route;
    for (final r in routes) {
      if (r.id == routeId) {
        route = r;
        break;
      }
    }
    String? dbId;
    if (route != null) {
      // Photo-scoped (D2 fix): a wall with multiple photos can have several
      // routes numbered the same across DIFFERENT photos (route `number` is
      // only stable per-photo — see RouteRepository's class doc), so this
      // must be narrowed to the CURRENTLY ACTIVE photo or it could resolve
      // to the wrong photo's same-numbered route.
      final dbIds = await ref
          .read(routeRepositoryProvider)
          .routeDbIdsByNumber(widget.wallId, drawState.activePhotoId);
      dbId = dbIds[route.number];
    }
    if (!mounted) return;
    if (dbId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Route is still saving — try again in a moment.'),
        ),
      );
      return;
    }
    // Rebind to a non-nullable local: closures don't retain the null-check
    // promotion of a captured mutable variable like `dbId` above.
    final resolvedDbId = dbId;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => LogAscentSheet(
        routeId: resolvedDbId,
        wallId: widget.wallId,
        keyPrefix: 'topo',
      ),
    );
    // #20a keyboard-dismiss fix (same rationale as this file's own
    // `_openMetadataSheet` and the community screen's
    // `_openLogAscentSheet`): LogAscentSheet's own `_save` already
    // unfocuses before popping itself, but a swipe-down/scrim dismissal
    // bypasses `_save` entirely — this is the belt-and-suspenders backstop
    // for that path.
    if (!context.mounted) return;
    FocusManager.instance.primaryFocus?.unfocus();
  }

  /// "Set location"/"Edit location" flow for the wall this canvas is bound
  /// to ([TopoCanvasScreen.wallId]) — the canvas-screen counterpart to
  /// `topos_screen.dart`'s `_handleSetLocation` (the Topos-home overflow
  /// menu's only previous entry point for this same action). Opens
  /// [showSetLocationPicker] centered on [currentTopo]'s existing
  /// coordinates when it has any (`null` otherwise — the picker itself
  /// decides what to do with an absent `initial`), and on a non-null pick
  /// writes it via [LibraryCrudRepository.setWallCoordinates]. Mirrors
  /// `_handleSetLocation`'s shape exactly: await a value-returning picker,
  /// bail on a null (cancelled) result, then write through the real repo
  /// inside a try/catch that surfaces a confirmation/error [SnackBar], with
  /// `mounted` guards across every await.
  ///
  /// [currentTopo] is [_TopoCanvasScreenState.build]'s own read of
  /// [toposProvider] (the same flat, live list `topos_screen.dart` is built
  /// from — see that provider's doc; there is no single-wall-by-id
  /// provider) filtered down to [TopoCanvasScreen.wallId], so the picker
  /// opens on this wall's CURRENT coordinates rather than always starting
  /// from a neutral view. Since [toposProvider] is a live `StreamProvider`
  /// backed by a Drift `.watch()` query that reads from the `walls` table
  /// (see `LibraryCrudRepository.watchTopos`'s `readsFrom`), a successful
  /// `setWallCoordinates` write below causes that stream to emit a fresh
  /// list on its own — no manual invalidation needed — so the next time
  /// this button is pressed, `currentTopo` (and therefore both the
  /// tooltip's "Set location"/"Edit location" label and the picker's
  /// `initial` center) already reflects the new coordinates.
  Future<void> _handleEditLocation(TopoRef? currentTopo) async {
    if (widget.readOnly) return;
    final initial =
        (currentTopo?.latitude != null && currentTopo?.longitude != null)
        ? LatLng(currentTopo!.latitude!, currentTopo.longitude!)
        : null;

    final picked = await showSetLocationPicker(
      context,
      initial: initial,
      tileProvider: widget.setLocationTileProvider,
      controller: widget.setLocationMapController,
      locationService: widget.setLocationLocationService,
    );
    if (picked == null || !mounted) return;

    try {
      await ref
          .read(libraryCrudRepositoryProvider)
          .setWallCoordinates(widget.wallId, picked.latitude, picked.longitude);
    } catch (e, st) {
      debugPrint('Failed to set topo location: $e\n$st');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Couldn't save location — please try again"),
        ),
      );
      return;
    }
    if (!mounted) return;

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Location saved')));
  }

  /// Lets the user choose Camera or Library (via [showPhotoSourceSheet]'s
  /// iOS action sheet — see DESIGN.md "Photo source") before picking an
  /// image with [pickPhotoFrom], then kicks off the attach-and-load flow
  /// ([_attachPickedPhoto] -> [_attachPhotoAndLoad]) directly — there is no
  /// decode callback to re-home this onto any more (see [build]'s doc for
  /// why [_imageSize] is now derived from the persisted [PhotoRef] instead
  /// of a `FileImage` decode): selecting the picked path first (so the
  /// screen immediately shows a loading spinner for it via [build]'s
  /// `ref.listen`/`beginPhotoSwitch`), then firing the attach
  /// fire-and-forget, mirrors the previous sequencing exactly. Replaces the
  /// previous `ImagePicker().pickImage(source: ImageSource.gallery)`-only
  /// call so the canvas's "replace/add photo" FAB offers the same
  /// Camera/Library choice as the Topos-home "New topo" flow.
  Future<void> _pickImage() async {
    if (widget.readOnly) return;
    final source = await showPhotoSourceSheet(context);
    if (source == null || !mounted) return;
    final xfile = await pickPhotoFrom(source);
    if (xfile == null || !mounted) return;
    ref.read(selectedImageProvider.notifier).select(xfile.path);
    unawaited(_attachPickedPhoto(xfile));
  }

  /// Restores [wallId]'s already-attached original photo (if any) so the
  /// canvas shows it and its persisted routes immediately on open, without
  /// requiring the user to re-pick a photo they attached on a previous
  /// visit. If the wall has no original photo yet, leaves the empty-state UI
  /// in place — but see [loadWallOriginalPhoto]'s unconditional-reset doc:
  /// this is now a genuinely CLEAN empty state (previous wall's photo/routes
  /// cleared), not a leftover one.
  ///
  /// Guarded by [_loadedWallId] so this runs at most once per wall — called
  /// from [initState] (Flutter itself only invokes that once per widget
  /// instance) and from [didUpdateWidget] on a wallId change (which first
  /// resets [_loadedWallId] so the guard re-arms), but the guard also
  /// protects against any incidental re-entry.
  ///
  /// The actual repository read + [DrawController.loadForWall] call, AND the
  /// unconditional pre-load reset, are delegated to [loadWallOriginalPhoto]
  /// (see that function's doc for why it's a standalone, directly-testable
  /// function); this method's own job is purely the screen-side bookkeeping:
  /// clearing `selectedImageProvider` up front (via the `onReset` hook) so a
  /// photo-less wall never shows the previous wall's image, and selecting
  /// the found photo's path (via [loadWallOriginalPhoto]'s
  /// `beforeLoadForWall` hook, at the correct point in the sequence — see
  /// that function's doc) so [TopoCanvas] shows the restored image.
  Future<void> _loadInitialPhotoForWall(String wallId) async {
    if (_loadedWallId == wallId) return;
    _loadedWallId = wallId;
    try {
      await loadWallOriginalPhoto(
        ref.read(photoRepositoryProvider),
        ref.read(drawControllerProvider(widget.wallId).notifier),
        wallId,
        onReset: () {
          ref.read(selectedImageProvider.notifier).clear();
        },
        beforeLoadForWall: (p) =>
            ref.read(selectedImageProvider.notifier).select(p.localPath),
      );
    } catch (e, st) {
      debugPrint('Failed to load initial photo for wall $wallId: $e\n$st');
    }
  }

  /// Attaches the freshly-picked image at [xfile] (now that its natural
  /// [width]/[height] are known) to [TopoCanvasScreen.wallId] via
  /// [LibraryCrudRepository.attachPhotoToWall], then loads that new photo's
  /// (empty) routes into [drawControllerProvider] via
  /// [DrawController.loadForWall].
  ///
  /// This is what resets/repopulates the draw state for a newly-picked
  /// photo: [DrawController.loadForWall] itself clears in-progress drawing
  /// state (current points, redo stack, selection) and replaces
  /// [DrawState.routes] with whatever is persisted for this photo's wall
  /// (empty, since attaching just created the photo), and marks the
  /// controller as persistence-backed so subsequent edits write through.
  ///
  /// Called only once [width]/[height] are known (i.e. from
  /// [_attachPickedPhoto], fired from [_pickImage] right after the photo is
  /// selected), since [LibraryCrudRepository.attachPhotoToWall] needs the
  /// image's natural size to create its Photo row. Since that decode is
  /// async, there is
  /// necessarily a window between the photo becoming selected and this
  /// method's [DrawController.loadForWall] call resolving; the `ref.listen`
  /// in [build] calls [DrawController.beginPhotoSwitch] synchronously the
  /// moment the path changes so [DrawState] never shows the previous
  /// photo's routes/wall during that window (see that method's doc for why
  /// this also prevents a mid-window commit from persisting to the wrong
  /// wall). The latest-path guard below additionally drops this call
  /// entirely if the user has since moved on to yet another photo, so an
  /// out-of-order resolution can't clobber a newer photo's state.
  ///
  /// FIX #4 (continued, CONFIRMED — "an early-return/exception path here can
  /// leave isSwitchingPhoto stuck true"): [generation] is captured up front,
  /// before any `await` -- the `ref.listen` in [build] has already called
  /// [DrawController.beginPhotoSwitch] synchronously by the time this method
  /// runs (see this doc's paragraph above), so [DrawState.switchGeneration]
  /// at entry IS the generation that switch opened. [DrawController
  /// .loadForWall] at the bottom is the ONLY call in this method that
  /// settles [DrawState.isSwitchingPhoto] on success; every OTHER way out of
  /// this method (the mounted/latest-path guards returning early, or the
  /// catch-all below, which covers [LibraryCrudRepository.attachPhotoToWall]
  /// throwing, [DrawController.loadForWall] itself throwing, or anything
  /// else in between) must instead call [DrawController.cancelPhotoSwitch]
  /// with this SAME [generation] so the switch this call opened is always
  /// settled one way or the other -- [cancelPhotoSwitch] is itself a no-op
  /// if a NEWER switch has since superseded [generation], so this is always
  /// safe to call even on a stale/superseded path. The two `!mounted`
  /// returns (right after the GPS-capture await, and folded into the
  /// owned-path check below) are the exception: once unmounted, [ref] itself
  /// is no longer safe to use (mirrors every other post-await unmount guard
  /// in this class), so those two paths return without settling -- if
  /// nothing else is watching this wallId's [drawControllerProvider], it
  /// will be torn down (autoDispose) along with the stuck flag anyway.
  Future<void> _attachPhotoAndLoad(XFile xfile, int width, int height) async {
    final generation =
        ref.read(drawControllerProvider(widget.wallId)).switchGeneration;
    try {
      final libraryRepo = ref.read(libraryCrudRepositoryProvider);
      final photoId = await libraryRepo.attachPhotoToWall(
        widget.wallId,
        xfile,
        width,
        height,
      );
      // Best-effort GPS capture (see captureWallGpsFromPhoto's doc): reads
      // the same freshly-attached file's EXIF and, if it carries GPS tags,
      // records them on this wall; if not, falls back to the device's
      // current location via locationServiceProvider. Independent of the
      // mounted/latest-path guards below — it targets the wall, not any
      // in-flight widget/photo state, so it's safe to run even if the user
      // has since moved on to a different photo.
      final gpsResult = await captureWallGpsFromPhoto(
        libraryRepo,
        widget.wallId,
        xfile,
        locationService: ref.read(locationServiceProvider),
      );
      if (!mounted) return;
      // Surfaces the outcome regardless of the latest-path guard below —
      // it's telling the user what just happened to THIS wall's location,
      // which is true no matter which photo they've since moved on to.
      ScaffoldMessenger.of(context).showSnackBar(
        gpsCaptureResultSnackBar(gpsResult),
      );
      // Latest-path guard: if the user has already moved on to a different
      // photo since this call started (e.g. this is a stale/out-of-order
      // resolution for a photo the user swiped past), bail out instead of
      // calling loadForWall — otherwise this stale load could clobber the
      // CURRENT photo's in-memory state with the wrong wall's routes.
      // Settling this call's own switch here is harmless even though the
      // user has moved on: cancelPhotoSwitch no-ops if the newer switch
      // already bumped the generation past ours.
      if (ref.read(selectedImageProvider) != xfile.path) {
        ref
            .read(drawControllerProvider(widget.wallId).notifier)
            .cancelPhotoSwitch(generation);
        return;
      }

      // Photo-ownership bug fix: attachPhotoToWall already copied the
      // picked file into the app-owned photos/ dir and stored THAT path on
      // the new row, but only returns the id — resolveAttachedPhotoPath
      // re-reads the owned path and swaps selectedImageProvider onto it.
      final ownedPath = await resolveAttachedPhotoPath(
        libraryRepo,
        ref.read(selectedImageProvider.notifier),
        photoId,
        xfile.path,
      );
      if (!mounted) return;
      if (ref.read(selectedImageProvider) != ownedPath) {
        ref
            .read(drawControllerProvider(widget.wallId).notifier)
            .cancelPhotoSwitch(generation);
        return;
      }

      await ref
          .read(drawControllerProvider(widget.wallId).notifier)
          .loadForWall(widget.wallId, photoId);
    } catch (e, st) {
      debugPrint('Failed to attach/load photo for ${xfile.path}: $e\n$st');
      // FIX #4 (continued): settle the switch this call opened even when
      // attaching/loading blew up mid-flight (e.g. attachPhotoToWall or
      // loadForWall's own repository read throwing) -- without this,
      // DrawState.isSwitchingPhoto stays stuck true forever, corrupting the
      // NEXT beginPhotoSwitch's routes handling exactly like the no-photo
      // and delete-photo cases this same FIX already covers elsewhere. Only
      // if still mounted -- see this method's doc for why ref is unsafe to
      // touch otherwise.
      if (mounted) {
        ref
            .read(drawControllerProvider(widget.wallId).notifier)
            .cancelPhotoSwitch(generation);
      }
    }
  }

  /// Decodes [xfile]'s natural pixel dimensions via the cross-platform
  /// [decodeImageSize] utility and hands them to [_attachPhotoAndLoad].
  /// Called (fire-and-forget) directly from [_pickImage] for a
  /// freshly-picked photo, right after it's selected. This decode is only
  /// ever used to populate the new Photo row's `width`/`height` columns —
  /// once [_attachPhotoAndLoad] persists them, [build] picks the SAME
  /// stored values back up via [wallOriginalsProvider] to drive
  /// `_imageSize`/display; this helper never touches `_imageSize` itself.
  Future<void> _attachPickedPhoto(XFile xfile) async {
    final size = await decodeImageSize(xfile);
    if (!mounted) return;
    await _attachPhotoAndLoad(xfile, size.width.round(), size.height.round());
  }

  /// U2 (photo-strip switch): switches the canvas over to a DIFFERENT
  /// already-attached original — [PhotoStrip]'s `onSelect` callback.
  ///
  /// Selecting [photo.localPath] via `selectedImageProvider` synchronously
  /// fires [build]'s own `ref.listen<String?>(selectedImageProvider, ...)`
  /// callback (the same one [loadWallOriginalPhoto]'s `beforeLoadForWall`
  /// hook relies on for the initial-load path) — which calls
  /// [DrawController.beginPhotoSwitch] and resets the transform BEFORE this
  /// method's own `loadForWall` call even starts, exactly the same "reset
  /// first, load second" sequencing [loadWallOriginalPhoto] documents. So
  /// the canvas never shows a stale mix of the old photo's image with the
  /// new photo's routes (or vice versa) while this awaits.
  ///
  /// No-ops if [photo] is already the active one (nothing to switch to).
  ///
  /// Latest-selection guard (mirrors [_attachPhotoAndLoad]'s own
  /// `ref.read(selectedImageProvider) != xfile.path` check): if the user
  /// has since switched to yet ANOTHER photo while this call's
  /// [DrawController.loadForWall] was still awaiting (e.g. rapid taps
  /// across [PhotoStrip]), applying this call's result is already made
  /// SAFE internally by [DrawController.loadForWall]'s own
  /// `switchGeneration` guard (see that method's doc) -- it silently
  /// no-ops rather than clobbering the newer photo's state. This guard is
  /// the screen-side half: it stops THIS method from doing anything
  /// further on behalf of a switch that's already been superseded, so a
  /// burst of rapid taps coalesces onto whichever photo the user actually
  /// landed on instead of each stale call independently retrying/logging.
  Future<void> _switchToPhoto(PhotoRef photo) async {
    if (ref.read(selectedImageProvider) == photo.localPath) return;
    ref.read(selectedImageProvider.notifier).select(photo.localPath);
    try {
      await ref
          .read(drawControllerProvider(widget.wallId).notifier)
          .loadForWall(widget.wallId, photo.id);
      if (!mounted || ref.read(selectedImageProvider) != photo.localPath) {
        return;
      }
    } catch (e, st) {
      debugPrint('Failed to switch to photo ${photo.id}: $e\n$st');
    }
  }

  /// U4 (manage menu): promotes [photo] to [TopoCanvasScreen.wallId]'s
  /// cover/primary photo. Purely a bookkeeping flag — it does NOT switch
  /// which photo is currently shown on the canvas (see
  /// [PhotoRepository.setPrimaryPhoto]'s doc); [wallOriginalsProvider]'s
  /// live stream re-emits on its own, so the strip's star badge moves to
  /// [photo] the moment this write lands.
  Future<void> _handleSetCoverPhoto(PhotoRef photo) async {
    if (widget.readOnly) return;
    try {
      await ref
          .read(photoRepositoryProvider)
          .setPrimaryPhoto(widget.wallId, photo.id);
    } catch (e, st) {
      debugPrint('Failed to set cover photo ${photo.id}: $e\n$st');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Couldn't update cover photo — please try again"),
        ),
      );
      return;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Cover photo updated')));
  }

  /// U4 (manage menu): deletes [photo] (and, via
  /// [PhotoRepository.deleteOriginalPhoto]'s cascade, every route drawn on
  /// it) after the strip's own confirm dialog. If [photo] was the currently
  /// ACTIVE photo, this then switches the canvas onto whatever
  /// [PhotoRepository.loadOriginal] reports as the wall's new primary —
  /// deleting a photo out from under the canvas must never leave it showing
  /// a dangling image/route set for a photo that no longer exists. Falls
  /// back to the empty state if the wall has no photos left at all.
  ///
  /// FIX #4 (continued, CONFIRMED — "deleting the photo you are currently
  /// switching TO is unaware its target is gone"): [wasActiveOrInFlight]
  /// treats [photo] as needing this settle-and-redirect handling if it
  /// matches EITHER [DrawState.activePhotoId] (the ordinary case) OR
  /// [DrawState.switchTargetPhotoId] — the latter catches deleting [photo]
  /// while an in-flight [DrawController.loadForWall] is still awaiting ITS
  /// routes (mid photo-switch, [DrawState.activePhotoId] is null for the
  /// whole window, so checking only that would silently no-op here, leaving
  /// [DrawState.isSwitchingPhoto] stuck `true` and that stale load free to
  /// apply once it resolves — see [DrawState.switchTargetPhotoId]'s doc for
  /// the full regression). In that mid-switch case, the redirect below
  /// (`_switchToPhoto`/the no-photo branch) itself calls
  /// [DrawController.beginPhotoSwitch] again, which — since
  /// [DrawState.isSwitchingPhoto] is already `true` — bumps
  /// [DrawState.switchGeneration] (invalidating the stale in-flight
  /// [DrawController.loadForWall] for the now-deleted target so it can't
  /// apply once it resolves) while carrying forward [DrawState.routes]
  /// (any route committed mid-switch), which the subsequent
  /// [DrawController.loadForWall] call then merges in and persists against
  /// the REDIRECTED wall/photo exactly like an ordinary mid-switch commit —
  /// nothing is discarded.
  Future<void> _handleDeletePhoto(PhotoRef photo) async {
    if (widget.readOnly) return;
    final drawState = ref.read(drawControllerProvider(widget.wallId));
    final wasActiveOrInFlight = drawState.activePhotoId == photo.id ||
        drawState.switchTargetPhotoId == photo.id;
    try {
      final storedPaths = await ref
          .read(photoRepositoryProvider)
          .deleteOriginalPhoto(photo.id);
      // Purge the tombstoned photo's on-disk/IndexedDB bytes (canonical +
      // every cascaded child) now that the DB write committed — best-effort
      // and never throws (see PhotoFiles.deletePhotoBytes). Fired
      // non-blocking (not awaited) so filesystem/IndexedDB I/O can never
      // delay or hang the user-facing delete (the SnackBar + photo-switch
      // below) — the DB row is already tombstoned, which is what makes the
      // delete correct; byte cleanup is background housekeeping only.
      final photoFiles = ref.read(photoFilesProvider);
      unawaited(Future.wait(storedPaths.map(photoFiles.deletePhotoBytes)));
    } catch (e, st) {
      debugPrint('Failed to delete photo ${photo.id}: $e\n$st');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Couldn't delete photo — please try again"),
        ),
      );
      return;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Photo deleted')));
    if (!wasActiveOrInFlight) return;

    final remaining = await ref
        .read(photoRepositoryProvider)
        .loadOriginal(widget.wallId);
    if (!mounted) return;
    if (remaining == null) {
      // No photos left on this wall at all: fall back to a clean empty
      // state, mirroring loadWallOriginalPhoto's own unconditional reset
      // for a photo-less wall. FIX #4 (continued): cancelPhotoSwitch right
      // after beginPhotoSwitch -- there is no loadForWall coming for THIS
      // switch (the wall has no photo to load), so without settling it
      // here DrawState.isSwitchingPhoto would stay stuck true and corrupt
      // the NEXT beginPhotoSwitch's routes handling (see that method's
      // doc).
      final notifier = ref.read(drawControllerProvider(widget.wallId).notifier);
      final generation = notifier.beginPhotoSwitch();
      notifier.cancelPhotoSwitch(generation);
      ref.read(selectedImageProvider.notifier).clear();
      return;
    }
    await _switchToPhoto(remaining);
  }

  @override
  Widget build(BuildContext context) {
    // Fires synchronously, as part of the same state-change notification
    // triggered by SelectedImageNotifier.select, whenever the selected
    // image path changes to a new non-null value (including the very
    // first pick). This is what closes the M3 race: DrawController state
    // is cleared (activeWallId -> null, routes -> empty, ...) the MOMENT
    // the new photo is selected, well before the async
    // ensureDefaultForImage -> loadForWall chain (kicked off from
    // _pickImage/_loadInitialPhotoForWall) resolves. See
    // DrawController.beginPhotoSwitch for why nulling activeWallId is what
    // actually prevents a mid-switch commit from persisting against the
    // previous photo's wall.
    ref.listen<String?>(selectedImageProvider, (previous, next) {
      if (next != null && next != previous) {
        ref.read(drawControllerProvider(widget.wallId).notifier).beginPhotoSwitch();
        // Fix 1 (M5 hardening): also reset the shared
        // transformationController synchronously, right alongside
        // beginPhotoSwitch above. Without this, a fresh TopoCanvas for the
        // new photo could see this SAME (screen-owned, never-recreated)
        // TransformationController still holding the PREVIOUS photo's
        // non-identity fit matrix — TopoCanvas's own pre-seeded-controller
        // escape hatch (see _TopoCanvasState._reframeIfNeeded) would read
        // that stale non-identity matrix as "a caller intentionally
        // pre-seeded this" and leave it alone forever, permanently showing
        // the new photo through the old one's transform. Resetting it to a
        // known "nothing framed yet" state here means the next reframe
        // always computes a fresh, correct fit for whatever photo actually
        // ends up active.
        _transformationController.value = Matrix4.identity();
      }
    });

    // Fix 1/3 (legend expand/collapse): reset the legend card to its
    // mode-appropriate default the moment DrawMode actually changes — expanded
    // in view mode (nothing else occupies this screen real estate, so show
    // the full route list), collapsed to the compact chip in draw mode (so
    // the floating card doesn't sit over the drawing surface the user is
    // actively working on). `.select` + the `previous != next` guard here
    // keep this from firing on every unrelated DrawState rebuild — only an
    // actual mode flip should reset the user's toggle. No `fireImmediately`:
    // this callback synchronously writes another provider, and doing so
    // while THIS widget is still building throws (see the `beginPhotoSwitch`
    // listener above / its own microtask-deferral doc for the same
    // Riverpod rule).
    ref.listen<DrawMode>(
      drawControllerProvider(widget.wallId).select((s) => s.mode),
      (previous, next) {
        if (previous != next) {
          ref.read(legendExpandedProvider(widget.wallId).notifier).setForMode(next);
        }
      },
    );

    final imagePath = ref.watch(selectedImageProvider);
    final drawState = ref.watch(drawControllerProvider(widget.wallId));
    final drawNotifier = ref.read(drawControllerProvider(widget.wallId).notifier);
    // The topo/wall name backs the canvas title (DESIGN.md "Topo canvas"):
    // AsyncValue.maybeWhen falls back to "Topo" both while this is still
    // loading and if the wall genuinely has no name (or doesn't exist —
    // see router_test.dart's nonexistent-wall-id smoke test), so the title
    // is never blank and never shows the literal app name "Masi".
    final wallName = ref.watch(wallNameProvider(widget.wallId));
    final title = wallName.maybeWhen(
      data: (name) => (name == null || name.isEmpty) ? 'Topo' : name,
      orElse: () => 'Topo',
    );

    // Backs the "Edit location"/"Set location" button (_topTrailingActions'
    // topo-edit-location-button) and _handleEditLocation's `initial` picker
    // center: there is no single-wall-by-id provider exposing lat/lng (see
    // that button's doc), so this filters toposProvider's flat, live list —
    // the same one topos_screen.dart itself is built from — down to this
    // wall. A live StreamProvider, not a one-shot read: a successful
    // setWallCoordinates write re-emits this list on its own (see
    // _handleEditLocation's doc), so this always reflects the wall's
    // CURRENT coordinates, including right after a save.
    final topos = ref
        .watch(toposProvider)
        .maybeWhen(data: (list) => list, orElse: () => const <TopoRef>[]);
    TopoRef? currentTopo;
    for (final t in topos) {
      if (t.wallId == widget.wallId) {
        currentTopo = t;
        break;
      }
    }

    // U1/U2/U3/U4 (photo strip): switching between DIFFERENT photos on this
    // wall (see PhotoStrip's class doc). NOT gated on `widget.readOnly` — a
    // read-only community viewer can still switch between someone else's
    // photos (see PhotoStrip.readOnly's doc for what IS suppressed in that
    // case: the add/manage affordances). PhotoStrip itself renders nothing
    // once the wall's live-original list (`wallOriginalsProvider`) comes
    // back empty, but the Divider ABOVE it (this call site's own wrapping)
    // is not PhotoStrip's to skip — so this also watches the same live list
    // to keep that divider from floating over an empty strip before the
    // wall's first photo is attached.
    //
    // Moved above the `_imageSize` derivation below (F-A1/F-A2 fix): this
    // is now the SAME live list `_imageSize` is read from — no separate
    // FileImage/codec decode probe — so it needs to be watched first.
    final wallPhotos = ref
        .watch(wallOriginalsProvider(widget.wallId))
        .maybeWhen(data: (list) => list, orElse: () => const <PhotoRef>[]);
    final showPhotoStrip = wallPhotos.isNotEmpty;

    // Derives _imageSize straight from the displayed photo's own persisted
    // PhotoRef.width/height — the SAME source `imagePath` (PhotoRef.localPath)
    // itself comes from — instead of running a real FileImage/codec decode
    // probe. The old probe LATCHED a permanent `_imageLoadError` on any
    // decode failure (e.g. a friend opening this wall mid-download, or a
    // cold web-cache miss for the underlying bytes), which blanked the
    // canvas until the user left and re-entered; the stored width/height
    // are populated at import time (see PhotoRepository/decodeImageSize)
    // and don't depend on the bytes being resolvable right now, so this can
    // never latch that way. Genuinely-missing bytes are instead handled by
    // TopoCanvasBody's own PhotoImage, which self-heals/placeholders per
    // key (see photo_image_source_web.dart) rather than needing this
    // screen to track an error state at all.
    if (imagePath != null && imagePath != _resolvedForPath) {
      final debugSize = widget.debugInitialImageSize;
      if (debugSize != null) {
        // TEST-ONLY seam (see TopoCanvasScreen.debugInitialImageSize's doc):
        // bypass the persisted-size lookup entirely and use the injected
        // size directly. Mutating these fields directly (no setState) is
        // safe here — it's still within this same build call, before
        // _buildCanvasArea below reads them.
        _resolvedForPath = imagePath;
        _imageSize = debugSize;
      } else {
        PhotoRef? match;
        for (final p in wallPhotos) {
          if (p.localPath == imagePath) {
            match = p;
            break;
          }
        }
        if (match != null && match.width > 0 && match.height > 0) {
          _resolvedForPath = imagePath;
          _imageSize = Size(match.width.toDouble(), match.height.toDouble());
        } else {
          // Either the matching PhotoRef hasn't shown up in
          // wallOriginalsProvider yet (a freshly-picked photo whose
          // attachPhotoToWall write is still in flight) or it has a
          // defensive/degenerate non-positive width or height — either
          // way, DON'T set _resolvedForPath: leaving it mismatched means
          // the next rebuild (which the live wallOriginalsProvider watch
          // above triggers once a valid row lands) retries this lookup
          // instead of getting stuck with a stale null forever.
          // _buildCanvasArea shows a loading spinner for as long as
          // _imageSize stays null — never a permanent error state.
          _imageSize = null;
        }
      }
    }

    final colors = MasiColors.of(context);

    // Canvas look rework: the symbol palette only ever means anything with a
    // photo loaded AND while actually drawing.
    final showSymbolPalette =
        !widget.readOnly &&
        imagePath != null &&
        drawState.mode == DrawMode.draw;

    // Floating translucent-glass chrome over an edge-to-edge photo, per
    // DESIGN.md "Topo canvas": no opaque AppBar/BottomAppBar — the canvas
    // area (or empty state) fills the whole Scaffold behind a top glass
    // pill (back + title + mode-aware actions, including add-photo — see
    // `_topTrailingActions`'s `topo-add-photo-button`), the symbol palette
    // (draw mode only, floating directly below the title pill on the SAME
    // glass material), and a bottom glass cluster (undo/redo/cancel/commit,
    // draw mode only — see `_buildBottomChrome`), all floating within thumb
    // reach and inset by the safe area.
    return Scaffold(
      backgroundColor: colors.ground,
      extendBody: true,
      body: Stack(
        children: [
          Positioned.fill(
            child: imagePath == null
                ? _buildEmptyState(context)
                : _buildCanvasArea(imagePath, drawState),
          ),
          // `embedded` gate (ghost-back-chevron fix — see
          // TopoCanvasScreen.embedded's doc): this whole block is the top
          // GlassChrome pill (wall-name title + `topo-back-button`, plus the
          // symbol palette/photo strip that share its band) — none of it
          // paints at all when embedded, rather than merely being made
          // gesture-inert by an ancestor IgnorePointer as before.
          if (!widget.embedded)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                    MasiSpacing.lg,
                    MasiSpacing.sm,
                    MasiSpacing.lg,
                    0,
                  ),
                  // The title row and the (multi-photo-only) PhotoStrip share
                  // a SINGLE GlassChrome card (an inner Column keeps them
                  // from overlapping — no transparent gap between them
                  // exposes the full-bleed photo behind). The (draw-mode-only)
                  // symbol palette remains a separate floating sibling below,
                  // in this outer Column, so it still can never overlap the
                  // shared card: its position is always "directly below
                  // whatever's already rendered above it, plus a fixed gap",
                  // which a Column gives for free without needing to know the
                  // other's runtime size.
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      GlassChrome(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 4,
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _buildTopChromeRow(
                              context,
                              colors,
                              title,
                              drawState,
                              drawNotifier,
                              currentTopo,
                            ),
                            if (showPhotoStrip) ...[
                              Divider(
                                height: MasiSpacing.sm,
                                thickness: 1,
                                color: colors.separator,
                              ),
                              PhotoStrip(
                                wallId: widget.wallId,
                                activePhotoId: drawState.activePhotoId,
                                onSelect: _switchToPhoto,
                                readOnly: widget.readOnly,
                                onAdd: widget.readOnly ? null : _pickImage,
                                onSetCover: widget.readOnly
                                    ? null
                                    : _handleSetCoverPhoto,
                                onDelete: widget.readOnly
                                    ? null
                                    : _handleDeletePhoto,
                              ),
                            ],
                          ],
                        ),
                      ),
                      if (showSymbolPalette) ...[
                        const SizedBox(height: MasiSpacing.sm),
                        SymbolPaletteBar(wallId: widget.wallId),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  MasiSpacing.lg,
                  0,
                  MasiSpacing.lg,
                  MasiSpacing.md,
                ),
                child: _buildBottomChrome(colors, drawNotifier, drawState.mode),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The top chrome row: a back chevron, the topo name (never truncated —
  /// [Expanded] + `maxLines: 1` + [TextOverflow.ellipsis] — see
  /// [_topTrailingActions]'s doc for why it was truncating to "ClimbT…"
  /// before), and mode-aware trailing action glyphs. Returns just the `Row`
  /// — the caller wraps it (together with the photo strip) in a single
  /// shared `GlassChrome` card.
  Widget _buildTopChromeRow(
    BuildContext context,
    MasiColors colors,
    String title,
    DrawState drawState,
    DrawController drawNotifier,
    TopoRef? currentTopo,
  ) {
    return Row(
      children: [
        IconButton(
          key: const Key('topo-back-button'),
          icon: MasiIcon('chevron_left'),
          tooltip: 'Back',
          onPressed: () {
            if (context.canPop()) {
              FocusManager.instance.primaryFocus?.unfocus();
              context.pop();
            } else {
              context.go('/');
            }
          },
          color: colors.accent,
          style: _topRowIconStyle(),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: MasiSpacing.xs,
            ),
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: colors.ink,
              ),
            ),
          ),
        ),
        ..._topTrailingActions(context, drawState, drawNotifier, currentTopo),
      ],
    );
  }

  /// A [ButtonStyle] for every glyph in the top chrome's back-button-plus-
  /// trailing-actions row: [CircleBorder] exactly like before, plus an
  /// explicit 44x44 [minimumSize] — the iOS HIG minimum tap target (this
  /// app is iOS-primary; see project CLAUDE.md) — paired with
  /// [MaterialTapTargetSize.shrinkWrap] so the button's actual footprint is
  /// exactly 44x44, not Material's own larger 48x48 default.
  ///
  /// Accessibility-regression fix: an earlier pass (to make room for the
  /// "Edit location" glyph — see this row's other docs) shrank this to
  /// `Size(36, 40)`, BELOW the 44x44 HIG floor, on every glyph in this row.
  /// 44x44 turns out to still fit the same worst case — the back chevron
  /// plus up to FIVE simultaneous trailing glyphs (edit-metadata + AR +
  /// mode-toggle + locate-on-map + add-photo, once a route is selected) —
  /// at this project's supported minimum width (375px — see
  /// `canvas_bottom_reclaim_test.dart`'s own regression test): 6 glyphs *
  /// 44 = 264px against ~331px available inside the top pill's own chrome
  /// padding (375 - 2*`MasiSpacing.lg` outer padding - 2*6
  /// `GlassChrome` padding), leaving the title's `Expanded` slot ~67px to
  /// shrink into (it already ellipsizes — see [_buildTopChromeRow]) rather
  /// than overflowing. Verified empirically by that same test, with no
  /// further padding/spacing changes needed.
  ///
  /// The visible icon glyph itself is unaffected (still whatever size
  /// [MasiIcon] renders at, e.g. 24) — only the tappable footprint grows
  /// back to the accessible minimum.
  ///
  /// Applied uniformly to every glyph in THIS row only — never the bottom
  /// draw-mode cluster ([_buildBottomChrome]), which never gets this
  /// crowded — so none of this row's glyphs reads as visually inconsistent
  /// with its neighbors. Purely a size/padding tweak: every button's key,
  /// tooltip, and `onPressed` behavior is completely unchanged.
  ButtonStyle _topRowIconStyle({Color? backgroundColor}) =>
      IconButton.styleFrom(
        shape: const CircleBorder(),
        backgroundColor: backgroundColor,
        minimumSize: const Size(44, 44),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
        // Without this, Theme.of(context).materialTapTargetSize's default
        // (MaterialTapTargetSize.padded) silently pads the interactive area
        // back out to Material's accessibility-minimum 48x48 REGARDLESS of
        // the smaller minimumSize/padding above — i.e. the shrink above
        // would otherwise have zero effect on this row's actual layout
        // width, which is exactly what was observed before this line was
        // added (still an identical 7.0px overflow). shrinkWrap makes the
        // button's rendered footprint match minimumSize/padding exactly.
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      );

  /// Mode-aware trailing glyphs for [_buildTopChromeRow] — this is what keeps
  /// the top chrome from ever becoming the old crowded AR/X/check/pencil
  /// jumble (which was also what forced the old long app-name title to
  /// truncate to an ellipsis): an optional edit-metadata glyph (route selected) + an
  /// optional AR glyph (view mode, eligible wall) + the draw/view mode
  /// toggle + (view mode only) the locate-on-map entry point + (draw mode
  /// only) the edit-location entry point.
  List<Widget> _topTrailingActions(
    BuildContext context,
    DrawState drawState,
    DrawController drawNotifier,
    TopoRef? currentTopo,
  ) {
    final colors = MasiColors.of(context);
    final actions = <Widget>[];

    if (!widget.readOnly && drawState.selectedRouteId != null) {
      actions.add(
        IconButton(
          key: const Key('topo-edit-metadata-button'),
          icon: MasiIcon('edit_note'),
          tooltip: 'Edit route metadata',
          onPressed: () {
            final selected = drawState.routes.firstWhere(
              (r) => r.id == drawState.selectedRouteId,
            );
            _openMetadataSheet(selected);
          },
          color: colors.accent,
          style: _topRowIconStyle(),
        ),
      );
    }

    // Only meaningful once the wall has a photo AND at least one committed,
    // VISIBLE route: with nothing to align (or every route hidden), AR
    // would show an empty feed. Kept to view mode (rather than always-on,
    // as it was before) so draw mode's row stays a clean back + name + a
    // single mode-toggle glyph.
    if (drawState.mode == DrawMode.view &&
        drawState.activePhotoId != null &&
        drawState.routes.any((r) => r.visible)) {
      final arSupported = isArSupported();
      actions.add(
        IconButton(
          key: const Key('topo-ar-button'),
          icon: MasiIcon('ar_peak'),
          tooltip: arSupported ? 'View in AR' : 'AR is available on iOS only',
          onPressed: arSupported
              ? () => context.push('/walls/${widget.wallId}/ar')
              : null,
          color: colors.accent,
          style: _topRowIconStyle(),
        ),
      );
    }

    // Rock-segmentation highlight toggle (#68): a sibling of the AR button,
    // gated the same way (view mode, a photo loaded). Runs a one-shot native
    // segmentation of the active photo and washes the detected rock with a
    // translucent tint under the routes (see rock_highlight_controller.dart /
    // rock_mask_painter.dart). Enabled only where native segmentation exists
    // (isArSupported — iOS); disabled with an explanatory tooltip elsewhere.
    if (drawState.mode == DrawMode.view && drawState.activePhotoId != null) {
      final photoId = drawState.activePhotoId!;
      final imagePath = ref.watch(selectedImageProvider);
      final arSupported = isArSupported();
      final rockState = ref.watch(rockHighlightControllerProvider(photoId));
      actions.add(
        IconButton(
          key: const Key('topo-highlight-rock-toggle'),
          icon: MasiIcon(rockState.enabled ? 'boulder_fill' : 'boulder'),
          tooltip: arSupported
              ? (rockState.enabled ? 'Hide rock highlight' : 'Highlight rock')
              : 'Rock segmentation is available on iOS only',
          onPressed: (arSupported && imagePath != null)
              ? () => ref
                    .read(rockHighlightControllerProvider(photoId).notifier)
                    .toggle(imagePath)
              : null,
          color: colors.accent,
          style: _topRowIconStyle(
            backgroundColor: rockState.enabled
                ? colors.accent.withValues(alpha: 0.16)
                : null,
          ),
        ),
      );
    }

    // The mode toggle itself stays UNGATED (other than the readOnly check
    // below): flipping DrawState.mode (an app-lifetime-global) with no photo
    // loaded is inert — there's no canvas mounted to observe it on (see
    // `_buildCanvasArea`) — but harmless, and a substantial part of this
    // screen's own test suite deliberately exercises the draw-mode
    // toggle/toolbar in isolation from the image-decode path this way (see
    // the M3 NOTE elsewhere in test/widget_test.dart).
    //
    // readOnly gate: this is the ONLY control anywhere in this screen that
    // can flip DrawState.mode to DrawMode.draw — hiding it here is what
    // makes [TopoCanvasScreen.readOnly]'s "never enter Draw mode" guarantee
    // hold, since every mutating handler is otherwise unreachable once
    // draw mode itself is unreachable.
    if (!widget.readOnly) {
      actions.add(
        IconButton(
          key: const Key('topo-mode-toggle'),
          // Bug fix ("topo opens showing an eye, reads as read-only"): the
          // glyph is the AFFORDANCE for what tapping it does, not a mirror
          // of the current mode — in view mode (the mode every topo opens
          // in) it shows the edit/pencil glyph ("tap to edit"), and in draw
          // mode it shows the eye glyph ("tap to preview"). This is the
          // deliberate INVERSE of the naive `mode == draw ? edit : eye`
          // reading.
          icon: drawState.mode == DrawMode.draw
              ? MasiIcon('eye')
              : MasiIcon('edit'),
          tooltip: drawState.mode == DrawMode.draw ? 'Preview' : 'Edit',
          onPressed: drawNotifier.toggleMode,
          color: colors.accent,
          style: _topRowIconStyle(
            backgroundColor: drawState.mode == DrawMode.draw
                ? colors.accent.withValues(alpha: 0.16)
                : null,
          ),
        ),
      );
    }

    // Set/edit this wall's map location — the canvas-screen counterpart to
    // `topos_screen.dart`'s overflow-menu "Set location"/"Edit location"
    // item (previously the ONLY way to reach this flow). Per user feedback,
    // this button now lives in DRAW mode only (moved from view mode — see
    // the view-mode "locate on map" button just below for the mode split):
    // editing IS a draw-mode action, alongside every other mutating control
    // in this row (edit-metadata, add-photo, etc). NOT gated on
    // `activePhotoId != null` like the AR button above: a wall's location
    // is a property of the WALL, not of any particular photo, so it's just
    // as settable before a photo has ever been attached as after.
    if (!widget.readOnly && drawState.mode == DrawMode.draw) {
      final hasCoords =
          currentTopo?.latitude != null && currentTopo?.longitude != null;
      actions.add(
        IconButton(
          key: const Key('topo-edit-location-button'),
          icon: MasiIcon('pin'),
          tooltip: hasCoords ? 'Edit location' : 'Set location',
          onPressed: () => _handleEditLocation(currentTopo),
          color: colors.accent,
          style: _topRowIconStyle(),
        ),
      );
    }

    // Locate this wall ON the map — the view-mode counterpart to the
    // edit-location button above. Per user feedback ("only show the
    // location edit button in edit mode, on normal mode use the button to
    // locate the topo on the map"), view mode's glyph is no longer the
    // picker: it's a read-only "show me where this is" jump into
    // `/community`'s Map tab, focused on this wall — the EXACT same
    // navigation `topos_screen.dart`'s `_handleShowOnMap` uses for its
    // home-list "Show on map" menu item, reused verbatim so both entry
    // points behave identically. Disabled (not hidden) when the wall has no
    // coordinates yet — there's nothing to locate — mirroring
    // `topos_screen.dart`'s own disabled "Show on map" menu item rather
    // than making the control disappear.
    if (!widget.readOnly && drawState.mode == DrawMode.view) {
      final hasCoords =
          currentTopo?.latitude != null && currentTopo?.longitude != null;
      actions.add(
        IconButton(
          key: const Key('topo-locate-on-map-button'),
          icon: MasiIcon('topo_map'),
          tooltip: hasCoords ? 'Show on map' : 'No location set',
          onPressed: hasCoords
              ? () => context.push('/community?tab=map&focus=${widget.wallId}')
              : null,
          color: colors.accent,
          style: _topRowIconStyle(),
        ),
      );
    }

    // add-photo lives in the top chrome, alongside the other trailing
    // glyphs, so it's reachable in BOTH view and draw mode — unconditional
    // on mode (other than readOnly, matching every other editing affordance
    // in this list) and, critically, NOT gated on `activePhotoId != null`
    // like the AR button above: this is the one control that must still
    // work with NO photo loaded yet (see `_buildEmptyState`) — the user's
    // only way to attach a wall's first photo. There is no bottom FAB for
    // this action; see `_buildBottomChrome`'s doc.
    if (!widget.readOnly) {
      actions.add(
        IconButton(
          key: const Key('topo-add-photo-button'),
          icon: MasiIcon('image_add'),
          tooltip: 'Pick a photo',
          onPressed: _pickImage,
          color: colors.accent,
          style: _topRowIconStyle(),
        ),
      );
    }

    return actions;
  }

  /// The bottom glass cluster (undo / redo / discard-current / commit) —
  /// gated to [DrawMode.draw] ONLY; every other mode renders nothing here.
  ///
  /// Bug fix ("the editor remains open, overlaying the bottom ... covers
  /// the RouteLegend"): this cluster used to be rendered mode-INDEPENDENTLY
  /// (unconditionally, in both view and draw mode), on the theory that
  /// undo/redo/commit act on [DrawState.currentPoints] regardless of mode
  /// so they should stay tappable at all times. In practice that meant the
  /// cluster sat on screen — and visually covered [RouteLegend]'s bottom
  /// rows, since both float at the very bottom of the same [Stack] — even
  /// in view mode, where there is nothing in progress to undo/redo/commit
  /// (undo/redo only ever act on [DrawState.currentPoints], which is only
  /// ever non-empty while actively drawing). Per DESIGN.md's "Topo canvas"
  /// spec ("bottom pill (undo / redo / commit)" is one of DRAW mode's
  /// tools), the cluster now only shows in draw mode.
  ///
  /// Bottom-band reclaim (masi-canvas-bottom-reclaim.md): add-photo lives in
  /// the top chrome's trailing-action cluster instead (see
  /// `_topTrailingActions`'s `topo-add-photo-button`, reachable in both view
  /// AND draw mode) — there is no bottom FAB. So this method renders
  /// literally nothing outside draw mode, letting [TopoCanvasBody]'s
  /// floating [RouteLegend] sit flush near the bottom safe area instead of
  /// leaving that band empty.
  Widget _buildBottomChrome(
    MasiColors colors,
    DrawController drawNotifier,
    DrawMode mode,
  ) {
    // readOnly: no bottom chrome at all — the draw cluster is already
    // unreachable, since draw mode itself is unreachable (see
    // `_topTrailingActions`'s mode-toggle gate).
    if (widget.readOnly) {
      return const SizedBox.shrink();
    }

    if (mode != DrawMode.draw) {
      return const SizedBox.shrink();
    }

    return GlassChrome(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          IconButton(
            key: const Key('topo-undo-button'),
            icon: MasiIcon('undo'),
            tooltip: 'Undo',
            onPressed: drawNotifier.undo,
            color: colors.accent,
            style: IconButton.styleFrom(shape: const CircleBorder()),
          ),
          IconButton(
            key: const Key('topo-redo-button'),
            icon: MasiIcon('redo'),
            tooltip: 'Redo',
            onPressed: drawNotifier.redo,
            color: colors.accent,
            style: IconButton.styleFrom(shape: const CircleBorder()),
          ),
          IconButton(
            key: const Key('topo-clear-button'),
            icon: MasiIcon('close'),
            tooltip: 'Discard current route',
            onPressed: drawNotifier.clearCurrent,
            color: colors.accent,
            style: IconButton.styleFrom(shape: const CircleBorder()),
          ),
          IconButton(
            key: const Key('topo-commit-button'),
            icon: MasiIcon('check'),
            tooltip: 'Commit route',
            onPressed: _handleCommitRoute,
            color: colors.accent,
            style: IconButton.styleFrom(
              backgroundColor: colors.accent.withValues(alpha: 0.16),
              shape: const CircleBorder(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    final colors = MasiColors.of(context);
    return ColoredBox(
      color: colors.ground,
      child: Center(
        child: Column(
          key: const Key('topo-empty-state'),
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            MasiIcon(
              'image',
              size: 72,
              color: colors.ink3,
            ),
            const SizedBox(height: MasiSpacing.lg),
            Text(
              'No photo yet — pick one to start',
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: colors.ink2,
              ),
            ),
            // readOnly: no add affordance — there is no photo a read-only
            // viewer could pick to attach to someone else's wall.
            if (!widget.readOnly) ...[
              const SizedBox(height: MasiSpacing.lg),
              // "Filled" (primary) per DESIGN.md "Buttons": accent bg,
              // onAccent text, radius `MasiRadii.control` — same
              // ElevatedButton.styleFrom shape used by
              // `crud_list_scaffold.dart`'s own add button. This is the
              // screen's ONLY action while empty, so it reads as primary.
              ElevatedButton(
                key: const Key('topo-empty-state-add-photo'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: colors.accent,
                  foregroundColor: colors.onAccent,
                  padding: const EdgeInsets.symmetric(
                    horizontal: MasiSpacing.lg,
                    vertical: MasiSpacing.md,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(MasiRadii.control),
                  ),
                ),
                onPressed: _pickImage,
                child: const Text('Add a photo'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Builds the canvas body once a photo is selected: a `topo-image-loading`
  /// spinner while [_imageSize] is still unresolved (see [build]'s doc for
  /// how it's derived from the displayed photo's persisted [PhotoRef]),
  /// otherwise the real [TopoCanvasBody]. There is no separate
  /// permanent-error branch here (see the removed `_imageLoadError`/
  /// `_buildImageErrorState` — F-A1/F-A2 fix): genuinely-missing photo
  /// bytes are handled by [TopoCanvasBody]'s own `PhotoImage`, which
  /// self-heals/placeholders per key rather than latching a screen-level
  /// error that used to require leaving and re-entering to clear.
  Widget _buildCanvasArea(
    String imagePath,
    DrawState drawState,
  ) {
    final imageSize = _imageSize;
    if (imageSize == null) {
      return const Center(
        key: Key('topo-image-loading'),
        child: CircularProgressIndicator(),
      );
    }
    return TopoCanvasBody(
      wallId: widget.wallId,
      imagePath: imagePath,
      imageSize: imageSize,
      drawState: drawState,
      transformationController: _transformationController,
      canvasKey: _canvasKey,
      readOnly: widget.readOnly,
      // See TopoCanvasScreen.embedded's doc: suppresses TopoCanvasBody's own
      // floating RouteLegend overlay (both its expanded card and its
      // collapsed chip) for the community header's embedded preview, while
      // leaving the photo + route overlays (TopoCanvas/TopoPainter) shown
      // exactly as they otherwise would be.
      embedded: widget.embedded,
      // Only ever wired when NOT readOnly: the community (readOnly) canvas
      // has its own separate per-route log-ascent button on
      // CommunityTopoDetailScreen — see RouteLegend.onLogAscent's doc for
      // why this widget's own copy must stay hidden there.
      onLogAscent: widget.readOnly ? null : _openLogAscentSheet,
    );
  }
}

/// The canvas area shown once [imageSize] is resolved: the interactive
/// [TopoCanvas] and the [RouteLegend].
///
/// Extracted as a standalone public widget (rather than inlined into
/// [_TopoCanvasScreenState._buildCanvasArea]) so it can be pumped directly
/// in widget tests with an injected [imageSize] and [drawState] — the same
/// approach [TopoCanvas] itself uses (see its class doc) — without needing
/// a real, decodable image file on disk or waiting on the async image
/// decode that only [TopoCanvasScreen] drives.
class TopoCanvasBody extends ConsumerWidget {
  const TopoCanvasBody({
    super.key,
    required this.wallId,
    required this.imagePath,
    required this.imageSize,
    required this.drawState,
    required this.transformationController,
    this.canvasKey,
    this.readOnly = false,
    this.embedded = false,
    this.onLogAscent,
  });

  /// FIX #6: family key for [drawControllerProvider]/[legendExpandedProvider]
  /// — see [drawControllerProvider]'s doc. Always the same wallId as the
  /// owning [TopoCanvasScreen].
  final String wallId;

  final String imagePath;
  final Size imageSize;
  final DrawState drawState;
  final TransformationController transformationController;

  /// See [TopoCanvasScreen.readOnly]. Hides [RouteLegend]'s per-route
  /// visibility-toggle/delete controls, leaving tap-to-select (a
  /// non-mutating view affordance) untouched. Defaults to `false`,
  /// preserving every existing call site's behavior.
  final bool readOnly;

  /// A stable identity for the [TopoCanvas] built inside [build], assigned
  /// as its [Widget.key]. See [_TopoCanvasScreenState._canvasKey]'s doc for
  /// why this must be a caller-owned [GlobalKey] (not one this widget
  /// creates itself — [TopoCanvasBody] is reconstructed fresh on every
  /// rebuild, so a key it created internally would be equally short-lived).
  /// Null (the default) preserves every pre-existing call site/test that
  /// doesn't care about [TopoCanvas]'s identity across rebuilds.
  final Key? canvasKey;

  /// See [TopoCanvasScreen.embedded]'s doc. When `true`, [build] never
  /// paints the floating [RouteLegend] overlay — neither its expanded
  /// [GlassChrome] card (`topo-route-legend-overlay`) nor its collapsed
  /// [_LegendChip] (`topo-route-legend-chip`) — regardless of [hasRoutes]/
  /// [legendExpandedProvider]. The canvas ([TopoCanvas]) is unaffected: only
  /// the legend overlay is gated by this flag. Defaults to `false`,
  /// preserving every pre-existing call site's behavior exactly.
  final bool embedded;

  /// Passed straight through to [RouteLegend.onLogAscent] — see that
  /// field's doc. Null (the default, and always what [TopoCanvasScreen]
  /// passes when [readOnly] is `true`) hides the per-route log-ascent
  /// button entirely.
  final void Function(int routeId)? onLogAscent;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasRoutes = drawState.routes.isNotEmpty;
    final legendExpanded = ref.watch(legendExpandedProvider(wallId));

    // Bottom clearance reserved above the floating RouteLegend overlay, so
    // both the legend's Padding AND its maxHeight cap (below) can share the
    // same value. Mode-aware (bottom-band reclaim,
    // masi-canvas-bottom-reclaim.md): only DRAW mode's undo/redo/clear/
    // commit cluster (see TopoCanvasScreen._buildBottomChrome) actually
    // occupies this floating bottom band, so only draw mode needs the extra
    // `kBottomChromeClusterHeight + sm` reserved above it to avoid occluding
    // RouteLegend's last row(s). VIEW mode's bottom chrome is now empty (the
    // add-photo action lives in the top bar instead — see
    // `_topTrailingActions`), so the legend only needs the same small `md`
    // breathing-room gap every OTHER floating element gets above the safe
    // area, letting it sit flush near the bottom instead of leaving a dead
    // gap where the draw-mode cluster would have been.
    final legendBottomPadding = hasRoutes
        ? MediaQuery.paddingOf(context).bottom +
              MasiSpacing.md +
              (drawState.mode == DrawMode.draw
                  ? kBottomChromeClusterHeight + MasiSpacing.sm
                  : 0.0)
        : 0.0;

    return Column(
      children: [
        // The canvas + [RouteLegend] region: [RouteLegend] is now
        // PERMANENTLY a floating, translucent [GlassChrome] overlay pinned
        // near the bottom via a [Stack] (whenever routes exist) — it never
        // reflows or resizes the canvas beneath it, regardless of zoom.
        // [TopoCanvas] itself fills this ENTIRE `Flexible` region via
        // `Positioned.fill`, full-bleed to the screen edges (under the
        // floating top/bottom chrome and the status bar — see
        // [TopoCanvas.build]'s own doc for why it no longer clips to a
        // rounded, inset frame). `BoxFit.contain` on the image (unchanged)
        // still keeps the WHOLE wall visible; the only non-image area is
        // any letterbox from an aspect mismatch, which falls against the
        // Scaffold's own `ground` fill showing through.
        //
        // `Flexible(fit: FlexFit.tight)` rather than `Expanded` here
        // deliberately: it fills the remaining Column space identically
        // (`Expanded` IS just `Flexible(fit: FlexFit.tight)` — see its own
        // source), but as a DIFFERENT runtime type, so it doesn't get
        // confused with an `Expanded` ancestor elsewhere in this subtree.
        Flexible(
          fit: FlexFit.tight,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final innerAvailableHeight = constraints.maxHeight;
              // The reserved chrome-clearance must never exceed the height
              // that actually exists, or the bottom offset alone (applied
              // unconditionally, regardless of the legend's own height)
              // could push the floating overlay's `Positioned` bounds
              // negative on an extremely short viewport. On absurdly tiny
              // viewports the legend is allowed to degrade toward zero
              // visible height; a negative/invalid `Positioned` offset is
              // not.
              final effectiveLegendBottomPadding = math.max(
                0.0,
                math.min(legendBottomPadding, innerAvailableHeight),
              );
              final overlayLegendMaxHeight =
                  innerAvailableHeight * kLegendMaxHeightFraction;

              final canvasStack = TopoCanvas(
                key: canvasKey,
                wallId: wallId,
                imagePath: imagePath,
                imageSize: imageSize,
                transformationController: transformationController,
              );

              // The canvas ALWAYS takes the entire region (no row reserved
              // for RouteLegend below it — the image fills the whole
              // screen, permanently) and RouteLegend floats on top instead,
              // via a Positioned overlay that takes no layout space. Gated
              // on `hasRoutes` so an empty wall doesn't float a useless
              // empty glass chip.
              return Stack(
                children: [
                  Positioned.fill(child: canvasStack),
                  // Fix 1/3 (legend expand/collapse): the full RouteLegend
                  // card and the compact chip are mutually exclusive views of
                  // the SAME `legendExpandedProvider` state, not two
                  // independently-toggled widgets — exactly one of them (or
                  // neither, when `!hasRoutes`) is ever in the tree at once.
                  // `topo-route-legend-overlay` lives ONLY on the expanded
                  // card (not on this outer Positioned) so a widget-test
                  // finder for that key is a true "is the full card showing"
                  // signal — absent while only the collapsed chip
                  // (`topo-route-legend-chip`) is present.
                  if (hasRoutes && !embedded)
                    Positioned(
                      left: MasiSpacing.md,
                      right: MasiSpacing.md,
                      bottom: effectiveLegendBottomPadding,
                      child: legendExpanded
                          ? GlassChrome(
                              key: const Key('topo-route-legend-overlay'),
                              strong: true,
                              // `Material(type: transparency)` — required so
                              // RouteLegend's ListTiles have a Material
                              // ANCESTOR closer than the Scaffold's own:
                              // without it, GlassChrome's own colored/
                              // blurred Container sits BETWEEN each ListTile
                              // and the nearest Material (the Scaffold's),
                              // which Flutter flags as a debug assertion
                              // ("ListTile background color or ink splashes
                              // may be invisible") since that opaque layer
                              // would paint over — and hide — the
                              // ListTile's own background/ink-splash
                              // effects.
                              child: Material(
                                type: MaterialType.transparency,
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    _LegendHeader(
                                      routeCount: drawState.routes.length,
                                      onToggle: () => ref
                                          .read(legendExpandedProvider(wallId).notifier)
                                          .toggle(),
                                    ),
                                    RouteLegend(
                                      wallId: wallId,
                                      maxHeight: overlayLegendMaxHeight,
                                      readOnly: readOnly,
                                      onLogAscent: onLogAscent,
                                    ),
                                  ],
                                ),
                              ),
                            )
                          : Align(
                              alignment: Alignment.centerLeft,
                              child: _LegendChip(
                                key: const Key('topo-route-legend-chip'),
                                routeCount: drawState.routes.length,
                                onTap: () => ref
                                    .read(legendExpandedProvider(wallId).notifier)
                                    .toggle(),
                              ),
                            ),
                    ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

/// `'$n route(s)'` label shared by [_LegendChip] and [_LegendHeader], so the
/// collapsed and expanded states of the legend always agree on wording.
String _routeCountLabel(int n) => '$n ${n == 1 ? 'route' : 'routes'}';

/// The collapsed form of the floating route-legend overlay (Fix 1/3): a
/// compact frosted pill showing just the route count, tappable to re-expand
/// [RouteLegend] via [legendExpandedProvider]. Shown instead of the full card
/// while [DrawMode.draw] is active (see [LegendExpandedController.setForMode])
/// or whenever the user has manually collapsed it, so the full route list
/// never sits over the surface the user is actively drawing on.
class _LegendChip extends StatelessWidget {
  const _LegendChip({super.key, required this.routeCount, required this.onTap});

  final int routeCount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    return GlassChrome(
      strong: true,
      padding: const EdgeInsets.symmetric(
        horizontal: MasiSpacing.md,
        vertical: MasiSpacing.sm,
      ),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                _routeCountLabel(routeCount),
                style: Theme.of(
                  context,
                ).textTheme.labelLarge?.copyWith(color: colors.ink),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: MasiSpacing.xs),
            MasiIcon('chevron_up', size: 18, color: colors.ink),
          ],
        ),
      ),
    );
  }
}

/// The expanded [RouteLegend] card's header (Fix 1/3): a grab handle, the
/// route count, and a collapse chevron, tappable anywhere to collapse back to
/// [_LegendChip] via [legendExpandedProvider]. Lives INSIDE the card's own
/// `Material(type: transparency)` (see the legend-overlay build site) so its
/// [InkWell] gets a splash.
class _LegendHeader extends StatelessWidget {
  const _LegendHeader({required this.routeCount, required this.onToggle});

  final int routeCount;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    return InkWell(
      onTap: onToggle,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          MasiSpacing.sm,
          MasiSpacing.xs,
          MasiSpacing.xs,
          MasiSpacing.xs,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Center(
              child: Container(
                width: 32,
                height: 4,
                decoration: BoxDecoration(
                  color: colors.ink3,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: MasiSpacing.xs),
            Row(
              children: [
                Flexible(
                  child: Text(
                    _routeCountLabel(routeCount),
                    style: Theme.of(
                      context,
                    ).textTheme.labelLarge?.copyWith(color: colors.ink),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const Spacer(),
                MasiIcon('chevron_down', size: 18, color: colors.ink),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
