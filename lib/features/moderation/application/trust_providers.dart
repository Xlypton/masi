import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/supabase_providers.dart';
import '../../account/application/auth_providers.dart';

/// How much of the review queue an account is allowed to skip (community
/// editing phase 8a / C-4).
///
/// Two levels, not six. Every platform that runs a real ladder has a community
/// large enough to need the granularity; this one has five distinct owners,
/// and a ladder nobody climbs only hides how the thing actually works.
class TrustStanding {
  const TrustStanding({
    required this.level,
    required this.approved,
    required this.needed,
    required this.blocked,
  });

  /// 0 — everything goes to the queue. 1 — submissions publish immediately.
  final int level;

  /// Topos of theirs a moderator has actually approved.
  ///
  /// Counts only submissions with a real reviewer. Topos that were published
  /// by the phase 1 backfill carry a review TIMESTAMP that no moderator ever
  /// produced, so counting those would have handed instant trust to every
  /// account that existed before the queue did.
  final int approved;

  /// How many are needed for the next level.
  final int needed;

  /// Whether an upheld report is holding them at 0 regardless of count.
  final bool blocked;

  bool get isTrusted => level >= 1;

  /// The unknown standing: what every caller sees before the answer arrives,
  /// and what a signed-out or offline reader keeps seeing.
  ///
  /// Level 0 — fail closed. Guessing "trusted" while loading would let the
  /// submit sheet promise instant publication to somebody whose topo is about
  /// to sit in a queue, and being wrong in that direction is the one that
  /// makes a person think the app is broken.
  static const TrustStanding unknown = TrustStanding(
    level: 0,
    approved: 0,
    needed: 3,
    blocked: false,
  );

  factory TrustStanding.fromRow(Map<String, dynamic> row) => TrustStanding(
    level: _asInt(row['level']) ?? 0,
    approved: _asInt(row['approved']) ?? 0,
    needed: _asInt(row['needed']) ?? 3,
    blocked: row['blocked'] == true,
  );

  static int? _asInt(Object? value) => switch (value) {
    final int v => v,
    final num v => v.toInt(),
    final String v => int.tryParse(v),
    _ => null,
  };
}

/// The signed-in user's own standing.
///
/// Their own only — `my_trust()` reads `auth.uid()` and there is deliberately
/// no way to ask about anybody else. Trust is a moderation input, not a public
/// score, and a leaderboard is the fastest route to people gaming it.
///
/// Best-effort: any failure resolves to [TrustStanding.unknown] rather than
/// erroring. This decorates a settings screen and adjusts one confirmation's
/// wording; neither is worth an error dialog, and both are correct when the
/// answer is "assume nothing".
final myTrustProvider = FutureProvider.autoDispose<TrustStanding>((ref) async {
  final uid = ref.watch(effectiveUidProvider);
  if (uid == null) return TrustStanding.unknown;
  try {
    final client = ref.watch(supabaseClientProvider);
    final rows = await client.rpc<dynamic>('my_trust');
    if (rows is! List || rows.isEmpty) return TrustStanding.unknown;
    return TrustStanding.fromRow(Map<String, dynamic>.from(rows.first as Map));
  } catch (_) {
    return TrustStanding.unknown;
  }
});
