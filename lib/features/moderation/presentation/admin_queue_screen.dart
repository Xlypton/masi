import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme.dart';
import '../../../shared/presentation/masi_async_view.dart';
import '../../../shared/presentation/masi_dialogs.dart';
import '../../../shared/presentation/masi_icon.dart';
import '../../../shared/presentation/masi_pending_button.dart';
import '../application/moderation_providers.dart';

/// The admin review queue: pending topo submissions, oldest first
/// (community editing phase 3).
///
/// Reaching this screen is not what makes someone an admin — every action it
/// offers is re-checked server-side by a `SECURITY DEFINER` RPC. Hiding the
/// route from non-admins is a courtesy so nobody is shown a button that will
/// only ever fail.
///
/// Deliberately shows enough per row to make a decision without leaving:
/// name, area, route count and how long it has waited. A queue that forces a
/// round trip per item to learn anything is a queue that does not get worked.
class AdminQueueScreen extends ConsumerWidget {
  const AdminQueueScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isAdmin = ref.watch(isAdminProvider).asData?.value ?? false;

    return Scaffold(
      key: const Key('admin-queue-screen'),
      appBar: AppBar(
        title: Text(
          'Review queue',
          style: Theme.of(context).textTheme.displaySmall,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        centerTitle: false,
      ),
      body: !isAdmin
          ? const _NotAnAdmin()
          : RefreshIndicator(
              onRefresh: () async => ref.invalidate(moderationQueueProvider),
              child: MasiAsyncView<List<ModerationQueueEntry>>(
                value: ref.watch(moderationQueueProvider),
                errorMessage: "Couldn't load the review queue",
                onRetry: () => ref.invalidate(moderationQueueProvider),
                // A spinner, not a skeleton: the queue is usually EMPTY, and
                // a skeleton showing three placeholder rows to an admin whose
                // real answer is "nothing waiting" states the opposite of the
                // truth for the whole load.
                skeleton: (context) => const Center(
                  child: Padding(
                    padding: EdgeInsets.all(MasiSpacing.xxl),
                    child: CircularProgressIndicator(),
                  ),
                ),
                data: (context, entries) => entries.isEmpty
                    ? const _QueueEmpty()
                    : ListView.builder(
                        padding: const EdgeInsets.only(bottom: MasiSpacing.xxl),
                        itemCount: entries.length,
                        itemBuilder: (context, i) =>
                            _QueueRow(entry: entries[i]),
                      ),
              ),
            ),
    );
  }
}

class _NotAnAdmin extends StatelessWidget {
  const _NotAnAdmin();

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    return Center(
      key: const Key('admin-queue-forbidden'),
      child: Padding(
        padding: const EdgeInsets.all(MasiSpacing.xl),
        child: Text(
          'This area is for moderators.',
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: colors.ink2),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

class _QueueEmpty extends StatelessWidget {
  const _QueueEmpty();

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
                'Nothing waiting for review',
                key: const Key('admin-queue-empty'),
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

class _QueueRow extends ConsumerStatefulWidget {
  const _QueueRow({required this.entry});

  final ModerationQueueEntry entry;

  @override
  ConsumerState<_QueueRow> createState() => _QueueRowState();
}

class _QueueRowState extends ConsumerState<_QueueRow> {
  Future<void> _approve() => _review(approve: true);

  Future<void> _reject() async {
    // A reason is REQUIRED to reject. A silent rejection teaches the owner
    // nothing and guarantees they resubmit the same thing.
    final reason = await showMasiTextPrompt(
      context,
      title: 'Why are you rejecting this?',
      submitLabel: 'Reject',
      placeholder: 'Shown to the owner',
      fieldKey: const Key('admin-reject-reason-field'),
      submitKey: const Key('admin-reject-reason-submit'),
    );
    if (reason == null || reason.trim().isEmpty) return;
    await _review(approve: false, reason: reason.trim());
  }

  Future<void> _review({required bool approve, String? reason}) async {
    try {
      await ref
          .read(moderationRemoteProvider)
          .reviewTopo(
            wallId: widget.entry.wallId,
            approve: approve,
            reason: reason,
          );
      if (!mounted) return;
      ref.invalidate(moderationQueueProvider);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            approve
                ? '"${widget.entry.wallName}" is now public'
                : '"${widget.entry.wallName}" was rejected',
          ),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      // The RPC re-checks admin status server-side, so this is also what a
      // stale session looks like — say what happened rather than leaving the
      // row looking as if the tap did nothing.
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Couldn't record that decision")),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    final entry = widget.entry;
    final textTheme = Theme.of(context).textTheme;

    return Container(
      key: Key('admin-queue-row-${entry.wallId}'),
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
            entry.wallName,
            style: textTheme.titleMedium,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Text(
            [
              entry.areaName ?? 'Unfiled',
              '${entry.routeCount} route${entry.routeCount == 1 ? '' : 's'}',
              if (entry.submittedAt != null) _waitedFor(entry.submittedAt!),
            ].join(' · '),
            style: textTheme.bodySmall?.copyWith(color: colors.ink2),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: MasiSpacing.sm),
          Row(
            children: [
              // Opening the topo comes FIRST: approving something you have not
              // looked at is the failure mode a review queue is supposed to
              // prevent, so the affordance to look is not buried behind the
              // decision buttons.
              TextButton(
                key: Key('admin-queue-open-${entry.wallId}'),
                onPressed: () => context.push('/walls/${entry.wallId}'),
                child: const Text('Open'),
              ),
              const Spacer(),
              TextButton(
                key: Key('admin-queue-reject-${entry.wallId}'),
                onPressed: _reject,
                style: TextButton.styleFrom(foregroundColor: colors.gradeHard),
                child: const Text('Reject'),
              ),
              const SizedBox(width: MasiSpacing.xs),
              MasiPendingButton.filled(
                key: Key('admin-queue-approve-${entry.wallId}'),
                onPressed: _approve,
                child: const Text('Approve'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// "waited 3d" / "waited 4h" / "waited 12m". Deliberately how long it has
  /// WAITED rather than an absolute timestamp: the queue is worked oldest
  /// first, and the number that matters is how badly somebody is being kept
  /// waiting.
  static String _waitedFor(int submittedAtMs) {
    final waited = DateTime.now().difference(
      DateTime.fromMillisecondsSinceEpoch(submittedAtMs),
    );
    if (waited.inDays >= 1) return 'waited ${waited.inDays}d';
    if (waited.inHours >= 1) return 'waited ${waited.inHours}h';
    if (waited.inMinutes >= 1) return 'waited ${waited.inMinutes}m';
    return 'just submitted';
  }
}
