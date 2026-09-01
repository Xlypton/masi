import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../../../shared/presentation/bottom_safe_inset.dart';
import '../../../shared/presentation/masi_icon.dart';
import '../../../shared/presentation/masi_toast.dart';
import '../../../shared/presentation/masi_pending_button.dart';
import '../../topo/domain/topo_route.dart';
import '../application/geometry_providers.dart';
import '../application/suggestion_providers.dart';
import '../domain/edit_suggestion.dart';
import '../domain/geometry_proposal.dart';
import 'topo_line_view.dart';

/// Draw a line on somebody else's published topo and send it to them
/// (community editing phase 7b / C-5b, requirement 4).
///
/// ## What this deliberately is not
///
/// It is not `TopoCanvas`. That widget is the OWNER's editor: every gesture on
/// it runs through `DrawController`, which write-throughs to the routes table.
/// Reusing it here would put a stranger's drawing one branch away from writing
/// to a topo they do not own, and the branch would be a null check. The rule
/// this phase keeps is the same one that has held since 7a: **non-owners have
/// no write access to any content table.** A proposal is a row in
/// `topo_edit_suggestions` and nothing else; if the owner accepts it, THEIR
/// client writes THEIR rows.
///
/// ## What it cannot do yet, and why that is honest
///
/// No markers. Bolts, anchors and crux dots are not proposable in this phase,
/// and a proposal that touches a route's line leaves its existing markers
/// alone rather than clearing them (see [GeometryProposal.symbols]). Proposing
/// a shape is the contribution people actually want to make; proposing where a
/// bolt is can wait for someone to ask for it.
class ProposeLineScreen extends ConsumerStatefulWidget {
  const ProposeLineScreen({super.key, required this.wallId, this.topoName});

  final String wallId;
  final String? topoName;

  @override
  ConsumerState<ProposeLineScreen> createState() => _ProposeLineScreenState();
}

class _ProposeLineScreenState extends ConsumerState<ProposeLineScreen> {
  final List<Offset> _points = [];

  /// The route this proposal replaces, by [TopoRoute.number], or null for a
  /// line the topo does not have yet.
  ///
  /// Held as a NUMBER and resolved to the database uuid only at send time,
  /// through [TopoGeometry.dbIdFor]. `TopoRoute.id` is reassigned 1..n on
  /// every load (§C-5b, requirement 2) and must never leave the device.
  int? _replacing;

  void _addPoint(Offset percent) {
    if (_points.length >= kMaxProposedPoints) return;
    setState(() => _points.add(percent));
  }

  void _undo() {
    if (_points.isEmpty) return;
    setState(() => _points.removeLast());
  }

  void _clear() => setState(_points.clear);

  /// The "why" that travels with the line.
  ///
  /// A field ON THIS SCREEN rather than a prompt after tapping Send. Two
  /// reasons, and the second is the real one: a modal chain hides the drawing
  /// at the moment someone is explaining it, and the Send button sits there
  /// spinning behind the dialog as though the line had already gone.
  final TextEditingController _note = TextEditingController();

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _send(TopoGeometry geometry) async {
    final proposal = GeometryProposal(points: List.of(_points));
    if (!proposal.isDrawable) return;

    final replacing = _replacing;
    final routeId = replacing == null
        ? null
        : geometry.routeIdsByNumber[replacing];
    // The target vanished between opening this screen and sending — the owner
    // deleted the route, or a pull removed it. Sending anyway would file a
    // proposal against nothing.
    if (replacing != null && routeId == null) {
      _say("That route isn't there any more", kind: MasiToastKind.warning);
      return;
    }

    final note = _note.text.trim();
    try {
      await ref
          .read(suggestionServiceProvider)
          .suggest(
            wallId: widget.wallId,
            kind: SuggestionKind.routeGeometry,
            patch: proposal.toPatch(),
            note: note.isEmpty ? null : note,
            routeId: routeId,
            photoId: geometry.photo.id,
          );
      if (!mounted) return;
      Navigator.of(context).pop();
      _say('Sent — the owner decides whether to use it',
          kind: MasiToastKind.success);
    } catch (error) {
      if (!mounted) return;
      // The server's refusals are written to be read by the person who drew
      // the line ("that line has too many points"), so show what it said
      // rather than a generic failure that hides an actionable reason.
      _say(_reason(error), kind: MasiToastKind.error);
    }
  }

  /// Both outcomes of [_send] speak through here, so the kind is a required
  /// argument rather than a default: the two call sites are a success and a
  /// failure, and a helper that quietly picked one for them is how they would
  /// end up looking identical again.
  void _say(String message, {required MasiToastKind kind}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showMasiToast(message, kind: kind);
  }

  static String _reason(Object error) {
    final raw = error.toString();
    final match = RegExp(r'message: ([^,)]+)').firstMatch(raw);
    final message = match?.group(1)?.trim();
    return message == null || message.isEmpty
        ? "Couldn't send that line — try again in a moment"
        : message;
  }

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    // The PRIMARY photo (a null id): this is where a proposer starts, and it
    // is the same photo the community detail screen's canvas opens on, so the
    // line is drawn over the picture they were just looking at.
    final geometry = ref.watch(
      topoGeometryProvider((wallId: widget.wallId, photoId: null)),
    );

    return Scaffold(
      key: const Key('propose-line-screen'),
      appBar: AppBar(
        title: Text(
          widget.topoName ?? 'Suggest a line',
          style: Theme.of(context).textTheme.displaySmall,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        centerTitle: false,
        actions: [
          IconButton(
            key: const Key('propose-line-undo'),
            onPressed: _points.isEmpty ? null : _undo,
            icon: const MasiIcon('undo', size: 20),
            tooltip: 'Undo',
          ),
          TextButton(
            key: const Key('propose-line-clear'),
            onPressed: _points.isEmpty ? null : _clear,
            child: const Text('Clear'),
          ),
        ],
      ),
      body: switch (geometry) {
        AsyncValue(hasValue: true, value: final TopoGeometry data) => _Editor(
          geometry: data,
          points: _points,
          replacing: _replacing,
          onTapPercent: _addPoint,
          onReplacingChanged: (number) => setState(() => _replacing = number),
          onSend: () => _send(data),
          note: _note,
          // Computed here, not inside `_Editor`, because that widget is a
          // plain `StatelessWidget` with no `ref` of its own — this State
          // already has one (`ConsumerState`).
          bottomInset: masiBottomInset(context, ref),
        ),
        // A published topo with no photo has nothing to draw on. Not an
        // error — a real, if odd, state — so it says so instead of offering a
        // retry that would resolve to the same thing.
        AsyncValue(hasValue: true) => Center(
          child: Text(
            'This topo has no photo to draw on',
            key: const Key('propose-line-no-photo'),
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: colors.ink2),
          ),
        ),
        AsyncValue(hasError: true) => Center(
          child: Text(
            "Couldn't open this topo",
            key: const Key('propose-line-error'),
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: colors.ink2),
          ),
        ),
        _ => const Center(child: CircularProgressIndicator()),
      },
    );
  }
}

class _Editor extends StatelessWidget {
  const _Editor({
    required this.geometry,
    required this.points,
    required this.replacing,
    required this.onTapPercent,
    required this.onReplacingChanged,
    required this.onSend,
    required this.note,
    required this.bottomInset,
  });

  final TopoGeometry geometry;
  final List<Offset> points;
  final int? replacing;
  final void Function(Offset) onTapPercent;
  final void Function(int?) onReplacingChanged;
  final Future<void> Function() onSend;
  final TextEditingController note;

  /// `masiBottomInset(context, ref)`, computed by the parent State (which
  /// has the `ref` this plain `StatelessWidget` does not) — see the call
  /// site's doc.
  final double bottomInset;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    final textTheme = Theme.of(context).textTheme;
    final enough = points.length >= 2;

    return Column(
      children: [
        // What is being proposed, said before it is drawn. "Correcting route 3"
        // and "adding a line" produce identical gestures and completely
        // different consequences for the owner.
        Padding(
          padding: const EdgeInsets.fromLTRB(
            MasiSpacing.lg,
            MasiSpacing.sm,
            MasiSpacing.lg,
            0,
          ),
          child: SizedBox(
            height: 36,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                _TargetChip(
                  key: const Key('propose-line-target-new'),
                  label: 'New line',
                  selected: replacing == null,
                  onTap: () => onReplacingChanged(null),
                ),
                for (final route in geometry.routes)
                  if (geometry.dbIdFor(route) != null)
                    _TargetChip(
                      key: Key('propose-line-target-${route.number}'),
                      label: route.name?.trim().isNotEmpty == true
                          ? 'Fix ${route.name!.trim()}'
                          : 'Fix line ${route.number}',
                      selected: replacing == route.number,
                      onTap: () => onReplacingChanged(route.number),
                    ),
              ],
            ),
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(MasiSpacing.md),
            child: Center(
              child: InteractiveViewer(
                minScale: 1,
                maxScale: 6,
                // The tap handler sits INSIDE this transform, so it is handed
                // already-untransformed local coordinates and needs no inverse
                // of its own — see `TopoLineView.onTapPercent`.
                child: TopoLineView(
                  key: const Key('propose-line-canvas'),
                  photo: geometry.photo,
                  routes: geometry.routes,
                  proposedPoints: points,
                  replacedRouteNumber: replacing,
                  onTapPercent: onTapPercent,
                ),
              ),
            ),
          ),
        ),
        Padding(
          // Standalone iOS PWA reports safe-area-inset-bottom = 0, so a bare
          // `MediaQuery.paddingOf(context).bottom` read here evaluates to
          // zero and the note field + submit button land on the home
          // indicator. `bottomInset` replaces that term outright (it is
          // already `max(deviceInset, floor)`) rather than being added
          // alongside it — the `MasiSpacing.lg` stays the deliberate gap.
          padding: EdgeInsets.fromLTRB(
            MasiSpacing.lg,
            0,
            MasiSpacing.lg,
            MasiSpacing.lg + bottomInset,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                enough
                    ? '${points.length} points · tap to keep going'
                    : 'Tap along the line — two points is the minimum',
                key: const Key('propose-line-hint'),
                style: textTheme.bodySmall?.copyWith(color: colors.ink2),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: MasiSpacing.sm),
              TextField(
                key: const Key('propose-line-note-field'),
                controller: note,
                textInputAction: TextInputAction.done,
                maxLength: 280,
                decoration: const InputDecoration(
                  hintText: 'Why this line? Optional — but it is what gets one accepted',
                  counterText: '',
                ),
              ),
              const SizedBox(height: MasiSpacing.sm),
              MasiPendingButton.filled(
                key: const Key('propose-line-send'),
                onPressed: enough ? onSend : null,
                child: const Text('Send to the owner'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _TargetChip extends StatelessWidget {
  const _TargetChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(right: MasiSpacing.xs),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: MasiSpacing.md,
            vertical: MasiSpacing.xs,
          ),
          decoration: BoxDecoration(
            color: selected ? colors.accent : colors.surface,
            borderRadius: BorderRadius.circular(MasiRadii.control),
            border: Border.all(
              color: selected ? colors.accent : colors.separator,
            ),
          ),
          child: Center(
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: selected ? colors.onAccent : colors.ink,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
