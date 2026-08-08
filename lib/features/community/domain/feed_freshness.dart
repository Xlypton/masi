/// One feed entry reduced to the only two things "is there anything new"
/// needs to know: when it entered the feed, and whose it is.
typedef FeedArrival = ({int at, String? ownerId});

/// The most recent moment SOMEBODY ELSE put something in the feed, or `null`
/// if nobody has.
///
/// **Own items are excluded, and that is the point.** Publishing a topo or
/// sharing an ascent is the user's own action, performed seconds ago in this
/// app; dotting the Feed tab to tell them about it would be telling them
/// something they already know, and it would fire on the single most common
/// path through the feature. `ownerId == null` (a row that predates ownership
/// tracking, or one created signed-out) counts as foreign — it cannot be
/// proven to be theirs, and a spurious dot is a far cheaper mistake here than
/// a missing one.
int? newestForeignArrival(Iterable<FeedArrival> arrivals, String? myUid) {
  int? newest;
  for (final arrival in arrivals) {
    if (myUid != null && arrival.ownerId == myUid) continue;
    if (newest == null || arrival.at > newest) newest = arrival.at;
  }
  return newest;
}

/// Whether the Feed tab should carry an unseen dot.
///
/// [lastSeenAt] is `null` the first time this device ever renders the shell,
/// and that case deliberately resolves to **no dot**: a brand-new install has
/// an entire feed of things it has never seen, and greeting someone with a dot
/// that means "everything is new" tells them nothing and trains them to ignore
/// it. The first visit to the Feed stamps a baseline, and everything after
/// that is a real "since you last looked".
///
/// Strictly greater than, not `>=`: the moment the Feed is opened the baseline
/// is stamped to `now`, and an item that arrived in that same millisecond must
/// not immediately re-dot the tab the user is looking at.
bool feedHasUnseen({required int? newestForeignAt, required int? lastSeenAt}) {
  if (newestForeignAt == null) return false;
  if (lastSeenAt == null) return false;
  return newestForeignAt > lastSeenAt;
}
