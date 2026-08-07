import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme.dart';
import '../../../shared/presentation/masi_async_view.dart';
import '../../../shared/presentation/masi_dialogs.dart';
import '../../../shared/presentation/masi_icon.dart';
import '../../../shared/presentation/masi_pending_button.dart';
import '../application/duplicate_providers.dart';
import '../application/moderation_providers.dart';
import '../application/report_providers.dart';
import '../domain/content_report.dart';

/// The admin review queue (community editing phases 3 and 6b).
///
/// Two tabs, and the split is the point. **Submissions** are content asking to
/// come in; **Reports** are content already in that somebody says should not
/// be. A queue containing only the first stops bad submissions and does
/// nothing about a good submission that goes bad later — which, with owner
/// approval final and no re-review after publication (C-5c), is most of what
/// actually happens.
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
    if (!isAdmin) {
      return Scaffold(
        key: const Key('admin-queue-screen'),
        appBar: AppBar(
          title: Text(
            'Review queue',
            style: Theme.of(context).textTheme.displaySmall,
          ),
          centerTitle: false,
        ),
        body: const _NotAnAdmin(),
      );
    }

    final reports = ref.watch(openReportsProvider).asData?.value;
    final urgent = reports?.any((r) => r.isUrgent) ?? false;

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        key: const Key('admin-queue-screen'),
        appBar: AppBar(
          title: Text(
            'Review queue',
            style: Theme.of(context).textTheme.displaySmall,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          centerTitle: false,
          bottom: TabBar(
            tabs: [
              const Tab(key: Key('admin-tab-submissions'), text: 'Submissions'),
              Tab(
                key: const Key('admin-tab-reports'),
                // The count is on the tab rather than inside it because an
                // unsafe report the admin never opens the tab to see is the
                // failure mode C-12 exists to prevent. `!` marks urgency
                // without needing colour to carry the meaning.
                text: switch ((reports?.length ?? 0, urgent)) {
                  (0, _) => 'Reports',
                  (final n, true) => 'Reports ($n) !',
                  (final n, _) => 'Reports ($n)',
                },
              ),
            ],
          ),
        ),
        body: const TabBarView(
          children: [_SubmissionsTab(), _ReportsTab()],
        ),
      ),
    );
  }
}

class _SubmissionsTab extends ConsumerWidget {
  const _SubmissionsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return RefreshIndicator(
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
                itemBuilder: (context, i) => _QueueRow(entry: entries[i]),
              ),
      ),
    );
  }
}

class _ReportsTab extends ConsumerWidget {
  const _ReportsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = MasiColors.of(context);
    return RefreshIndicator(
      onRefresh: () async => ref.invalidate(openReportsProvider),
      child: MasiAsyncView<List<ContentReport>>(
        value: ref.watch(openReportsProvider),
        errorMessage: "Couldn't load reports",
        onRetry: () => ref.invalidate(openReportsProvider),
        skeleton: (context) => const Center(
          child: Padding(
            padding: EdgeInsets.all(MasiSpacing.xxl),
            child: CircularProgressIndicator(),
          ),
        ),
        data: (context, reports) => reports.isEmpty
            ? ListView(
                padding: const EdgeInsets.symmetric(
                  vertical: MasiSpacing.xxl * 2,
                ),
                children: [
                  Center(
                    child: Column(
                      children: [
                        MasiIcon('check', size: 40, color: colors.ink3),
                        const SizedBox(height: MasiSpacing.md),
                        Text(
                          'Nothing reported',
                          key: const Key('admin-reports-empty'),
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(color: colors.ink2),
                        ),
                      ],
                    ),
                  ),
                ],
              )
            : ListView.builder(
                padding: const EdgeInsets.only(bottom: MasiSpacing.xxl),
                itemCount: reports.length,
                itemBuilder: (context, i) => _ReportRow(report: reports[i]),
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

/// One open report, with everything needed to decide without leaving.
///
/// The reporter is named here and NOWHERE else in the app. `content_reports`
/// is readable by its author and by admins only — the topo's owner cannot read
/// it or learn who filed it — because several of the reasons are accusations
/// ABOUT the owner, and handing the accused the reporter's identity is how a
/// community learns that reporting invites retaliation.
class _ReportRow extends ConsumerStatefulWidget {
  const _ReportRow({required this.report});

  final ContentReport report;

  @override
  ConsumerState<_ReportRow> createState() => _ReportRowState();
}

class _ReportRowState extends ConsumerState<_ReportRow> {
  Future<void> _uphold() async {
    // A note is optional here, unlike a rejection reason. A rejection is shown
    // to the owner and has to teach them something; a report resolution is
    // read by moderators and by phase 8's trust maths, both of which get what
    // they need from the verdict alone.
    await _resolve(uphold: true);
  }

  Future<void> _dismiss() => _resolve(uphold: false);

  /// Records that the two topos are the same place, and upholds the report in
  /// the same gesture (community editing phase 8b / C-6.4).
  ///
  /// One tap for both, because they are one decision: an admin who agrees these
  /// are the same boulder has both linked them and found the complaint correct,
  /// and making them press two buttons is how the queue ends up full of linked
  /// pairs whose reports are still open.
  ///
  /// **Nothing is deleted.** Both topos stay published, owned and editable;
  /// readers see one card for the place instead of two. That is the whole of
  /// what "merge" means here (§3.3 — never destroy something people have logged
  /// ascents against), and it is why this needs no confirmation step: there is
  /// nothing to undo but a link, and `unlink_alternate` undoes it.
  Future<void> _link() async {
    final report = widget.report;
    final duplicateOf = report.duplicateOfId;
    if (duplicateOf == null) return;
    try {
      await ref
          .read(alternateServiceProvider)
          .link(
            // The REPORTED topo becomes the alternate and the named one the
            // canonical. That direction follows the reporter's own sentence —
            // "this is the same boulder as X" makes X the one that was already
            // here — and it is the direction that leaves the older listing as
            // the group's identity.
            duplicateId: report.wallId,
            canonicalId: duplicateOf,
          );
      await ref
          .read(reportServiceProvider)
          .resolve(reportId: report.id, uphold: true);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Linked to ${report.duplicateOfName ?? 'the other topo'} — '
            'both are still published',
          ),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Couldn't link those two")),
      );
    }
  }

  /// Removes the topo from public view AND deletes its published photo bytes,
  /// then upholds the report (W-2 / C-7).
  ///
  /// Confirmed first, unlike every other action on this row, because it is the
  /// only one that destroys something: the public copies of the photos. What it
  /// does NOT destroy — the topo record, its routes, its ascents, the owner's
  /// own copy of the photo — is said out loud in the sheet, because an admin who
  /// believes they are deleting a climber's work will hesitate to use the
  /// control that exists precisely for the cases where hesitating is wrong.
  Future<void> _takeDown() async {
    final report = widget.report;
    final confirmed = await showMasiConfirm(
      context,
      sheetKey: const Key('admin-takedown-confirm'),
      confirmKey: const Key('admin-takedown-confirm-yes'),
      cancelKey: const Key('admin-takedown-confirm-no'),
      title: 'Take down this topo?',
      message:
          'It stops being public and its published images are deleted. The '
          'routes, ascents and history are kept, and the owner keeps their own '
          'copy of the photo — so this can be undone by re-publishing.',
      confirmLabel: 'Take down',
      isDestructive: true,
    );
    if (!confirmed || !mounted) return;

    try {
      final result = await ref
          .read(takedownServiceProvider)
          .remove(wallId: report.wallId, reason: report.reason.wire);
      await ref
          .read(reportServiceProvider)
          .resolve(reportId: report.id, uphold: true);
      if (!mounted) return;

      // The counts are surfaced rather than smoothed over. A takedown that
      // changed the state but removed none of the bytes is exactly W-2, and an
      // unqualified "Taken down" is what let that hide.
      final missed = result.photoObjects - result.photoBytesRemoved;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            missed == 0
                ? 'Taken down — ${result.photoBytesRemoved} image(s) removed'
                : 'Taken down, but $missed of ${result.photoObjects} image(s) '
                      'could not be removed',
          ),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Couldn't take that down")),
      );
    }
  }

  Future<void> _resolve({required bool uphold}) async {
    try {
      await ref
          .read(reportServiceProvider)
          .resolve(reportId: widget.report.id, uphold: uphold);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(uphold ? 'Report upheld' : 'Report dismissed'),
        ),
      );
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
    final report = widget.report;
    final urgent = report.isUrgent;

    return Container(
      key: Key('admin-report-row-${report.id}'),
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
        border: Border.all(
          color: urgent ? colors.gradeHard : colors.separator,
          width: urgent ? 1.5 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (urgent) ...[
                MasiIcon('warning', size: 16, color: colors.gradeHard),
                const SizedBox(width: MasiSpacing.xs),
              ],
              Flexible(
                child: Text(
                  report.reason.label,
                  key: Key('admin-report-reason-${report.id}'),
                  style: textTheme.titleSmall?.copyWith(
                    color: urgent ? colors.gradeHard : colors.ink,
                    fontWeight: FontWeight.w700,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            report.targetLabel,
            style: textTheme.titleMedium,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          // Phase 8b: WHICH topo it duplicates. Without this an admin holding a
          // "duplicate" report has to go and find the other one by hand, which
          // is how this half of the queue stops being worked at all.
          if (report.duplicateOfName != null) ...[
            const SizedBox(height: 2),
            Text(
              report.alreadyLinked
                  ? 'Already linked to ${report.duplicateOfName}'
                  : 'Same as: ${report.duplicateOfName}',
              key: Key('admin-report-duplicate-of-${report.id}'),
              style: textTheme.bodySmall?.copyWith(color: colors.ink2),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          if (report.body != null) ...[
            const SizedBox(height: 2),
            Text(
              report.body!,
              style: textTheme.bodySmall?.copyWith(color: colors.ink),
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          const SizedBox(height: 2),
          Text(
            '${report.reporterLabel} · ${_waitedFor(report.createdAt)}',
            style: textTheme.bodySmall?.copyWith(color: colors.ink2),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: MasiSpacing.sm),
          Row(
            children: [
              // Same reasoning as the submissions queue: deciding on content
              // you have not looked at is the failure a review surface exists
              // to prevent, so looking is the first affordance, not the last.
              TextButton(
                key: Key('admin-report-open-${report.id}'),
                onPressed: () => context.push('/walls/${report.wallId}'),
                child: const Text('Open'),
              ),
              const Spacer(),
              if (report.canLink) ...[
                MasiPendingButton.text(
                  key: Key('admin-report-link-${report.id}'),
                  onPressed: _link,
                  child: const Text('Link'),
                ),
                const SizedBox(width: MasiSpacing.xs),
              ],
              // Only where taking the images down is the point. A duplicate or
              // an inaccurate grade is fixed by linking or editing, and offering
              // a destructive control next to those invites using it for
              // problems it does not solve.
              if (report.canTakeDown) ...[
                // A plain TextButton, not MasiPendingButton, and for a concrete
                // reason: this action opens a confirmation sheet first, and a
                // pending button would sit spinning for as long as the admin
                // takes to read it — which also hangs `pumpAndSettle` in tests.
                // `_reject` in the submissions queue is a TextButton for the
                // same reason.
                TextButton(
                  key: Key('admin-report-takedown-${report.id}'),
                  onPressed: _takeDown,
                  child: Text(
                    'Take down',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
                const SizedBox(width: MasiSpacing.xs),
              ],
              TextButton(
                key: Key('admin-report-dismiss-${report.id}'),
                onPressed: _dismiss,
                child: const Text('Dismiss'),
              ),
              const SizedBox(width: MasiSpacing.xs),
              MasiPendingButton.filled(
                key: Key('admin-report-uphold-${report.id}'),
                onPressed: _uphold,
                child: const Text('Uphold'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Shared with `_QueueRowState._waitedFor`'s reasoning: how long something has
/// been waiting is the number that matters in a queue worked oldest-first, and
/// an absolute timestamp makes the reader do the subtraction.
String _waitedFor(int atMs) {
  final waited = DateTime.now().difference(
    DateTime.fromMillisecondsSinceEpoch(atMs),
  );
  if (waited.inDays >= 1) return '${waited.inDays}d ago';
  if (waited.inHours >= 1) return '${waited.inHours}h ago';
  if (waited.inMinutes >= 1) return '${waited.inMinutes}m ago';
  return 'just now';
}
