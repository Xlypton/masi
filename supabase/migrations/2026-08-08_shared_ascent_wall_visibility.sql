-- A shared ascent must not outlive its topo's visibility.
--
-- `ascents_shared_select` was `visibility = 'shared'` and nothing else, while
-- every ancestor table is gated on `is_wall_public(...)`. So a shared ascent
-- stayed world-readable after its topo was deleted, unpublished, withdrawn,
-- taken down by a moderator, or marked access-sensitive. Two separate defects
-- fall out of that one asymmetry.
--
-- 1. A LEAK PAST A MODERATION DECISION. The ascent row carries `wallId`,
--    `routeId`, `climbedAt`, `style`, `notes` and `gradeOpinion`. Read straight
--    off PostgREST, that is a readable trace of a topo an admin has just taken
--    down, or one whose owner marked it access-sensitive precisely so it would
--    stop being findable. The takedown removed the topo, its routes, its photos
--    and its photo bytes (W-2), and left the ascents pointing at them.
--
-- 2. PERMANENTLY BROKEN SYNC, FOR EVERY USER. The client's `fetchSharedAscents`
--    fetches each shared ascent's ancestor chain so the local FKs
--    (`ascents.routeId -> routes`, `ascents.wallId -> walls`, both NOT NULL and
--    enforced) resolve. Those follow-up queries are subject to the ancestor
--    policies, which correctly refuse a non-public wall — so the ascent arrived
--    with no route and no wall, the import deferred it, and `pullOwnAndShared`
--    reported `shared rows deferred (parent row missing)`. That surfaces as the
--    red "Couldn't sync - Retry" banner on the feed, and it can never heal: the
--    parent is soft-deleted server-side and will never be returned. Observed on
--    live on 2026-08-08 with one real row.
--
-- The fix is to make the ascent obey the same gate as everything else it points
-- at. `is_wall_public` already encodes every case that matters - deleted,
-- private, unpublished, withdrawn past the grace window, or sensitive anywhere
-- up the Wall/Sector/Area chain.
--
-- NOTHING IS LOST TO THE PERSON WHO LOGGED IT. `ascents_owner_all` is a
-- separate, unchanged policy (`"ownerId" = auth.uid()`), so an owner still
-- reads, writes and syncs their own ascents whatever happened to the topo.
-- This narrows only what OTHER people can see, which is what `visibility`
-- was always supposed to mean.
--
-- Measured before applying: 2 shared ascents live, 1 of which points at a wall
-- that is no longer public - so this hides exactly the broken row and nothing
-- else.
--
-- STILL OPEN after this (deliberately not fixed here, it is a product
-- decision): the ascent's OWN owner keeps a dangling row. Their ascent arrives
-- through `fetchOwnRows`, which is owner-scoped and unaffected by this policy,
-- but the foreign route and wall it points at are owned by someone ELSE and
-- were deleted, so that device still cannot satisfy the FK. Fixing that means
-- choosing between logbook continuity (let you read the skeleton of a topo you
-- logged a climb on) and moderation strictness (a takedown must hide the
-- content from everyone, including people who climbed there).

DROP POLICY IF EXISTS ascents_shared_select ON public.ascents;
CREATE POLICY ascents_shared_select
  ON public.ascents
  FOR SELECT TO authenticated
  USING (
    visibility = 'shared'
    AND public.is_wall_public("wallId")
  );
