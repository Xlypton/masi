import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme.dart';
import '../../../core/db/database_provider.dart';
import '../../../shared/presentation/masi_async_view.dart';
import '../../../shared/presentation/masi_icon.dart';
import '../../../shared/presentation/masi_pending_button.dart';
import '../../topo/data/photo_path_resolution.dart';
import '../application/geometry_providers.dart';
import '../application/suggestion_providers.dart';
import '../domain/edit_suggestion.dart';
import 'topo_line_view.dart';

/// The owner's inbox of suggested edits (community editing phase 7a / C-5).
///
/// The owner decides and their decision is final — no admin re-review
/// (decided 2026-08-06). That makes this screen the entire governance of edits
/// to published content, which is worth saying out loud: everything C-5c warns
/// about lands here.
///
/// Oldest first. An owner who ignores suggestions is not a bug, but a topo
/// with a growing pile and an absent owner is the C-11 failure, and working
/// oldest-first is what keeps a pile from becoming permanent.
class SuggestionsInboxScreen extends ConsumerWidget {
  const SuggestionsInboxScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      key: const Key('suggestions-inbox-screen'),
      appBar: AppBar(
        title: Text(
          'Suggested edits',
          style: Theme.of(context).textTheme.displaySmall,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        centerTitle: false,
      ),
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(mySuggestionsProvider),
        child: MasiAsyncView<List<EditSuggestion>>(
          value: ref.watch(mySuggestionsProvider),
          errorMessage: "Couldn't load your suggestions",
          onRetry: () => ref.invalidate(mySuggestionsProvider),
          skeleton: (context) => const Center(
            child: Padding(
              padding: EdgeInsets.all(MasiSpacing.xxl),
              child: CircularProgressIndicator(),
            ),
          ),
          data: (context, list) =>
              list.isEmpty ? const _InboxEmpty() : _InboxList(list: list),
        ),
      ),
    );
  }
}

class _InboxEmpty extends StatelessWidget {
  const _InboxEmpty();

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    // A ListView, not a Center: an empty state inside a RefreshIndicator has
    // to be scrollable or pull-to-refresh does not work on it.
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: MasiSpacing.xxl * 2),
      children: [
        Center(
          child: Column(
            children: [
              MasiIcon('check', size: 40, color: colors.ink3),
              const SizedBox(height: MasiSpacing.md),
              Text(
                'Nothing suggested',
                key: const Key('suggestions-inbox-empty'),
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(color: colors.ink2),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _InboxList extends StatelessWidget {
  const _InboxList({required this.list});

  final List<EditSuggestion> list;

  @override
  Widget build(BuildContext context) => ListView.builder(
    padding: const EdgeInsets.only(bottom: MasiSpacing.xxl),
    itemCount: list.length,
    itemBuilder: (context, i) => _SuggestionRow(suggestion: list[i]),
  );
}

/// Whether [key] (a `PhotoFiles`-style storage key) actually has bytes
/// behind it locally.
///
/// `topoGeometryProvider` resolving proves the photo's DB ROW exists, not
/// that anything is behind the THUMBNAIL key `_GeometryDiff` asks
/// `TopoLineView` to render (MEM-1, `TopoLineView.useThumbnail`) — a photo
/// published before thumbnail generation existed has no `thumbs/<id>.jpg`
/// ever written for it. This is what lets `_SuggestionRow` fall back to the
/// full-resolution original in exactly that case, instead of rendering
/// nothing behind an Apply button that stayed enabled.
final _thumbHasBytesProvider = FutureProvider.autoDispose.family<bool, String>(
  (ref, key) => ref.watch(photoFilesProvider).hasPhotoBytes(key),
);

/// The proposed line drawn over the topo it is proposed for (§C-5b,
/// requirement 3).
///
/// Bounded to a row-sized box on purpose. This is the "is this worth looking
/// at" view, not the decision surface — "Open" is right there for the full
/// canvas — and an inbox where every unanswered suggestion is a full-bleed
/// photo is an inbox nobody scrolls to the bottom of.
class _GeometryDiff extends StatelessWidget {
  const _GeometryDiff({
    required this.suggestion,
    required this.geometry,
    required this.useThumbnail,
  });

  final EditSuggestion suggestion;
  final AsyncValue<TopoGeometry?> geometry;

  /// Whether to render the photo's small `thumbs/<id>.jpg` derivative rather
  /// than the full-resolution original — decided by `_SuggestionRowState`
  /// from [_thumbHasBytesProvider], not by this widget: see
  /// `TopoLineView.useThumbnail`'s doc for why the inbox wants the small one
  /// at all (MEM-1 — a full-resolution decode behind every pending row's
  /// 180px box is a mobile-Safari crash risk), and this class's own
  /// [_thumbHasBytesProvider] doc for why it is not unconditional.
  final bool useThumbnail;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    final proposal = suggestion.geometry;

    return SizedBox(
      height: 180,
      child: switch (geometry) {
        AsyncValue(hasValue: true, value: final TopoGeometry data)
            when proposal != null =>
          Align(
            alignment: Alignment.centerLeft,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(MasiRadii.control),
              child: TopoLineView(
                key: Key('suggestion-diff-${suggestion.id}'),
                photo: data.photo,
                routes: data.routes,
                proposedPoints: proposal.points,
                proposedSymbols: proposal.symbols ?? const [],
                // The line being replaced is dropped from the underlay: what
                // is on screen is what accepting would produce. See
                // `TopoLineView.replacedRouteNumber`.
                replacedRouteNumber: _replacedNumber(data),
                useThumbnail: useThumbnail,
              ),
            ),
          ),
        // The photo this was drawn on is not on this device — usually because
        // the owner deleted it. Says so rather than showing an empty frame,
        // and the Apply button is disabled alongside (see the row's
        // `canApply`), because a line nobody can see is a line nobody can
        // judge.
        AsyncValue(hasValue: true) => Center(
          child: Text(
            'That photo is no longer on this topo',
            key: Key('suggestion-diff-missing-${suggestion.id}'),
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: colors.ink2),
          ),
        ),
        AsyncValue(hasError: true) => Center(
          child: Text(
            "Couldn't draw this suggestion",
            key: Key('suggestion-diff-error-${suggestion.id}'),
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: colors.ink2),
          ),
        ),
        _ => const Center(child: CircularProgressIndicator()),
      },
    );
  }

  /// Maps the suggestion's target route (a database uuid) back to the local
  /// [TopoRoute.number] the painter draws by.
  ///
  /// This direction, not the other: the uuid is the stable identity and the
  /// number is the local one, so the lookup has to start from the uuid. Doing
  /// it the other way is exactly the §C-5b requirement-2 bug.
  int? _replacedNumber(TopoGeometry data) {
    final routeId = suggestion.routeId;
    if (routeId == null) return null;
    for (final entry in data.routeIdsByNumber.entries) {
      if (entry.value == routeId) return entry.key;
    }
    return null;
  }
}

class _SuggestionRow extends ConsumerStatefulWidget {
  const _SuggestionRow({required this.suggestion});

  final EditSuggestion suggestion;

  @override
  ConsumerState<_SuggestionRow> createState() => _SuggestionRowState();
}

class _SuggestionRowState extends ConsumerState<_SuggestionRow> {
  Future<void> _accept() async {
    try {
      await ref.read(suggestionServiceProvider).accept(widget.suggestion);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Applied — ${widget.suggestion.authorLabel} credited'),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      // The apply happens BEFORE the mark (see `SuggestionService.accept`), so
      // a failure here can mean the edit landed and only the bookkeeping did
      // not. Saying "couldn't apply" would be a guess; saying what to do next
      // is not.
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Couldn't finish that — try again in a moment"),
        ),
      );
    }
  }

  Future<void> _reject() async {
    try {
      await ref.read(suggestionServiceProvider).reject(widget.suggestion);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Declined')));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Couldn't record that decision")),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    final textTheme = Theme.of(context).textTheme;
    final s = widget.suggestion;

    // A geometry proposal is decided from a picture, so the picture has to be
    // resolvable before Apply means anything. This watches the same local rows
    // the diff draws from: no photo row, no diff, no Apply — an owner tapping
    // Apply on a blank box would be approving something they never saw.
    final geometry = s.kind == SuggestionKind.routeGeometry
        ? ref.watch(
            topoGeometryProvider((wallId: s.wallId, photoId: s.photoId)),
          )
        : null;

    // The diff reads the photo's THUMBNAIL (MEM-1), which a photo published
    // before thumbnail generation existed has no bytes behind — resolving
    // `geometry` only proves the ROW is there, not that key. `_GeometryDiff`
    // falls back to the full-resolution original the moment this resolves
    // `false`, rather than rendering nothing behind an enabled Apply button.
    final geometryPhoto = geometry?.value?.photo;
    final thumbHasBytes = geometryPhoto == null
        ? null
        : ref.watch(
            _thumbHasBytesProvider(thumbKeyFor(geometryPhoto.localPath)),
          );

    // NOT YET KNOWN is not the same as PRESENT: `useThumbnail` below defaults
    // to `true` while `thumbHasBytes` is still resolving (the common case,
    // and the whole memory fix — defaulting the other way would decode the
    // full-resolution original on every row's first frame, exactly the cost
    // this activation exists to avoid), which means the row can briefly show
    // an empty placeholder for a photo that in fact has no thumbnail. So
    // Apply waits for `thumbHasBytes` to have SETTLED (`hasValue`, true
    // whichever way it resolves) in addition to `geometry` itself — the same
    // "no photo row [resolved], no diff, no Apply" reasoning this gate
    // already applied to `geometry`, extended to the second async read the
    // fallback introduced. Never permanently blocked: once settled, either
    // branch renders a real, visible line.
    final canApply =
        geometry == null ||
        (geometry.value != null && (thumbHasBytes?.hasValue ?? false));
    final useThumbnail = thumbHasBytes?.value ?? true;

    return Container(
      key: Key('suggestion-row-${s.id}'),
      margin: const EdgeInsets.fromLTRB(
        MasiSpacing.lg,
        MasiSpacing.sm,
        MasiSpacing.lg,
        0,
      ),
      padding: const EdgeInsets.all(MasiSpacing.md),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(MasiRadii.card),
        border: Border.all(color: colors.separator),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            s.targetLabel,
            style: textTheme.titleMedium,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: MasiSpacing.xs),
          // A proposed LINE is shown, not described (§C-5b, requirement 3).
          // "points: [Offset(0.41, 0.72), …]" renders the patch faithfully and
          // tells the owner nothing they could decide on.
          if (s.kind == SuggestionKind.routeGeometry) ...[
            Text(
              s.isNewLine
                  ? 'A line this topo does not have'
                  : 'A different shape for ${s.targetLabel}',
              key: Key('suggestion-geometry-summary-${s.id}'),
              style: textTheme.bodySmall?.copyWith(color: colors.ink2),
            ),
            const SizedBox(height: MasiSpacing.xs),
            _GeometryDiff(
              suggestion: s,
              geometry: geometry!,
              useThumbnail: useThumbnail,
            ),
            const SizedBox(height: MasiSpacing.xs),
          ],
          // What is actually proposed, spelled out. An owner deciding from
          // "someone suggested an edit" is deciding on nothing.
          for (final change in s.changes)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: '${change.label}: ',
                      style: textTheme.bodySmall?.copyWith(color: colors.ink2),
                    ),
                    TextSpan(
                      text: change.value,
                      style: textTheme.bodySmall?.copyWith(
                        color: colors.ink,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          if (s.note != null) ...[
            const SizedBox(height: 2),
            Text(
              s.note!,
              style: textTheme.bodySmall?.copyWith(color: colors.ink),
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          // Not a blocker, and not styled as an error: the owner may well still
          // want the fix. But "somebody suggests renaming this to X" and
          // "somebody suggested renaming this to X before you renamed it
          // yourself" are different decisions, and only one of them is safe to
          // make without looking (C-5, Guardrails).
          if (s.isStale) ...[
            const SizedBox(height: MasiSpacing.xs),
            Row(
              key: Key('suggestion-stale-${s.id}'),
              children: [
                MasiIcon('warning', size: 14, color: colors.gradeHard),
                const SizedBox(width: MasiSpacing.xs),
                Flexible(
                  child: Text(
                    'Written before your last change to this topo',
                    style: textTheme.bodySmall?.copyWith(
                      color: colors.gradeHard,
                    ),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 2),
          Text(
            '${s.authorLabel} · ${_ago(s.createdAt)}',
            style: textTheme.bodySmall?.copyWith(color: colors.ink2),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: MasiSpacing.sm),
          Row(
            children: [
              TextButton(
                key: Key('suggestion-open-${s.id}'),
                onPressed: () => context.push('/walls/${s.wallId}'),
                child: const Text('Open'),
              ),
              const Spacer(),
              TextButton(
                key: Key('suggestion-reject-${s.id}'),
                onPressed: _reject,
                child: const Text('Decline'),
              ),
              const SizedBox(width: MasiSpacing.xs),
              MasiPendingButton.filled(
                key: Key('suggestion-accept-${s.id}'),
                onPressed: canApply ? _accept : null,
                child: const Text('Apply'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static String _ago(int atMs) {
    final waited = DateTime.now().difference(
      DateTime.fromMillisecondsSinceEpoch(atMs),
    );
    if (waited.inDays >= 1) return '${waited.inDays}d ago';
    if (waited.inHours >= 1) return '${waited.inHours}h ago';
    if (waited.inMinutes >= 1) return '${waited.inMinutes}m ago';
    return 'just now';
  }
}
