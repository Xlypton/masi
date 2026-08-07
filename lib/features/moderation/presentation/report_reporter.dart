import 'package:flutter/material.dart';

import '../../../shared/presentation/masi_dialogs.dart';
import '../domain/content_report.dart';

/// What [showReportReporter] resolved to.
class ReportDraft {
  const ReportDraft({required this.reason, this.body});

  final ReportReason reason;

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
Future<ReportDraft?> showReportReporter(
  BuildContext context, {
  required String targetLabel,
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
  );

  // `null` means they dismissed the prompt, which abandons the report. An
  // EMPTY string means they submitted without typing, which is allowed —
  // see [ReportDraft.body].
  if (body == null) return null;

  return ReportDraft(
    reason: reason,
    body: body.trim().isEmpty ? null : body.trim(),
  );
}
