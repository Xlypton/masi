import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme.dart';
import '../../../shared/presentation/masi_async_view.dart';
import '../../../shared/presentation/masi_icon.dart';
import '../../../shared/presentation/masi_pending_button.dart';
import '../application/suggestion_providers.dart';
import '../domain/edit_suggestion.dart';

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
                onPressed: _accept,
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
