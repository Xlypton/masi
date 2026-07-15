import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../../app/theme.dart';
import '../../../core/grades/grade_system.dart';
import '../../account/application/auth_providers.dart';
import '../../account/application/email_initials.dart';
import '../../topo/presentation/photo_source_sheet.dart';
import '../application/library_providers.dart';
import '../data/library_crud_repository.dart';

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
  });

  final Future<ImageSource?> Function(BuildContext) photoSourcePicker;
  final Future<XFile?> Function(ImageSource) photoPicker;

  @override
  ConsumerState<ToposScreen> createState() => _ToposScreenState();
}

class _ToposScreenState extends ConsumerState<ToposScreen> {
  /// Re-entrancy guard for [_handleNewTopo]: true for the whole duration of
  /// an in-flight "New topo" flow (source picker -> photo picker -> decode
  /// -> createTopo -> attachPhotoToWall -> navigate). While true, the
  /// button is disabled and a second tap is a no-op.
  bool _creating = false;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    final asyncTopos = ref.watch(toposProvider);
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
          TextButton(
            key: const Key('topos-organize'),
            style: TextButton.styleFrom(foregroundColor: colors.accent),
            onPressed: () => context.push('/areas'),
            child: const Text('Organize'),
          ),
          IconButton(
            key: const Key('home-community-button'),
            icon: Icon(Icons.explore_outlined, color: colors.accent),
            tooltip: 'Community',
            onPressed: () => context.push('/community'),
          ),
          IconButton(
            key: const Key('home-logbook-button'),
            icon: Icon(Icons.menu_book_outlined, color: colors.accent),
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
                : Icon(Icons.person_outline, color: colors.accent),
            tooltip: 'Account',
            onPressed: () => context.push('/account'),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: asyncTopos.when(
                data: (topos) {
                  if (topos.isEmpty) {
                    return const _EmptyState();
                  }
                  return _ToposList(topos: topos);
                },
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (error, stackTrace) => Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('Something went wrong: $error'),
                      const SizedBox(height: 8),
                      ElevatedButton(
                        key: const Key('topos-retry'),
                        onPressed: () => ref.invalidate(toposProvider),
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                MasiSpacing.lg,
                MasiSpacing.md,
                MasiSpacing.lg,
                MasiSpacing.lg,
              ),
              child: SizedBox(
                width: double.infinity,
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
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(13),
                    ),
                  ),
                  onPressed: canCreate ? _handleNewTopo : null,
                  child: const Text('New topo'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Photo-first "New topo" creation flow: pick a source, pick a photo,
  /// decode its pixel size, create a wall named after the current topo
  /// count, attach the photo to it, then navigate straight into the canvas.
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
      final repo = ref.read(libraryCrudRepositoryProvider);
      final wallId = await repo.createTopo('Topo ${count + 1}');
      await repo.attachPhotoToWall(wallId, xfile.path, width, height);

      if (!mounted) return;
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

class _EmptyState extends StatelessWidget {
  const _EmptyState();

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
        ],
      ),
    );
  }
}

class _ToposList extends StatelessWidget {
  const _ToposList({required this.topos});

  final List<TopoRef> topos;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.symmetric(
        horizontal: MasiSpacing.lg,
        vertical: MasiSpacing.md,
      ),
      itemCount: topos.length,
      separatorBuilder: (context, index) =>
          const SizedBox(height: MasiSpacing.sm),
      itemBuilder: (context, index) => _TopoRow(topo: topos[index]),
    );
  }
}

class _TopoRow extends ConsumerWidget {
  const _TopoRow({required this.topo});

  final TopoRef topo;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = MasiColors.of(context);
    final textTheme = Theme.of(context).textTheme;
    final routeCount = topo.routeCount;

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
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (topo.topGradeLabel != null &&
                            topo.topGradeBand != null) ...[
                          _GradePill(
                            label: topo.topGradeLabel!,
                            band: topo.topGradeBand!,
                          ),
                          const SizedBox(width: MasiSpacing.xs),
                        ],
                        Text(
                          '$routeCount route${routeCount == 1 ? '' : 's'}',
                          style: textTheme.titleSmall?.copyWith(
                            color: colors.ink2,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                key: Key('topo-menu-${topo.wallId}'),
                icon: Icon(Icons.more_vert, color: colors.ink3),
                onSelected: (value) {
                  switch (value) {
                    case 'rename':
                      _handleRename(context, ref, topo);
                    case 'publish':
                      _handlePublish(context, ref, topo);
                    case 'unpublish':
                      _handleUnpublish(ref, topo);
                    case 'delete':
                      _handleDelete(context, ref, topo);
                  }
                },
                itemBuilder: (context) {
                  final isShared = topo.visibility == 'shared';
                  return [
                    PopupMenuItem(
                      key: Key('topo-rename-${topo.wallId}'),
                      value: 'rename',
                      child: const Text('Rename'),
                    ),
                    PopupMenuItem(
                      key: Key('topo-publish-${topo.wallId}'),
                      value: isShared ? 'unpublish' : 'publish',
                      child: Text(isShared ? 'Unpublish' : 'Publish'),
                    ),
                    PopupMenuItem(
                      key: Key('topo-delete-${topo.wallId}'),
                      value: 'delete',
                      child: const Text('Delete'),
                    ),
                  ];
                },
              ),
              Icon(Icons.chevron_right, color: colors.ink3),
            ],
          ),
        ),
      ),
    );
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

  /// Publishes [topo] to Community after an explicit confirm (this is the
  /// one-way-feeling, "everyone can see this" action, so — mirroring
  /// [_handleDelete]'s confirm-then-act shape — it asks first rather than
  /// firing straight off the menu tap). [_handleUnpublish] (the reverse
  /// direction) needs no such confirmation.
  Future<void> _handlePublish(
    BuildContext context,
    WidgetRef ref,
    TopoRef topo,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Publish to Community?'),
        content: Text(
          '"${topo.name}" will become visible to everyone in Community. '
          'You can unpublish it again at any time.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: Key('topo-publish-confirm-${topo.wallId}'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Publish'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(libraryCrudRepositoryProvider).publishTopo(topo.wallId);
    }
  }

  Future<void> _handleUnpublish(WidgetRef ref, TopoRef topo) {
    return ref.read(libraryCrudRepositoryProvider).unpublishTopo(topo.wallId);
  }

  Future<void> _handleDelete(
    BuildContext context,
    WidgetRef ref,
    TopoRef topo,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete?'),
        content: Text('Delete "${topo.name}"? This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: Key('topo-delete-confirm-${topo.wallId}'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(libraryCrudRepositoryProvider).softDeleteWall(topo.wallId);
    }
  }
}

/// Small grade pill shown in a topo row's subtitle (see DESIGN.md "Topos
/// home"): [band]-color background, white text = [label]. Placed before the
/// "N routes" text; omitted entirely by the caller when a topo has no
/// graded route.
class _GradePill extends StatelessWidget {
  const _GradePill({required this.label, required this.band});

  final String label;
  final GradeBand band;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: MasiSpacing.sm,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        color: _colorForGradeBand(colors, band),
        borderRadius: BorderRadius.circular(MasiRadii.control),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
          color: Colors.white,
          fontWeight: FontWeight.w600,
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
/// when it has one and the file is still readable, else an amethyst gradient
/// placeholder. `errorBuilder` covers the file existing-at-query-time but
/// failing to decode/load; `existsSync` covers it having been moved/deleted
/// out from under us, so neither path ever surfaces a broken-image icon.
class _Thumbnail extends StatelessWidget {
  const _Thumbnail({required this.path});

  final String? path;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    final radius = BorderRadius.circular(10);
    final thumbnailPath = path;

    Widget child;
    if (thumbnailPath != null && File(thumbnailPath).existsSync()) {
      child = Image.file(
        File(thumbnailPath),
        width: 52,
        height: 52,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) =>
            _GradientFallback(colors: colors),
      );
    } else {
      child = _GradientFallback(colors: colors);
    }

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
