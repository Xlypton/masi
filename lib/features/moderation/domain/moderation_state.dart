/// The moderation lifecycle of a topo (community editing, phase 1).
///
/// Mirrors the `state` column of the server's `public.wall_moderation`. The
/// server is the authority: this enum exists to render banners and gate
/// client-side affordances, never to decide whether content is visible —
/// that decision lives in Postgres, in `is_wall_public()`, where a client
/// cannot reach it (COMMUNITY_PLAN.md guardrail G-2).
library;

enum ModerationState {
  /// Private to its owner. The default, and the state in which the app
  /// behaves exactly as it always has — none of the community constraints
  /// apply to a topo nobody else can see.
  draft,

  /// Submitted, awaiting review. Visible to its owner and to admins only.
  pending,

  /// Approved and publicly visible.
  published,

  /// Reviewed and turned down. The owner can see the reason and resubmit.
  rejected,

  /// The owner withdrew it after the cooldown elapsed. Content is retained,
  /// not destroyed, so an admin can restore it if the withdrawal turns out
  /// to be vandalism.
  withdrawn,

  /// Taken down by an admin.
  removed;

  /// Parses a raw server string.
  ///
  /// An unrecognised value resolves to [draft] rather than throwing. That
  /// direction is deliberate: [draft] is the LEAST public state, so a client
  /// running against a newer server that has invented a state it does not
  /// understand fails closed — it may under-display a banner, but it can
  /// never present unreviewed content as approved. The reverse default would
  /// turn every future schema addition into a disclosure bug.
  static ModerationState fromWire(String? raw) {
    return switch (raw) {
      'pending' => ModerationState.pending,
      'published' => ModerationState.published,
      'rejected' => ModerationState.rejected,
      'withdrawn' => ModerationState.withdrawn,
      'removed' => ModerationState.removed,
      _ => ModerationState.draft,
    };
  }

  /// The wire value for this state.
  String get wire => name;

  /// Whether this topo is (or is meant to be) publicly visible.
  ///
  /// NOT a visibility decision — the server already made that one and simply
  /// did not send you the row if the answer was no. This only drives UI that
  /// distinguishes "live" from "not live yet".
  bool get isPublic => this == ModerationState.published;

  /// Whether the owner is waiting on somebody else.
  bool get isAwaitingReview => this == ModerationState.pending;
}

/// How long a published topo stays visible after its owner asks to withdraw
/// it (C-3), so people relying on it get warning rather than a topo vanishing
/// from under them.
///
/// The SERVER enforces this, inside `is_wall_public()`'s predicate. This
/// constant exists only to render the countdown, and must stay in step with
/// the `864000000` in
/// `supabase/migrations/2026-08-06_community_phase1_foundations.sql`.
const Duration kWithdrawalCooldown = Duration(days: 10);

/// A topo's moderation status as a reader actually experiences it (community
/// editing phase 5 / C-3).
///
/// This exists because the stored `state` column and the observable truth come
/// apart for exactly one case, on purpose. When a withdrawal's ten days run
/// out the row keeps saying `published` — nothing flips it, because the
/// deadline is evaluated lazily inside `is_wall_public()` rather than by a
/// scheduled job (COMMUNITY_IMPL.md §0.2: no `pg_cron`, no clock drift, no
/// job that can fail silently, and the answer is correct at every instant).
/// The cost of that choice is that the client has to do the same arithmetic
/// to describe the row, and this is the one place it happens.
///
/// [now] is injected rather than read from the clock so the boundary cases —
/// the last hour, the moment of expiry, an already-expired row — are testable
/// without waiting ten days or stubbing time globally.
class ModerationView {
  ModerationView({
    required this.storedState,
    this.withdrawRequestedAt,
    this.rejectionReason,
    required this.now,
  });

  /// The literal `state` column. Prefer [effectiveState] for anything a user
  /// reads; this is here for diagnostics and for the one caller that genuinely
  /// needs to know what the server thinks it stored.
  final ModerationState storedState;

  /// When the owner asked to withdraw, in epoch ms, or null if they have not.
  final int? withdrawRequestedAt;

  final String? rejectionReason;

  final DateTime now;

  /// Builds a view from raw row fields, so callers do not have to depend on
  /// the generated Drift row type to reason about moderation.
  factory ModerationView.fromRow({
    required String? state,
    int? withdrawRequestedAt,
    String? rejectionReason,
    DateTime? now,
  }) => ModerationView(
    storedState: ModerationState.fromWire(state),
    withdrawRequestedAt: withdrawRequestedAt,
    rejectionReason: rejectionReason,
    now: now ?? DateTime.now(),
  );

  /// The instant this topo stops being public, or null when no withdrawal is
  /// running.
  DateTime? get deadline => withdrawRequestedAt == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(
          withdrawRequestedAt!,
        ).add(kWithdrawalCooldown);

  /// Whether the ten days have already run out.
  ///
  /// False when no withdrawal was ever requested — "not withdrawing" is not
  /// the same as "withdrawal complete", and conflating them would report every
  /// healthy published topo as gone.
  bool get hasMatured {
    final at = deadline;
    return at != null && !at.isAfter(now);
  }

  /// A withdrawal is running and has not yet elapsed. This is the state the
  /// countdown banner describes, and the state in which the server refuses to
  /// let the owner unshare or delete.
  bool get isWithdrawing => storedState == ModerationState.published &&
      withdrawRequestedAt != null &&
      !hasMatured;

  /// What to tell the user. A matured withdrawal reads as [withdrawn] even
  /// though the column still says `published`, because that is what everyone
  /// else observes: the topo is out of every public query.
  ModerationState get effectiveState =>
      storedState == ModerationState.published && hasMatured
      ? ModerationState.withdrawn
      : storedState;

  /// Whether the withdrawal cooldown currently protects this topo — i.e.
  /// unsharing or deleting it will be silently reverted by the server, so the
  /// client should offer the withdrawal flow instead of pretending it worked.
  ///
  /// This is the client-side half of the guard and is deliberately the primary
  /// path: the trigger reverts rather than raising (it has to — a raise fails
  /// the whole batched push), and a bounced-back unshare with no explanation
  /// is a terrible way to learn a rule exists.
  bool get isDeleteProtected =>
      storedState == ModerationState.published && !hasMatured;

  /// Whole days left before the topo stops being public, rounded UP, so the
  /// final partial day reads "1 day" rather than "0 days". Null when nothing
  /// is running; 0 only once the deadline has actually passed.
  int? get daysRemaining {
    final at = deadline;
    if (at == null) return null;
    final left = at.difference(now);
    if (left.isNegative || left == Duration.zero) return 0;
    return (left.inMinutes / Duration.minutesPerDay).ceil();
  }
}
