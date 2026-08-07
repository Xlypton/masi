import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/content_report.dart';

/// The cloud seam for reporting (community editing phase 6b / C-7).
///
/// No local mirror, deliberately. Reports are neither read offline nor useful
/// stale: a reporter files one and moves on, and an admin works the queue
/// online. Mirroring them would mean caching other people's private complaints
/// on a device for no benefit.
abstract class ReportsRemote {
  /// Files a report and returns its id.
  ///
  /// Server-side this is rate limited two ways: one open report per person per
  /// topo per reason (a second tap returns the FIRST report's id rather than
  /// erroring, because the outcome the reporter wanted is already true), and
  /// twenty per person per day overall.
  ///
  /// Throws when the topo is not public — you can only report what you can
  /// see — and when the reason is not one the server knows.
  Future<String> report({
    required String wallId,
    required ReportReason reason,
    String? body,
    String? routeId,
  });

  /// Open reports for an admin, unsafe first and then oldest first.
  ///
  /// Throws for a non-admin, deliberately: a moderation queue that renders
  /// empty because the session expired says "nothing to deal with" when the
  /// truth is "we could not ask".
  Future<List<Map<String, dynamic>>> fetchReports({int limit});

  /// Closes a report. `uphold` records whether the complaint was justified —
  /// kept in both directions because phase 8's trust levels need to see
  /// consistently-upheld and consistently-frivolous reporters alike.
  Future<String> resolve({
    required String reportId,
    required bool uphold,
    String? note,
  });
}

class SupabaseReportsRemote implements ReportsRemote {
  SupabaseReportsRemote(this._client);

  final SupabaseClient _client;

  @override
  Future<String> report({
    required String wallId,
    required ReportReason reason,
    String? body,
    String? routeId,
  }) async {
    final result = await _client.rpc<dynamic>(
      'report_content',
      params: {
        'wall_id': wallId,
        'reason': reason.wire,
        'body': body,
        'route_id': routeId,
      },
    );
    return result is String ? result : '';
  }

  @override
  Future<List<Map<String, dynamic>>> fetchReports({int limit = 50}) async {
    final rows = await _client.rpc<dynamic>(
      'moderation_reports',
      params: {'limit_count': limit},
    );
    if (rows is! List) return const [];
    return [for (final row in rows) Map<String, dynamic>.from(row as Map)];
  }

  @override
  Future<String> resolve({
    required String reportId,
    required bool uphold,
    String? note,
  }) async {
    final result = await _client.rpc<dynamic>(
      'resolve_report',
      params: {'report_id': reportId, 'uphold': uphold, 'note': note},
    );
    return result is String ? result : (uphold ? 'upheld' : 'dismissed');
  }
}
