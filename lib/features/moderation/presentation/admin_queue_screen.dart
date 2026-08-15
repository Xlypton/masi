import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme.dart';
import '../../../shared/presentation/bottom_safe_inset.dart';
import '../../../shared/presentation/masi_async_view.dart';
import '../../../shared/presentation/masi_dialogs.dart';
import '../../../shared/presentation/masi_icon.dart';
import '../../../shared/presentation/masi_pending_button.dart';
import '../application/duplicate_providers.dart';
import '../../../core/db/database_provider.dart';
import '../application/moderation_providers.dart';
import '../application/report_providers.dart';
import '../domain/abandoned_topo.dart';
import '../domain/content_report.dart';
import '../domain/deletion_request.dart';
import '../domain/material_change.dart';

/// The admin review queue (community editing phases 3 and 6b, C-5d, C-11).
///
/// Five tabs, and the split is the point. **Submissions** are content asking to
/// come in; the other four are all about content already in. A queue containing
/// only the first stops bad submissions and does nothing about a good
/// submission that goes bad later — which, with owner approval final and no
/// re-review after publication (C-5c), is most of what actually happens.
///
/// The four after it are deliberately different KINDS of "later", not
/// variations on one: **Reports** are somebody complaining; **Stalled** is
/// nothing happening at all when it should be (C-11); **Changes** are a
/// published topo quietly changing shape with nobody complaining (C-5d); and
/// **Deletions** are an owner asking to destroy one outright.
///
/// Only Reports carries a count, and that restraint is the design. Deletions
/// has the next-best claim — a person is genuinely waiting — but a bar where
/// everything is badged is a bar where nothing is, and the one that has to
/// survive a busy day is the unsafe report (C-12).
///
/// Deletions is also the only tab whose decision is irreversible, which is why
/// it is the only one that states what would be LOST (the ascent count) rather
/// than what the item is.
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
      length: 5,
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
            // Scrollable from the fourth tab on. Four fixed tabs divide a phone
            // width into ~95px each, which is narrower than "Submissions" and
            // narrower still than "Reports (12) !" — and a tab bar that
            // ellipsises its own labels hides which queues exist at all.
            isScrollable: true,
            tabAlignment: TabAlignment.start,
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
              // No count on this one, deliberately. Submissions and reports are
              // work that arrived and is waiting; abandonment is a slow
              // condition that was already true yesterday and will still be
              // true tomorrow. A badge would make it compete for the same
              // urgency as an unsafe report, which is exactly the attention it
              // should not take.
              const Tab(key: Key('admin-tab-abandoned'), text: 'Stalled'),
              // No count here either, and for a different reason than Stalled.
              // A material change BLOCKS NOTHING by design (C-5d) — the content
              // is already public and was always allowed to be. Badging it would
              // put "someone edited a topo" at the same volume as an unsafe
              // report, and the tab that must survive a busy day is that one.
              // `Submissions` carries no count for the same reason.
              const Tab(key: Key('admin-tab-changes'), text: 'Changes'),
              // No count here either. Somebody IS waiting on each of these, so
              // it has more claim to a badge than Stalled or Changes — but
              // Submissions carries none for the same reason, and the tab that
              // has to survive a busy day is Reports. One badge in the bar is
              // what keeps that badge meaning "look now".
              const Tab(key: Key('admin-tab-deletions'), text: 'Deletions'),
            ],
          ),
        ),
        body: const TabBarView(
          children: [
            _SubmissionsTab(),
            _ReportsTab(),
            _AbandonedTab(),
            _MaterialChangesTab(),
            _DeletionsTab(),
          ],
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
                // No SafeArea wraps any of these five tab bodies (the
                // TabBarView sits directly under the AppBar's TabBar), so a
                // standalone iOS PWA (safe-area-inset-bottom = 0) leaves the
                // last row flush on the home indicator with nothing
                // reserving the floor. `masiBottomInset` adds it on top of
                // the existing `MasiSpacing.xxl` breathing room.
                padding: EdgeInsets.only(
                  bottom: MasiSpacing.xxl + masiBottomInset(context, ref),
                ),
                itemCount: entries.length,
                itemBuilder: (context, i) => _QueueRow(entry: entries[i]),
              ),
      ),
    );
  }
}

/// Published topos whose owner has stopped answering suggestions (C-11).
///
/// Read-only on purpose. The plan's remedy — transferring ownership, or marking
/// a topo community-maintained — is irreversible and aimed at a real person's
/// work, and it is explicitly meant to be rare. So this surface stops at
/// telling an admin where the problem is; it does not put a button next to it
/// that makes taking someone's topo away the path of least resistance. Opening
/// the topo and its suggestions is the next step, and both already exist.
class _AbandonedTab extends ConsumerWidget {
  const _AbandonedTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = MasiColors.of(context);
    final nowMs = ref.watch(nowMsProvider)();
    return RefreshIndicator(
      onRefresh: () async => ref.invalidate(abandonedToposProvider),
      child: MasiAsyncView<List<AbandonedTopo>>(
        value: ref.watch(abandonedToposProvider),
        errorMessage: "Couldn't load stalled topos",
        onRetry: () => ref.invalidate(abandonedToposProvider),
        skeleton: (context) => const Center(
          child: Padding(
            padding: EdgeInsets.all(MasiSpacing.xxl),
            child: CircularProgressIndicator(),
          ),
        ),
        data: (context, topos) => topos.isEmpty
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
                          'Nothing stalled',
                          key: const Key('admin-abandoned-empty'),
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(color: colors.ink2),
                        ),
                        const SizedBox(height: MasiSpacing.xs),
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: MasiSpacing.xxl,
                          ),
                          child: Text(
                            'Owners are answering their suggestions.',
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: colors.ink3),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              )
            : ListView.builder(
                // No SafeArea wraps any of these five tab bodies (the
                // TabBarView sits directly under the AppBar's TabBar), so a
                // standalone iOS PWA (safe-area-inset-bottom = 0) leaves the
                // last row flush on the home indicator with nothing
                // reserving the floor. `masiBottomInset` adds it on top of
                // the existing `MasiSpacing.xxl` breathing room.
                padding: EdgeInsets.only(
                  bottom: MasiSpacing.xxl + masiBottomInset(context, ref),
                ),
                itemCount: topos.length,
                itemBuilder: (context, i) =>
                    _AbandonedRow(topo: topos[i], nowMs: nowMs),
              ),
      ),
    );
  }
}

class _AbandonedRow extends StatelessWidget {
  const _AbandonedRow({required this.topo, required this.nowMs});

  final AbandonedTopo topo;
  final int nowMs;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    return Padding(
      key: Key('admin-abandoned-row-${topo.wallId}'),
      padding: const EdgeInsets.symmetric(
        horizontal: MasiSpacing.lg,
        vertical: MasiSpacing.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            topo.wallName,
            style: Theme.of(context).textTheme.titleMedium,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: MasiSpacing.xs),
          Text(
            '${topo.summary(nowMs)} · ${topo.ownerLabel}',
            key: Key('admin-abandoned-summary-${topo.wallId}'),
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: colors.ink2),
          ),
          const SizedBox(height: MasiSpacing.xs),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              key: Key('admin-abandoned-open-${topo.wallId}'),
              onPressed: () => context.push('/walls/${topo.wallId}'),
              child: const Text('Open'),
            ),
          ),
        ],
      ),
    );
  }
}

/// Published topos that changed shape after approval (C-5d).
///
/// The two controls are **Open** and **Clear**, and there is deliberately no
/// third. Approval is a one-time gate, so by the time a notice exists the
/// change is already public and was always allowed to be — this surface is a
/// watch list, not a decision. If the change turns out to be vandalism, the
/// actions that carry a consequence already exist on the topo itself (revert,
/// C-8) and in the reports queue (take down, C-7), and routing an admin through
/// looking at the topo before reaching either of them is the right order.
class _MaterialChangesTab extends ConsumerWidget {
  const _MaterialChangesTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = MasiColors.of(context);
    return RefreshIndicator(
      onRefresh: () async => ref.invalidate(materialChangesProvider),
      child: MasiAsyncView<List<MaterialChange>>(
        value: ref.watch(materialChangesProvider),
        errorMessage: "Couldn't load recent changes",
        onRetry: () => ref.invalidate(materialChangesProvider),
        skeleton: (context) => const Center(
          child: Padding(
            padding: EdgeInsets.all(MasiSpacing.xxl),
            child: CircularProgressIndicator(),
          ),
        ),
        data: (context, changes) => changes.isEmpty
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
                          'No published topo has changed shape',
                          key: const Key('admin-changes-empty'),
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(color: colors.ink2),
                        ),
                      ],
                    ),
                  ),
                ],
              )
            : ListView.builder(
                // No SafeArea wraps any of these five tab bodies (the
                // TabBarView sits directly under the AppBar's TabBar), so a
                // standalone iOS PWA (safe-area-inset-bottom = 0) leaves the
                // last row flush on the home indicator with nothing
                // reserving the floor. `masiBottomInset` adds it on top of
                // the existing `MasiSpacing.xxl` breathing room.
                padding: EdgeInsets.only(
                  bottom: MasiSpacing.xxl + masiBottomInset(context, ref),
                ),
                itemCount: changes.length,
                itemBuilder: (context, i) => _ChangeRow(change: changes[i]),
              ),
      ),
    );
  }
}

class _ChangeRow extends ConsumerStatefulWidget {
  const _ChangeRow({required this.change});

  final MaterialChange change;

  @override
  ConsumerState<_ChangeRow> createState() => _ChangeRowState();
}

class _ChangeRowState extends ConsumerState<_ChangeRow> {
  Future<void> _clear() async {
    try {
      await ref
          .read(materialChangeServiceProvider)
          .resolve(widget.change.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cleared')),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Couldn't clear that")),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    final textTheme = Theme.of(context).textTheme;
    final change = widget.change;

    return Container(
      key: Key('admin-change-row-${change.id}'),
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
            change.wallName,
            style: textTheme.titleMedium,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Text(
            change.summary,
            key: Key('admin-change-summary-${change.id}'),
            style: textTheme.bodySmall?.copyWith(color: colors.ink),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Text(
            [
              // Who, and whether it was the owner themselves. Both readings
              // matter: a stranger reshaping someone's topo and an owner
              // quietly replacing their own approved content are different
              // problems, and only one of them is bait-and-switch. Qualified
              // to "last edit by …" once several changes are folded in — see
              // [MaterialChange.actorSentence].
              change.actorSentence,
              if (change.changeCount > 1) '${change.changeCount} edits',
              _waitedFor(change.lastAt),
            ].join(' · '),
            key: Key('admin-change-actor-${change.id}'),
            style: textTheme.bodySmall?.copyWith(color: colors.ink2),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: MasiSpacing.sm),
          Row(
            children: [
              // Looking comes first, as everywhere else in this queue — and
              // here it is the only thing the admin can actually do about the
              // change, so burying it would leave the row with nothing but a
              // dismiss button.
              TextButton(
                key: Key('admin-change-open-${change.id}'),
                onPressed: () => context.push('/walls/${change.wallId}'),
                child: const Text('Open'),
              ),
              const Spacer(),
              MasiPendingButton.text(
                key: Key('admin-change-clear-${change.id}'),
                onPressed: _clear,
                child: const Text('Clear'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Owners asking permission to delete a topo that has been public.
///
/// The number this queue is built around is the ASCENT COUNT. Routes can be
/// re-drawn and a photo can be re-taken; somebody's record of a climb they did
/// cannot, and that is the whole of §3.3. So it is on every row, stated even
/// when it is zero — "no ascents logged" is the fact that makes an approval
/// easy, and omitting it would leave its absence ambiguous.
class _DeletionsTab extends ConsumerWidget {
  const _DeletionsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = MasiColors.of(context);
    return RefreshIndicator(
      onRefresh: () async => ref.invalidate(deletionRequestsProvider),
      child: MasiAsyncView<List<DeletionRequest>>(
        value: ref.watch(deletionRequestsProvider),
        errorMessage: "Couldn't load deletion requests",
        onRetry: () => ref.invalidate(deletionRequestsProvider),
        skeleton: (context) => const Center(
          child: Padding(
            padding: EdgeInsets.all(MasiSpacing.xxl),
            child: CircularProgressIndicator(),
          ),
        ),
        data: (context, requests) => requests.isEmpty
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
                          'Nobody is waiting to delete anything',
                          key: const Key('admin-deletions-empty'),
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(color: colors.ink2),
                        ),
                      ],
                    ),
                  ),
                ],
              )
            : ListView.builder(
                // No SafeArea wraps any of these five tab bodies (the
                // TabBarView sits directly under the AppBar's TabBar), so a
                // standalone iOS PWA (safe-area-inset-bottom = 0) leaves the
                // last row flush on the home indicator with nothing
                // reserving the floor. `masiBottomInset` adds it on top of
                // the existing `MasiSpacing.xxl` breathing room.
                padding: EdgeInsets.only(
                  bottom: MasiSpacing.xxl + masiBottomInset(context, ref),
                ),
                itemCount: requests.length,
                itemBuilder: (context, i) =>
                    _DeletionRow(request: requests[i]),
              ),
      ),
    );
  }
}

class _DeletionRow extends ConsumerStatefulWidget {
  const _DeletionRow({required this.request});

  final DeletionRequest request;

  @override
  ConsumerState<_DeletionRow> createState() => _DeletionRowState();
}

class _DeletionRowState extends ConsumerState<_DeletionRow> {
  /// Approving is the consequential act here, so it asks first — and the sheet
  /// states the ascent count rather than a generic warning, because "11 people
  /// logged climbs on this" is the fact that should change the answer.
  ///
  /// What it does NOT do is delete. The sheet says so out loud: an admin who
  /// believes they are destroying a topo will hesitate over a control that
  /// only grants permission, and an admin who believes the opposite would
  /// approve too freely. Both misreadings are worth one sentence.
  Future<void> _approve() async {
    final request = widget.request;
    final confirmed = await showMasiConfirm(
      context,
      sheetKey: const Key('admin-deletion-approve-confirm'),
      confirmKey: const Key('admin-deletion-approve-yes'),
      cancelKey: const Key('admin-deletion-approve-no'),
      title: 'Let "${request.wallName}" be deleted?',
      message: request.costsOthers
          ? '${request.stakes}. Those ascents belong to other climbers and go '
                'with it. This does not delete anything now — it lets the owner '
                'do it.'
          : '${request.stakes}. This does not delete anything now — it lets '
                'the owner do it.',
      confirmLabel: 'Approve',
      isDestructive: true,
    );
    if (!confirmed || !mounted) return;
    await _review(approve: true);
  }

  /// A reason is REQUIRED to decline, and unlike a report resolution the owner
  /// can read it — `deletion_requests` is readable by its requester. A silent
  /// refusal teaches them nothing and guarantees they ask again.
  Future<void> _decline() async {
    final reason = await showMasiTextPrompt(
      context,
      title: 'Why not?',
      submitLabel: 'Decline',
      placeholder: 'Shown to the owner',
      fieldKey: const Key('admin-deletion-decline-reason-field'),
      submitKey: const Key('admin-deletion-decline-reason-submit'),
    );
    if (reason == null || reason.trim().isEmpty || !mounted) return;
    await _review(approve: false, note: reason.trim());
  }

  Future<void> _review({required bool approve, String? note}) async {
    try {
      await ref
          .read(deletionReviewServiceProvider)
          .review(
            requestId: widget.request.id,
            approve: approve,
            note: note,
          );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            approve
                ? '"${widget.request.wallName}" can now be deleted by its owner'
                : 'Declined — "${widget.request.wallName}" stays',
          ),
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
    final request = widget.request;

    return Container(
      key: Key('admin-deletion-row-${request.id}'),
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
          // Bordered like an urgent report only when other people's climbing
          // records are at stake. A topo nobody has climbed is the owner's
          // alone, and dressing that up as grave would make the border stop
          // meaning anything on the rows where it does.
          color: request.costsOthers ? colors.gradeHard : colors.separator,
          width: request.costsOthers ? 1.5 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            request.wallName,
            style: textTheme.titleMedium,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Text(
            request.stakes,
            key: Key('admin-deletion-stakes-${request.id}'),
            style: textTheme.titleSmall?.copyWith(
              color: request.costsOthers ? colors.gradeHard : colors.ink,
              fontWeight: request.costsOthers ? FontWeight.w700 : null,
            ),
          ),
          if (request.reason != null) ...[
            const SizedBox(height: 2),
            Text(
              request.reason!,
              style: textTheme.bodySmall?.copyWith(color: colors.ink),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          const SizedBox(height: 2),
          Text(
            '${request.requesterLabel} · ${_waitedFor(request.createdAt)}',
            style: textTheme.bodySmall?.copyWith(color: colors.ink2),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: MasiSpacing.sm),
          Row(
            children: [
              // Looking first, as everywhere in this queue — and more so here
              // than anywhere else, because this is the only decision that
              // ends with content gone for good.
              TextButton(
                key: Key('admin-deletion-open-${request.wallId}'),
                onPressed: () => context.push('/walls/${request.wallId}'),
                child: const Text('Open'),
              ),
              const Spacer(),
              TextButton(
                key: Key('admin-deletion-decline-${request.id}'),
                onPressed: _decline,
                child: const Text('Decline'),
              ),
              const SizedBox(width: MasiSpacing.xs),
              // A plain TextButton, not MasiPendingButton: this opens a
              // confirmation sheet first, and a pending button would spin for
              // as long as the admin takes to read it (and hang
              // `pumpAndSettle` in tests). Same reason as `_takeDown`.
              TextButton(
                key: Key('admin-deletion-approve-${request.id}'),
                onPressed: _approve,
                child: Text(
                  'Approve',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            ],
          ),
        ],
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
                // No SafeArea wraps any of these five tab bodies (the
                // TabBarView sits directly under the AppBar's TabBar), so a
                // standalone iOS PWA (safe-area-inset-bottom = 0) leaves the
                // last row flush on the home indicator with nothing
                // reserving the floor. `masiBottomInset` adds it on top of
                // the existing `MasiSpacing.xxl` breathing room.
                padding: EdgeInsets.only(
                  bottom: MasiSpacing.xxl + masiBottomInset(context, ref),
                ),
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
