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
