import 'package:flutter/material.dart';

import '../../../shared/presentation/masi_dialogs.dart';
import '../domain/content_report.dart';
import '../domain/nearby_topo.dart';

/// What [showReportReporter] resolved to.
class ReportDraft {
  const ReportDraft({required this.reason, this.body, this.duplicateOfId});

  final ReportReason reason;

  /// Which topo this one duplicates, when the reporter picked one from the
  /// nearby list (community editing phase 8b / C-6.4). Always null for every
  /// other reason — the server refuses the combination outright.
  ///
  /// Null on a duplicate report too when they chose "somewhere else" or there
  /// was nothing nearby to offer. That is a real answer, not a failure: a
  /// duplicate 200 m away across a boulder field, or one with no coordinates at
  /// all, still deserves to be reported.
  final String? duplicateOfId;

  /// Optional, unlike a hazard's. A hazard with no description tells a climber
  /// nothing they can act on, so an empty one abandons the report — but
  /// "duplicate" or "not their content" are complete complaints on their own,
  /// and forcing a sentence out of someone would mostly produce "duplicate".
  final String? body;
}

/// Lets anyone signed in report a published topo (community editing phase 6b
/// / C-7).
///
/// Returns `null` if they backed out.
///
/// The order of the reasons is not alphabetical and not arbitrary: **Unsafe
/// first**, because it is the one that is escalated rather than queued (C-12),
/// and because a climber who has just found a spinning bolt should not have to
/// read past five listing-quality categories to say so.
///
/// The sheet says who will see this, which matters more here than anywhere
/// else in the app. A report is a private complaint — the topo's owner cannot
/// read it or learn who filed it — and saying so is what makes people willing
/// to report a topo belonging to somebody they might meet at the crag.
/// [duplicateCandidates] are the published topos near this one, used ONLY if
/// the reporter picks "Duplicate" — see [ReportDraft.duplicateOfId] for why
/// naming one is optional even then. Fetched by the caller rather than here so
/// this stays a plain function with no provider dependency, matching every
/// other sheet in this folder.
Future<ReportDraft?> showReportReporter(
  BuildContext context, {
  required String targetLabel,
  List<NearbyTopo> duplicateCandidates = const [],
}) async {
  final picked = await showMasiActionSheet<String>(
    context,
    sheetKey: const Key('report-reporter-sheet'),
    title: 'Report "$targetLabel"',
    message:
        'Goes to a moderator. The owner is not told who reported it.',
    actions: [
      for (final reason in const [
        ReportReason.unsafe,
        ReportReason.inaccurate,
        ReportReason.access,
        ReportReason.duplicate,
        ReportReason.inappropriate,
        ReportReason.notYours,
      ])
        MasiSheetAction(
          key: Key('report-reason-${reason.wire}'),
          label: reason.label,
          value: reason.wire,
          subtitle: reason.hint,
          isDestructive: reason.isUrgent,
        ),
    ],
  );
  if (picked == null) return null;

  final reason = ReportReason.fromWire(picked);
  // Cannot happen from this sheet, whose values come from the enum itself.
  // Bailing rather than defaulting: guessing a category on a moderation
  // report would put a decision in front of a human under a label nobody
  // chose.
  if (reason == null) return null;

  // "Duplicate of WHAT" — the step that turns this report from research an
  // admin has to do into a decision they can make in one tap (C-6.4). Skipped
  // entirely when there is nothing nearby to offer, rather than showing a sheet
  // whose only option is "somewhere else".
  String? duplicateOfId;
  if (reason == ReportReason.duplicate && duplicateCandidates.isNotEmpty) {
    if (!context.mounted) return null;
    final picked = await showMasiActionSheet<String>(
      context,
      sheetKey: const Key('report-duplicate-target-sheet'),
      title: 'Which one is it the same as?',
      message: 'Nearby topos. Picking one lets a moderator link them.',
      actions: [
        for (final candidate in duplicateCandidates)
          MasiSheetAction(
            key: Key('report-duplicate-target-${candidate.wallId}'),
            label: candidate.name,
            value: candidate.wallId,
            subtitle: '${candidate.distanceLabel} · ${candidate.ownerLabel}',
          ),
        const MasiSheetAction(
          key: Key('report-duplicate-target-other'),
          label: 'Something else',
          value: _kDuplicateTargetOther,
          subtitle: 'Not in this list — say which in the next step',
        ),
      ],
    );
    // Dismissing THIS sheet abandons the report rather than falling through
    // unnamed: the reporter was asked a question and backed out of it, and
    // filing anyway would put a claim in a queue they chose not to make.
    if (picked == null) return null;
    if (picked != _kDuplicateTargetOther) duplicateOfId = picked;
  }

  if (!context.mounted) return null;
  final body = await showMasiTextPrompt(
    context,
    title: 'Anything to add?',
    submitLabel: 'Send report',
    placeholder: reason.isUrgent
        ? 'Bolt 2 spins — do not fall on it'
        : 'Optional, but it helps',
    fieldKey: const Key('report-body-field'),
    submitKey: const Key('report-body-submit'),
    // [ReportDraft.body]'s doc has always said an empty note is allowed —
    // "duplicate" and "not their content" are complete complaints on their own.
    // The prompt was disabling its own submit button on empty text, so that had
    // been false since phase 6b: the app was demanding a sentence and mostly
    // getting the word "duplicate" typed back at it.
    allowEmpty: true,
  );

  // `null` means they dismissed the prompt, which abandons the report. An
  // EMPTY string means they submitted without typing, which is allowed —
  // see [ReportDraft.body].
  if (body == null) return null;

  return ReportDraft(
    reason: reason,
    body: body.trim().isEmpty ? null : body.trim(),
    duplicateOfId: duplicateOfId,
  );
}

/// Sentinel for "not in this list". A wall id can never collide with it —
/// every wall id in this app is a uuid.
const _kDuplicateTargetOther = '__other__';
