part of 'topos_screen.dart';

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
            key: ValueKey(('own', entry.wallId)),
            topo: entry.ownTopo!,
            distanceKm: entry.distanceKm,
            setLocationTileProvider: setLocationTileProvider,
            setLocationMapController: setLocationMapController,
            setLocationLocationService: setLocationLocationService,
          );
        }
        return _CommunityProximityRow(
          key: ValueKey(('community', entry.wallId)),
          entry: entry,
        );
      },
    );
  }
}

/// The Topos-home first-load placeholder: [_ToposList]'s geometry, in shimmer.
///
/// `MasiSkeletonList.listRows()` is deliberately NOT reused here. That
/// composite stands in for `crud_list_scaffold.dart`'s text-only rows and comes
/// out 64 px tall; a topo row is driven by its 52 px thumbnail plus 2 ×
/// [MasiSpacing.sm] of padding, i.e. 68 px, and leads with that thumbnail. Six
/// rows of the wrong composite would be ~24 px of cumulative drift plus a
/// missing image slot — visible as a jolt the moment real rows arrive, which is
/// exactly what a skeleton is supposed to prevent. `.feedCards()` is closer in
/// shape but 86 px tall (it carries a third text line this row does not have).
///
/// So the numbers below are copied from [_TopoRow], one for one: [Material] at
/// [MasiRadii.card], padding `horizontal: md / vertical: sm`, a 52 px thumbnail
/// at radius 10, [MasiSpacing.md], then the name (titleMedium 17) over the
/// grade/route-count line (titleSmall 15). Text slots are text-scaled for the
/// same reason [MasiSkeletonListRow]'s are: the real row grows at large
/// accessibility scales, so this has to grow with it or the jump comes back for
/// the users least able to absorb it.
///
/// Like every skeleton it is inert — no scrolling (nothing to reveal) and no
/// taps.
class _ToposSkeleton extends StatelessWidget {
  const _ToposSkeleton({this.bottomInset = 0});

  /// On the outermost widget, so a test (or a driver flow) can tell "still
  /// loading" from "empty" on this screen.
  static const Key skeletonKey = Key('topos-skeleton');

  /// [_TopoRow]'s height at the default text scale: the 52 px thumbnail plus
  /// 2 × [MasiSpacing.sm]. A floor, not a cap.
  static const double rowHeight = 68;

  /// How many placeholder rows. A couple past the fold is enough to read as "a
  /// list", and every shape here is its own ticker.
  static const int count = 6;

  /// Matched to [_ToposList.bottomInset] so the placeholder occupies the same
  /// scroll area the real list will.
  final double bottomInset;

  /// Deterministic width variation (no `Random` — a skeleton must not reshuffle
  /// on every rebuild), so it reads as a list of different topos rather than a
  /// table.
  static const List<double> _widthFactors = [0.52, 0.38, 0.61, 0.44, 0.55, 0.34];

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    final scaler = MediaQuery.textScalerOf(context);

    return Semantics(
      key: skeletonKey,
      container: true,
      label: 'Loading',
      child: IgnorePointer(
        child: ListView.separated(
          physics: const NeverScrollableScrollPhysics(),
          padding: EdgeInsets.fromLTRB(
            MasiSpacing.lg,
            MasiSpacing.md,
            MasiSpacing.lg,
            MasiSpacing.md + bottomInset,
          ),
          itemCount: count,
          separatorBuilder: (context, index) =>
              const SizedBox(height: MasiSpacing.sm),
          itemBuilder: (context, index) => Material(
            color: colors.surface,
            borderRadius: BorderRadius.circular(MasiRadii.card),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: rowHeight),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: MasiSpacing.md,
                  vertical: MasiSpacing.sm,
                ),
                child: Row(
                  children: [
                    const MasiSkeleton.box(width: 52, height: 52, radius: 10),
                    const SizedBox(width: MasiSpacing.md),
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          MasiSkeleton.textLine(
                            fontSize: scaler.scale(17),
                            widthFactor:
                                _widthFactors[index % _widthFactors.length],
                          ),
                          const SizedBox(height: 2),
                          MasiSkeleton.textLine(
                            fontSize: scaler.scale(15),
                            widthFactor: 0.3,
                          ),
                        ],
                      ),
                    ),
                    // The trailing chevron only. The row's "More" button is
                    // deliberately not drawn: shimmering a fake control invites
                    // a tap on something that cannot be tapped.
                    const SizedBox(width: MasiSpacing.md),
                    const MasiSkeleton.box(width: 8, height: 14, radius: 4),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TopoRow extends ConsumerStatefulWidget {
  const _TopoRow({
    super.key,
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
  ConsumerState<_TopoRow> createState() => _TopoRowState();
}

/// Stateful for the same reason `crud_list_scaffold.dart`'s `_CrudRow` is, and
/// with the same two-flag split: every action on this row's menu is a database
/// write behind a sheet, a dialog or a full-screen picker, and the row had no
/// in-flight state at all — the surface dismissed, the write ran unannounced,
/// and a second menu tap could start a second one at the same topo.
///
/// [_locked] is the invisible re-entrancy lock and spans the whole flow,
/// modal included. [_working] is the visible cue and spans only what the APP is
/// doing (see [MasiBusyReporter]) — never the part where the user is reading a
/// confirm sheet, which is both wrong and unbounded.
/// [AutomaticKeepAliveClientMixin] is load-bearing here, not an optimisation —
/// same reasoning as `crud_list_scaffold.dart`'s `_CrudRowState` (see its doc,
/// where the failure was measured): both flags live in this State, and the
/// proximity list is a lazy [ListView.separated]. A row scrolled past the cache
/// extent mid-write is DISPOSED, so `reportBusy(false)` and `_run`'s `finally`
/// no-op; scrolled back it is rebuilt with both flags clear — idle-looking
/// glyph, navigable row, and a second tap that starts a second concurrent write
/// on the same topo. The row therefore asks to stay alive for exactly as long as
/// it is [_locked], and every write of that flag goes through [_setLocked]
/// because [wantKeepAlive] is only re-read when [updateKeepAlive] is called.
class _TopoRowState extends ConsumerState<_TopoRow>
    with AutomaticKeepAliveClientMixin {
  bool _locked = false;
  bool _working = false;

  @override
  bool get wantKeepAlive => _locked;

  void _setLocked(bool value) {
    if (_locked == value) return;
    _locked = value;
    updateKeepAlive();
  }

  Future<void> _run(
    Future<void> Function(MasiBusyReporter reportBusy) body,
  ) async {
    if (_locked) return;
    _setLocked(true);
    try {
      await body((isBusy) {
        // A deleted row is gone long before its own cascade settles.
        if (!mounted) return;
        if (isBusy != _working) setState(() => _working = isBusy);
      });
    } finally {
      _setLocked(false);
      if (mounted && _working) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Required by AutomaticKeepAliveClientMixin.
    super.build(context);
    final ref = this.ref;
    final topo = widget.topo;
    final distanceKm = widget.distanceKm;
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
        // Not navigable mid-write: opening a canvas for a topo that is halfway
        // through being deleted is a race with a guaranteed loser.
        onTap: _working ? null : () => context.push('/walls/${topo.wallId}'),
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
                            '${distanceKm.toStringAsFixed(1)} km',
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
                // The cue lands on the control the user pressed to get here,
                // at the glyph's own size so the row cannot change height.
                icon: _working
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: Center(child: MasiLoadingIndicator.inline()),
                      )
                    : MasiIcon('more_horiz', color: colors.ink3),
                tooltip: 'More',
                onPressed: _working
                    ? null
                    : () => _run(
                        (reportBusy) =>
                            _showMenu(context, ref, topo, reportBusy),
                      ),
              ),
              MasiIcon('chevron_right', color: colors.ink3),
            ],
          ),
        ),
      ),
    );
  }

  /// The `topo-menu-<wallId>` row action sheet, via the shared
  /// [showMasiActionSheet]. Every action keeps its PRE-EXISTING key
  /// (`topo-rename-<wallId>`, `topo-move-<wallId>`, etc.).
  ///
  /// "Show on map" stays visually muted rather than omitted when [topo] has
  /// no coordinates, so a user isn't left wondering why the action is
  /// missing — that is [MasiSheetAction.enabled] plus its [subtitle], which
  /// exists precisely for this case. "Set location"/"Edit location" stays
  /// always-enabled either way (see its own doc below).
  Future<void> _showMenu(
    BuildContext context,
    WidgetRef ref,
    TopoRef topo,
    MasiBusyReporter reportBusy,
  ) async {
    final isShared = topo.visibility == 'shared';
    final hasCoords = topo.latitude != null && topo.longitude != null;
    // Read, not watch: the sheet is a snapshot taken at open time and does not
    // rebuild. `.value` (rather than awaiting `.future`) so an un-pulled
    // mirror yields null and the menu degrades to its pre-phase-5 shape
    // instead of blocking the sheet on a network round trip — the server
    // trigger is still there to catch anything the client gets wrong.
    final view = ref.read(wallModerationViewProvider(topo.wallId)).value;
    final isProtected = view?.isDeleteProtected ?? false;
    final isWithdrawing = view?.isWithdrawing ?? false;
    // A topo whose ten days ran out: still `visibility = 'shared'`, still
    // stored as `published`, and invisible to everyone. Without an explicit
    // way back the owner is stuck — the menu would offer "Unpublish" on
    // something nobody can see, and re-sharing an already-shared topo is not
    // an action the UI can express.
    final isWithdrawn =
        isShared && view?.effectiveState == ModerationState.withdrawn;

    final action = await showMasiActionSheet<String>(
      context,
      actions: [
        MasiSheetAction(
          key: Key('topo-rename-${topo.wallId}'),
          label: 'Rename',
          value: 'rename',
        ),
        MasiSheetAction(
          key: Key('topo-move-${topo.wallId}'),
          label: 'Move to…',
          value: 'move',
        ),
        // Three shapes, decided by how public the topo actually is:
        //
        //   not shared            → "Submit to Community"
        //   shared, not published → "Unpublish" (immediate, as it always was —
        //                           nothing anyone else can see is at stake)
        //   published             → "Withdraw…", the ten-day flow (C-3)
        //
        // The last is the client-side half of the guard. The server would
        // silently revert a plain unpublish here (it CANNOT raise — see the
        // phase 5 migration), so without this the owner would tap Unpublish,
        // watch it appear to work, and find the topo still public tomorrow.
        if (isWithdrawing)
          MasiSheetAction(
            key: Key('topo-cancel-withdraw-${topo.wallId}'),
            label: 'Cancel withdrawal',
            value: 'cancel-withdraw',
            subtitle: _withdrawalSubtitle(view),
          )
        else if (isWithdrawn)
          // Same RPC as Cancel, because on the server they are the same act —
          // "stop the withdrawal". Only the outcome differs, and the server
          // decides it: in time it stays published, afterwards it goes back
          // in the queue. Two labels for one call, rather than two calls that
          // could disagree about where the boundary is.
          MasiSheetAction(
            key: Key('topo-resubmit-${topo.wallId}'),
            label: 'Submit for review again',
            value: 'cancel-withdraw',
            subtitle: 'Withdrawn — not public',
          )
        else
          MasiSheetAction(
            key: Key('topo-publish-${topo.wallId}'),
            // "Submit", not "Publish" — see `_handlePublish`. `isShared` is the
            // owner's own `visibility` flag and still means "I have shared
            // this", so it remains the right thing to key the reverse action
            // on even though sharing no longer implies being visible.
            label: isShared
                ? (isProtected ? 'Withdraw from Community…' : 'Unpublish')
                : 'Submit to Community',
            value: isShared
                ? (isProtected ? 'withdraw' : 'unpublish')
                : 'publish',
            subtitle: isProtected ? 'Stays visible for 10 days' : null,
          ),
        MasiSheetAction(
          key: Key('topo-access-${topo.wallId}'),
          label: 'Access…',
          value: 'access',
          subtitle: 'Closed, restricted, not listed',
        ),
        // Enabled only when the wall actually has coordinates (from
        // EXIF/device GPS capture at photo-attach time — see
        // `setWallCoordinates`); a located topo pushes straight into
        // `/community`'s Map tab, focused on this wall (see
        // `_handleShowOnMap`).
        MasiSheetAction(
          key: Key('topo-show-on-map-${topo.wallId}'),
          label: 'Show on map',
          value: 'show-on-map',
          enabled: hasCoords,
          subtitle: hasCoords ? null : 'No location set',
        ),
        // Always enabled -- unlike "Show on map" above, a topo can be
        // GIVEN a location whether or not it has one already, so this
        // action is never muted; the label just flips to "Edit location"
        // once coordinates exist, so the menu reads as "add" vs "change"
        // appropriately.
        MasiSheetAction(
          key: Key('topo-set-location-${topo.wallId}'),
          label: hasCoords ? 'Edit location' : 'Set location',
          value: 'set-location',
        ),
        // Offered only for a topo that HAS a history. Versions are recorded
        // for published topos only (a draft is the owner's scratch space and
        // snapshotting every keystroke of it would be the most expensive thing
        // in the schema), so on anything else this would open an empty sheet
        // and teach the owner the feature does not work.
        if (isShared)
          MasiSheetAction(
            key: Key('topo-history-${topo.wallId}'),
            label: 'History',
            value: 'history',
            subtitle: 'What changed, and when',
          ),
        // Delete lives one step further in, deliberately (decided
        // 2026-08-08). It used to sit right here, a single tap from "Rename"
        // and "Show on map" — same sheet, same gesture, and the only thing
        // between a mis-tap and destroying a topo was the confirm. Deletion is
        // meant to be rare, so reaching it should be a decision rather than a
        // slip. This is about the PATH to the control, not the control: the
        // confirm sheet and the published-topo block below are unchanged.
        MasiSheetAction(
          key: Key('topo-more-${topo.wallId}'),
          label: 'More…',
          value: 'more',
        ),
      ],
    );

    if (!context.mounted || action == null) return;
    switch (action) {
      case 'rename':
        await _handleRename(context, ref, topo, reportBusy);
      case 'move':
        await _handleMove(context, ref, topo, reportBusy);
      case 'publish':
        await _handlePublish(context, ref, topo, reportBusy);
      case 'unpublish':
        await _handleUnpublish(context, ref, topo, reportBusy);
      case 'access':
        await _handleAccess(context, ref, topo, reportBusy);
      case 'show-on-map':
        _handleShowOnMap(context, topo);
      case 'set-location':
        await _handleSetLocation(context, ref, topo, reportBusy);
      case 'history':
        await showTopoHistory(context, wallId: topo.wallId);
      case 'withdraw':
        await _handleWithdraw(context, ref, topo, reportBusy);
      case 'cancel-withdraw':
        await _handleCancelWithdraw(context, ref, topo, isWithdrawn, reportBusy);
      case 'more':
        await _showMoreSheet(context, ref, topo, reportBusy, isProtected);
      case 'delete':
        await _handleDelete(context, ref, topo, reportBusy, isProtected);
    }
  }

  /// The second step in front of [_handleDelete].
  ///
  /// One entry today, which is the point: this sheet exists to put a
  /// deliberate step between the everyday menu and the only action that
  /// destroys something. Keyed `topo-delete-<id>` exactly as before, so the
  /// control it leads to is the same one every test and flow already targets —
  /// only the route to it changed.
  Future<void> _showMoreSheet(
    BuildContext context,
    WidgetRef ref,
    TopoRef topo,
    MasiBusyReporter reportBusy,
    bool isProtected,
  ) async {
    final action = await showMasiActionSheet<String>(
      context,
      sheetKey: Key('topo-more-sheet-${topo.wallId}'),
      title: topo.name,
      actions: [
        MasiSheetAction(
          key: Key('topo-delete-${topo.wallId}'),
          label: 'Delete',
          value: 'delete',
          isDestructive: true,
          subtitle: isProtected ? 'Published — withdraw first' : null,
        ),
      ],
    );
    if (!context.mounted || action != 'delete') return;
    await _handleDelete(context, ref, topo, reportBusy, isProtected);
  }

  /// "Stops being public in 3 days" for the Cancel action's subtitle, or null
  /// when nothing is running. Never reads "0 days": this is only shown while
  /// the withdrawal is live, and [ModerationView.daysRemaining] rounds up, so
  /// the floor is 1.
  static String? _withdrawalSubtitle(ModerationView? view) {
    final days = view?.daysRemaining;
    if (days == null) return null;
    return 'Stops being public in $days day${days == 1 ? '' : 's'}';
  }

  /// See `crud_list_scaffold.dart`'s identical helper: a guarded mutation
  /// that could not be applied now throws (row-count verification, audit
  /// L4), and the user must be told rather than shown a dismissed sheet.
  ///
  /// Returns the action's value, or null when it threw — so a caller that
  /// needs to report WHAT happened (the withdrawal RPCs, whose answer differs
  /// depending on whether the window had elapsed) can tell success from
  /// failure without a second try/catch of its own.
  Future<T?> _runGuarded<T>(
    BuildContext context,
    String failureMessage,
    Future<T> Function() action,
  ) async {
    try {
      return await action();
    } catch (e, st) {
      debugPrint('Topo write failed: $e\n$st');
      if (!context.mounted) return null;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(failureMessage)));
      return null;
    }
  }

  Future<void> _handleRename(
    BuildContext context,
    WidgetRef ref,
    TopoRef topo,
    MasiBusyReporter reportBusy,
  ) async {
    final newName = await showMasiTextPrompt(
      context,
      title: 'Rename topo',
      submitLabel: 'Save',
      initialValue: topo.name,
      fieldKey: const Key('crud-name-field'),
      submitKey: const Key('crud-name-submit'),
    );
    if (newName == null) return;
    if (!context.mounted) return;
    reportBusy(true);
    await _runGuarded(
      context,
      "Couldn't rename — please try again",
      () => ref
          .read(libraryCrudRepositoryProvider)
          .renameWall(topo.wallId, newName),
    );
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
    MasiBusyReporter reportBusy,
  ) async {
    final repo = ref.read(libraryCrudRepositoryProvider);
    // §1c: the single local-data uid door — never `authStateProvider.asData`,
    // which reads null on AsyncError too.
    final myUid = ref.read(effectiveUidProvider);
    // THREE database reads have to finish before the sheet can even be built,
    // and until they did, choosing "Move to…" left the menu closing onto a row
    // that showed nothing at all — the classic "did that work?" gap.
    reportBusy(true);
    final String? currentSectorId;
    final List<AreaRef> areas;
    final List<SectorRef> ownSectors;
    try {
      currentSectorId = await repo.wallSectorId(topo.wallId);
      areas = await repo.listAreas();
      ownSectors = await repo.listOwnSectors(myUid);
    } catch (e, st) {
      // Guarded HERE rather than relying on an outer `_runGuarded`, because
      // unlike every other action on this menu there isn't one: `_handleMove`
      // is called raw from the menu switch, so a throw in these three reads
      // escaped out of the unawaited `_run` future as an uncaught async error
      // and the user saw the menu close, a brief cue, and then nothing at all.
      debugPrint('Failed to read move targets: $e\n$st');
      reportBusy(false);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Couldn't load where to move this — please try again"),
        ),
      );
      return;
    }
    // Back to the user (the sheet).
    reportBusy(false);
    final areaNames = {for (final area in areas) area.id: area.name};
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

    reportBusy(true);
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
  /// Uses the shared [showMasiConfirm] surface, with `isDestructive: false` —
  /// publishing is consequential enough to confirm, but it is not a deletion
  /// and should not be dressed in the destructive red.
  Future<void> _handlePublish(
    BuildContext context,
    WidgetRef ref,
    TopoRef topo,
    MasiBusyReporter reportBusy,
  ) async {
    // Wording changed with community editing phase 3: sharing is now a
    // SUBMISSION, not a publication. Saying "will become visible to everyone"
    // would be a straightforward lie — the server puts it in `pending` and
    // nobody but the owner and a moderator can see it until it is approved.
    // The old copy also promised "you can unpublish it again at any time",
    // which the phase 5 withdrawal cooldown made untrue.
    //
    // Phase 8a made it conditionally true again: a trusted account's topo
    // publishes immediately. So the sheet has to ask which case this is rather
    // than assert one — a person told "a moderator will review this" whose
    // topo is public thirty seconds later has been misled, and one told "this
    // goes live now" who then waits three days for a moderator has been misled
    // worse.
    final trusted =
        ref.read(myTrustProvider).asData?.value.isTrusted ?? false;

    // Phase 8b / C-6.1: what is already here, BEFORE anything is submitted.
    // Only possible when this topo has coordinates, which is most of them —
    // they arrive automatically from photo EXIF (see `setWallCoordinates`).
    // A topo with none simply skips the check rather than being nagged to set
    // a location it may not have.
    final latitude = topo.latitude;
    final longitude = topo.longitude;
    if (latitude != null && longitude != null) {
      reportBusy(true);
      final nearby = await ref.read(
        nearbyToposProvider((
          latitude: latitude,
          longitude: longitude,
          excludeWallId: topo.wallId,
        )).future,
      );
      reportBusy(false);
      if (!context.mounted) return;
      if (nearby.isNotEmpty) {
        final proceed = await showDuplicateWarning(
          context,
          nearby: nearby,
          topoName: topo.name,
          trusted: trusted,
        );
        // Backing out here ends the flow entirely rather than falling through
        // to the publish confirm — being shown the crag you are duplicating and
        // then asked "publish?" anyway would read as the app not listening.
        if (!proceed || !context.mounted) return;
        reportBusy(true);
        await _runGuarded(
          context,
          "Couldn't publish — please try again",
          () =>
              ref.read(libraryCrudRepositoryProvider).publishTopo(topo.wallId),
        );
        return;
      }
    }

    final confirmed = await showMasiConfirm(
      context,
      title: trusted ? 'Publish to Community?' : 'Submit to Community?',
      message: trusted
          ? '"${topo.name}" becomes visible to other climbers straight away. '
                'They can rely on it, so it is worth a last look first.'
          : '"${topo.name}" goes to a moderator for review. Once approved, '
                'other climbers can see it and rely on it.',
      confirmLabel: trusted ? 'Publish' : 'Submit',
      confirmKey: Key('topo-publish-confirm-${topo.wallId}'),
      isDestructive: false,
    );
    if (confirmed) {
      if (!context.mounted) return;
      reportBusy(true);
      await _runGuarded(
        context,
        "Couldn't publish — please try again",
        () => ref.read(libraryCrudRepositoryProvider).publishTopo(topo.wallId),
      );
    }
  }

  /// States this topo's own access/closure (community editing phase 2 / R-2).
  ///
  /// Wall-level only. A restriction inherited from the sector or area still
  /// wins if it is more severe (see `ResolvedAccess.resolve`), so this cannot
  /// be used to reopen a crag somebody closed above it — which is the point.
  Future<void> _handleAccess(
    BuildContext context,
    WidgetRef ref,
    TopoRef topo,
    MasiBusyReporter reportBusy,
  ) async {
    final edit = await showAccessEditor(context, targetLabel: topo.name);
    // `null` means they backed out; an AccessEdit with a null state means
    // "clear it". Conflating those would make cancel erase a closure.
    if (edit == null || !context.mounted) return;
    reportBusy(true);
    await _runGuarded(
      context,
      "Couldn't save the access state — please try again",
      () => ref
          .read(libraryCrudRepositoryProvider)
          .setWallAccess(topo.wallId, edit.state?.wire, edit.note),
    );
  }

  /// Starts the ten-day withdrawal clock (C-3).
  ///
  /// Confirmed rather than fired straight off the menu, and the confirmation
  /// says the two things the owner cannot guess: that the topo stays visible
  /// meanwhile, and that everyone will be told. Both are deliberate — people
  /// who planned a trip around this crag get warning, and the notice is what
  /// makes a spiteful withdrawal socially expensive.
  Future<void> _handleWithdraw(
    BuildContext context,
    WidgetRef ref,
    TopoRef topo,
    MasiBusyReporter reportBusy,
  ) async {
    final confirmed = await showMasiConfirm(
      context,
      title: 'Withdraw "${topo.name}"?',
      message:
          'It stays visible for 10 more days, with a notice telling people '
          'it is being withdrawn, and then stops being public. You can cancel '
          'any time before then.',
      confirmLabel: 'Withdraw',
      confirmKey: Key('topo-withdraw-confirm-${topo.wallId}'),
      isDestructive: true,
    );
    if (!confirmed || !context.mounted) return;
    reportBusy(true);
    await _runGuarded(
      context,
      "Couldn't withdraw — please try again",
      () => ref.read(withdrawalServiceProvider).request(topo.wallId),
    );
  }

  /// Stops the clock.
  ///
  /// Reads as two different actions depending on whether the ten days already
  /// ran out, because it IS two different actions — the server decides which,
  /// and returns the resulting state. Cancelling in time changes nothing;
  /// coming back afterwards is a fresh submission that goes through review
  /// again, and saying so up front is the difference between an owner
  /// understanding the rule and feeling ambushed by it.
  Future<void> _handleCancelWithdraw(
    BuildContext context,
    WidgetRef ref,
    TopoRef topo,
    bool hasMatured,
    MasiBusyReporter reportBusy,
  ) async {
    final confirmed = await showMasiConfirm(
      context,
      title: hasMatured
          ? 'Submit "${topo.name}" again?'
          : 'Keep "${topo.name}" public?',
      message: hasMatured
          ? 'The withdrawal window has closed, so this goes back to a '
                'moderator for review before it becomes public again.'
          : 'The withdrawal is cancelled and the topo stays public. Nothing '
                'else changes.',
      confirmLabel: hasMatured ? 'Submit' : 'Keep it public',
      confirmKey: Key('topo-cancel-withdraw-confirm-${topo.wallId}'),
      isDestructive: false,
    );
    if (!confirmed || !context.mounted) return;
    reportBusy(true);
    final state = await _runGuarded(
      context,
      "Couldn't cancel — please try again",
      () => ref.read(withdrawalServiceProvider).cancel(topo.wallId),
    );
    if (state == null || !context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          state == 'pending'
              ? 'Sent back for review'
              : 'Still public — withdrawal cancelled',
        ),
      ),
    );
  }

  Future<void> _handleUnpublish(
    BuildContext context,
    WidgetRef ref,
    TopoRef topo,
    MasiBusyReporter reportBusy,
  ) {
    // The only action here with nothing to confirm, so the wait is ours from
    // the instant the menu closes.
    reportBusy(true);
    return _runGuarded(
      context,
      "Couldn't unpublish — please try again",
      () => ref.read(libraryCrudRepositoryProvider).unpublishTopo(topo.wallId),
    );
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
    MasiBusyReporter reportBusy,
  ) async {
    final initial = (topo.latitude != null && topo.longitude != null)
        ? LatLng(topo.latitude!, topo.longitude!)
        : null;

    final picked = await showSetLocationPicker(
      context,
      initial: initial,
      tileProvider: widget.setLocationTileProvider,
      controller: widget.setLocationMapController,
      locationService: widget.setLocationLocationService,
    );
    if (picked == null) return;
    if (!context.mounted) return;

    reportBusy(true);
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

  /// Whether deletion is still gated on an admin, and says so — returning true
  /// means [_handleDelete] must stop.
  ///
  /// Reads the request on demand rather than from a local mirror: deletion is
  /// rare, so this is one network read on a rare path, and mirroring it would
  /// put a table and a sync rule in front of every ordinary write for a state
  /// almost no topo is ever in.
  ///
  /// A topo that was never public has no request and needs none — `null` from
  /// the server means "no request", and for a draft the caller never gets here
  /// because `isProtected` already sent it down the withdrawal path.
  ///
  /// Fails CLOSED. If the read fails we cannot tell approved from pending, and
  /// the honest answer is the one that does not end in a delete that silently
  /// undoes itself.
  Future<bool> _needsDeletionApproval(
    BuildContext context,
    WidgetRef ref,
    TopoRef topo,
  ) async {
    // Decided BEFORE anything is read from the moderation layer, and that
    // ordering is load-bearing. A draft is the overwhelmingly common case and
    // must cost nothing extra: no provider read, no network, no behaviour
    // change at all. `moderationRemoteProvider` also throws outright when
    // Supabase is not initialised (early boot, and every widget test that does
    // not stand up a fake client), so touching it up here would break deleting
    // a draft in exactly the situations that have nothing to do with sharing.
    final view = ref.read(wallModerationViewProvider(topo.wallId)).asData?.value;
    final everPublic =
        view?.storedState == ModerationState.published ||
        view?.storedState == ModerationState.removed;
    if (!everPublic) return false;

    Map<String, dynamic>? request;
    var readFailed = false;
    try {
      request = await ref.read(moderationRemoteProvider).deletionRequestFor(
        topo.wallId,
      );
    } catch (_) {
      readFailed = true;
    }
    if (!context.mounted) return true;

    final status = request?['status'];
    if (status == 'approved') return false; // cleared — carry on and delete

    if (readFailed) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Couldn't check whether deletion was approved"),
        ),
      );
      return true;
    }

    if (status == 'pending') {
      await showMasiConfirm(
        context,
        title: 'Waiting for a moderator',
        message:
            'You have already asked to delete "${topo.name}". A moderator will '
            'review it — nothing is lost in the meantime.',
        confirmLabel: 'OK',
        confirmKey: Key('topo-delete-pending-${topo.wallId}'),
      );
      return true;
    }

    final ask = await showMasiConfirm(
      context,
      title: status == 'rejected'
          ? 'Ask again about "${topo.name}"?'
          : 'Ask to delete "${topo.name}"?',
      message: status == 'rejected'
          ? 'A moderator declined the last request. You can ask again.'
          : 'People may have logged ascents on this topo, so deleting it needs '
                'a moderator to agree. Nothing is deleted until they do.',
      confirmLabel: 'Ask',
      confirmKey: Key('topo-delete-request-${topo.wallId}'),
    );
    if (!ask || !context.mounted) return true;

    await _runGuarded(
      context,
      "Couldn't send that request",
      () => ref.read(moderationRemoteProvider).requestDeletion(topo.wallId),
    );
    if (!context.mounted) return true;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Asked a moderator to review it')),
    );
    return true;
  }

  /// Title/message wording is now byte-identical to `crud_list_scaffold.dart`'s
  /// delete confirm. It used to read title "Delete?" over message 'Delete
  /// "X"? This cannot be undone.' — asking the same question twice, once
  /// without the name that makes it answerable.
  Future<void> _handleDelete(
    BuildContext context,
    WidgetRef ref,
    TopoRef topo,
    MasiBusyReporter reportBusy,
    bool isProtected,
  ) async {
    // Deleting is the OTHER way to make a published topo vanish instantly, and
    // leaving it open would make the withdrawal cooldown theatre — `deletedAt
    // = now` achieves in one tap exactly what the ten days exist to slow down
    // (COMMUNITY_PLAN.md C-3). The server reverts it either way; this is what
    // stops the owner watching a delete appear to succeed and silently undo
    // itself, and it offers the flow that does work.
    if (isProtected) {
      final withdraw = await showMasiConfirm(
        context,
        title: 'Withdraw "${topo.name}" first',
        message:
            'Other climbers can see this topo and may be relying on it, so it '
            'cannot be deleted straight away. Withdrawing keeps it visible for '
            '10 days with a notice, and after that you can delete it.',
        confirmLabel: 'Withdraw',
        confirmKey: Key('topo-delete-blocked-${topo.wallId}'),
        isDestructive: true,
      );
      if (!withdraw || !context.mounted) return;
      await _handleWithdraw(context, ref, topo, reportBusy);
      return;
    }

    // The withdrawal has matured, but a topo that HAS been public also needs an
    // admin's approval before it can be destroyed (decided 2026-08-08). The
    // ten days protect readers; the approval protects the record (§3.3).
    //
    // This branch is not optional politeness. The server trigger enforces the
    // approval, so without it the owner taps Delete, the row disappears from
    // the list, the push is reverted server-side and the topo REAPPEARS on the
    // next pull — the exact silently-undone delete the block above exists to
    // prevent, just moved ten days later.
    if (await _needsDeletionApproval(context, ref, topo)) return;
    if (!context.mounted) return;

    final confirmed = await showMasiConfirm(
      context,
      title: 'Delete "${topo.name}"?',
      message: 'This cannot be undone.',
      confirmLabel: 'Delete',
      confirmKey: Key('topo-delete-confirm-${topo.wallId}'),
    );
    if (confirmed) {
      if (!context.mounted) return;
      reportBusy(true);
      await _runGuarded(
        context,
        "Couldn't delete — please try again",
        () =>
            ref.read(libraryCrudRepositoryProvider).softDeleteWall(topo.wallId),
      );
    }
  }
}

/// A nearby COMMUNITY topo's row in the proximity-sorted Topos-home list
/// (see `_ToposList`/`sortedByProximityToposProvider`) -- visually mirrors
/// [_TopoRow] (same 52x52 thumbnail, same grade-band dots and route count)
/// but marked with a `_CommunitySharedBadge` instead of [_VisibilityBadge],
/// and taps straight into the read-only topo canvas
/// (`/walls/<wallId>?readonly=1` -- NOT the social/likes-first
/// `/community/topo/<wallId>` detail, which stays reserved for the Feed) so
/// the wall photo + drawn routes render the same way an owner sees them, just
/// non-editable.
///
/// **The grade dots are the same widget the owner's row uses**, not a
/// look-alike: `_GradeBandDots` fed from `gradeBandsFor`. They were missing
/// here for a while, which made hardness an owner-only signal — the row that
/// most needs it is a stranger's crag you are deciding whether to walk to.
/// The data was always present locally (`CommunityRepository.watchSharedTopos`
/// counts routes from the local `routes` table, and the sync pull imports
/// foreign `routes` rows), so their absence was only ever a rendering gap.
///
/// **A menu appears here only for an admin.** For everyone else there is still
/// none, and that remains right: a community entry is never "mine" to
/// publish/unpublish/rename/delete. An admin is the exception, because
/// moderation has to be reachable from wherever the offending topo is
/// visible, and this list is one of those places.
class _CommunityProximityRow extends ConsumerWidget {
  const _CommunityProximityRow({super.key, required this.entry});

  final ProximityTopoEntry entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = MasiColors.of(context);
    final textTheme = Theme.of(context).textTheme;
    final SharedTopo topo = entry.communityTopo!;
    final wallId = entry.wallId;
    final routeCount = topo.routeCount;
    final bands = gradeBandsFor(topo.routeGradeKeys);
    // `.value ?? false` — fails CLOSED. An unresolved or errored admin lookup
    // draws no destructive control, which is the only safe default here.
    final isAdmin = ref.watch(isAdminProvider).value ?? false;

    return Material(
      key: Key('topo-item-community-$wallId'),
      color: colors.surface,
      borderRadius: BorderRadius.circular(MasiRadii.card),
      child: InkWell(
        borderRadius: BorderRadius.circular(MasiRadii.card),
        onTap: () => context.push('/walls/$wallId?readonly=1'),
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
                        // Same order as `_TopoRow`: dots, count, badge,
                        // distance — so the two row kinds scan identically.
                        if (bands.isNotEmpty)
                          _GradeBandDots(wallId: wallId, bands: bands),
                        Text(
                          '$routeCount route${routeCount == 1 ? '' : 's'}',
                          style: textTheme.titleSmall?.copyWith(
                            color: colors.ink2,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
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
              if (isAdmin)
                IconButton(
                  key: Key('community-row-menu-$wallId'),
                  icon: MasiIcon('more_horiz', color: colors.ink3),
                  tooltip: 'Moderator tools',
                  onPressed: () => _openAdminSheet(context, ref, wallId),
                ),
              MasiIcon('chevron_right', color: colors.ink3),
            ],
          ),
        ),
      ),
    );
  }

  /// Admin-only takedown of somebody else's topo, straight from this list.
  ///
  /// Routed through [AdminDeleteService.deleteTopo], i.e. the
  /// `admin_delete_topo` SECURITY DEFINER RPC — which re-checks `is_admin()`
  /// server-side and writes the `moderation_log` entry. The `isAdmin` gate on
  /// the button only decides whether the control is DRAWN; it is not the
  /// authority check, and must never be treated as one.
  ///
  /// Two steps then a confirm, matching `community_topo_detail_screen`'s
  /// `_openAdminDeleteSheet` — a destructive action that reaches other
  /// people's data should not be one tap away from a scrolling list.
  Future<void> _openAdminSheet(
    BuildContext context,
    WidgetRef ref,
    String wallId,
  ) async {
    final action = await showMasiActionSheet<String>(
      context,
      sheetKey: Key('community-row-admin-sheet-$wallId'),
      actions: [
        MasiSheetAction(
          key: Key('community-row-admin-delete-$wallId'),
          label: 'Delete this topo',
          value: 'delete',
          subtitle:
              'Removes it for everyone, with its routes, ascents and comments',
          isDestructive: true,
        ),
      ],
    );
    if (action != 'delete' || !context.mounted) return;

    final confirmed = await showMasiConfirm(
      context,
      title: 'Delete this topo?',
      message:
          'Removes this topo for everyone — its routes, ascents and comments '
          'go with it, and its photos come down too. This cannot be undone.',
      confirmLabel: 'Delete',
      confirmKey: Key('community-row-admin-delete-confirm-$wallId'),
    );
    if (!confirmed || !context.mounted) return;

    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final result = await ref
          .read(adminDeleteServiceProvider)
          .deleteTopo(wallId: wallId);
      // Counts surfaced rather than smoothed over, the same way
      // `community_topo_detail_screen` and `admin_queue_screen` do it: a
      // delete that removed the record but left world-readable photo bytes
      // behind is exactly the failure a bare "Deleted" hides.
      final missed = result.photoObjects - result.photoBytesRemoved;
      messenger?.showSnackBar(
        SnackBar(
          content: Text(
            missed == 0
                ? 'Deleted — ${result.photoBytesRemoved} image(s) removed'
                : 'Deleted, but $missed of ${result.photoObjects} image(s) '
                      'could not be removed',
          ),
        ),
      );
    } catch (error) {
      // Loud, not silent — an admin who believes a delete went through when it
      // did not is worse off than one who was told it failed.
      messenger?.showSnackBar(
        SnackBar(content: Text("Couldn't delete that topo. $error")),
      );
    }
  }
}

/// 52x52 rounded thumbnail: the topo's downscaled `thumbs/<id>.jpg`
/// thumbnail (#56 — resolved by `LibraryCrudRepository`/`CommunityRepository`
/// `_resolveThumbnail`, NOT the full-resolution original) when it has one
/// and its bytes are readable, else an amethyst gradient placeholder.
/// [PhotoImage]'s `placeholder` covers every way that can fail (no path at
/// all, a decode error, or — on web — bytes not found/not yet loaded from
/// IndexedDB) so no path ever surfaces a broken-image icon; its
/// `loadingPlaceholder` (an animated [MasiShimmer]) covers the DISTINCT
/// "still loading" window so a genuinely-missing photo never shimmers
/// forever.
class _Thumbnail extends StatelessWidget {
  const _Thumbnail({required this.path});

  final String? path;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    final radius = BorderRadius.circular(10);
    final thumbnailPath = path;
    // #56: decode at display size, not the original's full resolution —
    // the tile is 52 LOGICAL px, so the decode target is that times the
    // device's pixel ratio.
    //
    // WIDTH ONLY. This used to pass the same value as `cacheHeight` too,
    // which made `ResizeImage` (default policy `exact`) scale the bitmap to
    // exactly 52x52 whatever the source's aspect ratio was — `BoxFit.fill`,
    // done in the decoder. Every portrait photo therefore arrived here
    // already squashed (~1.33x for a 4:3) and the `BoxFit.cover` below had
    // nothing left to crop, because the bitmap really was square by then.
    // With the width alone the height follows the intrinsic ratio and `cover`
    // centre-crops the tile as intended. See [PhotoImage]'s doc.
    final cacheWidthPx = (52 * MediaQuery.of(context).devicePixelRatio).round();

    final child = thumbnailPath == null
        ? _GradientFallback(colors: colors)
        : PhotoImage(
            thumbnailPath,
            width: 52,
            height: 52,
            fit: BoxFit.cover,
            cacheWidth: cacheWidthPx,
            placeholder: () => _GradientFallback(colors: colors),
            loadingPlaceholder: () => const MasiShimmer(),
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
