import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme.dart';
import '../../../shared/presentation/masi_pending_button.dart';
import '../../account/application/profile_providers.dart';
import '../application/ascents_providers.dart';
import '../data/ascents_repository.dart';
import 'logbook_screen.dart' show styleLabel;

/// Modal sheet for logging an ascent of one route: an [AscentStyle] picker,
/// an optional notes field, and a save action that stamps `climbedAt` to
/// "now" (no date picker — matches the ticket's "date defaulting to now"
/// spec).
///
/// Extracted from `CommunityTopoDetailScreen`'s original private
/// `_LogAscentSheet` so it can be shared by BOTH that screen's per-route
/// "log ascent" button AND the user's own topo canvas legend
/// (`RouteLegend.onLogAscent` / `TopoCanvasScreen`) — previously logging an
/// ascent was only reachable from the community (published-topo) detail
/// view, with no discoverable way to log an ascent while viewing one's own
/// routes.
///
/// [keyPrefix] namespaces every [Key] this widget assigns (the outer sheet,
/// each style chip, the notes field, and the save button) so two different
/// call sites keep their own stable widget-test keys without colliding —
/// e.g. `'$keyPrefix-ascent-save'`. The community screen passes
/// `'community'`, preserving its pre-extraction keys
/// (`community-log-ascent-sheet` / `community-ascent-style-<name>` /
/// `community-ascent-notes` / `community-ascent-save`) exactly; the topo
/// canvas passes `'topo'`.
/// How long the post-save "Ascent logged" confirmation stays up.
///
/// Longer than Material's 4 s default, deliberately. A snackbar carrying only
/// a message can afford 4 s; this one carries the app's most prominent signal
/// that a Logbook exists at all, and spending it needs the user to notice the
/// bar, read it, notice there is an action to its right, decide, and move a
/// thumb there — right after a save they were already done with. 4 s
/// reliably lost that race in review; this is the same order as Material's
/// own guidance for a snackbar whose action matters.
const Duration kAscentLoggedSnackDuration = Duration(seconds: 6);

class LogAscentSheet extends ConsumerStatefulWidget {
  const LogAscentSheet({
    super.key,
    required this.routeId,
    required this.wallId,
    required this.keyPrefix,
  });

  /// The route's real, persisted DB row id — see
  /// `RouteRepository.routeDbIdsByNumber`'s doc for why this must NOT be
  /// `TopoRoute.id` (a locally-reassigned sequential int with no stable
  /// identity across a `loadRoutes` call). This is the only id
  /// [AscentsRepository.logAscent] (and `Ascents.routeId`) can reference.
  final String routeId;

  /// The wall the route belongs to, passed straight through to
  /// [AscentsRepository.logAscent].
  final String wallId;

  /// Namespaces this widget's own [Key]s — see class doc.
  final String keyPrefix;

  @override
  ConsumerState<LogAscentSheet> createState() => _LogAscentSheetState();
}

class _LogAscentSheetState extends ConsumerState<LogAscentSheet> {
  AscentStyle _style = AscentStyle.redpoint;
  final _notesController = TextEditingController();

  /// Feature #12 opt-in: whether this ascent should be visible on the
  /// public community feed (`Ascent.visibility == 'shared'`). Defaults to
  /// `false` ('private') — sharing is opt-in, never on by default.
  bool _shared = false;

  @override
  void dispose() {
    _notesController.dispose();
    super.dispose();
  }

  /// The re-entrancy guard that used to live here as a `_saving` bool — without
  /// which a double-tap on Save logged a duplicate ascent — is now
  /// [MasiPendingButton]'s: it swallows a second tap in the same frame and
  /// stays disabled for the whole flight.
  Future<void> _save() async {
    final notes = _notesController.text.trim();
    final authorName = ref.read(myDisplayNameProvider).asData?.value;
    // Both captured BEFORE the await, because this sheet pops ITSELF below and
    // a popped route's `context` can no longer look either of them up. The
    // messenger this resolves to is the app-level one `MaterialApp` installs
    // above the Navigator (a modal bottom sheet has no Scaffold of its own),
    // so it outlives the sheet route and paints the confirmation over
    // whichever screen opened the sheet.
    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.maybeOf(context);
    await ref
        .read(ascentsRepositoryProvider)
        .logAscent(
          routeId: widget.routeId,
          wallId: widget.wallId,
          climbedAt: DateTime.now(),
          style: _style,
          notes: notes.isEmpty ? null : notes,
          shared: _shared,
          authorName: authorName,
        );
    if (mounted) {
      FocusManager.instance.primaryFocus?.unfocus();
      Navigator.of(context).pop();
    }
    // Raised HERE — in the shared sheet — rather than at either call site, so
    // both entry points into logging an ascent (the community topo detail
    // screen's per-route button and the user's own topo canvas legend) get the
    // confirmation and the Logbook signpost from one place, and a third call
    // site cannot be added without it.
    //
    // Deliberately NOT `mounted`-gated: the ascent is written either way, so a
    // sheet torn down mid-flight (swipe-dismiss racing the save) must still
    // confirm. And deliberately AFTER the await, so a `logAscent` that throws
    // skips this entirely and only `MasiPendingButton`'s `onError` failure
    // snackbar is shown — never both.
    messenger.showSnackBar(
      SnackBar(
        key: const Key('ascent-logged-snack'),
        content: const Text('Ascent logged'),
        duration: kAscentLoggedSnackDuration,
        action: SnackBarAction(
          key: const Key('ascent-logged-view-logbook'),
          label: 'View logbook',
          // `router?.push`, not `context.push`/`GoRouter.of`: there is no live
          // context to route from once the sheet has popped, and the captured
          // router is null ONLY in a widget-test harness with no router above
          // the sheet. The action is rendered unconditionally regardless, so
          // whether the confirmation OFFERS a way to the Logbook never depends
          // on the harness — every real call site sits under the app router.
          //
          // `push` (not `go`) so the Logbook is a detour: dismissing it
          // returns to the topo the ascent was just logged on.
          onPressed: () => router?.push('/logbook'),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: Key('${widget.keyPrefix}-log-ascent-sheet'),
      padding: EdgeInsets.only(
        left: MasiSpacing.lg,
        right: MasiSpacing.lg,
        top: MasiSpacing.lg,
        bottom: MediaQuery.viewInsetsOf(context).bottom + MasiSpacing.lg,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Log ascent', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: MasiSpacing.md),
          Wrap(
            spacing: MasiSpacing.sm,
            children: [
              for (final style in AscentStyle.values)
                ChoiceChip(
                  key: Key('${widget.keyPrefix}-ascent-style-${style.name}'),
                  label: Text(styleLabel(style)),
                  selected: _style == style,
                  onSelected: (_) => setState(() => _style = style),
                ),
            ],
          ),
          const SizedBox(height: MasiSpacing.md),
          TextField(
            key: Key('${widget.keyPrefix}-ascent-notes'),
            controller: _notesController,
            decoration: const InputDecoration(hintText: 'Notes (optional)'),
          ),
          const SizedBox(height: MasiSpacing.md),
          SwitchListTile(
            key: const Key('log-ascent-share-toggle'),
            contentPadding: EdgeInsets.zero,
            value: _shared,
            onChanged: (value) => setState(() => _shared = value),
            title: const Text('Share to community feed'),
            subtitle: const Text(
              'Others can see, like & comment on this ascent',
            ),
          ),
          const SizedBox(height: MasiSpacing.md),
          MasiPendingButton.filled(
            key: Key('${widget.keyPrefix}-ascent-save'),
            expand: true,
            onPressed: _save,
            onError: (error, stackTrace) => ScaffoldMessenger.of(
              context,
            ).showSnackBar(
              const SnackBar(
                content: Text("Couldn't log this ascent — please try again"),
              ),
            ),
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }
}
