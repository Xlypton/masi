/// A published topo whose owner has stopped answering suggestions (C-11).
///
/// Owner approval of edits is final (C-5c), which is the right default right up
/// until the owner stops opening the app. Then suggestions pile up, nothing is
/// applied, and "the owner approves edits" quietly becomes "nobody can fix
/// this" — over a few years, for a topo the whole community relies on.
///
/// This type is the SIGNAL, not the remedy. It tells an admin where the problem
/// is; transferring ownership or marking a topo community-maintained stays a
/// human decision, because both are irreversible acts against a real person's
/// work and the plan is explicit that they should be rare.
class AbandonedTopo {
  const AbandonedTopo({
    required this.wallId,
    required this.wallName,
    required this.ownerId,
    this.ownerName,
    required this.openSuggestions,
    required this.oldestSuggestionAt,
    this.lastOwnerActivityAt,
  });

  /// Builds one from a raw `abandoned_topos` row, or returns null if the row is
  /// not usable.
  ///
  /// Dropped rather than half-built, matching [ContentReport.fromRow]: an
  /// unlabelled row in an admin surface invites a decision made on no
  /// information, and here the decision on the table is taking someone's topo
  /// away from them.
  static AbandonedTopo? fromRow(Map<String, dynamic> row) {
    final wallId = row['wallId'];
    final ownerId = row['ownerId'];
    final oldest = row['oldestSuggestionAt'];
    if (wallId is! String || wallId.isEmpty) return null;
    if (ownerId is! String || ownerId.isEmpty) return null;
    if (oldest is! int) return null;
    final name = row['wallName'];
    return AbandonedTopo(
      wallId: wallId,
      wallName: name is String && name.trim().isNotEmpty ? name : 'Untitled',
      ownerId: ownerId,
      ownerName: switch (row['ownerName']) {
        final String v when v.trim().isNotEmpty => v,
        _ => null,
      },
      openSuggestions: switch (row['openSuggestions']) {
        final int v => v,
        final num v => v.toInt(),
        _ => 0,
      },
      oldestSuggestionAt: oldest,
      lastOwnerActivityAt: switch (row['lastOwnerActivityAt']) {
        final int v when v > 0 => v,
        final num v when v > 0 => v.toInt(),
        _ => null,
      },
    );
  }

  final String wallId;
  final String wallName;
  final String ownerId;

  /// Null when the owner has no profile row. Rendered as a fallback rather than
  /// as a bare uid — see [ownerLabel].
  final String? ownerName;

  final int openSuggestions;

  /// When the oldest still-pending suggestion arrived. This is the number that
  /// actually says how long the community has been stuck, which is why the
  /// server orders by it rather than by suggestion count.
  final int oldestSuggestionAt;

  /// The last time the owner did anything at all, or null if never.
  final int? lastOwnerActivityAt;

  String get ownerLabel => ownerName ?? 'Unknown owner';

  DateTime get oldestAt =>
      DateTime.fromMillisecondsSinceEpoch(oldestSuggestionAt);

  /// How long the oldest suggestion has been waiting, given [nowMs].
  ///
  /// Takes `now` rather than reading the clock so this stays pure and testable —
  /// the same reason `TopoRank` does.
  Duration waiting(int nowMs) =>
      Duration(milliseconds: (nowMs - oldestSuggestionAt).clamp(0, 1 << 62));

  /// "3 suggestions waiting 14 months" — the sentence an admin actually needs,
  /// assembled once here rather than in the widget, so the queue and any future
  /// surface cannot describe the same row differently.
  String summary(int nowMs) {
    final days = waiting(nowMs).inDays;
    final period = switch (days) {
      < 1 => 'today',
      < 60 => '$days days',
      < 730 => '${(days / 30).round()} months',
      _ => '${(days / 365).round()} years',
    };
    final count = openSuggestions == 1
        ? '1 suggestion'
        : '$openSuggestions suggestions';
    return days < 1 ? '$count, opened today' : '$count waiting $period';
  }
}
