import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/supabase_providers.dart';
import '../data/reports_remote.dart';
import '../domain/content_report.dart';

/// The cloud seam for reports. Overridden in tests with an in-memory fake —
/// never the real one, which would touch the network.
final reportsRemoteProvider = Provider<ReportsRemote>(
  (ref) => SupabaseReportsRemote(ref.watch(supabaseClientProvider)),
);

/// Open reports awaiting a moderator, unsafe first and then oldest first.
///
/// Deliberately NOT best-effort. An error surfaces as an error, for the same
/// reason `moderationQueueProvider` does: a queue that renders empty because
/// the session expired says "nothing to deal with", which is the opposite of
/// the truth and the one message a moderation surface must never send.
///
/// Rows whose reason this client does not recognise are dropped rather than
/// shown unlabelled — see [ContentReport.fromRow].
final openReportsProvider = FutureProvider.autoDispose<List<ContentReport>>((
  ref,
) async {
  final rows = await ref.watch(reportsRemoteProvider).fetchReports();
  return [for (final row in rows) ?ContentReport.fromRow(row)];
});

/// Filing and closing reports.
class ReportService {
  const ReportService(this._ref);

  final Ref _ref;

  /// Files a report. Errors propagate: there is no outbox behind this
  /// (decision D-4), so a failure means nothing was recorded anywhere, and a
  /// reporter who believes they raised an alarm that never left the device is
  /// worse off than one who was told it failed.
  Future<String> report({
    required String wallId,
    required ReportReason reason,
    String? body,
    String? routeId,
    String? duplicateOfId,
  }) => _ref.read(reportsRemoteProvider).report(
    wallId: wallId,
    reason: reason,
    body: body,
    routeId: routeId,
    duplicateOfId: duplicateOfId,
  );

  /// Closes a report and refreshes the queue.
  Future<String> resolve({
    required String reportId,
    required bool uphold,
    String? note,
  }) async {
    final status = await _ref
        .read(reportsRemoteProvider)
        .resolve(reportId: reportId, uphold: uphold, note: note);
    _ref.invalidate(openReportsProvider);
    return status;
  }
}

final reportServiceProvider = Provider<ReportService>(ReportService.new);
