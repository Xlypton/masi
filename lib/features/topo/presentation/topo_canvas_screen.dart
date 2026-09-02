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
import 'package:masi/core/db/storage_durability_provider.dart';
import 'package:masi/core/platform/ar_support.dart';
import 'package:masi/core/location/location_service.dart';
import 'package:masi/features/library/application/library_providers.dart';
import 'package:masi/features/library/data/library_crud_repository.dart';
import 'package:masi/features/import/application/pending_import_providers.dart';
import 'package:masi/features/import/presentation/guidebook_import_sheet.dart';
import 'package:masi/features/library/presentation/set_location_picker.dart';
import 'package:masi/features/logbook/presentation/log_ascent_sheet.dart';
import 'package:masi/features/moderation/application/moderation_providers.dart';
import 'package:masi/features/moderation/application/suggestion_providers.dart';
import 'package:masi/features/moderation/domain/edit_suggestion.dart';
import 'package:masi/features/moderation/domain/geometry_proposal.dart';
import 'package:masi/features/moderation/presentation/moderation_banner.dart';
import 'package:masi/features/topo/application/draw_controller.dart';
import 'package:masi/features/topo/application/draw_hint_providers.dart';
import 'package:masi/features/topo/data/image_dimensions.dart';
import 'package:masi/features/topo/data/photo_repository.dart';
import 'package:masi/features/topo/data/photo_write_exception.dart';
import 'package:masi/features/topo/domain/topo_route.dart';
import 'package:masi/features/topo/presentation/canvas_chrome.dart';
import '../application/face_layout_providers.dart';
import 'package:masi/features/topo/domain/face_layout/layout_resolver.dart';
import 'face_lane.dart';
import 'package:masi/features/topo/presentation/photo_source_sheet.dart';
import 'package:masi/features/topo/presentation/route_legend.dart';
import 'package:masi/features/topo/presentation/route_metadata_sheet.dart';
import 'package:masi/features/topo/presentation/symbol_palette_bar.dart';
import 'package:masi/features/topo/presentation/topo_canvas.dart';
import 'package:masi/features/topo/presentation/topo_canvas_gps.dart';
import 'package:masi/features/topo/presentation/topo_canvas_photo_ops.dart';
import 'package:masi/shared/presentation/masi_async_view.dart';
import 'package:masi/shared/presentation/bottom_safe_inset.dart';
import 'package:masi/shared/presentation/masi_dialogs.dart';
import 'package:masi/shared/presentation/masi_icon.dart';
import 'package:masi/shared/presentation/masi_toast.dart';
import 'package:masi/shared/presentation/masi_loading_gate.dart';
import 'package:masi/shared/presentation/masi_loading_indicator.dart';
import 'package:masi/shared/presentation/masi_pending_button.dart';
import 'package:masi/shared/presentation/masi_skeleton.dart';

// Split out of this god-file (pure refactor, zero behavior change): GPS
// capture helpers moved to `topo_canvas_gps.dart`, and the selected-image
// provider + photo-attach helpers moved to `topo_canvas_photo_ops.dart`.
// Re-exported here so every existing importer of this file (e.g.
// `topos_screen.dart`'s `show captureWallGpsFromPhoto,
// gpsCaptureResultSnackBar`, and this feature's own tests) keeps resolving
// with no edit required on their end.
export 'topo_canvas_gps.dart';
export 'topo_canvas_photo_ops.dart';

/// A [SnackBar] presenting [error]'s [RouteLoadException.userMessage] behind a
/// warning glyph — the READ-side sibling of `topo_canvas_photo_ops.dart`'s
/// [photoWriteFailureSnackBar]/[routeWriteFailureSnackBar], deliberately the
/// same shape for the same reason those two share theirs: one device problem
/// must not read as three unrelated faults.
///
/// Lives HERE rather than beside its two siblings because it has exactly one
/// consumer — [TopoCanvasScreen]'s `lastLoadFailure` listener. The other two
/// were hoisted into `topo_canvas_photo_ops.dart` specifically because BOTH
/// photo-attach entry points (this screen and `topos_screen.dart`'s
/// `_handleNewTopo`) had to present identical words; no second screen loads
/// routes, so hoisting this one would move it away from its only caller for
/// no gain.
SnackBar routeLoadFailureSnackBar(RouteLoadException error) {
  return masiToast(error.userMessage, kind: MasiToastKind.error);
}

// Theme-follow fix: the canvas backdrop used to be a hardcoded near-black
// (`_kCanvasBackdrop = Color(0xFF121316)`) regardless of the app's
// light/dark theme. The Scaffold below now uses `colors.ground` — the same
// theme-derived token the empty-state placeholder ([_buildEmptyState]) has
// always used — so the canvas follows the theme like every other screen.

/// Where the line currently on the canvas should be saved, when a route is
/// selected that ALREADY has one and the two readings genuinely differ.
///
/// Only reachable from that one ambiguous case: with nothing selected, or
/// with an unplaced route selected, there is exactly one sensible answer and
/// `_handleCommitRoute` takes it without asking.
/// The two readings of a freshly drawn line on a rock that already has
/// climbs on its other faces.
enum _NewOrExisting { newClimb, existingClimb }

enum _DraftTarget {
  /// Replace the selected route's geometry, keeping its identity and
  /// metadata.
  selectedRoute,

  /// Ignore the selection and commit a new, separately-numbered route — the
  /// behaviour every commit had before a selection could claim the draft.
  newRoute,
}

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
    @visibleForTesting this.photoSourcePicker = showPhotoSourceSheet,
    @visibleForTesting this.photoPicker = pickPhotoFrom,
  });

  /// The wall this canvas is bound to (from the `/walls/:wallId` route).
  /// Routes/photos loaded and attached by this screen are always scoped to
  /// this wall — see [loadWallOriginalPhoto] and [_attachPhotoAndLoad].
  final String wallId;

  /// TEST-ONLY seams for the two native choosers [_pickImage] drives: the
  /// Camera/Library action sheet and the picker itself. They default to the
  /// real module-level [showPhotoSourceSheet]/[pickPhotoFrom], so production
  /// behavior is bit-identical and no call site changes.
  ///
  /// They exist because both defaults are native OS surfaces that
  /// `flutter_test` cannot drive, which left [_attachPhotoAndLoad]'s
  /// `on PhotoWriteException` clause — the whole user-visible half of the L3
  /// fix on this screen — with no way to be reached from a test at all. It was
  /// consequently deletable with the entire suite still green. These two
  /// parameters are the smallest seam that closes that hole, and they
  /// deliberately mirror `ToposScreen`'s long-standing
  /// `photoSourcePicker`/`photoPicker` pair (same names, same signatures, same
  /// defaults) rather than inventing a second convention.
  final Future<ImageSource?> Function(BuildContext) photoSourcePicker;
  final Future<XFile?> Function(ImageSource) photoPicker;

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

  /// True from the instant a picked photo starts being attached
  /// ([_attachPickedPhoto]: decode + `attachPhotoToWall` + GPS capture +
  /// `loadForWall`) until that whole chain settles — the longest wait in the
  /// app, and until this existed the most invisible: [_pickImage] fired it
  /// fire-and-forget, so both "Add a photo" affordances stayed idle and
  /// re-tappable for the entire time.
  ///
  /// Deliberately NOT `MasiPendingButton` at those two call sites (which is the
  /// house pattern for an awaiting button): the tap does not start the wait. It
  /// opens the OS photo-source sheet and then the system picker, which stay up
  /// for as long as the user browses — a button that disabled itself and span a
  /// spinner from the tap would be reporting "loading" while it is in fact the
  /// app that is waiting for a human. This flag brackets exactly the machine
  /// part, and drives the same two effects (disabled + a gated inline cue) on
  /// both controls.
  bool _attachInFlight = false;

  /// Whether [_loadInitialPhotoForWall] has finished (successfully or not).
  ///
  /// Read by [build] to tell "this wall has no photo" from "this wall's photo
  /// has not arrived yet" — the empty state must only ever claim the former.
  /// Set on the failure path too, on purpose: a load that threw is not a photo
  /// still coming, and a placeholder that shimmers forever is its own lie.
  bool _initialPhotoLoadSettled = false;

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
      // Fill the moderation mirror for this wall so the banner above the
      // canvas has something to say. `wall_moderation` is pull-only and
      // nothing else on this route fetches it, so without this the banner is
      // permanently blank on a deep link or a cold start — which is
      // indistinguishable from "your topo is fine".
      //
      // Fire-and-forget, and guarded all the way down to the provider reads —
      // see `refreshWallModerationFrom`. A canvas that failed to open because
      // a banner could not fetch its data would be a spectacularly bad trade.
      refreshWallModerationFrom(ref, {widget.wallId});
    });
  }

  /// Forces [DrawState.mode] back to [DrawMode.view]. See [initState]'s doc
  /// for why this must run once per fresh screen mount (and again from
  /// [didUpdateWidget] on a wallId change) rather than relying on
  /// [DrawController.beginPhotoSwitch], which deliberately preserves mode
  /// across an in-screen photo swap.
  void _resetToViewMode() {
    ref
        .read(drawControllerProvider(widget.wallId).notifier)
        .setMode(DrawMode.view);
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
    ref
        .read(legendExpandedProvider(widget.wallId).notifier)
        .setForMode(DrawMode.view);
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
  /// Pending-state note: this method IS the future `topo-commit-button`'s
  /// [MasiPendingButton] waits on, so it must resolve when the WRITE resolves.
  /// [DrawController.commitRoute] awaits a real repository upsert (see its
  /// write-through doc), which is the thing worth showing progress for and the
  /// thing a double-tap would otherwise run twice. The metadata sheet that
  /// follows is deliberately NOT awaited here: it is a modal the climber drives,
  /// and folding it into the pending future would keep the button disabled and
  /// spinning for as long as they were typing a route name.
  /// The photos on which the climber has already said "a new climb" — see
  /// [_handleCommitRoute]. Per visit to this screen, deliberately: it is a
  /// question about what they are doing right now, not a preference.
  final Set<String> _askedWhichClimbFor = <String>{};

  Future<void> _handleCommitRoute() async {
    if (widget.readOnly) return;
    final notifier = ref.read(drawControllerProvider(widget.wallId).notifier);

    // A SELECTED route can claim the line instead of a new one being made —
    // see [DrawController.commitRoute]. Which of the two happens is settled
    // here, because only one of the cases is ambiguous:
    //
    //  * Nothing selected -> a new route, as always.
    //  * An UNPLACED route selected (the guidebook-import case this exists
    //    for) -> it gets the line, with no prompt. Nothing is destroyed and
    //    there is no second reading to choose between.
    //  * A selected route that already HAS a line -> genuinely ambiguous, and
    //    one of the answers overwrites work. Ask.
    // And a fourth reading, which nothing on this screen used to ASK about:
    // the line just drawn is a climb that already exists on another face of
    // this same rock. The control for it sits above the tools while drawing,
    // and twice now it has gone unfound — so on a wall where the question is
    // live, the save itself puts it. Once per photo: answer "a new climb"
    // and the ✓ goes straight through for the rest of this visit, because
    // somebody drawing ten new lines on the second face should be asked
    // once, not ten times.
    final photoId = ref
        .read(drawControllerProvider(widget.wallId))
        .activePhotoId;
    final elsewhere = photoId == null
        ? const <TopoRoute>[]
        : ref
                  .read(
                    climbsElsewhereProvider((
                      wallId: widget.wallId,
                      photoId: photoId,
                    )),
                  )
                  .value ??
              const <TopoRoute>[];
    if (notifier.pendingDraftTarget == null &&
        elsewhere.isNotEmpty &&
        photoId != null &&
        !_askedWhichClimbFor.contains(photoId)) {
      final choice = await showMasiActionSheet<_NewOrExisting>(
        context,
        sheetKey: const Key('topo-new-or-existing-sheet'),
        title: 'Is this a new climb?',
        message:
            'This rock has climbs drawn on its other photos. A line here can '
            'be one of them, seen from this side — same number, same name, '
            'same grade — or a climb of its own.',
        actions: const [
          MasiSheetAction(
            key: Key('topo-new-or-existing-new'),
            label: 'A new climb',
            value: _NewOrExisting.newClimb,
          ),
          MasiSheetAction(
            key: Key('topo-new-or-existing-same'),
            label: 'A climb I already have…',
            value: _NewOrExisting.existingClimb,
          ),
        ],
      );
      // Dismissed: the line stays on the canvas, undamaged, and nothing is
      // written — same rule as the prompt below.
      if (!mounted || choice == null) return;
      if (choice == _NewOrExisting.existingClimb) {
        await _handleLinkToExistingClimb(elsewhere);
        return;
      }
      _askedWhichClimbFor.add(photoId);
    }

    final target = notifier.pendingDraftTarget;
    var replaceSelectedLine = false;
    if (target != null && target.overwritesLine) {
      final choice = await showMasiActionSheet<_DraftTarget>(
        context,
        title: 'Save this line to which route?',
        message:
            '${routeDisplayLabel(target.route)} already has a line. Saving to '
            'it replaces that line; its name, grade and number stay.',
        actions: [
          MasiSheetAction(
            key: const Key('topo-draft-target-replace'),
            label: 'Replace ${routeDisplayLabel(target.route)}',
            value: _DraftTarget.selectedRoute,
            isDestructive: true,
          ),
          const MasiSheetAction(
            key: Key('topo-draft-target-new'),
            label: 'Add as a new route',
            value: _DraftTarget.newRoute,
          ),
        ],
      );
      // Dismissing the sheet cancels the save outright rather than silently
      // picking one of the two — the line stays on the canvas, undamaged, and
      // the climber can press save again once they have decided.
      if (!mounted || choice == null) return;
      replaceSelectedLine = choice == _DraftTarget.selectedRoute;
    }

    // Which route (if any) the line is about to land on, resolved BEFORE the
    // commit empties the draft that `pendingDraftTarget` depends on.
    final targetId =
        (target != null && (replaceSelectedLine || !target.overwritesLine))
        ? target.route.id
        : null;
    final countBefore = ref
        .read(drawControllerProvider(widget.wallId))
        .routes
        .length;
    await notifier.commitRoute(replaceSelectedLine: replaceSelectedLine);
    if (!mounted) return;

    final routes = ref.read(drawControllerProvider(widget.wallId)).routes;

    if (targetId != null) {
      // The line went onto a route that already existed, so there is no new
      // route to name: it keeps the name, grade and number it already had,
      // which is the entire reason it was there waiting to be drawn. No
      // metadata sheet, just confirmation of where the line landed.
      notifier.setMode(DrawMode.view);
      for (final route in routes) {
        if (route.id != targetId) continue;
        // Only when the write actually landed. A refused one already reverts
        // the geometry and raises its own message (UF-1), and two snackbars
        // for one action is one message too many.
        if (route.points.length >= 2) {
          ScaffoldMessenger.of(context).showMasiToast(
            'Line saved to ${routeDisplayLabel(route)}',
            kind: MasiToastKind.success,
          );
        }
        break;
      }
      return;
    }

    if (routes.length <= countBefore) return;

    notifier.setMode(DrawMode.view);
    unawaited(_openMetadataSheet(routes.last));
  }

  /// The bottom cluster's ✓. Commits whatever line is in progress and then
  /// leaves edit mode — the "save and I'm done" action.
  ///
  /// [_handleCommitRoute] already returns to [DrawMode.view] when it actually
  /// commits, but it no-ops on fewer than two points, and ✓ with nothing
  /// half-drawn must still close the editor rather than looking dead. That is
  /// the whole reason this wrapper exists: the ✓/✗ pair is now the ONLY way
  /// out of edit mode (2026-08-12 — the top row's Cancel/Save was the same
  /// thing said twice), so neither may be inert in any state. The mode is
  /// re-asserted unconditionally; it is idempotent when the commit already
  /// did it.
  /// Saves the drawn line as another face's view of a climb the wall already
  /// has — the answer to "this is climb 3, drawn here".
  ///
  /// The data model has carried this since v16: a climb's home drawing lives
  /// on its own row and every other face's drawing of it lives in
  /// `route_lines`. Nothing in the UI could ever ASK for it. The only way to
  /// reach the second-face write was to draw a line whose number happened to
  /// collide with an existing climb's — which the per-photo number seed made
  /// happen by accident, on an unrelated climb, wiping that climb's name and
  /// grade with the blank draft's (see [RouteRepository.maxRouteNumber]).
  /// Fixing the seed closes the accident; this opens the door the accident
  /// was coming through.
  ///
  /// The picked climb is passed whole to the controller so its name, grade
  /// and colour come back unchanged — the shared-field fold in `upsertRoute`
  /// writes what it is given.
  Future<void> _handleLinkToExistingClimb(List<TopoRoute> candidates) async {
    if (widget.readOnly || candidates.isEmpty) return;
    final notifier = ref.read(drawControllerProvider(widget.wallId).notifier);
    final photoId = ref
        .read(drawControllerProvider(widget.wallId))
        .activePhotoId;
    if (photoId == null) return;

    final choice = await showMasiActionSheet<int>(
      context,
      sheetKey: const Key('topo-link-climb-sheet'),
      title: 'Which climb is this?',
      message:
          'The line stays on this photo. Its number, name and grade come '
          'from the climb you pick — this is that climb, seen from here.',
      actions: [
        for (final climb in candidates)
          MasiSheetAction(
            key: Key('topo-link-climb-${climb.number}'),
            label: routeDisplayLabel(climb),
            value: climb.number,
          ),
      ],
    );
    if (!mounted || choice == null) return;

    final climb = candidates.firstWhere((c) => c.number == choice);
    await notifier.commitDraftAsClimb(climb);
    if (!mounted) return;

    // The climb is on this photo now, so it is no longer a candidate for the
    // next line drawn here.
    ref.invalidate(
      climbsElsewhereProvider((wallId: widget.wallId, photoId: photoId)),
    );
    notifier.setMode(DrawMode.view);

    // Only when the write actually landed — a refused one reverts the
    // geometry and raises its own message (UF-1), and two messages for one
    // action is one too many.
    final saved = ref
        .read(drawControllerProvider(widget.wallId))
        .routes
        .where((r) => r.number == climb.number)
        .any((r) => r.points.length >= 2);
    if (!saved) return;
    ScaffoldMessenger.of(context).showMasiToast(
      '${routeDisplayLabel(climb)} is on this photo too.',
      kind: MasiToastKind.success,
      key: const Key('topo-link-climb-saved'),
    );
  }

  /// "That is not its own climb — it is one this rock already has."
  ///
  /// The way back from a line saved as a new climb when it was meant to be a
  /// second view of an existing one. Until this existed the row was stuck:
  /// an unnamed 'Route 9' on the second photo of a wall whose first photo
  /// already carried that climb under its real name, and every way of saying
  /// so happened BEFORE the save.
  Future<void> _handleSameClimbAs(int routeId) async {
    if (widget.readOnly) return;
    final state = ref.read(drawControllerProvider(widget.wallId));
    final photoId = state.activePhotoId;
    if (photoId == null) return;
    final mine = state.routes.where((r) => r.id == routeId).firstOrNull;
    if (mine == null) return;

    // Read fresh rather than off the cached provider: this runs long after
    // the screen was built, and the climb the contributor is about to name
    // may have been drawn on another face since.
    final candidates = await ref
        .read(routeRepositoryProvider)
        .loadClimbsElsewhere(widget.wallId, photoId);
    if (!mounted) return;
    if (candidates.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          key: Key('topo-same-climb-none'),
          content: Text('No climb on the other photos of this rock to be.'),
        ),
      );
      return;
    }

    final choice = await showMasiActionSheet<int>(
      context,
      sheetKey: const Key('topo-same-climb-sheet'),
      title: 'Which climb is this?',
      message:
          '${routeDisplayLabel(mine)} becomes that climb\'s line on this '
          'photo. Its number, name and grade come from the climb you pick.',
      actions: [
        for (final climb in candidates)
          MasiSheetAction(
            key: Key('topo-same-climb-${climb.number}'),
            label: routeDisplayLabel(climb),
            value: climb.number,
          ),
      ],
    );
    if (!mounted || choice == null) return;

    final climb = candidates.firstWhere((c) => c.number == choice);
    // One climb becoming another is two writes, and the first one destroys
    // something — anything logged against the old number goes with it. So
    // this asks, in the words of what is actually lost.
    final confirmed = await showMasiConfirm(
      context,
      title: 'Merge into ${routeDisplayLabel(climb)}?',
      message:
          '${routeDisplayLabel(mine)} stops being its own climb. Its line '
          'stays on this photo as ${routeDisplayLabel(climb)}, and anything '
          'logged against ${routeDisplayLabel(mine)} goes with it.',
      confirmLabel: 'Merge',
      confirmKey: const Key('topo-same-climb-confirm'),
    );
    if (!mounted || !confirmed) return;

    await ref
        .read(drawControllerProvider(widget.wallId).notifier)
        .mergeRouteIntoClimb(routeId, climb);
    if (!mounted) return;
    ref.invalidate(
      climbsElsewhereProvider((wallId: widget.wallId, photoId: photoId)),
    );
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        key: const Key('topo-same-climb-merged'),
        content: Text('${routeDisplayLabel(climb)} is on this photo too.'),
      ),
    );
  }

  Future<void> _handleFinishEditing() async {
    if (widget.readOnly) return;
    final hint = ref.read(drawHintProvider.notifier);
    await _handleCommitRoute();
    if (!mounted) return;
    ref
        .read(drawControllerProvider(widget.wallId).notifier)
        .setMode(DrawMode.view);
    // They have drawn a route, so the beginner nudge has done its job and
    // retires for good. Also clears any hint still on screen — leaving draw
    // mode means the advice no longer applies.
    hint.dismiss();
    unawaited(hint.markRouteDrawn());
  }

  /// The bottom cluster's ✗, which does one of two things depending on
  /// whether there is a line in progress — and the split is deliberate, not
  /// an accident of implementation.
  ///
  ///  * **Something half-drawn** -> discard just that line and STAY in edit
  ///    mode. Scrapping a bad line and immediately drawing another is the
  ///    single most common thing anyone does on this screen, and kicking them
  ///    back to view mode every time would make drawing a wall of ten routes
  ///    an exercise in re-entering the editor.
  ///  * **Nothing half-drawn** -> leave edit mode. There is nothing to
  ///    discard, so the only reading left for "✗" is "cancel out of editing",
  ///    and a button that does nothing at all in a state you can sit in
  ///    indefinitely is worse than one that does the obvious thing.
  ///
  /// Committed routes are untouched either way: this canvas persists a route
  /// the moment it is committed (see [DrawController.commitRoute]'s
  /// write-through), so there is no edit session to roll back and this makes
  /// no pretence of rolling one back. The tooltip says which of the two it
  /// currently is.
  void _handleCancelEditing() {
    if (widget.readOnly) return;
    final notifier = ref.read(drawControllerProvider(widget.wallId).notifier);
    if (ref.read(drawControllerProvider(widget.wallId)).currentPoints.isEmpty) {
      notifier.setMode(DrawMode.view);
      return;
    }
    notifier.clearCurrent();
  }

  /// [_openMetadataSheet] by [TopoRoute.id] — what [RouteLegend.onEditRoute]
  /// hands back, since a legend row knows its route's id and nothing else.
  ///
  /// Silently does nothing if that id is no longer in [DrawState.routes]
  /// (a race with a concurrent delete, or a photo switch landing between the
  /// tap and this call). `firstWhere` without an `orElse` would throw there,
  /// and a crash is a poor answer to "the row you tapped just went away".
  void _openMetadataSheetForId(int routeId) {
    final routes = ref.read(drawControllerProvider(widget.wallId)).routes;
    for (final route in routes) {
      if (route.id == routeId) {
        unawaited(_openMetadataSheet(route));
        return;
      }
    }
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
      ScaffoldMessenger.of(context).showMasiToast(
        'Route is still saving — try again in a moment.',
        kind: MasiToastKind.warning,
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
  /// Opens the guidebook-import sheet for [photoId] and, if routes were
  /// added, reloads this photo's route set.
  ///
  /// The reload is not optional. The import writes through
  /// [RouteRepository.upsertRoute] directly rather than through
  /// [DrawController], so the controller's in-memory `routes` list — and the
  /// "next number" counter it seeds from that list — are both stale the moment
  /// the sheet returns. Without [DrawController.loadForWall] the new routes
  /// simply would not appear, and the next hand-drawn route would be numbered
  /// on top of one of them.
  Future<void> _handleImportFromGuidebook(String photoId) async {
    if (widget.readOnly) return;

    // A page queued from the chat app takes priority over the paste flow: the
    // user already did the work elsewhere, so opening a "copy this prompt"
    // screen on top of a waiting import would be asking them to repeat it.
    final pending = ref
        .read(pendingImportsProvider(widget.wallId))
        .asData
        ?.value;
    final queued = (pending == null || pending.isEmpty) ? null : pending.first;

    final result = await showGuidebookImportSheet(
      context,
      wallId: widget.wallId,
      photoId: queued?.photoId ?? photoId,
      initial: queued?.import,
      pendingId: queued?.id,
    );

    // Whether it was applied or discarded, the queue has moved on.
    ref.invalidate(pendingImportsProvider(widget.wallId));

    if (result == null || !mounted) return;

    await ref
        .read(drawControllerProvider(widget.wallId).notifier)
        .loadForWall(widget.wallId, photoId);
    if (!mounted) return;

    final drawn = result.unplaced > 0 ? ' · ${result.unplaced} to draw' : '';
    ScaffoldMessenger.of(context).showMasiToast(
      'Added ${result.added} route${result.added == 1 ? '' : 's'}$drawn',
      kind: MasiToastKind.success,
      key: const Key('topo-import-applied'),
    );
  }

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
      ScaffoldMessenger.of(context).showMasiToast(
        "Couldn't save location — please try again",
        kind: MasiToastKind.error,
      );
      return;
    }
    if (!mounted) return;

    ScaffoldMessenger.of(
      context,
    ).showMasiToast('Location saved', kind: MasiToastKind.success);
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
  ///
  /// The attach is now AWAITED (it was `unawaited`) and bracketed by
  /// [_attachInFlight], so both add-photo controls disable themselves and show a
  /// gated progress cue for the whole decode + copy + insert + GPS + load chain
  /// instead of looking idle through it. Awaiting changes no ordering: the path
  /// is still selected first (so the canvas switches over immediately), and the
  /// attach still runs after.
  Future<void> _pickImage() async {
    if (widget.readOnly) return;
    // Re-entrancy guard, independent of the visual gate below: during the
    // reveal delay the controls look idle but an attach is very much running.
    if (_attachInFlight) return;
    final source = await widget.photoSourcePicker(context);
    if (source == null || !mounted) return;
    final xfile = await widget.photoPicker(source);
    if (xfile == null || !mounted) return;
    ref.read(selectedImageProvider.notifier).select(xfile.path);
    setState(() => _attachInFlight = true);
    try {
      await _attachPickedPhoto(xfile);
    } finally {
      if (mounted) setState(() => _attachInFlight = false);
    }
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
    } finally {
      // Records that the question "does this wall have a photo?" has been
      // answered — see [_initialPhotoLoadSettled]. setState, not a bare
      // assignment: [build] reads it to choose between the empty state and the
      // still-loading placeholder, and nothing else necessarily rebuilds here
      // (a photo-less wall's providers emit no further values).
      if (mounted) setState(() => _initialPhotoLoadSettled = true);
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
  ///
  /// L3 fix (photo-byte write failures): a [PhotoWriteException] out of
  /// [LibraryCrudRepository.attachPhotoToWall] is caught in its OWN clause,
  /// above the catch-all — it is the one failure with a specific, actionable
  /// cause to tell the user about (out of storage space), and it is the one
  /// failure that additionally requires clearing `selectedImageProvider`,
  /// since the optimistically-selected picked path has no row behind it and
  /// never will. Both effects plus the SnackBar come from the single
  /// [settleFailedPhotoAttach] call, which settles [generation] exactly like
  /// every other exit path in this method must.
  Future<void> _attachPhotoAndLoad(XFile xfile, int width, int height) async {
    final generation = ref
        .read(drawControllerProvider(widget.wallId))
        .switchGeneration;
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
        // Also records this photo's OWN fix, accuracy and heading, which is
        // what the face layout is arranged from. Same parse, different
        // question: the wall pin says which crag, the face metadata says
        // where round the rock this shot was taken.
        photoId: photoId,
        photoRepo: ref.read(photoRepositoryProvider),
      );
      if (!mounted) return;
      // Surfaces the outcome regardless of the latest-path guard below —
      // it's telling the user what just happened to THIS wall's location,
      // which is true no matter which photo they've since moved on to.
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(gpsCaptureResultSnackBar(gpsResult));
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
    } on PhotoWriteException catch (e) {
      // L3 fix: attachPhotoToWall PROPAGATES a byte-write failure now (quota
      // exhaustion above all — originals stay FULL resolution per decision
      // D-5) and throws BEFORE its insert transaction, so no Photos row was
      // created and there is nothing to undo in the database. What DOES need
      // undoing is the optimistic UI: _pickImage already selected the picked
      // path so this screen would show a spinner for an image that will never
      // have a row. settleFailedPhotoAttach clears it, settles the switch
      // generation THIS call opened (see this method's FIX #4 doc — every exit
      // path must), and hands back the SnackBar to show. Deliberately caught
      // ABOVE the generic clause below so a quota problem gets its own
      // actionable wording instead of the silent debugPrint every other
      // failure still gets. Only while mounted — see this method's doc for why
      // `ref` is unsafe to touch otherwise.
      debugPrint('Failed to store photo bytes for ${xfile.path}: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          settleFailedPhotoAttach(
            ref.read(selectedImageProvider.notifier),
            ref.read(drawControllerProvider(widget.wallId).notifier),
            generation,
            e,
          ),
        );
      }
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

  /// Opens the plan view, and switches to whatever face the reader chose
  /// there.
  ///
  /// The map screen writes nothing — it pops the id back (or `null` if they
  /// backed out) and this switches the canvas, which keeps every path that
  /// changes the shown photo running through [_switchToPhoto].
  Future<void> _openFaceMap(List<PhotoRef> photos) async {
    final active = ref
        .read(drawControllerProvider(widget.wallId))
        .activePhotoId;
    final chosen = await context.push<String>(
      Uri(
        path: '/walls/${widget.wallId}/faces',
        queryParameters: <String, String>{
          'photo': ?active,
          if (widget.readOnly) 'readonly': '1',
        },
      ).toString(),
    );
    if (!mounted || chosen == null) return;
    for (final photo in photos) {
      if (photo.id == chosen) {
        await _switchToPhoto(photo);
        return;
      }
    }
  }

  /// U4 (manage menu): promotes [photo] to [TopoCanvasScreen.wallId]'s
  /// cover/primary photo. Purely a bookkeeping flag — it does NOT switch
  /// which photo is currently shown on the canvas (see
  /// [PhotoRepository.setPrimaryPhoto]'s doc); [wallOriginalsProvider]'s
  /// live stream re-emits on its own, so the strip's star badge moves to
  /// [photo] the moment this write lands.
  /// Long-press on a face dot: the photo-management actions that used to
  /// hang off each strip tile.
  ///
  /// Navigation moved to the dots and the minimap, but adding, re-covering
  /// and deleting a photo still have to live somewhere, and the dot is the
  /// only thing on screen that stands for exactly one photo. A sheet rather
  /// than a popup menu because the dot is 7px wide and an anchored menu would
  /// have nothing to anchor to.
  Future<void> _showFaceMenu(PhotoRef photo) async {
    if (widget.readOnly) return;
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              key: const Key('face-menu-add'),
              leading: const MasiIcon('image_add'),
              title: const Text('Add a photo'),
              onTap: () => Navigator.of(context).pop('add'),
            ),
            if (!photo.isPrimary)
              ListTile(
                key: const Key('face-menu-cover'),
                leading: const MasiIcon('star'),
                title: const Text('Set as cover'),
                onTap: () => Navigator.of(context).pop('cover'),
              ),
            ListTile(
              key: const Key('face-menu-layout'),
              leading: const MasiIcon('topo_map'),
              title: const Text('Edit layout'),
              onTap: () => Navigator.of(context).pop('layout'),
            ),
            ListTile(
              key: const Key('face-menu-delete'),
              leading: const MasiIcon('delete'),
              title: const Text('Delete photo'),
              onTap: () => Navigator.of(context).pop('delete'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'add':
        await _pickImage();
      case 'cover':
        await _handleSetCoverPhoto(photo);
      case 'layout':
        if (mounted) context.push('/walls/${widget.wallId}/layout');
      case 'delete':
        await _handleDeletePhoto(photo);
    }
  }

  Future<void> _handleSetCoverPhoto(PhotoRef photo) async {
    if (widget.readOnly) return;
    try {
      await ref
          .read(photoRepositoryProvider)
          .setPrimaryPhoto(widget.wallId, photo.id);
    } catch (e, st) {
      debugPrint('Failed to set cover photo ${photo.id}: $e\n$st');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showMasiToast(
        "Couldn't update cover photo — please try again",
        kind: MasiToastKind.error,
      );
      return;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showMasiToast('Cover photo updated', kind: MasiToastKind.success);
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
    final wasActiveOrInFlight =
        drawState.activePhotoId == photo.id ||
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
      ScaffoldMessenger.of(context).showMasiToast(
        "Couldn't delete photo — please try again",
        kind: MasiToastKind.error,
      );
      return;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showMasiToast('Photo deleted', kind: MasiToastKind.success);
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
        ref
            .read(drawControllerProvider(widget.wallId).notifier)
            .beginPhotoSwitch();
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
          ref
              .read(legendExpandedProvider(widget.wallId).notifier)
              .setForMode(next);
        }
      },
    );

    // UF-1 (silent data loss), presentation half. [DrawController._writeThrough]
    // already stops the CORRUPTION — a route/marker/grade whose repository
    // write throws is reverted off the canvas and recorded on
    // [DrawState.lastWriteFailure] — but nothing read that record, so all the
    // climber saw was their line disappearing. This listener is what turns that
    // disappearance into an explanation, which is the actual invariant: if the
    // write failed, the climber is told.
    //
    // Deliberately the same shape as [_attachPhotoAndLoad]'s
    // `on PhotoWriteException` clause — same warning glyph, same one-sentence
    // frame, same "Out of storage space — … Free up space on this device and
    // try again." words for the same underlying problem (see
    // [routeWriteFailureSnackBar]/[RouteWriteException.userMessage]) — because
    // one out-of-room device can refuse the photo attach and then the route
    // commit in a single session, and two different-looking warnings for one
    // problem read as two unrelated faults.
    //
    // Fires for EVERY failure, including
    // [RouteWriteException.rolledBack] `false`. That case (the climber kept
    // drawing during the failed write, so reverting would have clobbered the
    // newer line) is the one where the canvas is knowingly ahead of the
    // database — the loss is invisible to the climber precisely because
    // nothing disappeared — so it is the LAST case that may be silent. It
    // deliberately gets the SAME words rather than its own: "this route was
    // not saved" is exactly as true whether or not the canvas reverted (the
    // rollback governs the screen, never whether the write landed), the
    // remedy is identical (free up space, save again), and the flag cannot
    // support a more specific sentence — `rolledBack: false` only means "the
    // revert was skipped because state moved on", NOT "the route is still on
    // screen": the mutation that moved state on may itself have been a
    // [DrawController.beginPhotoSwitch], which clears [DrawState.routes]. A
    // message asserting "it is still showing but will be gone" would therefore
    // be false some of the time, which is worse than one that is always true.
    //
    // No `fireImmediately` (Riverpod v3 has no such option on
    // [WidgetRef.listen], and the callback writes provider state, which is
    // forbidden mid-build — see the two listeners above). None is needed:
    // every write-through runs behind an `await`, and the only ones reachable
    // on a fresh canvas are kicked off from [initState]'s microtask, i.e.
    // strictly after this listener is registered by the first build.
    ref.listen<RouteWriteException?>(
      drawControllerProvider(widget.wallId).select((s) => s.lastWriteFailure),
      (previous, next) {
        if (next == null) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(routeWriteFailureSnackBar(next));
        // Clears the record now that it has been presented, per
        // [DrawState.lastWriteFailure]'s contract. Safe to call from here even
        // though the provider is autoDispose: a `ref.listen` subscription is
        // torn down with this widget, so this callback cannot run after the
        // canvas is popped and cannot resurrect the post-await write
        // [DrawController._writeThrough]'s own `ref.mounted` guard exists to
        // prevent.
        ref
            .read(drawControllerProvider(widget.wallId).notifier)
            .clearWriteFailure();
      },
    );

    // UF-2 (an unreadable topo presenting as an empty one), presentation half.
    //
    // [DrawController.loadForWall] now settles its switch and records
    // [DrawState.lastLoadFailure] instead of propagating (see its UF-2 doc for
    // the wrong-photo write that used to follow). That stops the CORRUPTION.
    // It does not, on its own, stop the LIE: `routes` is still empty, and an
    // empty canvas over a real photo says "this topo has no routes yet". A
    // climber who believes that redraws work that is sitting on disk unread.
    //
    // Two responses, because they answer two different questions:
    //  - the SnackBar answers "what just happened?" — same warning glyph and
    //    same one-sentence frame as the photo/route WRITE failures, since a
    //    climber can hit several in one session on one sick device;
    //  - `topo-routes-unavailable` (built below) answers "what am I looking at
    //    RIGHT NOW?", and unlike the SnackBar it stays for as long as the
    //    answer is "an incomplete route set". That is why this listener does
    //    NOT clear the record the way the write-failure listener above does —
    //    see [DrawState.lastLoadFailure]'s doc for the notification-versus-
    //    standing-property distinction.
    //
    // Also forces [DrawMode.view]. [DrawController.beginPhotoSwitch]
    // deliberately preserves `mode` across a switch (it's a tool choice, not
    // per-photo state), so a climber already drawing when the load failed
    // would otherwise be left holding a live pen over a topo whose real routes
    // nobody can see — the exact situation that produces duplicates. Writing
    // provider state from a `ref.listen` callback is fine (the write-failure
    // listener above does it); writing it during `build` would not be.
    ref.listen<RouteLoadException?>(
      drawControllerProvider(widget.wallId).select((s) => s.lastLoadFailure),
      (previous, next) {
        if (next == null) return;
        ref
            .read(drawControllerProvider(widget.wallId).notifier)
            .setMode(DrawMode.view);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(routeLoadFailureSnackBar(next));
      },
    );

    // Storage interlock, the canvas half of §1a. Non-null means the local
    // database is either known non-durable (in-memory: every write succeeds
    // and vanishes on reload) or could not be opened at all — so the editing
    // affordances below must not be offered. Same three-part shape as UF-2
    // directly above, for the same reason: forced back to view mode, the
    // control that enters draw mode hidden, and a standing notice saying why,
    // because a control that vanishes without a reason is its own bug.
    //
    // Deliberately NOT gating read-only interactions (pan/zoom, selecting a
    // route, the legend, AR): a session that cannot save is still worth
    // looking at, and blocking browsing buys no protection.
    final storageBlocked = storageBlockedNotice(
      ref.watch(storageDurabilityProvider),
    );
    // The verdict is normally final before this screen can mount — `bootApp`
    // awaits `verifyDatabaseUsable` before `runApp`. It can still flip
    // mid-session in one case: `main.dart`'s stalled-storage deadline
    // publishes `unavailable` ~30s in. Forcing view mode then is what stops a
    // climber being left holding a live pen over a database that has just
    // been declared unusable.
    ref.listen<String?>(
      storageDurabilityProvider.select(storageBlockedNotice),
      (previous, next) {
        if (next == null || previous != null) return;
        ref
            .read(drawControllerProvider(widget.wallId).notifier)
            .setMode(DrawMode.view);
      },
    );

    final imagePath = ref.watch(selectedImageProvider);
    // Web-perf fix (draw-gesture rebuild storm): `DrawState` has no
    // `operator==`, so watching the whole object made THIS screen (top
    // chrome, bottom chrome, route legend chip/card) rebuild on every single
    // `DrawController.addPoint()` call during a draw drag — including
    // `currentPoints`/`currentSymbols`/undo-redo churn nothing below actually
    // reads. Everything reachable from `drawState` in this build (directly
    // here, and via `_buildCanvasArea`→`TopoCanvasBody`,
    // `_buildTopChromeRow`→`_topTrailingActions`, and `_buildBottomChrome`
    // which only ever receives `drawState.mode`) only ever reads `mode`,
    // `routes`, `activePhotoId`, `selectedRouteId` (and, defensively,
    // `switchTargetPhotoId` — not currently read off THIS watched value, but
    // included to match the audited safe field set / future-proof against
    // drift). `.select`-ing a named-field record of just those means Riverpod
    // compares by the record's structural `==` and only rebuilds this widget
    // when one of them actually changes, never for a per-point mutation.
    // `TopoCanvas` (topo_canvas.dart) is UNAFFECTED: it holds its own,
    // independent `ref.watch(drawControllerProvider(wallId))` for the full
    // per-point state it needs to paint, so it keeps repainting on every
    // point exactly as before — only THIS screen's own chrome-rebuild is now
    // gated.
    ref.watch(
      drawControllerProvider(widget.wallId).select(
        (s) => (
          mode: s.mode,
          routes: s.routes,
          activePhotoId: s.activePhotoId,
          selectedRouteId: s.selectedRouteId,
          switchTargetPhotoId: s.switchTargetPhotoId,
          // Read below (via `TopoCanvasBody`, which receives the whole
          // `DrawState`) to show the photo-switch cue. Until it was part of
          // this record NOTHING in the widget tree read this flag at all, so
          // tapping a strip thumbnail flipped the image instantly and then sat
          // on an empty topo while `loadForWall` resolved — routes just popped
          // in, with no sign anything had been pending.
          isSwitchingPhoto: s.isSwitchingPhoto,
          // UF-2: read below by both the `topo-routes-unavailable` banner and
          // the mode-toggle gate, so it has to be part of what triggers a
          // rebuild here — otherwise the canvas would keep presenting itself
          // as a complete-but-empty topo until some unrelated field changed.
          lastLoadFailure: s.lastLoadFailure,
          // §3.2: drives the suggest/discard bar. `routes` above would
          // already catch an edit, but not the two cases where this map
          // changes on its OWN — a send clearing the routes it filed, and
          // `setProposalOnlyGeometryEdits` clearing everything when the
          // ownership answer changes. Without it the bar would linger over a
          // topo with nothing left to suggest.
          pendingProposalBaselines: s.pendingProposalBaselines,
          // A BOOL, deliberately — not `currentPoints`. It flips exactly
          // twice per line (at the second point, and when the draft is
          // consumed or discarded), so it costs two rebuilds rather than the
          // one-per-point storm this record exists to avoid. It has to be
          // here at all because the "this line is a climb I already have"
          // control appears only while there IS a line: gated on a value
          // nothing rebuilt for, it appeared a frame late at best, and in a
          // test that only draws, never at all.
          hasLine: s.currentPoints.length >= 2,
        ),
      ),
    );
    // One-shot read (not a watch) of the full object: everything downstream
    // that needs the real `DrawState` type (`TopoCanvasBody`'s public
    // `drawState` field, used directly by widget tests — see that class's
    // doc) still gets it, just without ALSO being a rebuild trigger on its
    // own; the `.select` watch above already governs when this widget
    // rebuilds, so this always reflects the current state exactly when this
    // method runs.
    final drawState = ref.read(drawControllerProvider(widget.wallId));
    final drawNotifier = ref.read(
      drawControllerProvider(widget.wallId).notifier,
    );
    // See `bottom_safe_inset.dart`: an installed iOS PWA reports a zero bottom
    // inset, so every SafeArea on this screen was contributing nothing.
    final standaloneBottomFloor = standaloneBottomFloorOf(ref);
    final drawHint = ref.watch(drawHintProvider);
    // The topo/wall name backs the canvas title (DESIGN.md "Topo canvas").
    // "Topo" is the fallback for a wall that genuinely has no name (or doesn't
    // exist — see router_test.dart's nonexistent-wall-id smoke test), so the
    // title is never blank and never shows the literal app name "Masi".
    //
    // What it is NOT any more is the fallback for "still loading": the old
    // `maybeWhen(..., orElse: 'Topo')` printed a wrong-but-plausible title for
    // a wall whose real name was on its way, so an opened topo read "Topo" and
    // then silently became "Kőbánya slab" — see `_buildTopChromeRow`, which
    // renders a shaped placeholder for that window instead.
    final wallNameAsync = ref.watch(wallNameProvider(widget.wallId));
    final wallName = wallNameAsync.hasValue ? wallNameAsync.requireValue : null;
    final title = (wallName == null || wallName.isEmpty) ? 'Topo' : wallName;
    final titlePending = wallNameAsync.isLoading && !wallNameAsync.hasValue;

    // Backs the "Edit location"/"Set location" button (_topTrailingActions'
    // topo-edit-location-button) and _handleEditLocation's `initial` picker
    // center: there is no single-wall-by-id provider exposing lat/lng (see
    // that button's doc), so this filters toposProvider's flat, live list —
    // the same one topos_screen.dart itself is built from — down to this
    // wall. A live StreamProvider, not a one-shot read: a successful
    // setWallCoordinates write re-emits this list on its own (see
    // _handleEditLocation's doc), so this always reflects the wall's
    // CURRENT coordinates, including right after a save.
    //
    // Loading is kept distinct from "no such wall in the list" (which is what
    // the old `maybeWhen(..., orElse: const [])` collapsed it into): an absent
    // `currentTopo` makes the view-mode glyph read "No location set" and go
    // dead, which is a CLAIM — and it was being made before this list had
    // arrived, about walls that do have coordinates. `locationUnknown` is that
    // window, and `_topTrailingActions` reports it rather than asserting.
    final toposAsync = ref.watch(toposProvider);
    final topos = toposAsync.hasValue
        ? toposAsync.requireValue
        : const <TopoRef>[];
    final locationUnknown = toposAsync.isLoading && !toposAsync.hasValue;
    TopoRef? currentTopo;
    for (final t in topos) {
      if (t.wallId == widget.wallId) {
        currentTopo = t;
        break;
      }
    }

    // Backs `_topTrailingActions`' `topo-open-community` shortcut — see
    // `wallVisibilityProvider`'s doc for why this is a dedicated,
    // owner-unscoped lookup rather than reusing `currentTopo?.visibility`
    // (which resolves to nothing for a read-only view of someone else's
    // shared topo). `'shared'` is the one real signal that a
    // `CommunityTopoDetailScreen` exists at all for this wall; anything
    // else (private, not-yet-loaded, no such wall) hides the shortcut —
    // never a dead button.
    final hasCommunityPage =
        ref.watch(wallVisibilityProvider(widget.wallId)).value == 'shared';

    // U1/U2/U3/U4 (photo strip): switching between DIFFERENT photos on this
    // wall (see PhotoStrip's class doc). NOT gated on `widget.readOnly` — a
    // read-only community viewer can still switch between someone else's
    // photos (see PhotoStrip.readOnly's doc for what IS suppressed in that
    // case: the add/manage affordances).
    //
    // PhotoStrip decides for itself whether the band appears at all, INCLUDING
    // its own hairline separator (which used to be this call site's wrapping):
    // it is the widget that knows whether the list is empty, still loading, or
    // real, and the separator has to follow that same answer rather than a
    // second, independently-derived one.
    //
    // Moved above the `_imageSize` derivation below (F-A1/F-A2 fix): this
    // is now the SAME live list `_imageSize` is read from — no separate
    // FileImage/codec decode probe — so it needs to be watched first.
    final wallPhotosAsync = ref.watch(wallOriginalsProvider(widget.wallId));
    final wallPhotos = wallPhotosAsync.hasValue
        ? wallPhotosAsync.requireValue
        : const <PhotoRef>[];

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

    // "This wall has no photo yet" versus "this wall's photo hasn't arrived
    // yet" — the single most expensive confusion on this screen. Both used to
    // render `_buildEmptyState`: opening a topo showed "No photo yet — pick one
    // to start" over an "Add a photo" button while the restore was still in
    // flight, which tells a climber their work is GONE. It is a photo-pending
    // state exactly while the initial restore is unfinished AND either the live
    // photo list is still on its first load or already says this wall has
    // photos.
    final photoPending =
        imagePath == null &&
        !_initialPhotoLoadSettled &&
        (wallPhotos.isNotEmpty ||
            (wallPhotosAsync.isLoading && !wallPhotosAsync.hasValue));

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
                ? (photoPending
                      ? _buildPhotoPendingState(context, colors)
                      : _buildEmptyState(context))
                : _buildCanvasArea(
                    imagePath,
                    drawState,
                    wallPhotosAsync,
                    hasCommunityPage,
                  ),
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
                  // The title row sits in a GlassChrome card. It used to
                  // share that card with the 52px PhotoStrip; navigating
                  // between a rock's photos now happens at the BOTTOM, in
                  // the dock's face lane, because six thumbnails in
                  // upload order told a reader how MANY photos there were and
                  // never where any of them was taken from. The (draw-mode-
                  // only) symbol palette remains a separate floating sibling below,
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
                              titlePending,
                              drawState,
                              drawNotifier,
                              currentTopo,
                              locationUnknown,
                            ),
                          ],
                        ),
                      ),
                      // Where the topo stands in review, and the withdrawal
                      // countdown (community editing phases 3 and 5).
                      //
                      // This is the screen an owner actually opens after
                      // submitting, so it is where "Waiting for review" has to
                      // appear — without it, submitting a topo produces no
                      // acknowledgement anywhere in the app and the owner
                      // learns something happened only when they notice nobody
                      // can see it. Renders to nothing for a draft or a
                      // healthy published topo, which is the overwhelmingly
                      // common case, so it costs an idle canvas nothing.
                      //
                      // `isOwner: !readOnly` — the same screen serves community
                      // readers at `/walls/<id>?readonly=1`, and they get only
                      // the withdrawal warning, never the owner's review state.
                      ModerationBanner(
                        wallId: widget.wallId,
                        isOwner: !widget.readOnly,
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
              // An installed iOS PWA reports a zero bottom inset, so this
              // `SafeArea` contributed nothing and the whole bottom cluster —
              // undo/redo/✗/✓, the standing notices, the proposal bar — sat
              // 12px off the screen edge. `minimum` is a per-edge `max`, so a
              // device that reports a real inset still wins — and the floor is
              // gated on standalone so a desktop browser, which has no home
              // indicator to clear, gets no dead space.
              minimum: EdgeInsets.only(bottom: standaloneBottomFloor),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  MasiSpacing.lg,
                  0,
                  MasiSpacing.lg,
                  MasiSpacing.md,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Where the reader moves between this rock's faces used
                    // to be a third floating panel right here, above the
                    // notices and below the route legend. It is the dock's
                    // pinned lane now (see [TopoCanvasBody]'s dock): three
                    // panels sharing one band meant each had to reserve
                    // pixels for the next by hand-maintained constant, and
                    // the constants drifted until the minimap was drawn on
                    // top of the route list.
                    // UF-2: shares the bottom slot with the draw-mode chrome
                    // rather than needing its own, because the two are
                    // mutually exclusive by construction — a set load failure
                    // is exactly what forces DrawMode.view and hides the mode
                    // toggle, so `_buildBottomChrome` renders nothing whenever
                    // this is showing.
                    if (drawState.lastLoadFailure != null)
                      _buildStandingNotice(
                        context,
                        colors,
                        noticeKey: const Key('topo-routes-unavailable'),
                        message: drawState.lastLoadFailure!.userMessage,
                      ),
                    // Storage interlock. Same slot and same mutual exclusion
                    // as UF-2 above: a blocked verdict hides the mode toggle,
                    // so `_buildBottomChrome` renders nothing beneath this.
                    if (storageBlocked != null)
                      _buildStandingNotice(
                        context,
                        colors,
                        noticeKey: const Key('topo-storage-blocked'),
                        message: storageBlocked,
                      ),
                    // The draw-mode tutorial (user request, 2026-08-15). Sits
                    // directly above the draw cluster, so the advice and the
                    // controls it is about are in the same place.
                    if (drawHintMessage(drawHint) case final hint?)
                      _buildDrawHint(context, colors, hint),
                    // §3.2: edits to somebody else's route were kept in
                    // memory and never written, so this is the ONLY way they
                    // can go anywhere. It sits above the draw cluster rather
                    // than replacing it because the suggester is still
                    // editing — they may want to adjust the line again before
                    // sending it.
                    if (drawState.pendingProposalBaselines.isNotEmpty)
                      _buildProposalBar(context, colors, drawState),
                    _buildBottomChrome(
                      colors,
                      drawNotifier,
                      drawState.mode,
                      // Read off the ONE-SHOT `drawState` read rather than
                      // the `.select` watch above, on purpose: adding
                      // `currentPoints` to that record would rebuild this
                      // whole screen's chrome on every single `addPoint`
                      // during a drag — the exact rebuild storm that watch
                      // exists to prevent. What the record carries instead is
                      // the BOOL `hasLine`, which flips twice a line: that is
                      // what makes this read fresh at the two moments the
                      // cluster's shape depends on it.
                      hasCurrentLine: drawState.currentPoints.isNotEmpty,
                      // The wall's climbs that are not on this photo. Read
                      // here rather than inside the cluster so the whole of
                      // this screen's chrome keeps its single build-time read
                      // of the draw state.
                      linkCandidates: drawState.activePhotoId == null
                          ? const <TopoRoute>[]
                          : ref
                                    .watch(
                                      climbsElsewhereProvider((
                                        wallId: widget.wallId,
                                        photoId: drawState.activePhotoId!,
                                      )),
                                    )
                                    .value ??
                                const <TopoRoute>[],
                      // Same one-shot read, same reason. Set ONLY for the
                      // case that needs no prompt — an unplaced selected
                      // route, which the ✓ will silently draw. With a placed
                      // route selected the ✓ asks first, so promising a
                      // destination here would be a lie.
                      draftTargetLabel: drawState.selectedRouteIsUnplaced
                          ? routeDisplayLabel(drawState.selectedRoute!)
                          : null,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// UF-2: the standing, non-dismissable counterpart to
  /// [routeLoadFailureSnackBar] — shown for as long as
  /// [DrawState.lastLoadFailure] is set, i.e. for as long as
  /// [DrawState.routes] is an INCOMPLETE picture of what is stored.
  ///
  /// The SnackBar is gone in four seconds; the climber may be looking at this
  /// canvas for the next twenty minutes. Everything else on screen — a real
  /// photo, zero routes drawn on it — reads as "this topo has no routes yet",
  /// which is the single most expensive thing this app could get wrong: acting
  /// on it means redrawing routes that already exist. This notice is the only
  /// thing standing between that reading and the truth, so it states the truth
  /// in both directions: the routes could not be loaded, AND they are still
  /// saved.
  ///
  /// Wired to no action on purpose. The honest remedy is to reopen the topo
  /// (which re-runs the load from scratch through `_loadInitialPhotoForWall`);
  /// a "Retry" button here would have to re-enter the switch machinery from a
  /// screen state that never opened one, which is how the original bug was
  /// built in the first place.
  /// Generalised in place so the storage interlock below reuses this exact
  /// chrome. Two different-looking "you can't do this right now" strips on one
  /// screen would be worse than either alone, and a climber on a sick device
  /// can plausibly hit both conditions in one session.
  Widget _buildStandingNotice(
    BuildContext context,
    MasiColors colors, {
    required Key noticeKey,
    required String message,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: MasiSpacing.sm),
      child: GlassChrome(
        key: noticeKey,
        padding: const EdgeInsets.symmetric(
          horizontal: MasiSpacing.md,
          vertical: MasiSpacing.sm,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            MasiIcon('warning', size: 18, color: colors.ink2),
            const SizedBox(width: MasiSpacing.sm),
            Flexible(
              child: Text(
                message,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: colors.ink2),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The draw-mode hint pill — the whole of the "minimal tutorial".
  ///
  /// A pill rather than an overlay with a spotlight, deliberately: the thing
  /// being taught is one sentence long, and a dimmed backdrop would hide the
  /// photo the climber is trying to draw on, which is the one thing they need
  /// to see. Tapping it dismisses it, so it can never be in the way.
  Widget _buildDrawHint(
    BuildContext context,
    MasiColors colors,
    String message,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: MasiSpacing.sm),
      child: GestureDetector(
        onTap: () => ref.read(drawHintProvider.notifier).dismiss(),
        child: GlassChrome(
          key: const Key('topo-draw-hint'),
          padding: const EdgeInsets.symmetric(
            horizontal: MasiSpacing.md,
            vertical: MasiSpacing.sm,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              MasiIcon('route', size: 18, color: colors.ink2),
              const SizedBox(width: MasiSpacing.sm),
              Flexible(
                child: Text(
                  message,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: colors.ink2),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The suggest/discard bar for edits made to somebody else's route
  /// (`ROUTE_EDITING_PLAN.md` §3.2).
  ///
  /// It says "not saved" out loud, and that wording is the point rather than
  /// hedging. The edits ARE on screen and they look exactly like an owner's
  /// would, so without a standing statement to the contrary the reasonable
  /// reading is that they were saved — and the visitor closes the topo
  /// believing they have corrected it when they have neither corrected it nor
  /// told anyone.
  Widget _buildProposalBar(
    BuildContext context,
    MasiColors colors,
    DrawState drawState,
  ) {
    final count = drawState.pendingProposalBaselines.length;
    return Padding(
      padding: const EdgeInsets.only(bottom: MasiSpacing.sm),
      child: GlassChrome(
        key: const Key('topo-proposal-bar'),
        padding: const EdgeInsets.symmetric(
          horizontal: MasiSpacing.md,
          vertical: MasiSpacing.sm,
        ),
        child: Row(
          children: [
            MasiIcon('edit', size: 18, color: colors.ink2),
            const SizedBox(width: MasiSpacing.sm),
            Expanded(
              child: Text(
                count == 1
                    ? "This is someone else's topo — your change is not saved"
                    : "This is someone else's topo — your $count changes are "
                          'not saved',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: colors.ink2),
              ),
            ),
            TextButton(
              key: const Key('topo-proposal-discard'),
              onPressed: _discardGeometryProposals,
              child: const Text('Discard'),
            ),
            MasiPendingButton.text(
              key: const Key('topo-proposal-send'),
              onPressed: _submitGeometryProposals,
              child: const Text('Suggest'),
            ),
          ],
        ),
      ),
    );
  }

  /// Puts the owner's geometry back. Nothing was ever written, so this is a
  /// complete undo of the visit — no reload, no network.
  void _discardGeometryProposals() {
    ref
        .read(drawControllerProvider(widget.wallId).notifier)
        .discardPendingGeometryProposals();
  }

  /// Files one `SuggestionKind.routeGeometry` suggestion per edited route, then
  /// restores the owner's geometry locally.
  ///
  /// Restoring on SUCCESS is not throwing the work away — the suggestion now
  /// lives on the server, and the local copy's job is to show what the owner
  /// actually has. Leaving the edit on screen would mean the canvas keeps
  /// displaying a line that exists nowhere, which reads as "accepted".
  ///
  /// Sends sequentially and stops at the first failure. There is no outbox
  /// (decision D-4), so each call either filed or did not, and only the ones
  /// that filed are cleared — see [DrawController.discardPendingGeometryProposals].
  Future<void> _submitGeometryProposals() async {
    final drawState = ref.read(drawControllerProvider(widget.wallId));
    final baselines = drawState.pendingProposalBaselines;
    final photoId = drawState.activePhotoId;
    if (baselines.isEmpty || photoId == null) return;

    // Built BEFORE the note is asked for: a proposal the server would refuse
    // should be reported now, not after the suggester has written an
    // explanation for it.
    final proposals = <int, GeometryProposal>{};
    for (final route in drawState.routes) {
      final baseline = baselines[route.id];
      if (baseline == null) continue;
      final proposal = GeometryProposal.fromEdit(
        points: route.points,
        symbols: route.symbols,
        originalSymbols: baseline.symbols,
      );
      if (!proposal.isSendable) {
        await showMasiAlert(
          context,
          title: 'That line is too long to suggest',
          message:
              'Route ${route.number} has more points or markers than a '
              'suggestion can carry. Remove some and try again.',
          dialogKey: const Key('topo-proposal-too-large'),
        );
        return;
      }
      proposals[route.id] = proposal;
    }
    if (proposals.isEmpty) return;

    final note = await showMasiTextPrompt(
      context,
      title: proposals.length == 1
          ? 'Suggest this change'
          : 'Suggest these ${proposals.length} changes',
      submitLabel: 'Send',
      placeholder: 'Why this line? Optional — but it is what gets one accepted',
      allowEmpty: true,
      dialogKey: const Key('topo-proposal-note'),
      fieldKey: const Key('topo-proposal-note-field'),
      submitKey: const Key('topo-proposal-note-send'),
    );
    // Dismissed: keep every edit exactly where it is, so backing out of the
    // note does not also throw away the line they drew.
    if (note == null || !mounted) return;

    final trimmedNote = note.trim();
    final repository = ref.read(routeRepositoryProvider);
    final service = ref.read(suggestionServiceProvider);
    final sent = <int>[];
    Object? failure;

    try {
      final dbIds = await repository.routeDbIdsByNumber(widget.wallId, photoId);
      for (final entry in proposals.entries) {
        final route = drawState.routes.firstWhere((r) => r.id == entry.key);
        final dbId = dbIds[route.number];
        // The route it targets is gone — the owner deleted it, or a pull
        // removed it, while this visit was editing. Filing against nothing
        // would produce a suggestion the owner can never act on.
        if (dbId == null) continue;
        await service.suggest(
          wallId: widget.wallId,
          kind: SuggestionKind.routeGeometry,
          patch: entry.value.toPatch(),
          note: trimmedNote.isEmpty ? null : trimmedNote,
          routeId: dbId,
          photoId: photoId,
        );
        sent.add(entry.key);
      }
    } catch (error) {
      failure = error;
    }

    if (!mounted) return;
    if (sent.isNotEmpty) {
      ref
          .read(drawControllerProvider(widget.wallId).notifier)
          .discardPendingGeometryProposals(sent);
    }
    final messenger = ScaffoldMessenger.of(context);
    if (failure != null) {
      messenger.showMasiToast(
        sent.isEmpty
            ? 'That could not be sent. Your changes are still here — try '
                  'again.'
            : 'Sent ${sent.length}, but the rest could not be sent. Those '
                  'changes are still here — try again.',
        kind: MasiToastKind.error,
      );
      return;
    }
    messenger.showMasiToast(
      'Sent to the owner',
      kind: MasiToastKind.success,
      key: Key('topo-proposal-sent'),
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
    bool titlePending,
    DrawState drawState,
    DrawController drawNotifier,
    TopoRef? currentTopo,
    bool locationUnknown,
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
            padding: const EdgeInsets.symmetric(horizontal: MasiSpacing.xs),
            child: _buildTitle(context, colors, title, titlePending),
          ),
        ),
        ..._topTrailingActions(
          context,
          drawState,
          drawNotifier,
          currentTopo,
          locationUnknown,
        ),
      ],
    );
  }

  /// The canvas title slot: the wall's real name, or — while that name is on
  /// its first load — a placeholder bar in the same line box, never the "Topo"
  /// fallback (see [build]'s `titlePending`).
  ///
  /// Three states rather than two, all the same height so the pill never
  /// resizes:
  ///  * not loading -> the name (or the genuine "Topo" fallback);
  ///  * loading, inside [MasiLoadingGate]'s reveal delay -> an empty line box,
  ///    because a name that arrives in 30 ms must produce no visible loading
  ///    state at all — and NOT a wrong title for those 30 ms;
  ///  * loading, past it -> a shimmering text-line skeleton.
  Widget _buildTitle(
    BuildContext context,
    MasiColors colors,
    String title,
    bool titlePending,
  ) {
    final style = Theme.of(
      context,
    ).textTheme.titleMedium?.copyWith(color: colors.ink);
    final fontSize = style?.fontSize ?? 17;

    return MasiLoadingGate(
      isLoading: titlePending,
      builder: (context, showSkeleton) {
        if (titlePending) {
          if (!showSkeleton) {
            return SizedBox(
              height: MediaQuery.textScalerOf(context).scale(fontSize) * 1.3,
            );
          }
          return MasiSkeleton.textLine(
            fontSize: MediaQuery.textScalerOf(context).scale(fontSize),
            widthFactor: 0.55,
          );
        }
        return Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: style,
        );
      },
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

  // A `_topRowTextStyle` lived here for draw mode's Cancel/Save text pair.
  // Both went when the bottom cluster absorbed those two jobs (2026-08-12),
  // and with them the width worst case they created — draw mode's row is
  // back to glyphs only.

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
    bool locationUnknown,
  ) {
    final colors = MasiColors.of(context);
    final actions = <Widget>[];

    // The `topo-edit-metadata-button` pencil used to sit here, in the top
    // chrome, whenever a route was selected in draw mode. It moved ONTO the
    // route (2026-08-12) — see `RouteLegend.onEditRoute`, which renders it on
    // the selected row itself. A control that edits one route belongs next to
    // that route, not a screen away in a row of canvas-wide actions.

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

    // Adding a photo. It has moved three times, and this is the one rule that
    // survived every move: there is EXACTLY ONE add-photo affordance on a
    // canvas that has a photo (see `canvas_bottom_reclaim_test.dart`). It was
    // a bottom-right FAB, then the '+' tile at the end of the 52px photo
    // strip — right beside the thumbnails it added to — then up here, because
    // the strip had become a row of 7px dots and a dot row has nothing you
    // can append a '+' to that still reads as "add a photo".
    //
    // The rail put real thumbnails back, so the '+' belongs beside them again
    // and lives in the rail on any wall that HAS one. This button is what a
    // single-photo wall gets instead — the rail needs two faces to appear at
    // all, so the two are mutually exclusive rather than competing.
    //
    // It is NOT a floating bottom-right button, which is where design 4c
    // draws it and where this first put it back. That corner belongs to the
    // route legend: a FAB there sits over the per-route menu buttons and
    // silently swallows their taps — the control still painted, still found
    // by a test, and simply not reachable.
    final railCarriesAdd =
        !widget.embedded &&
        (ref.watch(wallOriginalsProvider(widget.wallId)).value?.length ?? 0) >=
            2;
    if (drawState.mode == DrawMode.view &&
        !widget.readOnly &&
        !railCarriesAdd) {
      actions.add(
        IconButton(
          key: const Key('topo-add-photo-button'),
          icon: MasiIcon('image_add'),
          tooltip: 'Add a photo',
          onPressed: _pickImage,
          color: colors.accent,
          style: _topRowIconStyle(),
        ),
      );
    }

    // The rock-highlight ("boulder") toggle used to live here, between the
    // AR glyph and the mode toggle. Removed (user request, 2026-08-11): the
    // route-derived wash never read as useful on the canvas and did nothing
    // legible on web, so the whole feature went with it — the controller,
    // the painter, and `TopoCanvas`'s overlay layer. Nothing else consumed
    // it; the AR screen's own rock box is a separate path
    // (`ar_controller.dart`'s `setRockBox`) and is untouched.

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
    //
    // UF-2 gate, riding on exactly that property: while
    // [DrawState.lastLoadFailure] is set, this photo's real route set was
    // never read, so anything the climber draws would be numbered from an
    // empty list and would duplicate routes that already exist on disk. The
    // controller already refuses to PERSIST in that state (activeWallId stays
    // null — see [DrawController.loadForWall]'s UF-2 doc); hiding the toggle
    // is the honest front half of the same guarantee, so the climber is
    // stopped before drawing rather than silently losing the work afterwards.
    // The `topo-routes-unavailable` banner below is what explains the
    // absence — a control that vanishes without a reason is its own bug.
    //
    // Storage gate, riding on the SAME property: when the local database
    // cannot keep what we write (or cannot be opened), hiding this one control
    // is what makes every mutating handler on this screen unreachable, exactly
    // as `readOnly` and the UF-2 gate already do. `topo-storage-blocked`
    // explains the absence.
    if (!widget.readOnly &&
        drawState.lastLoadFailure == null &&
        storageBlockedNotice(ref.watch(storageDurabilityProvider)) == null) {
      // VIEW MODE ONLY. Draw mode carries no mode control up here at all any
      // more: the Cancel/Save text pair that briefly lived here was, in the
      // user's words (2026-08-12), the same thing as "the x and check button
      // on the bottom" — two identical-looking pairs on one screen, one
      // meaning the current line and one meaning the session. The bottom
      // cluster absorbed both jobs instead; see [_buildBottomChrome].
      if (drawState.mode == DrawMode.view) {
        actions.add(
          IconButton(
            key: const Key('topo-mode-toggle'),
            // Bug fix ("topo opens showing an eye, reads as read-only"): the
            // glyph is the AFFORDANCE for what tapping it does, not a mirror
            // of the current mode — in view mode (the mode every topo opens
            // in) it shows the edit/pencil glyph ("tap to edit").
            icon: MasiIcon('edit'),
            tooltip: 'Edit',
            onPressed: () {
              drawNotifier.toggleMode();
              // Entering draw mode is the only moment the unprompted nudge is
              // welcome: the climber has just said they intend to draw, and
              // has not yet had a chance to get it wrong. `offerFirstTime`
              // retires itself once a route has ever been drawn on this
              // device.
              ref.read(drawHintProvider.notifier).offerFirstTime();
            },
            color: colors.accent,
            style: _topRowIconStyle(),
          ),
        );
      }
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

    // Import a photographed guidebook page onto THIS photo.
    //
    // Draw mode, like every other mutating control in this row. Gated on an
    // active photo because the import writes routes in that photo's percent
    // space — there is nothing for the coordinates to mean without one.
    //
    // ADMIN-ONLY while the flow is still being shaped. Note what this gate is
    // and is not: every other admin surface in this app fronts a
    // `SECURITY DEFINER` RPC that re-checks `is_admin()` server-side, so
    // hiding the control there is convenience. There is no server call here at
    // all — an import writes the user's own routes to their own wall through
    // the same repository their finger already reaches by drawing. So this
    // hides an unfinished feature; it does not protect a privileged one, and
    // nothing is at risk if it is bypassed. `isAdminProvider` fails closed
    // (false while loading, false on error), matching every other admin gate.
    if (!widget.readOnly &&
        drawState.mode == DrawMode.draw &&
        drawState.activePhotoId != null &&
        (ref.watch(isAdminProvider).asData?.value ?? false)) {
      // A dot when a page queued from the chat app is waiting. Without it the
      // MCP path dead-ends: the user finishes in Claude, is told to open Masi,
      // and finds a screen that looks exactly as it did before.
      final waiting =
          ref.watch(pendingImportsProvider(widget.wallId)).asData?.value ??
          const [];
      actions.add(
        IconButton(
          key: const Key('topo-import-guidebook-button'),
          icon: waiting.isEmpty
              ? MasiIcon('scan')
              : Stack(
                  clipBehavior: Clip.none,
                  children: [
                    MasiIcon('scan'),
                    Positioned(
                      right: -2,
                      top: -2,
                      child: Container(
                        key: const Key('topo-import-waiting-dot'),
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: colors.accent,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                  ],
                ),
          tooltip: waiting.isEmpty
              ? 'Import from guidebook'
              : '${waiting.length} import waiting',
          onPressed: () => _handleImportFromGuidebook(drawState.activePhotoId!),
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
    //
    // `locationUnknown` (see [build]) is why this is not simply
    // `hasCoords ? ... : 'No location set'` any more: while [toposProvider] is
    // still on its first load, "No location set" is a statement about a wall
    // nobody has looked up yet, and it read identically to the real answer.
    // The glyph reports the wait instead — a gated inline spinner in place of
    // the map icon, and a tooltip that says what is happening — and only claims
    // "No location set" once the list has actually arrived.
    if (!widget.readOnly && drawState.mode == DrawMode.view) {
      final hasCoords =
          currentTopo?.latitude != null && currentTopo?.longitude != null;
      actions.add(
        IconButton(
          key: const Key('topo-locate-on-map-button'),
          // isLoading + child rather than a conditional mount: only this form
          // is still on screen when the wait ends, so only it can honour the
          // minimum-visible hold instead of blinking the spinner out.
          icon: MasiLoadingIndicator.inline(
            isLoading: locationUnknown,
            color: colors.accent,
            semanticLabel: 'Checking this wall for a location',
            child: MasiIcon('topo_map'),
          ),
          tooltip: locationUnknown
              ? 'Checking for a location…'
              : (hasCoords ? 'Show on map' : 'No location set'),
          // `go`, NOT `push` — this is the blank-screen bug of 2026-08-11,
          // root-caused by driving the real app in headless Chrome (the
          // push path raises, verbatim:
          //   "A GlobalKey was used multiple times inside one widget's child
          //    list. The offending GlobalKey was:
          //    [LabeledGlobalKey<NavigatorState>#… root]").
          //
          // `/community` redirects to `/map`, which lives inside the bottom
          // nav's `StatefulShellRoute.indexedStack` (see router.dart). The
          // canvas is itself reached by PUSHING `/walls/:id` on top of that
          // shell, so the shell page is ALREADY in the stack; pushing a shell
          // -branch route then builds a SECOND `StatefulNavigationShell`
          // carrying the same root-navigator GlobalKey. In a debug build that
          // is a red assertion screen; in release it is a torn tree that
          // paints nothing — the blank screen as reported.
          //
          // `go` switches the existing shell to its Map branch, which is what
          // "show this on the map" means anyway; the nav bar is then the way
          // back. Widget tests cannot catch this on their own: pumping a
          // pushed `/map` from a bare `/` builds `CommunityMapScreen` quite
          // happily, because the duplicate only arises once the shell is
          // under a pushed route.
          onPressed: hasCoords
              ? () => context.go('/community?tab=map&focus=${widget.wallId}')
              : null,
          color: colors.accent,
          style: _topRowIconStyle(),
        ),
      );
    }

    // Feed/community shortcut: "if one opens the topo they can easily
    // navigate to the info rich feed version" — jumps straight to
    // `CommunityTopoDetailScreen`'s richer social surface (comments, likes,
    // ascents, grade consensus, hazards, version history) for this SAME
    // wall. Named-path navigation (`context.push` on the real
    // `/community/topo/:wallId` route — see router.dart), never a direct
    // widget push, so deep-linking and this screen's own back stack stay
    // correct.
    //
    // Gated on `hasCommunityPage` (== `wallVisibilityProvider`'s
    // `'shared'`) — the exact same condition `community_repository.dart`'s
    // `sharedTopos` query requires for a wall to appear on the Feed/Map at
    // all. A private, never-published topo has no community page to open,
    // so this glyph must not exist for one (a "dead button" the user could
    // tap into nothing); see `wallVisibilityProvider`'s doc for why this
    // reads the wall directly rather than through the owner-scoped
    // `currentTopo`, so the shortcut also appears for a read-only view of
    // someone ELSE's shared topo (e.g. the community/nearby entry points
    // that route straight into this canvas without passing through
    // `CommunityTopoDetailScreen` first).
    //
    // View mode only, alongside the locate-on-map glyph just above: like
    // that one, this is a non-mutating "jump elsewhere" affordance rather
    // than a drawing tool, so it stays out of draw mode's crowded
    // editing cluster. Not gated on `widget.readOnly` — opening the feed is
    // exactly as meaningful whether this canvas is the owner's editable
    // copy or a read-only viewer.
    // The `topo-open-community` speech-bubble glyph used to sit here. It is
    // gone from the top row (user request, 2026-08-11) and the same
    // destination is now reached from the BOTTOM of the screen instead —
    // pull the route panel up, or tap its "Comments & ascents" footer row.
    // See `TopoCanvasBody`'s legend overlay: a bottom sheet you drag upward
    // for progressively more detail is the pattern this screen already half
    // had (the grab handle was there; it just did not respond to a drag),
    // and it keeps the top row down to the few controls that act on the
    // canvas itself.

    // The `topo-add-photo-button` image-plus glyph used to sit here too, and
    // was removed as redundant (user request, 2026-08-11): the photo strip
    // directly below this row already ends in a '+' tile wired to the SAME
    // `_pickImage`, right next to the thumbnails it adds to. `_pickImage`
    // itself is unchanged and still has two live entry points — that '+'
    // tile ([PhotoStrip.onAdd]) and the empty state's "Add a photo" button,
    // which is what covers the one case the strip cannot: a wall with no
    // photos at all renders no strip (see [PhotoStrip]'s class doc).

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
    DrawMode mode, {
    required bool hasCurrentLine,
    required List<TopoRoute> linkCandidates,
    String? draftTargetLabel,
  }) {
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
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ITS OWN LINE, above the tools, and in words.
          //
          // It was a bare glyph wedged into the cluster below, and a bare
          // glyph for a thing no app has done before says nothing: the person
          // who asked for this feature asked for it again after it shipped.
          // Spelling it out does not fit down there — five controls and a
          // phrase overflow a 390pt phone by 65px, measured — and it does not
          // belong there either. Those four are tools for the line being
          // drawn; this is the second READING of that line, and it appears
          // only in the moment there is a line and a climb elsewhere on the
          // rock for it to be.
          if (hasCurrentLine && linkCandidates.isNotEmpty) ...[
            SizedBox(
              width: double.infinity,
              child: TextButton.icon(
                key: const Key('topo-link-climb-button'),
                onPressed: () => _handleLinkToExistingClimb(linkCandidates),
                icon: MasiIcon('route', size: 18, color: colors.accent),
                label: const Text('Same climb, seen from here'),
                style: TextButton.styleFrom(
                  foregroundColor: colors.accent,
                  backgroundColor: colors.accent.withValues(alpha: 0.14),
                  minimumSize: const Size(0, 44),
                  shape: const StadiumBorder(),
                ),
              ),
            ),
            const SizedBox(height: MasiSpacing.xs),
          ],
          Row(
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
                // Two jobs, one glyph — see [_handleCancelEditing] for why the
                // split is deliberate. The tooltip has to track it, or the
                // control lies about what a tap will do.
                tooltip: hasCurrentLine
                    ? 'Discard current route'
                    : 'Stop editing',
                onPressed: _handleCancelEditing,
                color: colors.accent,
                style: IconButton.styleFrom(shape: const CircleBorder()),
              ),
              // "That is climb 3, seen from here." Shown only while there is a
              // line to say it about AND the wall has a climb that is not on
              // this photo — which is exactly when the question can arise, and
              // never otherwise. The alternative reading of the same draft, "a
              // new climb", is the ✓ beside it; both are one tap, and neither is
              // reachable by accident.
              // The drawing tool's primary action, and the only control in this
              // cluster that awaits a database write ([DrawController.commitRoute]
              // upserts the new route). It used to stay enabled throughout, so an
              // impatient second tap on a slow write ran the whole commit again.
              // [MasiPendingButton] swallows that second tap synchronously, dims the
              // control immediately, and — only if the write outlasts the reveal
              // delay — draws a spinner over the glyph without changing the
              // cluster's geometry. Tooltip kept via a wrapper (the pending button
              // has no tooltip slot of its own) with the Key still on the button
              // itself, so `find.byKey`/`find.byTooltip` both keep working.
              Tooltip(
                // Names the DESTINATION when a selected route is about to claim
                // the line, so "why did my line join route 5?" is answered before
                // it happens rather than after.
                message: !hasCurrentLine
                    ? 'Done editing'
                    : (draftTargetLabel == null
                          ? 'Save route'
                          : 'Save line to $draftTargetLabel'),
                child: MasiPendingButton.text(
                  key: const Key('topo-commit-button'),
                  onPressed: _handleFinishEditing,
                  style: TextButton.styleFrom(
                    backgroundColor: colors.accent.withValues(alpha: 0.16),
                    foregroundColor: colors.accent,
                    shape: const CircleBorder(),
                    // The 48x48 footprint an IconButton produced here (24 px glyph
                    // + 8 px padding, tap target padded to 48), so the glass
                    // cluster's height and spacing are unchanged.
                    minimumSize: const Size(48, 48),
                    padding: EdgeInsets.zero,
                  ),
                  onError: (error, stackTrace) {
                    // A refused write is already surfaced by the
                    // `lastWriteFailure` listener in [build] (that is the
                    // controller's contract — see UF-1 there), so this exists to
                    // keep an unexpected throw out of FlutterError.reportError,
                    // never to be the user's only notification.
                    debugPrint('Commit route failed: $error\n$stackTrace');
                  },
                  child: MasiIcon('check', color: colors.accent),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    final colors = MasiColors.of(context);
    // Storage gate. Unlike the top-chrome glyphs, this button cannot simply be
    // HIDDEN: it is the only thing on an otherwise empty screen, so removing
    // it would leave "No photo yet — pick one to start" above nothing at all,
    // which reads as a broken screen rather than a blocked one. Disabled in
    // place, with the reason replacing the invitation.
    final storageBlocked = storageBlockedNotice(
      ref.watch(storageDurabilityProvider),
    );
    return ColoredBox(
      color: colors.ground,
      child: Center(
        child: Column(
          key: const Key('topo-empty-state'),
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            MasiIcon('image', size: 72, color: colors.ink3),
            const SizedBox(height: MasiSpacing.lg),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: MasiSpacing.lg),
              child: Text(
                storageBlocked ?? 'No photo yet — pick one to start',
                key: const Key('topo-empty-state-message'),
                textAlign: TextAlign.center,
                style: Theme.of(
                  context,
                ).textTheme.bodyLarge?.copyWith(color: colors.ink2),
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
              // Pending state driven by [_attachInFlight] rather than by
              // MasiPendingButton — see that field's doc: the tap opens an OS
              // picker the user drives, and only what follows it is a wait.
              // The label stays laid out under the spinner (the same
              // `Visibility(maintainSize:)` trick MasiPendingButton uses) so
              // this button cannot shrink to 20 px mid-attach.
              MasiLoadingGate(
                isLoading: _attachInFlight,
                builder: (context, showLoading) => ElevatedButton(
                  key: const Key('topo-empty-state-add-photo'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: colors.accent,
                    foregroundColor: colors.onAccent,
                    disabledBackgroundColor: _attachInFlight
                        ? colors.accent.withValues(alpha: 0.6)
                        : null,
                    disabledForegroundColor: _attachInFlight
                        ? colors.onAccent
                        : null,
                    padding: const EdgeInsets.symmetric(
                      horizontal: MasiSpacing.lg,
                      vertical: MasiSpacing.md,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(MasiRadii.control),
                    ),
                  ),
                  onPressed: (storageBlocked == null && !_attachInFlight)
                      ? _pickImage
                      : null,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Visibility(
                        visible: !showLoading,
                        maintainSize: true,
                        maintainAnimation: true,
                        maintainState: true,
                        child: const Text('Add a photo'),
                      ),
                      if (showLoading)
                        MasiLoadingIndicator.inline(
                          // The gate above owns both delays already.
                          revealDelay: Duration.zero,
                          minVisible: Duration.zero,
                          color: colors.onAccent,
                          semanticLabel: 'Adding the photo',
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// The wall's photo is on its way but nothing can be drawn yet: no path
  /// selected, and [_initialPhotoLoadSettled] not yet true for a wall that has
  /// (or may have) photos — see [build]'s `photoPending`.
  ///
  /// A shaped placeholder in the shape of the thing that is coming (the photo
  /// fills this whole area) rather than a spinner, and behind
  /// [MasiLoadingGate]'s reveal delay so the overwhelmingly common fast restore
  /// still paints nothing but the canvas backdrop.
  ///
  /// The `isLoading: true` below is HARDCODED on purpose, and that is safe here
  /// for one specific reason worth stating because it reads like a stuck
  /// skeleton: this widget only exists while `photoPending` is true, so the
  /// resolution mechanism is the CALLER's condition going false, not the gate's
  /// flag. What makes that terminal is that `photoPending` requires
  /// `!_initialPhotoLoadSettled`, and [_loadInitialPhotoForWall] sets that flag
  /// in a `finally` — so the restore FAILING settles it just as surely as the
  /// restore succeeding, and the placeholder always gives way (to the real
  /// canvas, or to the empty state). Pinned by
  /// `canvas_loading_states_test.dart`'s "a photo restore that FAILS still
  /// resolves the placeholder". If you ever make that flag conditional, this gate
  /// becomes a shimmer nothing can end — which is worse than the premature empty
  /// state this whole state exists to replace.
  Widget _buildPhotoPendingState(BuildContext context, MasiColors colors) {
    return ColoredBox(
      key: const Key('topo-photo-pending'),
      color: colors.ground,
      child: MasiLoadingGate(
        isLoading: true,
        builder: (context, showLoading) {
          if (!showLoading) return const SizedBox.expand();
          return Semantics(
            container: true,
            label: 'Loading this topo',
            // No radius: the canvas photo is full-bleed to the screen edges
            // (see TopoCanvas.build), so a rounded placeholder would round
            // corners the photo is about to fill square.
            child: const MasiSkeleton.box(radius: 0),
          );
        },
      ),
    );
  }

  /// Builds the canvas body once a photo is selected: while [_imageSize] is
  /// still unresolved (see [build]'s doc for how it's derived from the displayed
  /// photo's persisted [PhotoRef]) this reports the state of the list that size
  /// comes from, `topo-image-loading`; otherwise the real [TopoCanvasBody].
  ///
  /// The unresolved case is genuinely three states, which a bare
  /// `CircularProgressIndicator` (what stood here) collapsed into one — and one
  /// of them it could not represent at all: if [wallOriginalsProvider] FAILS,
  /// no width/height can ever arrive, and that spinner span forever over a
  /// photo that was never coming. Now:
  ///  * list still loading -> a canvas-shaped skeleton;
  ///  * list has data but no usable row for this path yet (the ordinary case: a
  ///    freshly-picked photo whose `attachPhotoToWall` write is in flight) -> a
  ///    labelled spinner, the one legitimate spinner case on this screen since
  ///    an image whose aspect is unknown has no shape to reserve;
  ///  * list failed -> what failed, plus Retry.
  ///
  /// There is still no permanent-error branch for the photo BYTES (see the
  /// removed `_imageLoadError`/`_buildImageErrorState` — F-A1/F-A2 fix):
  /// genuinely-missing bytes are handled by [TopoCanvasBody]'s own `PhotoImage`,
  /// which self-heals/placeholders per key rather than latching a screen-level
  /// error that used to require leaving and re-entering to clear.
  Widget _buildCanvasArea(
    String imagePath,
    DrawState drawState,
    AsyncValue<List<PhotoRef>> wallPhotosAsync,
    bool hasCommunityPage,
  ) {
    final imageSize = _imageSize;
    if (imageSize == null) {
      final colors = MasiColors.of(context);
      return ColoredBox(
        key: const Key('topo-image-loading'),
        color: colors.ground,
        child: MasiAsyncView<List<PhotoRef>>(
          value: wallPhotosAsync,
          onRetry: () => ref.invalidate(wallOriginalsProvider(widget.wallId)),
          errorMessage: "Couldn't load this wall's photos",
          skeleton: (context) => const MasiSkeleton.box(radius: 0),
          data: (context, _) =>
              const MasiLoadingIndicator.standalone(label: 'Preparing photo…'),
        ),
      );
    }
    // Read here, where both providers are already watched, and handed DOWN to
    // the body — see TopoCanvasBody.facePhotos for why the body must not watch
    // them itself.
    //
    // Watched UNCONDITIONALLY, outside any mode check, even though the face
    // lane only renders in view mode. Both are autoDispose, so reading them
    // inside a ternary would drop the last listener the moment a pen is picked
    // up and tear the wall's layout subscription down — then rebuild it on the
    // way back out. That is a live drift query closing and reopening on every
    // draw/view toggle, and it closes ASYNCHRONOUSLY: the cancellation posts
    // a zero-duration timer that outlives the frame, which is why the canvas
    // widget tests that switch modes failed with a pending timer rather than
    // with anything that looked like a layout bug.
    final facePhotos =
        ref.watch(wallOriginalsProvider(widget.wallId)).value ??
        const <PhotoRef>[];
    final faceLayout = ref.watch(wallLayoutProvider(widget.wallId)).value;
    // The rail's badges. Same rule as the two above: watched here, where the
    // screen already holds a build, and handed down.
    final faceRouteCounts =
        ref.watch(wallRouteCountsProvider(widget.wallId)).value ??
        const <String, int>{};

    return TopoCanvasBody(
      wallId: widget.wallId,
      imagePath: imagePath,
      imageSize: imageSize,
      drawState: drawState,
      // The face lane's ingredients. They ride INSIDE the dock now rather
      // than in a panel of their own below it, which is what removed the
      // clearance arithmetic that kept drifting out of true.
      facePhotos: facePhotos,
      faceLayout: faceLayout,
      faceRouteCounts: faceRouteCounts,
      onSelectFace: _switchToPhoto,
      onManageFace: widget.readOnly ? null : _showFaceMenu,
      onOpenFaceMap: () => _openFaceMap(facePhotos),
      onAddPhoto: widget.readOnly ? null : _pickImage,
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
      // Edit a route's details FROM the route (2026-08-12) — the pencil that
      // used to sit in the top chrome. `TopoCanvasBody` narrows this to draw
      // mode; `RouteLegend` narrows it further to the selected row.
      onEditRoute: widget.readOnly ? null : _openMetadataSheetForId,
      onSameClimbAs: widget.readOnly ? null : _handleSameClimbAs,
      // The route panel's own way into the community/feed view of this same
      // wall, replacing the top row's removed speech-bubble glyph. Null when
      // the wall was never published — `hasCommunityPage` is
      // `wallVisibilityProvider == 'shared'`, the exact condition
      // `community_repository.dart`'s `sharedTopos` needs for a
      // `CommunityTopoDetailScreen` to exist at all, so this is never a dead
      // affordance.
      onOpenCommunity: hasCommunityPage
          ? () => context.push('/community/topo/${widget.wallId}')
          : null,
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
    this.onEditRoute,
    this.onSameClimbAs,
    this.onOpenCommunity,
    this.facePhotos = const <PhotoRef>[],
    this.faceLayout,
    this.faceRouteCounts = const <String, int>{},
    this.onSelectFace,
    this.onManageFace,
    this.onOpenFaceMap,
    this.onAddPhoto,
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

  /// Passed to [RouteLegend.onEditRoute] — but only in [DrawMode.draw] (see
  /// [build]). Editing a route's details is an edit-mode action, and the
  /// legend is a read surface in view mode.
  final void Function(int routeId)? onEditRoute;

  /// Passed to [RouteLegend.onSameClimbAs]: the way back from a line saved as
  /// a new climb when it was meant to be one this rock already has, on
  /// another of its photos.
  final void Function(int routeId)? onSameClimbAs;

  /// Opens the community/feed view of this same wall
  /// (`/community/topo/:wallId`). Non-null only for a wall that actually has
  /// one (see [TopoCanvasScreen.build]'s `hasCommunityPage`), so this is
  /// never a dead affordance; null (the default) renders no community
  /// affordance at all, preserving every pre-existing call site exactly.
  ///
  /// This is where the top row's removed speech-bubble glyph went. The bottom
  /// panel gets it in two forms, both wired here: the "Comments & ascents"
  /// footer row inside the expanded card (the visible, discoverable one) and
  /// an upward drag on the panel's grab handle (the fast one) — a bottom
  /// sheet you keep pulling up for progressively more detail, which is also
  /// what makes the handle mean something at last. See [_LegendHeader].
  final VoidCallback? onOpenCommunity;

  /// This rock's photos, for the dock's face lane. Empty (the default) means
  /// no lane — which is also every pre-existing call site and widget test, so
  /// they keep the plain floating route panel they always had.
  ///
  /// Passed IN rather than watched here, and this is not a style choice.
  /// Reading `wallOriginalsProvider`/`wallLayoutProvider` from this widget
  /// opened a second drift subscription per build, whose teardown left a
  /// pending timer at the end of every widget test that pumped this body — a
  /// failure with nothing to do with what those tests were about. The screen
  /// above already watches both.
  final List<PhotoRef> facePhotos;

  /// The resolved layout behind the rail's leading plan tile. Null while it
  /// loads, or on a wall whose baseline is degenerate — the tile simply does
  /// not appear then, rather than opening an empty box.
  final LayoutResult? faceLayout;

  /// How many climbs each photo shows, keyed by photo id — the rail's badges.
  /// Absent means none, and no badge is drawn.
  final Map<String, int> faceRouteCounts;

  /// Tapping a face in the rail.
  final void Function(PhotoRef photo)? onSelectFace;

  /// Long-pressing a face: set cover, delete, add. Null when read-only.
  final void Function(PhotoRef photo)? onManageFace;

  /// Opens the full-screen plan view. Null when there is no plan to open.
  final VoidCallback? onOpenFaceMap;

  /// The rail's trailing '+' tile. Null when read-only.
  ///
  /// It sat in the top row for as long as the lane was a row of 7px dots,
  /// which has nothing you can append a '+' to that still reads as "add a
  /// photo". With real thumbnails back in the rail it reads correctly again,
  /// right beside the tiles it adds to.
  final VoidCallback? onAddPhoto;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasRoutes = drawState.routes.isNotEmpty;
    final legendExpanded = ref.watch(legendExpandedProvider(wallId));
    // A community entry point alone is enough to float the bottom panel: a
    // published wall whose photo has no routes drawn on it yet still has
    // comments and ascents to reach, and with the top-row glyph gone this is
    // the only way there.
    final community = embedded ? null : onOpenCommunity;

    // The dock's pinned lane only exists where it means something: a rock with
    // more than one photo, being READ. A contributor drawing a line is working
    // on one photo, and offering to walk round the rock mid-stroke is an
    // invitation to lose the stroke — so draw mode keeps the plain collapsed
    // chip it always had. So does every wall with a single photo, and so does
    // every pre-existing caller and widget test, which pass no photos at all.
    final laneVisible =
        !embedded && drawState.mode == DrawMode.view && facePhotos.length >= 2;

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
    // The switch cue (below) occupies the same floating slot as the legend, so
    // it needs the same clearance — otherwise it would sit under the bottom
    // chrome/safe area on exactly the walls where `routes` is empty.
    // `masiBottomInset` rather than `MediaQuery.paddingOf(...).bottom`: an
    // installed iOS PWA reports a zero bottom inset, which left this panel
    // sitting 12px off the screen edge, on the home indicator (user report,
    // 2026-08-15). The helper floors it at the same value the nav bar has
    // always used, and takes a `max` so nothing double-counts.
    final legendBottomPadding =
        (hasRoutes ||
            drawState.isSwitchingPhoto ||
            community != null ||
            laneVisible)
        ? masiBottomInset(context, ref) +
              MasiSpacing.md +
              (drawState.mode == DrawMode.draw
                  ? kBottomChromeClusterHeight + MasiSpacing.sm
                  : 0.0) +
              // The draw hint shares this band, and without its height the
              // pill sits ON TOP of the collapsed legend chip — tapping the
              // chip hits the hint instead, which is how this was found.
              (drawHintMessage(ref.watch(drawHintProvider)) == null
                  ? 0.0
                  : kDrawHintHeight) +
              // There is deliberately no term here for the face lane or the
              // map. Both used to be a separate floating panel below this
              // one, each reserving space for the next by a hand-maintained
              // constant — and those constants went stale three times, the
              // last of which drew the minimap ON TOP of the route list. They
              // are rows inside the dock now, so the dock's own height is
              // whatever it renders and nothing has to predict it.
              0.0
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
                  // ONE dock, two lanes: the faces are its pinned header,
                  // the routes (or the map) its body. Three floating panels
                  // used to share this band — the legend, the dot row and the
                  // minimap — each reserving space for the next by a constant
                  // somebody had to keep in step with the widget's real
                  // height. Nobody did, three times running; the last of them
                  // put the minimap on top of the route list on a real phone.
                  // A dock cannot get that wrong because there is nothing
                  // below it to clear.
                  if (laneVisible)
                    Positioned(
                      left: MasiSpacing.md,
                      right: MasiSpacing.md,
                      bottom: effectiveLegendBottomPadding,
                      child: _TopoDock(
                        wallId: wallId,
                        photos: facePhotos,
                        layout: faceLayout,
                        activePhotoId: drawState.activePhotoId,
                        routeCount: drawState.routes.length,
                        faceRouteCounts: faceRouteCounts,
                        // The dock's OWN open flag, not the legend's: the
                        // plain floating card still opens by default for the
                        // callers that get one, and the dock deliberately does
                        // not.
                        expanded: ref.watch(dockExpandedProvider(wallId)),
                        legendMaxHeight: overlayLegendMaxHeight,
                        readOnly: readOnly,
                        isSwitchingPhoto: drawState.isSwitchingPhoto,
                        onToggleExpanded: () => ref
                            .read(dockExpandedProvider(wallId).notifier)
                            .toggle(),
                        onSelectFace: onSelectFace,
                        onManageFace: onManageFace,
                        onOpenFaceMap: onOpenFaceMap,
                        onAddPhoto: onAddPhoto,
                        onOpenCommunity: community,
                        onLogAscent: drawState.mode == DrawMode.draw
                            ? null
                            : onLogAscent,
                        onEditRoute: drawState.mode == DrawMode.draw
                            ? onEditRoute
                            : null,
                        // NOT mode-gated. Noticing that a climb is the wrong
                        // one happens while READING the legend, which is view
                        // mode, and having to enter draw mode to correct it is
                        // how it stayed uncorrected.
                        onSameClimbAs: onSameClimbAs,
                      ),
                    )
                  else ...[
                    if (!hasRoutes && community != null)
                      Positioned(
                        left: MasiSpacing.md,
                        right: MasiSpacing.md,
                        bottom: effectiveLegendBottomPadding,
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: _CommunityChip(onTap: community),
                        ),
                      ),
                    if (hasRoutes && !embedded)
                      Positioned(
                        left: MasiSpacing.md,
                        right: MasiSpacing.md,
                        bottom: effectiveLegendBottomPadding,
                        child: legendExpanded
                            ? GlassChrome(
                                key: const Key('topo-route-legend-overlay'),
                                strong: true,
                                // #80: was solid-on-web (`!kIsWeb`) to cap
                                // simultaneous `BackdropFilter`s, leaving the
                                // legend flat next to the frosted title pill —
                                // now blurs on web too, to match the header.
                                blur:
                                    true, // #80: frost the legend on web too, to match the header pill
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
                                        onCollapse: () => ref
                                            .read(
                                              legendExpandedProvider(
                                                wallId,
                                              ).notifier,
                                            )
                                            .toggle(),
                                        onOpenCommunity: community,
                                      ),
                                      RouteLegend(
                                        wallId: wallId,
                                        maxHeight: overlayLegendMaxHeight,
                                        readOnly: readOnly,
                                        // No logging an ascent while editing
                                        // (user request, 2026-08-11): draw mode
                                        // is for the drawing, and a per-row
                                        // "send" button beside the hide/delete
                                        // pair belongs to reading a topo, not
                                        // building one.
                                        onLogAscent:
                                            drawState.mode == DrawMode.draw
                                            ? null
                                            : onLogAscent,
                                        // The mirror image of the line above:
                                        // editing a route is an EDIT-mode
                                        // action, logging an ascent is a
                                        // VIEW-mode one, so the two swap over
                                        // at the same boundary and the row
                                        // never carries both.
                                        onEditRoute:
                                            drawState.mode == DrawMode.draw
                                            ? onEditRoute
                                            : null,
                                        onSameClimbAs: onSameClimbAs,
                                      ),
                                      if (community != null)
                                        _CommunityRow(onTap: community),
                                    ],
                                  ),
                                ),
                              )
                            : Align(
                                alignment: Alignment.centerLeft,
                                child: _LegendChip(
                                  key: const Key('topo-route-legend-chip'),
                                  routeCount: drawState.routes.length,
                                  onExpand: () => ref
                                      .read(
                                        legendExpandedProvider(wallId).notifier,
                                      )
                                      .toggle(),
                                ),
                              ),
                      ),
                    // The photo-switch cue. [DrawState.isSwitchingPhoto] is true
                    // from the instant a new photo is selected until its routes
                    // have been read (see DrawController.beginPhotoSwitch), and
                    // for that whole window `routes` is deliberately empty — so
                    // tapping a strip thumbnail swapped the image instantly and
                    // then showed a topo with NO routes on it, indistinguishable
                    // from a photo nobody has drawn on, until they popped in.
                    // Nothing in the tree read the flag at all before this. Shown
                    // only when the legend is not (an existing route set means the
                    // switch is already over, or is a mid-switch commit carrying
                    // forward) and never in the embedded preview, which paints no
                    // floating chrome by contract.
                    //
                    // The `isLoading: true` below is HARDCODED on purpose, and
                    // reads like a stuck skeleton, so: the flag it is gated on is
                    // the resolution mechanism, not the gate's own argument. What
                    // makes that terminal is that DrawController settles
                    // `isSwitchingPhoto` on EVERY exit path — `loadForWall`'s
                    // success, `loadForWall`'s catch (see its UF-2 doc: a stuck
                    // `true` there once carried stray routes into an unrelated
                    // photo and PERSISTED them), and `cancelPhotoSwitch` when a
                    // switch turns out to have nothing to load. Pinned by
                    // `canvas_loading_states_test.dart`'s "and it clears on EVERY
                    // way a switch can end". Widen this condition to something a
                    // settle does not clear (a recorded failure, say) and the pill
                    // becomes a "Loading routes…" that never resolves — the exact
                    // lie it was added to prevent.
                    if (drawState.isSwitchingPhoto && !hasRoutes && !embedded)
                      Positioned(
                        left: MasiSpacing.md,
                        right: MasiSpacing.md,
                        bottom: effectiveLegendBottomPadding,
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: MasiLoadingGate(
                            isLoading: true,
                            builder: (context, showLoading) => showLoading
                                ? const _RoutesLoadingChip()
                                : const SizedBox.shrink(),
                          ),
                        ),
                      ),
                  ],
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

/// The photo-switch cue: a frosted pill in the collapsed legend's own position
/// saying the routes for the photo now on screen are still being read.
///
/// Deliberately shaped like [_LegendChip] (same [GlassChrome], same padding,
/// same slot) because it stands in for exactly that chip — so when the load
/// lands, the chip or the legend card appears where this was rather than
/// somewhere else.
class _RoutesLoadingChip extends StatelessWidget {
  const _RoutesLoadingChip();

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    return GlassChrome(
      key: const Key('topo-routes-loading'),
      strong: true,
      blur: true,
      padding: const EdgeInsets.symmetric(
        horizontal: MasiSpacing.md,
        vertical: MasiSpacing.sm,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          MasiLoadingIndicator.inline(
            // The gate at the call site owns both delays.
            revealDelay: Duration.zero,
            minVisible: Duration.zero,
            color: colors.accent,
            semanticLabel: 'Loading this photo’s routes',
          ),
          const SizedBox(width: MasiSpacing.sm),
          Flexible(
            child: Text(
              'Loading routes…',
              style: Theme.of(
                context,
              ).textTheme.labelLarge?.copyWith(color: colors.ink),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
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
  const _LegendChip({
    super.key,
    required this.routeCount,
    required this.onExpand,
  });

  final int routeCount;

  /// Expands back to the full card. Wired to BOTH a tap and an upward drag —
  /// see [_LegendHeader] for why the drag exists at all.
  final VoidCallback onExpand;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    return GlassChrome(
      strong: true,
      // #80: was solid-on-web (stacked-blur cap), same reasoning as the
      // expanded legend card — now blurs on web too, for the same reason.
      blur: true, // #80: frost the legend on web too, to match the header pill
      padding: const EdgeInsets.symmetric(
        horizontal: MasiSpacing.md,
        vertical: MasiSpacing.sm,
      ),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onExpand,
        // An upward flick expands, the same gesture that works on the
        // expanded card's handle — so "drag this panel up for more" is one
        // rule across both of its states rather than a tap-only chip and a
        // draggable card.
        onVerticalDragEnd: (details) {
          if (details.primaryVelocity != null &&
              details.primaryVelocity! < -_kPanelFlickVelocity) {
            onExpand();
          }
        },
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

/// Vertical flick speed (logical px/s) past which a drag on the route panel
/// counts as a deliberate up/down gesture rather than an inexact tap.
/// Flutter's own bottom sheets use the same order of magnitude
/// (`_minFlingVelocity` is 700 in `bottom_sheet.dart`); 300 is deliberately
/// lower because this panel is small and its drags are short.
const double _kPanelFlickVelocity = 300;

/// The full-width "Comments & ascents" row at the foot of the expanded route
/// panel — the visible half of what replaced the top row's speech-bubble
/// glyph (the other half is the handle's upward drag, see [_LegendHeader]).
///
/// A labelled row rather than another icon on purpose: the gesture is faster
/// once you know it exists, and nothing on a canvas teaches you that it does.
class _CommunityRow extends StatelessWidget {
  const _CommunityRow({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Divider(
          height: 1,
          thickness: 0.5,
          color: colors.ink3.withValues(alpha: 0.4),
        ),
        InkWell(
          key: const Key('topo-open-community'),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: MasiSpacing.sm,
              vertical: MasiSpacing.sm,
            ),
            child: Row(
              children: [
                MasiIcon('comment', size: 18, color: colors.accent),
                const SizedBox(width: MasiSpacing.sm),
                Expanded(
                  child: Text(
                    'Comments & ascents',
                    style: Theme.of(
                      context,
                    ).textTheme.labelLarge?.copyWith(color: colors.accent),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                MasiIcon('chevron_right', size: 18, color: colors.accent),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// The same destination as [_CommunityRow], standing alone as a frosted pill
/// for the one case the route panel does not cover: a published wall whose
/// active photo has no routes drawn on it yet, where there is no legend card
/// for a footer row to sit in.
class _CommunityChip extends StatelessWidget {
  const _CommunityChip({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    return GlassChrome(
      strong: true,
      blur: true,
      padding: const EdgeInsets.symmetric(
        horizontal: MasiSpacing.md,
        vertical: MasiSpacing.sm,
      ),
      child: GestureDetector(
        key: const Key('topo-open-community-chip'),
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            MasiIcon('comment', size: 18, color: colors.accent),
            const SizedBox(width: MasiSpacing.sm),
            Flexible(
              child: Text(
                'Comments & ascents',
                style: Theme.of(
                  context,
                ).textTheme.labelLarge?.copyWith(color: colors.accent),
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

/// The expanded route panel's header: a grab handle, the route count, and a
/// collapse chevron. Lives INSIDE the card's own
/// `Material(type: transparency)` (see the legend-overlay build site) so its
/// [InkWell] gets a splash.
///
/// The grab handle used to be decoration and nothing else, which is the bug
/// this rewrite fixes (user report, 2026-08-11: "the horizontal line suggests
/// pulling but pulling doesn't do anything"). It is a real drag target now,
/// and the panel behaves like the bottom sheet it has always looked like:
///
///  * drag/flick DOWN, or tap the chevron — collapse to [_LegendChip];
///  * drag/flick UP — the next level of detail, i.e. the community view of
///    this wall ([onOpenCommunity]), which is the same destination as the
///    footer row below the list.
///
/// The chevron is a real [IconButton] now rather than a decorative glyph
/// inside a tap-anywhere row, for the other half of the same report ("the
/// down pointing arrow is random"): it points down because down is where it
/// puts the panel, and it is the only thing in this header that a tap acts
/// on. Tapping the label or the handle does nothing — the header is a drag
/// surface, and a row that both drags and swallows taps is how you collapse
/// a panel you meant to pull.
class _LegendHeader extends StatelessWidget {
  const _LegendHeader({
    required this.routeCount,
    required this.onCollapse,
    this.onOpenCommunity,
  });

  final int routeCount;
  final VoidCallback onCollapse;

  /// Null when this wall has no community page — an upward drag then simply
  /// does nothing rather than dead-ending somewhere. See
  /// [TopoCanvasBody.onOpenCommunity].
  final VoidCallback? onOpenCommunity;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    final community = onOpenCommunity;
    return GestureDetector(
      key: const Key('topo-route-legend-handle'),
      behavior: HitTestBehavior.opaque,
      onVerticalDragEnd: (details) {
        final velocity = details.primaryVelocity;
        if (velocity == null) return;
        if (velocity > _kPanelFlickVelocity) {
          onCollapse();
        } else if (velocity < -_kPanelFlickVelocity && community != null) {
          community();
        }
      },
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
                IconButton(
                  key: const Key('topo-route-legend-collapse'),
                  tooltip: 'Collapse the route list',
                  onPressed: onCollapse,
                  iconSize: 18,
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.all(4),
                  constraints: const BoxConstraints(
                    minWidth: 36,
                    minHeight: 36,
                  ),
                  icon: MasiIcon('chevron_down', size: 18, color: colors.ink),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The bottom dock: one surface carrying both of the things a reader needs
/// down here, instead of three floating panels stacked on each other.
///
/// **Why one panel and not three.** The face lane, the face map and the route
/// list all wanted the same band above the safe area. Each was a separate
/// `Positioned`, so each had to be told how tall the ones below it were — a
/// chain of hand-maintained constants (`kDrawHintHeight`,
/// `kBottomChromeClusterHeight`, and a `FacePager.reservedHeight` built from
/// two more) that only stayed true while nobody edited a padding. It went
/// stale three times: the draw hint landed on the collapsed chip, the chip
/// landed on the dot row, and finally the minimap was drawn straight over the
/// route list on a real phone. The measured gap at that point was 17px —
/// `reservedHeight` claimed 191 for a widget that rendered 208.
///
/// A dock ends that class of bug outright rather than correcting the latest
/// instance of it: the lane and the list are rows in one `Column`, so the
/// surface is exactly as tall as what it draws and nothing downstream has to
/// predict it. There is no clearance term left for the face lane at all.
///
/// **One lane and one body.** The pinned header is the rail — the photos
/// themselves, one tile each ([FaceRail]). The body is the route list, and
/// only ever the route list. The plan view used to be the other half of a
/// two-lane body here, and before that a card mounted permanently above the
/// legend at 153pt; it is a full screen now ([FaceMapScreen]), one tap away
/// behind the rail's leading tile, and costs this panel nothing until asked
/// for. What the reader gets back is the bottom half of their photo.
class _TopoDock extends StatelessWidget {
  const _TopoDock({
    required this.wallId,
    required this.photos,
    required this.layout,
    required this.activePhotoId,
    required this.routeCount,
    required this.faceRouteCounts,
    required this.expanded,
    required this.legendMaxHeight,
    required this.readOnly,
    required this.isSwitchingPhoto,
    required this.onToggleExpanded,
    required this.onSelectFace,
    required this.onManageFace,
    required this.onOpenFaceMap,
    required this.onAddPhoto,
    required this.onOpenCommunity,
    required this.onLogAscent,
    required this.onEditRoute,
    required this.onSameClimbAs,
  });

  final String wallId;
  final List<PhotoRef> photos;
  final LayoutResult? layout;
  final String? activePhotoId;
  final int routeCount;
  final Map<String, int> faceRouteCounts;
  final bool expanded;
  final double legendMaxHeight;
  final bool readOnly;
  final bool isSwitchingPhoto;
  final VoidCallback onToggleExpanded;
  final void Function(PhotoRef photo)? onSelectFace;
  final void Function(PhotoRef photo)? onManageFace;
  final VoidCallback? onOpenFaceMap;
  final VoidCallback? onAddPhoto;
  final VoidCallback? onOpenCommunity;
  final void Function(int routeId)? onLogAscent;
  final void Function(int routeId)? onEditRoute;
  final void Function(int routeId)? onSameClimbAs;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    final plan = layout;
    // No plan tile for a wall whose baseline is still loading or degenerate:
    // a tile that opens an empty screen is worse than no tile.
    final planAvailable = plan != null && !plan.baseline.isDegenerate;
    final select = onSelectFace ?? (_) {};

    return GlassChrome(
      key: const Key('topo-dock'),
      strong: true,
      blur: true,
      // `Material(type: transparency)` — required so RouteLegend's ListTiles
      // have a Material ancestor closer than the Scaffold's own. See the
      // identical wrapper on the non-dock legend card for the assertion this
      // avoids.
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _DockLane(
              photos: photos,
              layout: plan,
              activePhotoId: activePhotoId,
              routeCount: routeCount,
              faceRouteCounts: faceRouteCounts,
              expanded: expanded,
              colors: colors,
              onToggleExpanded: onToggleExpanded,
              onOpenMap: planAvailable ? onOpenFaceMap : null,
              onAddPhoto: onAddPhoto,
              onSelect: select,
              onManage: onManageFace,
              onOpenCommunity: onOpenCommunity,
            ),
            if (expanded) ...[
              Divider(
                key: const Key('topo-dock-body'),
                height: 1,
                thickness: 1,
                color: colors.separator,
              ),
              if (routeCount > 0)
                RouteLegend(
                  key: const Key('topo-dock-routes'),
                  wallId: wallId,
                  maxHeight: legendMaxHeight,
                  readOnly: readOnly,
                  onLogAscent: onLogAscent,
                  onEditRoute: onEditRoute,
                  onSameClimbAs: onSameClimbAs,
                )
              else if (isSwitchingPhoto)
                const Padding(
                  padding: EdgeInsets.all(MasiSpacing.md),
                  child: _RoutesLoadingChip(),
                ),
              if (onOpenCommunity case final open?) _CommunityRow(onTap: open),
            ],
          ],
        ),
      ),
    );
  }
}

/// The dock's pinned header: which face you are on, and the way into the rest.
///
/// The rail is the whole of it — a tile per photo, plus the plan tile that
/// opens the map and the '+' that adds another photo. It replaced a row of
/// 7px dots, and the difference is not decoration: a dot says there is a
/// fourth face, a thumbnail says what is on it. It scrolls horizontally
/// rather than shrinking, because a rock with a dozen photos is a real thing
/// and tiles that get smaller until they are one grey smear stop being a
/// control at all.
class _DockLane extends StatelessWidget {
  const _DockLane({
    required this.photos,
    required this.layout,
    required this.activePhotoId,
    required this.routeCount,
    required this.faceRouteCounts,
    required this.expanded,
    required this.colors,
    required this.onToggleExpanded,
    required this.onOpenMap,
    required this.onAddPhoto,
    required this.onSelect,
    required this.onManage,
    required this.onOpenCommunity,
  });

  final List<PhotoRef> photos;
  final LayoutResult? layout;
  final String? activePhotoId;
  final int routeCount;
  final Map<String, int> faceRouteCounts;
  final bool expanded;
  final MasiColors colors;
  final VoidCallback onToggleExpanded;
  final VoidCallback? onOpenMap;
  final VoidCallback? onAddPhoto;
  final void Function(PhotoRef photo) onSelect;
  final void Function(PhotoRef photo)? onManage;
  final VoidCallback? onOpenCommunity;

  @override
  Widget build(BuildContext context) {
    final community = onOpenCommunity;
    final canExpand = routeCount > 0 || community != null;

    return GestureDetector(
      key: const Key('topo-dock-lane'),
      behavior: HitTestBehavior.opaque,
      // The same three-way flick the panel had before the lane existed, kept
      // verbatim so the gesture means one thing across every state of this
      // surface: down closes, up opens, up again reaches the community page.
      onVerticalDragEnd: (details) {
        final velocity = details.primaryVelocity;
        if (velocity == null) return;
        if (velocity > _kPanelFlickVelocity) {
          if (expanded) onToggleExpanded();
        } else if (velocity < -_kPanelFlickVelocity) {
          if (!expanded) {
            onToggleExpanded();
          } else if (community != null) {
            community();
          }
        }
      },
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          MasiSpacing.xs,
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
                Expanded(
                  child: FaceRail(
                    photos: photos,
                    layout: layout,
                    activePhotoId: activePhotoId,
                    routeCounts: faceRouteCounts,
                    onSelect: onSelect,
                    onManage: onManage,
                    onOpenMap: onOpenMap,
                    onAddPhoto: onAddPhoto,
                    colors: colors,
                  ),
                ),
                if (canExpand)
                  GestureDetector(
                    key: const Key('topo-dock-routes-toggle'),
                    behavior: HitTestBehavior.opaque,
                    onTap: onToggleExpanded,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(
                        MasiSpacing.xs,
                        MasiSpacing.sm,
                        MasiSpacing.sm,
                        MasiSpacing.sm,
                      ),
                      child: Semantics(
                        button: true,
                        label:
                            '${_routeCountLabel(routeCount)}, '
                            '${expanded ? 'close the list' : 'open the list'}',
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // Spelled out, this said '0 routes' in most of
                            // a thumbnail's width, to name a list that names
                            // itself the moment it opens — and it took that
                            // width from the photos, which are what the rail
                            // is for. What survives is the count and the
                            // chevron that opens the list; the count is set
                            // in the quieter ink so it reads as a tally
                            // against the chevron rather than as another of
                            // the rail's numbered tiles.
                            if (routeCount > 0) ...[
                              Text(
                                '$routeCount',
                                style: Theme.of(context).textTheme.labelMedium
                                    ?.copyWith(color: colors.ink2),
                                maxLines: 1,
                              ),
                              const SizedBox(width: 3),
                            ],
                            MasiIcon(
                              expanded ? 'chevron_down' : 'chevron_up',
                              size: 18,
                              color: colors.ink,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
