-- Community editing, Phase 3: submission and admin review.
--
-- Phase 1 built the gate and deliberately left it open, so the enforcement
-- layer could be proven with behaviour unchanged. This closes it.
--
-- THE CENTRAL CHANGE is in `ensure_wall_moderation()`: a wall going
-- visibility='shared' now lands in 'pending', not 'published'. Until this
-- runs, an owner could publish unreviewed content simply by writing the
-- column directly, and the review queue was decorative.
--
-- Idempotent, per this repo's migration convention.

-- ---------------------------------------------------------------------------
-- 1. Sharing now means SUBMITTING, not publishing
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.ensure_wall_moderation() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  INSERT INTO public.wall_moderation ("wallId", state, "submittedAt", "updatedAt")
  VALUES (
    NEW.id,
    CASE WHEN NEW.visibility = 'shared' THEN 'pending' ELSE 'draft' END,
    CASE WHEN NEW.visibility = 'shared' THEN (extract(epoch FROM now()) * 1000)::bigint END,
    (extract(epoch FROM now()) * 1000)::bigint
  )
  ON CONFLICT ("wallId") DO UPDATE
    -- Still only ever promotes a row sitting in 'draft'. A published,
    -- rejected, withdrawn or removed topo keeps its state, so an owner
    -- toggling `visibility` can neither undo a moderator's decision nor
    -- re-enter the queue behind their back.
    SET state         = 'pending',
        "submittedAt" = (extract(epoch FROM now()) * 1000)::bigint,
        "updatedAt"   = (extract(epoch FROM now()) * 1000)::bigint
    WHERE public.wall_moderation.state = 'draft'
      AND NEW.visibility = 'shared';
  RETURN NULL;
END;
$$;

-- ---------------------------------------------------------------------------
-- 2. Review RPCs
-- ---------------------------------------------------------------------------
--
-- SECURITY DEFINER, each re-checking authority server-side rather than
-- trusting that the client only offered the button to the right person. Each
-- writes its own `moderation_log` row in the SAME statement it performs, so
-- an action and its audit entry cannot diverge.

-- Approve or reject a pending submission. Admins only.
CREATE OR REPLACE FUNCTION public.review_topo(
  wall_id text,
  approve boolean,
  reason  text DEFAULT NULL
) RETURNS text
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  now_ms    bigint := (extract(epoch FROM now()) * 1000)::bigint;
  actor     text   := (auth.uid())::text;
  new_state text;
BEGIN
  IF actor IS NULL OR NOT public.is_admin() THEN
    RAISE EXCEPTION 'not authorised' USING ERRCODE = '42501';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.wall_moderation WHERE "wallId" = wall_id) THEN
    RAISE EXCEPTION 'unknown wall %', wall_id USING ERRCODE = 'P0002';
  END IF;

  new_state := CASE WHEN approve THEN 'published' ELSE 'rejected' END;

  UPDATE public.wall_moderation
     SET state             = new_state,
         "reviewedAt"      = now_ms,
         "reviewerId"      = actor,
         -- Cleared on approval: a stale reason from an earlier rejection
         -- must not sit on a topo that has since been accepted.
         "rejectionReason" = CASE WHEN approve THEN NULL ELSE reason END,
         "updatedAt"       = now_ms
   WHERE "wallId" = wall_id;

  INSERT INTO public.moderation_log (id, "actorId", action, "targetType", "targetId", reason, "createdAt")
  VALUES (gen_random_uuid()::text, actor,
          CASE WHEN approve THEN 'approve' ELSE 'reject' END,
          'wall', wall_id, reason, now_ms);

  RETURN new_state;
END;
$$;

-- Take down an already-published topo. Admins only. Content is RETAINED
-- (COMMUNITY_PLAN.md §3.3 — merge or withdraw, never destroy), so this is
-- reversible by a later `review_topo(..., approve => true)`.
CREATE OR REPLACE FUNCTION public.remove_topo(wall_id text, reason text DEFAULT NULL)
  RETURNS void
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  now_ms bigint := (extract(epoch FROM now()) * 1000)::bigint;
  actor  text   := (auth.uid())::text;
BEGIN
  IF actor IS NULL OR NOT public.is_admin() THEN
    RAISE EXCEPTION 'not authorised' USING ERRCODE = '42501';
  END IF;

  UPDATE public.wall_moderation
     SET state = 'removed', "reviewedAt" = now_ms, "reviewerId" = actor,
         "rejectionReason" = reason, "updatedAt" = now_ms
   WHERE "wallId" = wall_id;

  INSERT INTO public.moderation_log (id, "actorId", action, "targetType", "targetId", reason, "createdAt")
  VALUES (gen_random_uuid()::text, actor, 'remove', 'wall', wall_id, reason, now_ms);
END;
$$;

-- The admin review queue: pending submissions, oldest first.
--
-- A SECURITY DEFINER function rather than a view, so the admin check is
-- inside it. It joins `walls` deliberately — a queue that shows only ids is
-- unreviewable, and RLS on `walls` would otherwise hide a pending topo from
-- the very admin who has to look at it.
CREATE OR REPLACE FUNCTION public.moderation_queue(limit_count int DEFAULT 50)
  RETURNS TABLE (
    "wallId"      text,
    "wallName"    text,
    "ownerId"     text,
    "submittedAt" bigint,
    "routeCount"  bigint,
    "areaName"    text
  )
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'not authorised' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT w.id, w.name, w."ownerId", m."submittedAt",
         (SELECT count(*) FROM public.routes r
            WHERE r."wallId" = w.id AND r."deletedAt" IS NULL),
         a.name
    FROM public.wall_moderation m
    JOIN public.walls w   ON w.id = m."wallId"
    LEFT JOIN public.sectors s ON s.id = w."sectorId"
    LEFT JOIN public.areas   a ON a.id = s."areaId"
   WHERE m.state = 'pending'
     AND w."deletedAt" IS NULL
   ORDER BY m."submittedAt" ASC NULLS LAST
   LIMIT limit_count;
END;
$$;

-- ---------------------------------------------------------------------------
-- 3. Privileges
-- ---------------------------------------------------------------------------
--
-- EXECUTE is granted broadly; each function's own admin check is the gate.
-- Granting narrowly would require a role the anon key does not carry.
GRANT EXECUTE ON FUNCTION public.review_topo(text, boolean, text)  TO authenticated;
GRANT EXECUTE ON FUNCTION public.remove_topo(text, text)           TO authenticated;
GRANT EXECUTE ON FUNCTION public.moderation_queue(int)             TO authenticated;

-- ---------------------------------------------------------------------------
-- 4. Grandfather everything already live
-- ---------------------------------------------------------------------------
--
-- Every topo published before this migration stays published. Retroactively
-- queueing eight already-public topos for review would unpublish them all on
-- deploy, which is precisely the "behaviour-neutral" promise Phase 1 made and
-- this phase must not break. Only NEW submissions go through the queue.
UPDATE public.wall_moderation
   SET state = 'published'
 WHERE state = 'pending'
   AND "reviewedAt" IS NULL;
