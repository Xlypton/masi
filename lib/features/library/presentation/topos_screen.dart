import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart' show MapController, TileProvider;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:latlong2/latlong.dart';

import '../../../app/shell_notice_dismissal.dart';
import '../../../app/theme.dart';
import '../../../core/db/storage_durability_provider.dart';
import '../../../core/grades/grade_system.dart';
import '../../../core/location/location_service.dart';
import '../../../shared/filtering/grade_range_picker.dart';
import '../../../shared/filtering/min_stars_filter_chips.dart';
import '../../moderation/application/duplicate_providers.dart';
import '../../moderation/application/moderation_providers.dart';
import '../../moderation/application/trust_providers.dart';
import '../../moderation/domain/moderation_state.dart';
import '../../moderation/presentation/access_editor.dart';
import '../../moderation/presentation/duplicate_warning_sheet.dart';
import '../../moderation/presentation/topo_history_sheet.dart';
import '../../../shared/filtering/style_filter_chips.dart';
import '../../../shared/filtering/style_tag_filter_chips.dart';
import '../../account/application/auth_providers.dart';
import '../../account/application/profile_providers.dart';
import '../../backup/application/offline_banner_dismissal.dart';
import '../../backup/application/reachability_providers.dart';
import '../../backup/application/sync_orchestrator.dart';
import '../../backup/data/sync_service.dart' show SharedPhotoBudgetReason;
import '../../community/data/community_repository.dart' show SharedTopo;
import '../../topo/data/image_dimensions.dart';
import '../../topo/presentation/photo_image.dart';
import '../../topo/presentation/photo_source_sheet.dart';
import '../../topo/data/photo_write_exception.dart';
import '../../topo/presentation/topo_canvas_screen.dart'
    show
        captureWallGpsFromPhoto,
        gpsCaptureResultSnackBar,
        photoWriteFailureSnackBar;
import '../../community/application/community_providers.dart'
    show myLocationProvider;
import '../application/library_providers.dart';
import '../application/proximity_topos_provider.dart';
import '../application/topo_tree.dart';
import '../data/library_crud_repository.dart';
import '../../../shared/presentation/masi_async_view.dart';
import '../../../shared/presentation/masi_avatar.dart';
import '../../../shared/presentation/masi_dialogs.dart';
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
// states) purely for file-size/readability — `part`/`part of`
// keeps them all in this ONE library, so every `_Foo` below stays exactly as
// library-private as it always was; nothing here is a public-API change.
// [ToposScreen] itself (the only symbol anything outside this library
// references) stays in this file, at its original path, per plan.
part 'topos_row.dart';
part 'topos_badges.dart';
part 'topos_filter.dart';
part 'topos_empty_states.dart';
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

/// The compact companion to [_StorageWarningBanner] (device-screenshot bug
/// fix, "say it once"): rendered in its place whenever `storageRetryNotice`
/// is non-null, i.e. whenever `app/nav_shell.dart`'s `ShellNotices` is
/// ALREADY showing `StorageRetryBanner` above this whole branch with the
/// human sentence and a working "Try again".
///
/// `_StorageWarningBanner`'s `unavailable` branch says almost that same
/// sentence again ("Can't open your saved topos... reload to try again"),
/// which is what produced the reported bug: two red blocks, one message,
/// filling the whole screen. This widget is deliberately NOT a rewrite of
/// that banner — `topos_storage_banner.dart` stays untouched, since its copy
/// is still exactly right for the two verdicts where the shell has nothing to
/// say (a schema downgrade; a chosen non-durable backend) — it is what is
/// left to say ONLY for the verdict the shell already covers: the technical
/// detail line worth reporting. Deleting that line outright was considered
/// and rejected — it is the one thing a "my data vanished" report needs and
/// the shell's compact banner has no room for it.
///
/// Bounded by construction (`maxLines`, no scroll needed) rather than by a
/// `ConstrainedBox`/viewport-share cap like `_StorageWarningBanner`: three
/// short lines of monospace-ish diagnostic text cannot repeat that banner's
/// 561px-into-364px overflow, so there is nothing here for a cap to guard
/// against — see `topos_screen_test.dart`'s squeeze-viewport coverage, which
/// pins that this stays true.
class _StorageDetailNotice extends StatelessWidget {
  const _StorageDetailNotice({required this.durability});

  final StorageDurability durability;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    final textTheme = Theme.of(context).textTheme;
    // Deliberately re-derived here rather than shared with
    // `_StorageWarningBanner`'s identical computation: that banner lives in
    // `topos_storage_banner.dart`, a file this fix does not touch, and the
    // alternative (a shared helper in `core/db/connection/storage_durability.dart`)
    // would edit a file outside this fix's remit for eight lines of string
    // formatting. Both computations read only `StorageDurability`'s public
    // getters, so they cannot drift into disagreement about what those
    // getters mean — only about wording, and there is none to disagree on
    // here.
    final missing = durability.missingFeatures.map((f) => f.name).toList()
      ..sort();
    final detail = StringBuffer(
      'Storage: '
      '${durability.backend?.name ?? (durability.unavailable ? 'unavailable' : 'probing')}',
    );
    if (missing.isNotEmpty) {
      detail.write(' · missing: ${missing.join(', ')}');
    }
    if (durability.unavailableReason != null) {
      detail.write(' · ${durability.unavailableReason}');
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        MasiSpacing.lg,
        MasiSpacing.sm,
        MasiSpacing.lg,
        0,
      ),
      child: Text(
        'If this keeps happening, report: ${detail.toString()}',
        key: const Key('topos-storage-detail-only'),
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        style: textTheme.labelSmall?.copyWith(color: colors.ink3),
      ),
    );
  }
}

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

  /// The [ToposGroupNode.id]s the user has opened in the tiered list.
  ///
  /// Held here, on the SCREEN state, rather than inside `_ToposList` or the row
  /// widgets: this list rebuilds constantly — every keystroke in the search
  /// field, every sync pull re-emitting `toposProvider`, every location
  /// refresh re-sorting the entries — and a group that snapped shut on any of
  /// those would be unusable. Keyed by id rather than by list position for the
  /// same reason: a group must stay open even when a fresh distance moves it
  /// up or down the list.
  ///
  /// Deliberately NOT persisted across app launches. The tiering is a function
  /// of where the climber is standing, so yesterday's expansions describe
  /// yesterday's location; restoring them would reopen groups that are now far
  /// away while the ones underfoot stayed shut.
  final Set<String> _expandedGroupIds = <String>{};

  void _toggleGroup(String groupId) {
    setState(() {
      if (!_expandedGroupIds.remove(groupId)) {
        _expandedGroupIds.add(groupId);
      }
    });
  }

  /// Wall ids whose moderation state this screen has already asked the server
  /// about, so the pull below runs once per topo per screen mount rather than
  /// on every rebuild (and this list rebuilds on every keystroke in the search
  /// field).
  final _moderationPulled = <String>{};

  /// Fills the moderation mirror for the user's own SHARED topos.
  ///
  /// Without this the library is the one place that never learns what happened
  /// to a submission: `wall_moderation` is pull-only and nothing else on this
  /// screen fetches it, so a topo waiting in the review queue would keep
  /// showing the plain "Published" badge it had before it was ever submitted.
  /// Only shared topos are asked about — a draft has no server-side moderation
  /// story worth a round trip.
  ///
  /// Fire-and-forget by design: [refreshWallModeration] is documented never to
  /// throw, and a badge that fails to sharpen must not be able to break the
  /// list it sits in.
  void _pullModerationFor(List<ProximityTopoEntry> entries) {
    final wanted = <String>{
      for (final entry in entries)
        if (entry.ownTopo?.visibility == 'shared') entry.wallId,
    }..removeAll(_moderationPulled);
    if (wanted.isEmpty) return;
    _moderationPulled.addAll(wanted);
    // The WidgetRef half, guarded down to the provider reads themselves — see
    // `refreshWallModerationFrom`. Deferred by a microtask because this is
    // called from `build`.
    Future.microtask(() => refreshWallModerationFrom(ref, wanted));
  }

  /// [_OfflineEmptyState]'s Retry: re-probes `reachabilityProvider` first
  /// (the same probe-on-demand contract `initState` uses at mount — see that
  /// provider's doc), then re-runs the real pull too, but ONLY if that fresh
  /// probe actually came back online. Re-pulling while still offline would
  /// just repeat the same failed request; re-probing without ever pulling
  /// would leave a genuinely-restored connection sitting there unused until
  /// the next unrelated rebuild. Never throws — `refresh()`/`pullNow()` are
  /// both documented not to.
  Future<void> _handleOfflineRetry() async {
    final verdict = await ref.read(reachabilityProvider.notifier).refresh();
    if (verdict.isKnownOnline) {
      await ref.read(syncOrchestratorProvider.notifier).pullNow();
    }
  }

  /// [body] — the whole loading/error/empty/list stack — with [banner] hung
  /// above it as a SLIVER of the same scroll view, so the banner can be
  /// scrolled out of the way once read.
  ///
  /// **Why a [NestedScrollView] and not "item 0 of the list".** A header baked
  /// into `_ToposList` would be correct exactly when there is a list, and would
  /// silently vanish in every one of the five states that render INSTEAD of one
  /// — `_SyncErrorEmptyState`, `_OfflineEmptyState`, `_EmptyState`,
  /// `_SearchEmptyState`, `_FilteredEmptyState`, plus the skeleton and
  /// `MasiAsyncView`'s error branch. Offline-at-a-crag with an empty library is
  /// precisely the case this banner exists for (see `SyncBanner`'s doc), so
  /// disappearing there would delete the feature while looking like it worked.
  /// Wrapping the whole of [body] instead means every one of those states keeps
  /// the banner, for free, and no future empty state can forget it.
  ///
  /// The inner scrollables need no changes: [NestedScrollView] publishes its
  /// inner controller through a [PrimaryScrollController] that inherits on
  /// every platform, and `_ToposList`'s `ListView` and `_EmptyStateShell`'s
  /// `SingleChildScrollView` both take no explicit controller, so they attach
  /// to it and drag the header away as they scroll.
  ///
  /// **Returns [body] UNWRAPPED when there is no banner.** The overwhelmingly
  /// common case then keeps byte-identical layout and scroll behaviour to
  /// before this existed, and a dismissal gives back the banner's space
  /// exactly — margin and all — rather than leaving an empty header sliver
  /// behind.
  Widget _withSyncBannerHeader({
    required Widget? banner,
    required Widget body,
  }) {
    if (banner == null) return body;
    return NestedScrollView(
      headerSliverBuilder: (context, innerBoxIsScrolled) => [
        SliverToBoxAdapter(child: banner),
      ],
      body: body,
    );
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
    // "Say it once" (device-screenshot bug fix): `storageRetryNotice` is the
    // EXACT same predicate `app/nav_shell.dart`'s `ShellNotices` uses to
    // decide whether `StorageRetryBanner` is on screen above this whole
    // branch — non-null for `StorageDurability.unavailable` verdicts other
    // than a schema downgrade (see that function's doc). Whenever it is
    // non-null, the shell has ALREADY said the human sentence and offered a
    // working "Try again" — `_StorageWarningBanner`'s own `unavailable`
    // branch says almost the identical sentence, so rendering both stacked
    // vertically filled the whole screen with two red blocks repeating one
    // fact. Computed from `storage` alone (not from anything about the
    // widget tree), which is safe because `ToposScreen` is only ever reached
    // as a branch of `NavShell` in production (see `router.dart`), so this
    // always agrees with what the shell actually did.
    final storageRetryNoticeText = storageRetryNotice(storage);
    // Defect-C fix: `_StorageDetailNotice` exists only as this exact banner's
    // companion (see its own doc), so it must disappear the moment the user
    // dismisses THAT banner — not stay behind as an orphaned diagnostic line
    // with no context and no retry. Reads the SAME shared
    // `shellNoticeDismissalProvider` `nav_shell.dart`'s `ShellNotices` writes
    // to (via `StorageRetryBanner`'s own dismiss button), comparing against
    // the identical signature that banner computes for itself.
    final shellStorageNoticeDismissed =
        storageRetryNoticeText != null &&
        ref.watch(shellNoticeDismissalProvider) ==
            ShellNoticeDismissalController.signature(
              'storageRetry',
              storageRetryNoticeText,
            );

    // Only an *actually loaded* topo list (AsyncData) is a safe source for
    // the "New topo" count; while still loading or errored there is no
    // trustworthy count to derive "Topo N+1" from, so the button must be
    // disabled rather than fall back to an empty list and mint "Topo 1"
    // over an existing topo. `storage.isEphemeral` is the third gate: it is
    // false while the verdict is still unknown (`probing`), so the interlock
    // only ever blocks on a KNOWN-bad backend.
    final loadedTopos = asyncTopos.asData?.value;
    final canCreate = loadedTopos != null && !_creating && !storage.isEphemeral;

    // Stage 3 (T2). Before this, EVERY sync/offline signal on this screen
    // lived inside the `proximityEntries.isEmpty` branch below, so the user
    // who had the most to lose — the one who HAS topos — was told nothing at
    // all. Offline at a crag they watch a list quietly fail to refresh and
    // conclude the app ate their work. The banner therefore renders
    // irrespective of how much is in the list — as the first SLIVER of the
    // scroll view below, so it can be scrolled out of the way but never
    // vanishes just because a list is empty. See `SyncBanner`'s class doc.
    //
    // `isKnownOffline`, never `!= online`: `Reachability.unknown` is the
    // pre-probe state, and treating it as offline flashes this banner for a
    // frame on every cold start (see `reachability_providers.dart`).
    final reachability = ref.watch(reachabilityProvider);
    final syncState = ref.watch(syncOrchestratorProvider);
    final pullError = syncState.lastPullError;
    // The full-screen `_SyncErrorEmptyState` below already reports a pull
    // error — larger, and with its own Retry — whenever the library is
    // genuinely empty. Rendering the banner too would print the same
    // sentence twice on one screen, so the banner yields in exactly that
    // case. The OFFLINE banner never yields: no empty state says anything
    // about reachability, and "No topos yet" on its own is precisely what
    // reads as "your topos are gone".
    final emptyStateOwnsTheError =
        loadedTopos != null && proximityEntries.isEmpty && pullError != null;
    // Device-screenshot bug fix, part 2 of "say it once": `asyncTopos` going
    // to a HARD error (no cached value at all) is exactly the case
    // `MasiAsyncView` below renders as its own full-screen "Couldn't load
    // your topos" + Retry (`_errorState`) — see that widget's doc. Without
    // this guard the sync/offline banner still resolves from `reachability`/
    // `pullError` alone and rides as the FIRST SLIVER above that full-screen
    // error, so the one underlying failure was reported three times over on
    // one screen: the shell's `StorageRetryBanner` ("Your topos couldn't be
    // opened"), this banner ("Couldn't sync"), and `MasiAsyncView`'s own
    // error ("Couldn't load your topos") — the exact stack from the reported
    // screenshot. `emptyStateOwnsTheError` above already covers the milder
    // sibling case (list loaded, but empty); this is its hard-error twin, and
    // strictly the more urgent one to fix since it hides the ENTIRE list, not
    // just an empty one.
    final asyncToposHardError = asyncTopos.hasError && !asyncTopos.hasValue;
    // #49 P2 fix: lowest priority of the three — a real fault or being
    // offline is worth reading about first, and this is neither: the pull
    // succeeded, it just downloaded fewer other-climbers' photos than usual.
    final sharedPhotosWithheld =
        syncState.lastSharedPhotoBudgetReason ==
        SharedPhotoBudgetReason.storagePressure;
    final SyncBannerKind? bannerKind = asyncToposHardError
        ? null
        : reachability.isKnownOffline
        ? SyncBannerKind.offline
        : (pullError != null && !emptyStateOwnsTheError)
        ? SyncBannerKind.syncFailed
        : sharedPhotosWithheld
        ? SyncBannerKind.sharedPhotosWithheld
        : null;
    // The reason text this banner is actually reporting. `null` for every kind
    // but `syncFailed`, matching `SyncBanner.detail`'s own contract — and the
    // reason the DISMISSAL below cannot be knocked loose by a stale pull error
    // changing underneath an offline banner that was never showing it.
    final bannerDetail = bannerKind == SyncBannerKind.syncFailed
        ? pullError
        : null;
    // The user closed THIS banner (see `offline_banner_dismissal.dart` — the
    // acknowledgement is shared with the Community Feed, re-arms when the
    // message changes, and, for the offline kind, expires with the offline
    // episode). Applied as a suppression of the resolved kind rather than
    // folded into the ranking above: falling through to the next kind would
    // answer "I've read that you're offline" by printing the stale
    // `SocketException` the offline banner deliberately outranks.
    final bannerSignature = bannerKind == null
        ? null
        : SyncBannerDismissalController.signature(
            bannerKind.name,
            bannerDetail,
          );
    // The RAW condition — reachability/pullError/sharedPhotosWithheld alone,
    // with NEITHER of this screen's own display suppressions
    // (`emptyStateOwnsTheError`, `asyncToposHardError`) folded in — reported
    // to the dismissal controller on every build so it can tell "the
    // condition actually cleared" apart from "this screen chose not to show
    // it right now" (see `SyncBannerDismissalController.reportCurrent`'s
    // doc). Using `bannerKind` here instead would report `null` the moment a
    // hard load error or an owned empty state suppressed the banner, and
    // wrongly forget a still-live failure's dismissal scope.
    final rawBannerKind = reachability.isKnownOffline
        ? SyncBannerKind.offline
        : pullError != null
        ? SyncBannerKind.syncFailed
        : sharedPhotosWithheld
        ? SyncBannerKind.sharedPhotosWithheld
        : null;
    final rawBannerSignature = rawBannerKind == null
        ? null
        : SyncBannerDismissalController.signature(
            rawBannerKind.name,
            rawBannerKind == SyncBannerKind.syncFailed ? pullError : null,
          );
    // Deferred by a microtask — see `_pullModerationFor`'s identical
    // convention just below for why mutating a provider from a value computed
    // during `build` cannot happen synchronously here.
    Future.microtask(
      () => ref
          .read(syncBannerDismissalProvider.notifier)
          .reportCurrent(rawBannerSignature),
    );
    final dismissedSignature = ref.watch(syncBannerDismissalProvider);
    // Built here, not in the tree below, purely so `bannerKind`'s null check
    // and its use land in one expression the compiler can promote — the tree
    // then only has to ask "is there a banner?".
    //
    // Dismissed means GONE, not collapsed: `null` puts no widget in the tree
    // at all, so neither the banner nor its own top margin contributes a
    // single logical pixel (the same requirement `install_banner.dart`
    // documents at its `SizedBox.shrink()`).
    final Widget? syncBannerWidget =
        (bannerKind == null || bannerSignature == dismissedSignature)
        ? null
        : SyncBanner(
            kind: bannerKind,
            detail: bannerDetail,
            // Nothing useful to press while genuinely offline; the honest
            // advice is to wait for signal.
            onRetry: bannerKind == SyncBannerKind.syncFailed
                ? () => ref.read(syncOrchestratorProvider.notifier).pullNow()
                : null,
            // EVERY kind is closable now (the user's decision — see
            // `SyncBanner.onDismiss`). What keeps that safe is the signature:
            // this acknowledgement covers this exact message and re-arms the
            // moment the underlying error changes.
            onDismiss: () => ref
                .read(syncBannerDismissalProvider.notifier)
                .dismiss(bannerSignature!),
          );

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
                ? MasiAvatar(
                    key: const Key('topos-account-avatar'),
                    avatarUrl: ref.watch(myAvatarUrlProvider).asData?.value,
                    email: signedInEmail,
                    radius: 14,
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
                  // The two DON'T always collide: a schema downgrade and a
                  // chosen-but-non-durable backend (`StorageBackend.inMemory`)
                  // both return `null` from `storageRetryNotice` — the shell
                  // has nothing to say about either, so `_StorageWarningBanner`
                  // remains the ONLY explanation and renders exactly as before.
                  // Only the `unavailable`-and-not-a-downgrade case (the one
                  // in the bug report) is ever actually duplicated.
                  storageRetryNoticeText != null
                      // Defect-C fix: gone entirely once the shell's own
                      // banner for this exact notice was dismissed — see
                      // `shellStorageNoticeDismissed`'s doc. Leaving this
                      // rendering behind would be the orphaned-diagnostic-line
                      // bug the fix exists to close.
                      ? (shellStorageNoticeDismissed
                            ? const SizedBox.shrink()
                            : _StorageDetailNotice(durability: storage))
                      : _StorageWarningBanner(durability: storage),
                _ToposFilterBar(
                  searchController: _searchController,
                  isActive: filter.isActive,
                  onTap: () => _showToposFiltersSheet(context),
                ),
                Expanded(
                  // Pull-to-refresh (user request, 2026-08-11), wrapping the
                  // WHOLE loading/error/empty/list stack rather than
                  // `_ToposList` alone — for the same reason
                  // [_withSyncBannerHeader] wraps all of it: the states where
                  // a climber most wants to yank the list (a failed sync, an
                  // offline empty library) are exactly the ones that render
                  // INSTEAD of a list, and an indicator attached to the list
                  // would be missing from every one of them.
                  //
                  // The gesture reaches whatever scrollable those states
                  // actually build; a state with nothing scrollable simply
                  // never triggers it, and every such state already carries
                  // its own retry button.
                  child: RefreshIndicator(
                    key: const Key('topos-pull-to-refresh'),
                    // The same work the Feed's pull-to-refresh and the Map's
                    // (now deleted) refresh button did: re-run the real remote
                    // pull, then invalidate the local list so a row that
                    // arrived through it shows up. `pullNow()` never throws
                    // and is a safe no-op signed out, so no guard is needed.
                    onRefresh: () async {
                      await ref.read(syncOrchestratorProvider.notifier).pullNow();
                      if (!context.mounted) return;
                      ref.invalidate(toposProvider);
                    },
                    // The sync/offline banner is a SLIVER of this scroll view,
                    // not a `Column` sibling above it — see
                    // [_withSyncBannerHeader]. As a sibling it cost the list
                    // ~122 px that scrolling could never reclaim.
                    child: _withSyncBannerHeader(
                    banner: syncBannerWidget,
                    // Defect-D fix (the reported screenshot): a hard load
                    // error caused by the SAME unopenable-database condition
                    // the shell's `StorageRetryBanner` already explains is
                    // the third repetition of one fact, not a second
                    // diagnosis — the shell already carries the human
                    // sentence AND a working retry, and
                    // `_StorageDetailNotice` above already carries the
                    // diagnostic detail line, so `MasiAsyncView`'s OWN
                    // "Couldn't load your topos" box would say the same thing
                    // a third time on one screen. Suppressed ONLY in this
                    // exact compound state (`asyncToposHardError` alone, or
                    // `storageRetryNoticeText != null` alone, still render
                    // normally — this is not a general MasiAsyncView change);
                    // the create-button interlock and this whole banner
                    // stack already make clear nothing here can be retried
                    // except through the shell's button, which stays live and
                    // re-opens the database that `toposProvider` itself
                    // depends on — so no retry ability is lost, only the
                    // duplicate report of it.
                    body: (asyncToposHardError && storageRetryNoticeText != null)
                        ? const SizedBox.shrink()
                        : MasiAsyncView<List<TopoRef>>(
                      value: asyncTopos,
                      onRetry: () => ref.invalidate(toposProvider),
                      errorMessage: "Couldn't load your topos",
                      // Opted in: this is the local-first library, where the
                      // raw drift/IO text is frequently the only diagnosis a
                      // release build on a phone can offer (#72).
                      showErrorDetail: true,
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
                          // Stage 3 offline-reads gap: a genuinely empty
                          // library with NO reported pull error can still mean
                          // "the app cannot currently tell" rather than "this
                          // account really has nothing" — a device that never
                          // pulled at all, or whose last pull succeeded before
                          // the signal dropped. `isKnownOffline`, never
                          // `!= online`, matching every other reachability
                          // check on this screen (see `bannerKind` above).
                          if (reachability.isKnownOffline) {
                            return _OfflineEmptyState(
                              onRetry: _handleOfflineRetry,
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
                                  .where(
                                    (e) => _matchesProximityQuery(e, query),
                                  )
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
                        // Ask about the SEARCHED/FILTERED set, not the whole
                        // library: the point is to be right about what is on
                        // screen, and a user with hundreds of topos should not
                        // pay a round trip for every one of them to render a
                        // badge on ten.
                        _pullModerationFor(filtered);
                        // Tier the list: nearest topos expanded, the rest
                        // folded into their Sector, and everything past that
                        // folded again into their Area — see `buildToposTree`.
                        //
                        // Suppressed entirely while a SEARCH is active. Someone
                        // who typed a name is asking for a specific topo, and
                        // burying the hit inside a collapsed group they then
                        // have to guess at would defeat the search outright.
                        // A query therefore renders flat, exactly as it did
                        // before tiering existed. The facet filter is NOT
                        // treated the same way: it narrows to a set the
                        // climber still wants to browse by place.
                        final nodes = _query.isNotEmpty
                            ? [
                                for (var i = 0; i < filtered.length; i++)
                                  ToposWallNode(entry: filtered[i], rank: i),
                              ]
                            : buildToposTree(
                                entries: filtered,
                                // `.value`, not `.asData?.value` — the RETAINED
                                // value, for the same reason
                                // `sortedByProximityToposProvider` documents at
                                // length: a merely-reloading provider is an
                                // `AsyncLoading` that still holds its fix, and
                                // reading it as "no fix" would collapse the
                                // whole list for a frame on every auth tick.
                                hasFix:
                                    ref.watch(myLocationProvider).value != null,
                              );
                        return _ToposList(
                          nodes: nodes,
                          expandedGroupIds: _expandedGroupIds,
                          onToggleGroup: _toggleGroup,
                          // The list now runs full-bleed behind the floating
                          // add button (see the `Positioned` button below), so
                          // its bottom padding must clear BOTH the floating nav
                          // bar (`bottomChromeInset`) AND the button itself
                          // (48 height + its own bottom margin) so the last row
                          // can still scroll fully into view instead of ending
                          // up permanently hidden under the button.
                          bottomInset: bottomChromeInset + 64,
                          setLocationTileProvider:
                              widget.setLocationTileProvider,
                          setLocationMapController:
                              widget.setLocationMapController,
                          setLocationLocationService:
                              widget.setLocationLocationService,
                        );
                      },
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
          //
          // OMITTED ENTIRELY (device-screenshot bug fix), not merely
          // disabled, while `storage.isEphemeral`: `canCreate` below already
          // forces `onPressed: null` in that state -- the interlock was never
          // the gap. The gap was that a `Positioned` button, unlike a Column
          // sibling, does not shrink the space above it to make room; it
          // floats at a FIXED bottom-right spot regardless of how tall
          // `_StorageWarningBanner`/`_StorageDetailNotice` render above it, so
          // on a squeezed viewport it sat visually on top of that banner's own
          // text. A button that cannot work should not be there to overlap
          // anything, so this branch removes it from the tree rather than
          // reserving dead space for it. The legitimate action while storage
          // is unavailable is Retry (`StorageRetryBanner`, shell-level) or a
          // manual reload, per `_StorageWarningBanner`'s copy -- never
          // creation.
          if (!storage.isEphemeral)
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
  /// [showMasiTextPrompt], prefilled with the `'Topo ${count + 1}'`
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

      // The cross-platform [decodeImageSize] seam rather than a hand-rolled
      // `instantiateImageCodec` here (`topo_canvas_screen.dart`'s
      // `_attachPickedPhoto` already went through it — this call site was the
      // last copy of the decode). Native is bit-identical: the native backend
      // IS this code, verbatim. Web is where it matters: that backend now
      // reads the intrinsic size out of the file header instead of decoding
      // the image, so creating a topo from a 24.5 MP photo no longer
      // materialises ~98 MB of RGBA on the main thread purely to learn two
      // integers — and then does it a SECOND time inside `attachPhotoToWall`'s
      // thumbnail generation. Losing the tab to memory pressure is at its
      // worst here, mid-creation, where there is nothing to recover from.
      final size = await decodeImageSize(xfile);
      final width = size.width.round();
      final height = size.height.round();

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
      final enteredName = await showMasiTextPrompt(
        context,
        title: 'Name this topo',
        submitLabel: 'Create',
        initialValue: defaultName,
        fieldKey: const Key('topo-name-field'),
        submitKey: const Key('topo-name-submit'),
      );
      if (enteredName == null) return;
      final trimmedName = enteredName.trim();
      // The dialog itself already disables its submit action while empty/
      // whitespace-only (see `showMasiTextPrompt`'s `_canSubmit`), so this
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
      // outcome to the user. It reads `xfile` itself rather than being handed
      // bytes this method already holds -- it holds none: the dimension probe
      // above reads and drops its own copy -- trading a negligible bit of I/O
      // for a single source of truth on the EXIF-wins/device-fallback/
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
