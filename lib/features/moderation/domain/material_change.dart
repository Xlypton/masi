/// A published topo that changed shape after it was approved (C-5d).
///
/// Approval is a one-time gate (C-5c): once a topo is published, the owner —
/// and anyone whose suggestion they accept — can change anything about it
/// forever, with no admin in the loop. That makes the review queue bypassable
/// by the obvious route: submit something clean, get approved, then replace
/// the content.
///
/// This is the plan's cheap middle ground. It BLOCKS NOTHING — publication
/// stays instant and the owner is never interrupted — it just means an admin
/// gets to see that a published topo changed shape. The remedies, if one is
/// needed, already exist and are the ones that carry a consequence: revert
/// (C-8) and take down (C-7). Clearing a notice is only ever "I have looked at
/// this", which is why there is no upheld/dismissed pair like a report has.
class MaterialChange {
  const MaterialChange({
    required this.id,
    required this.wallId,
    required this.wallName,
    this.ownerId,
    this.ownerName,
    this.actorId,
    this.actorName,
    required this.changes,
    required this.changeCount,
    required this.firstAt,
    required this.lastAt,
  });

  /// Builds one from a raw `material_changes` row, or null if it is not usable.
  ///
  /// Dropped rather than half-built, matching [AbandonedTopo.fromRow] and
  /// [ContentReport.fromRow]: an unlabelled row in an admin surface invites a
  /// decision made on no information.
  static MaterialChange? fromRow(Map<String, dynamic> row) {
    final id = row['id'];
    final wallId = row['wallId'];
    final lastAt = row['lastAt'];
    if (id is! String || id.isEmpty) return null;
    if (wallId is! String || wallId.isEmpty) return null;
    if (lastAt is! int) return null;
    final name = row['wallName'];
    return MaterialChange(
      id: id,
      wallId: wallId,
      wallName: name is String && name.trim().isNotEmpty ? name : 'Untitled',
      ownerId: _text(row['ownerId']),
      ownerName: _text(row['ownerName']),
      actorId: _text(row['actorId']),
      actorName: _text(row['actorName']),
      changes: switch (row['changesJson']) {
        final Map<String, dynamic> v => Map.unmodifiable(v),
        final Map<dynamic, dynamic> v => Map.unmodifiable({
          for (final e in v.entries)
            if (e.key case final String k) k: e.value,
        }),
        _ => const {},
      },
      changeCount: switch (row['changeCount']) {
        final int v when v > 0 => v,
        final num v when v > 0 => v.toInt(),
        _ => 1,
      },
      firstAt: switch (row['firstAt']) {
        final int v => v,
        final num v => v.toInt(),
        _ => lastAt,
      },
      lastAt: lastAt,
    );
  }

  static String? _text(Object? value) => switch (value) {
    final String v when v.trim().isNotEmpty => v,
    _ => null,
  };

  final String id;
  final String wallId;
  final String wallName;
  final String? ownerId;
  final String? ownerName;

  /// Who made the most recent change folded into this notice. The version
  /// history is the authority on who did what; this is a starting point, not
  /// an accusation — which is also why an unknown actor renders as a phrase
  /// and never as a bare uid.
  final String? actorId;
  final String? actorName;

  /// `{"routesRemoved": 3, "coverPhotoSwapped": true, …}` — counts summed
  /// across every change merged into this notice, flags left as flags.
  final Map<String, dynamic> changes;

  /// How many separate material changes have been folded in. At most one open
  /// notice exists per topo, so a vandal making fifty edits produces one row
  /// with a large count rather than fifty rows.
  final int changeCount;

  final int firstAt;
  final int lastAt;

  String get actorLabel => actorName ?? 'Someone';
  String get ownerLabel => ownerName ?? 'Unknown owner';

  /// The owner changing their own topo is the bait-and-switch case, so it is
  /// not filtered out — but it reads very differently from a stranger doing
  /// it, and an admin should be able to tell at a glance.
  bool get byOwner => actorId != null && actorId == ownerId;

  /// Who to name, qualified honestly when several edits are folded together.
  ///
  /// Only the LAST actor is stored, so a notice covering more than one change
  /// cannot claim one person made them all. That matters in the case this
  /// feature exists for: a stranger reshapes a topo and the owner then touches
  /// it, and an unqualified "the owner" would invite an admin to dismiss the
  /// row without looking. "last edit by the owner" makes no claim about the
  /// earlier ones, and the version history is where the full answer lives.
  String get actorSentence {
    final who = byOwner ? 'the owner' : actorLabel;
    return changeCount > 1 ? 'last edit by $who' : who;
  }

  /// One phrase per kind of change, in a fixed order rather than the map's.
  ///
  /// Removals come first because they are the only entries describing
  /// something a reader can no longer see.
  List<String> get changeLabels => [
    if (_count('routesRemoved') case final n when n > 0)
      n == 1 ? '1 route removed' : '$n routes removed',
    if (_count('geometryCleared') case final n when n > 0)
      n == 1 ? '1 line cleared' : '$n lines cleared',
    if (_count('routesReanchored') case final n when n > 0)
      n == 1 ? '1 route moved to another photo' : '$n routes moved to another photo',
    if (changes['coverPhotoSwapped'] == true) 'cover photo swapped',
    if (changes['coverPhotoReplaced'] == true) 'cover image replaced',
  ];

  /// The sentence shown in the queue.
  ///
  /// Falls back to a generic phrase when the server reports a kind this build
  /// does not know about. A notice that renders as an empty string would be a
  /// row an admin cannot act on and cannot dismiss with confidence — and since
  /// the server is deployed independently of the app, a newer kind reaching an
  /// older client is a matter of time, not a hypothetical.
  String get summary {
    final labels = changeLabels;
    if (labels.isEmpty) return 'Changed structurally';
    final sentence = labels.join(', ');
    return sentence[0].toUpperCase() + sentence.substring(1);
  }

  int _count(String key) => switch (changes[key]) {
    final int v => v,
    final num v => v.toInt(),
    _ => 0,
  };
}
