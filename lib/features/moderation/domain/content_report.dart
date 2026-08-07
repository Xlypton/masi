/// Reporting published content (community editing phase 6b / C-7).
///
/// An approval queue only catches content at submission time. Content goes bad
/// LATER — a route is retro-bolted, a boulder is chipped, access is revoked, a
/// photo turns out to show someone's face — and without a report path the only
/// people who can act are the owner, who may be the problem, and an admin who
/// happens to look.
library;

enum ReportReason {
  /// Wrong grade, wrong line, wrong bolt count, wrong name.
  inaccurate,

  /// **Not just another category.** This is climbing: a missing loose-block
  /// warning or a line drawn past a runout can hurt someone, so an unsafe
  /// report is escalated rather than queued behind twelve duplicate-listing
  /// complaints (C-12). The server sorts it to the front of the admin queue.
  unsafe,

  /// The same crag or boulder already exists elsewhere. Never resolved by
  /// deleting — merged (COMMUNITY_PLAN.md §3.3, and every platform in §3.1
  /// arrived at the same rule).
  duplicate,

  /// The approach is closed, the landowner has withdrawn permission, there is
  /// a nesting restriction. Overlaps deliberately with phase 2's access state:
  /// this is how a reader tells the owner something the owner has not recorded.
  access,

  /// Offensive content, or a photo of someone who did not agree to be in it.
  inappropriate,

  /// Somebody else's topo, uploaded as their own.
  notYours;

  /// The wire value. `notYours` is the one that differs from `name`, because
  /// the server column uses snake_case for it.
  String get wire => this == ReportReason.notYours ? 'not_yours' : name;

  static ReportReason? fromWire(String? raw) => switch (raw) {
    'inaccurate' => ReportReason.inaccurate,
    'unsafe' => ReportReason.unsafe,
    'duplicate' => ReportReason.duplicate,
    'access' => ReportReason.access,
    'inappropriate' => ReportReason.inappropriate,
    'not_yours' => ReportReason.notYours,
    _ => null,
  };

  /// Whether this report jumps the queue.
  bool get isUrgent => this == ReportReason.unsafe;

  String get label => switch (this) {
    ReportReason.inaccurate => 'Inaccurate',
    ReportReason.unsafe => 'Unsafe',
    ReportReason.duplicate => 'Duplicate',
    ReportReason.access => 'Access problem',
    ReportReason.inappropriate => 'Inappropriate',
    ReportReason.notYours => 'Not their content',
  };

  /// What picking this actually means, so the reporter chooses the category a
  /// moderator can act on rather than the one that sounds closest.
  String get hint => switch (this) {
    ReportReason.inaccurate => 'Wrong grade, wrong line, wrong bolt count',
    ReportReason.unsafe =>
      'Loose rock, a bad bolt, a dangerous line — looked at first',
    ReportReason.duplicate => 'This crag is already here under another name',
    ReportReason.access => 'Closed, restricted, or permission withdrawn',
    ReportReason.inappropriate => 'Offensive, or shows someone who did not agree',
    ReportReason.notYours => 'Published by someone who did not make it',
  };
}

/// One open report, as an admin sees it. Readers never see this type — a
/// report is a private complaint, readable only by its author and by admins,
/// and pointedly NOT by the topo's owner (see the RLS note in the phase 6b
/// migration: handing the accused the reporter's identity is how a community
/// learns that reporting invites retaliation).
class ContentReport {
  const ContentReport({
    required this.id,
    required this.wallId,
    required this.wallName,
    required this.reason,
    required this.createdAt,
    this.routeId,
    this.routeName,
    this.reporterId,
    this.reporterName,
    this.body,
  });

  final String id;
  final String wallId;
  final String wallName;
  final ReportReason reason;
  final int createdAt;
  final String? routeId;
  final String? routeName;
  final String? reporterId;
  final String? reporterName;
  final String? body;

  bool get isUrgent => reason.isUrgent;

  DateTime get at => DateTime.fromMillisecondsSinceEpoch(createdAt);

  /// What was reported: a specific route when one was named, otherwise the
  /// topo. An admin who cannot tell which of eleven routes is meant has to
  /// open the topo and guess.
  String get targetLabel =>
      routeName?.trim().isNotEmpty == true ? routeName! : wallName;

  String get reporterLabel => reporterName ?? 'Someone';

  /// Returns null for a row whose reason this client does not understand.
  ///
  /// Skipped rather than shown as "unknown": a report the app cannot describe
  /// is a report an admin cannot act on, and rendering an unlabelled row in a
  /// moderation queue invites a decision made on no information. A newer
  /// server adding a reason is the case this covers, and the right answer is
  /// for the older client to stay quiet about it.
  static ContentReport? fromRow(Map<String, dynamic> row) {
    final reason = ReportReason.fromWire(row['reason'] as String?);
    final id = row['id'] as String?;
    final wallId = row['wallId'] as String?;
    if (reason == null || id == null || wallId == null) return null;
    return ContentReport(
      id: id,
      wallId: wallId,
      wallName: (row['wallName'] as String?)?.trim().isNotEmpty == true
          ? row['wallName'] as String
          : 'Untitled topo',
      reason: reason,
      createdAt: _asInt(row['createdAt']) ?? 0,
      routeId: row['routeId'] as String?,
      routeName: row['routeName'] as String?,
      reporterId: row['reporterId'] as String?,
      reporterName: (row['reporterName'] as String?)?.trim().isNotEmpty == true
          ? row['reporterName'] as String
          : null,
      body: (row['body'] as String?)?.trim().isNotEmpty == true
          ? row['body'] as String
          : null,
    );
  }

  static int? _asInt(Object? value) => switch (value) {
    final int v => v,
    final num v => v.toInt(),
    final String v => int.tryParse(v),
    _ => null,
  };
}
