-- Community editing, Phase 1: server-side moderation foundations.
--
-- See COMMUNITY_IMPL.md §1 and §3. This migration is BEHAVIOUR-NEUTRAL by
-- design: every currently-shared wall is backfilled to state='published', so
-- nothing that is public today stops being public. The gate exists but starts
-- fully open.
--
-- The load-bearing idea (COMMUNITY_PLAN.md §0): moderation state must NOT live
-- on a synced table. The sync engine re-pushes whole rows with local-wins-ties
-- LWW and no outbox (D-4), so a moderation column on `walls` would be silently
-- reverted by the owner's next push. Hence `wall_moderation`, which the client
-- may read and may never write.
--
-- Idempotent, per this repo's migration convention.

-- ---------------------------------------------------------------------------
-- 1. Authority
-- ---------------------------------------------------------------------------

-- Admin status cannot be a column on `profiles`: that table's owner policy is
-- ALL USING (id = auth.uid()::text), so a user could set their own flag with
-- one PostgREST call. It gets its own table with no client write policy at all
-- (COMMUNITY_PLAN.md G-3).
CREATE TABLE IF NOT EXISTS public.admins (
  "userId"    text PRIMARY KEY NOT NULL,
  role        text NOT NULL DEFAULT 'admin',
  "createdAt" bigint NOT NULL
);

ALTER TABLE public.admins ENABLE ROW LEVEL SECURITY;

-- You may read YOUR OWN row and nobody else's: enough for the client to decide
-- whether to show /admin, without letting anyone enumerate the admin list.
DROP POLICY IF EXISTS admins_self_select ON public.admins;
CREATE POLICY admins_self_select ON public.admins
  FOR SELECT USING ("userId" = (auth.uid())::text);
-- Deliberately NO insert/update/delete policy. With RLS enabled and no
-- permissive policy, every client write is denied. Seeding is a Management API
-- operation.

-- SECURITY DEFINER so other policies can ask "is the caller an admin?" without
-- themselves needing read access to `admins`.
CREATE OR REPLACE FUNCTION public.is_admin() RETURNS boolean
  LANGUAGE sql SECURITY DEFINER STABLE SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.admins WHERE "userId" = (auth.uid())::text
  );
$$;

-- ---------------------------------------------------------------------------
-- 2. Moderation state
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.wall_moderation (
  "wallId"              text PRIMARY KEY NOT NULL
                          REFERENCES public.walls(id) ON DELETE CASCADE,
  state                 text NOT NULL,
  "submittedAt"         bigint,
  "reviewedAt"          bigint,
  "reviewerId"          text,
  "rejectionReason"     text,
  "withdrawRequestedAt" bigint,
  "updatedAt"           bigint NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_wall_moderation_state
  ON public.wall_moderation (state, "wallId");

ALTER TABLE public.wall_moderation ENABLE ROW LEVEL SECURITY;

-- Readable when the topo is public (so any reader can see e.g. a pending
-- withdrawal), by the wall's owner (so they can see their own pending or
-- rejected state and the reason), and by admins.
DROP POLICY IF EXISTS wall_moderation_select ON public.wall_moderation;
CREATE POLICY wall_moderation_select ON public.wall_moderation
  FOR SELECT USING (
    state = 'published'
    OR EXISTS (
      SELECT 1 FROM public.walls w
      WHERE w.id = wall_moderation."wallId"
        AND w."ownerId" = (auth.uid())::text
    )
    OR public.is_admin()
  );
-- No write policy: every mutation goes through a SECURITY DEFINER RPC, so the
-- action and its audit-log entry cannot diverge.

-- ---------------------------------------------------------------------------
-- 3. Audit log
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.moderation_log (
  id           text PRIMARY KEY NOT NULL,
  "actorId"    text NOT NULL,
  action       text NOT NULL,
  "targetType" text NOT NULL,
  "targetId"   text NOT NULL,
  reason       text,
  "createdAt"  bigint NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_moderation_log_target
  ON public.moderation_log ("targetType", "targetId", "createdAt");

ALTER TABLE public.moderation_log ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS moderation_log_admin_select ON public.moderation_log;
CREATE POLICY moderation_log_admin_select ON public.moderation_log
  FOR SELECT USING (public.is_admin());
-- Append-only from the client's perspective: no write policy at all. Admin
-- actions are as auditable as user actions, which matters more, not less,
-- when there is exactly one admin.

-- ---------------------------------------------------------------------------
-- 4. The visibility gate
-- ---------------------------------------------------------------------------

-- The single point at which "only approved topos are visible" is enforced.
--
-- `visibility` keeps its existing meaning (the owner's INTENT); the moderation
-- state is the GATE. Public read requires both, so no existing column changes
-- meaning and no client code becomes silently wrong.
--
-- The 10-day withdrawal window (C-3) is evaluated HERE rather than by a
-- scheduled job that flips state: no pg_cron, no job that can fail silently,
-- and the answer is correct at every instant. 864000000 ms = 10 days.
CREATE OR REPLACE FUNCTION public.is_wall_public(wall text) RETURNS boolean
  LANGUAGE sql SECURITY DEFINER STABLE SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.walls w
    JOIN public.wall_moderation m ON m."wallId" = w.id
    WHERE w.id = wall
      AND w.visibility = 'shared'
      AND w."deletedAt" IS NULL
      AND m.state = 'published'
      AND (
        m."withdrawRequestedAt" IS NULL
        OR m."withdrawRequestedAt"
             > (extract(epoch FROM now()) * 1000)::bigint - 864000000
      )
  );
$$;

-- ---------------------------------------------------------------------------
-- 5. Backfill BEFORE swapping the policies
-- ---------------------------------------------------------------------------
--
-- Order matters: swap the policies first and every currently-shared wall would
-- vanish from the feed for as long as it took this statement to run.
INSERT INTO public.wall_moderation ("wallId", state, "submittedAt", "reviewedAt", "updatedAt")
SELECT
  w.id,
  CASE WHEN w.visibility = 'shared' THEN 'published' ELSE 'draft' END,
  CASE WHEN w.visibility = 'shared' THEN w."createdAt" END,
  CASE WHEN w.visibility = 'shared' THEN w."createdAt" END,
  (extract(epoch FROM now()) * 1000)::bigint
FROM public.walls w
ON CONFLICT ("wallId") DO NOTHING;

-- ---------------------------------------------------------------------------
-- 6. Swap every shared-read policy onto the gate
-- ---------------------------------------------------------------------------

DROP POLICY IF EXISTS walls_shared_select ON public.walls;
CREATE POLICY walls_shared_select ON public.walls
  FOR SELECT USING (public.is_wall_public(id));

DROP POLICY IF EXISTS photos_shared_select ON public.photos;
CREATE POLICY photos_shared_select ON public.photos
  FOR SELECT USING (public.is_wall_public(photos."wallId"));

DROP POLICY IF EXISTS routes_shared_select ON public.routes;
CREATE POLICY routes_shared_select ON public.routes
  FOR SELECT USING (public.is_wall_public(routes."wallId"));

DROP POLICY IF EXISTS comments_shared_select ON public.comments;
CREATE POLICY comments_shared_select ON public.comments
  FOR SELECT USING (
    comments."wallId" IS NOT NULL AND public.is_wall_public(comments."wallId")
  );

DROP POLICY IF EXISTS likes_shared_select ON public.likes;
CREATE POLICY likes_shared_select ON public.likes
  FOR SELECT USING (
    likes."wallId" IS NOT NULL AND public.is_wall_public(likes."wallId")
  );

-- Sectors/Areas have no visibility column of their own; they are readable
-- because they are an ANCESTOR of a public wall. Same derivation as before,
-- with the gate substituted for the bare visibility check.
DROP POLICY IF EXISTS sectors_shared_select ON public.sectors;
CREATE POLICY sectors_shared_select ON public.sectors
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM public.walls w
      WHERE w."sectorId" = sectors.id AND public.is_wall_public(w.id)
    )
  );

DROP POLICY IF EXISTS areas_shared_select ON public.areas;
CREATE POLICY areas_shared_select ON public.areas
  FOR SELECT USING (
    EXISTS (
      SELECT 1
      FROM public.walls w
      JOIN public.sectors s ON w."sectorId" = s.id
      WHERE s."areaId" = areas.id AND public.is_wall_public(w.id)
    )
  );

-- NOTE: the ascent-attached comment/like policies (comments_ascent_shared_select,
-- likes_ascent_shared_select) are deliberately UNTOUCHED. An ascent's own
-- visibility is independent of its wall's — a public ascent on a private topo is
-- a supported state (see sync_remote.dart's fetchSharedAscents doc) — so gating
-- them on wall moderation would silently hide ascent discussion.
