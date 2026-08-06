-- Community editing, Phase 1b: keep `wall_moderation` populated for walls
-- created or shared AFTER the Phase 1 backfill ran.
--
-- Phase 1's backfill was a one-shot INSERT ... SELECT over the walls that
-- existed at that moment. Without this trigger, every wall created afterwards
-- has NO wall_moderation row, `is_wall_public()` returns false for it forever,
-- and publishing silently stops working for all new topos. The bug would look
-- like "sharing does nothing", with no error anywhere.
--
-- IMPORTANT — this trigger is a deliberately TEMPORARY bridge.
--
-- Phase 1 is specified as behaviour-neutral (COMMUNITY_IMPL.md §3): the gate
-- exists but starts fully open, so the enforcement layer can be proven in
-- isolation before any review workflow exists. That is why a wall shared by
-- its owner is auto-published here.
--
-- PHASE 3 MUST CHANGE THIS. Once `submit_topo`/`review_topo` exist, a wall
-- going visibility='shared' must land in 'pending', not 'published', or the
-- review queue is decorative — an owner could publish unreviewed content by
-- writing the column directly, exactly as they can today. This function is
-- the single place that changes.

CREATE OR REPLACE FUNCTION public.ensure_wall_moderation() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  INSERT INTO public.wall_moderation ("wallId", state, "submittedAt", "reviewedAt", "updatedAt")
  VALUES (
    NEW.id,
    -- PHASE 3: replace 'published' with 'pending' here.
    CASE WHEN NEW.visibility = 'shared' THEN 'published' ELSE 'draft' END,
    CASE WHEN NEW.visibility = 'shared' THEN (extract(epoch FROM now()) * 1000)::bigint END,
    CASE WHEN NEW.visibility = 'shared' THEN (extract(epoch FROM now()) * 1000)::bigint END,
    (extract(epoch FROM now()) * 1000)::bigint
  )
  ON CONFLICT ("wallId") DO UPDATE
    -- Only ever promotes a draft that has just been shared. Never touches a
    -- row that is already published/pending/rejected/withdrawn/removed, so a
    -- moderator's decision cannot be undone by an owner toggling `visibility`
    -- — which is the whole reason moderation state does not live on `walls`.
    SET state         = 'published',
        "submittedAt" = COALESCE(public.wall_moderation."submittedAt",
                                 (extract(epoch FROM now()) * 1000)::bigint),
        "reviewedAt"  = COALESCE(public.wall_moderation."reviewedAt",
                                 (extract(epoch FROM now()) * 1000)::bigint),
        "updatedAt"   = (extract(epoch FROM now()) * 1000)::bigint
    WHERE public.wall_moderation.state = 'draft'
      AND NEW.visibility = 'shared';
  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_ensure_wall_moderation ON public.walls;
CREATE TRIGGER trg_ensure_wall_moderation
  AFTER INSERT OR UPDATE OF visibility ON public.walls
  FOR EACH ROW EXECUTE FUNCTION public.ensure_wall_moderation();

-- Catch anything created between the Phase 1 backfill and this trigger.
INSERT INTO public.wall_moderation ("wallId", state, "submittedAt", "reviewedAt", "updatedAt")
SELECT
  w.id,
  CASE WHEN w.visibility = 'shared' THEN 'published' ELSE 'draft' END,
  CASE WHEN w.visibility = 'shared' THEN w."createdAt" END,
  CASE WHEN w.visibility = 'shared' THEN w."createdAt" END,
  (extract(epoch FROM now()) * 1000)::bigint
FROM public.walls w
ON CONFLICT ("wallId") DO NOTHING;
