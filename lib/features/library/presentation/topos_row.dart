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

class _TopoRow extends ConsumerWidget {
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
/// straight into the read-only topo canvas (`/walls/<wallId>?readonly=1` --
/// NOT the social/likes-first `/community/topo/<wallId>` detail, which stays
/// reserved for the Feed) so the wall photo + drawn routes render the same
/// way an owner sees them, just non-editable.
class _CommunityProximityRow extends StatelessWidget {
  const _CommunityProximityRow({super.key, required this.entry});

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
    final cachePx = (52 * MediaQuery.of(context).devicePixelRatio).round();

    final child = thumbnailPath == null
        ? _GradientFallback(colors: colors)
        : PhotoImage(
            thumbnailPath,
            width: 52,
            height: 52,
            fit: BoxFit.cover,
            cacheWidth: cachePx,
            cacheHeight: cachePx,
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
