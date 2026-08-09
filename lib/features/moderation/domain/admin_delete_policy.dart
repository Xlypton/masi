/// Who may delete what, as a pure function.
///
/// Import-free on purpose, exactly like [PublicPhotoPruner] next door: the rule
/// deciding whether one person may destroy another person's work should be
/// readable and testable without a `ProviderContainer`, a Supabase client or a
/// widget tree anywhere near it.
///
/// **This is a UI decision, never an authorisation one.** Every answer here is
/// re-derived server-side by `admin_delete_topo` / `admin_delete_ascent` /
/// `admin_delete_comment`, each of which raises `42501` unless `is_admin()`
/// passes. A client that lies to itself — a patched bundle, a stale
/// `isAdminProvider`, a hand-crafted RPC call — gains exactly nothing. What
/// this file decides is whether a CONTROL is drawn, and the cost of getting it
/// wrong is a button that errors, not a topo that dies.
library;

/// What an admin control should offer for one piece of content.
enum AdminContentAction {
  /// Draw nothing. The viewer is not an admin, or there is no useful admin
  /// action for this item in this state.
  hidden,

  /// Offer to soft-delete it.
  delete,

  /// Offer to put back what an earlier admin delete took.
  restore,
}

/// The admin control for one piece of content, or [AdminContentAction.hidden].
///
/// [isAdmin] is `isAdminProvider`'s resolved value, which is `false` while the
/// lookup is still in flight and `false` on any error — the admin surface fails
/// closed by construction, so a slow network shows an ordinary user's screen
/// rather than briefly flashing a delete button at them.
///
/// [isSignedIn] is checked SEPARATELY rather than folded into [isAdmin], even
/// though `isAdminProvider` already short-circuits to `false` without a uid.
/// Two independent reasons to hide the control is the right number for a
/// destructive one, and it keeps this function honest when called with a
/// hand-built `isAdmin: true` in a test.
///
/// [isDeleted] flips delete into restore for content that supports it. Only a
/// TOPO does ([isRestorable]): `admin_restore_topo` is scoped by the wall's own
/// `deletedAt` instant, and there is no equivalent for a lone ascent or comment
/// — nor a reason for one, since a deleted comment is not on screen to offer a
/// control from.
///
/// The remaining case — deleted, not restorable — is [AdminContentAction.hidden]
/// rather than a disabled `delete`. Offering "Delete" for something already
/// gone is how an admin taps twice, sees no change, and concludes the feature
/// is broken.
AdminContentAction adminContentAction({
  required bool isAdmin,
  required bool isSignedIn,
  bool isDeleted = false,
  bool isRestorable = false,
}) {
  if (!isSignedIn || !isAdmin) return AdminContentAction.hidden;
  if (isDeleted) {
    return isRestorable ? AdminContentAction.restore : AdminContentAction.hidden;
  }
  return AdminContentAction.delete;
}

/// Whether an admin deleting this item would be destroying SOMEONE ELSE's work.
///
/// Not a permission — an admin may delete their own content through the admin
/// path too, and blocking that would make the control blink out on exactly the
/// topos an admin is most likely to be testing against. It exists so the
/// confirmation can say which kind of act this is: taking down a stranger's
/// topo deserves a differently-worded warning from tidying up your own, and
/// the wording is the only brake between a mis-tap and someone else's data.
///
/// An unknown owner (`ownerId == null` — a legacy row, or one whose owner never
/// synced) counts as foreign. The conservative reading is the safe one here:
/// the louder confirmation is a worse outcome than a silent one only if you
/// value the tap, and we do not.
bool isForeignContent({required String? ownerId, required String? viewerUid}) {
  if (ownerId == null || viewerUid == null) return true;
  return ownerId != viewerUid;
}
