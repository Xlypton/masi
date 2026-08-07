-- C-11: abandoned topos.
--
-- An owner who stops using the app freezes their topos forever. Suggestions
-- pile up, nothing is applied, and the community cannot fix an error everyone
-- can see — because owner approval is final (C-5c). Over a few years "the owner
-- approves edits" degrades into "nobody can fix this."
--
-- This migration adds the SIGNAL only: a read that tells admins which published
-- topos have suggestions nobody is answering. It deliberately does NOT transfer
-- ownership or mark anything community-maintained. Those are irreversible acts
-- against a real person's work, and the plan is explicit that they are rare; an
-- admin should be looking at a list and deciding, not having a threshold decide
-- for them.
--
-- WHAT COUNTS AS ABANDONED, and why each part is there:
--   * the topo is PUBLISHED — a private topo nobody can suggest edits to cannot
--     be blocking anyone;
--   * it has at least one PENDING suggestion older than `inactive_days`;
--   * and the owner has done nothing since that suggestion arrived — neither
--     resolving any suggestion nor touching any of their own walls.
--
-- The last clause is what stops the list filling with false positives. Without
-- it, an active owner who simply disagrees with one suggestion and leaves it
-- open looks identical to someone who deleted the app. Disagreement is not
-- abandonment, and an admin surface that cannot tell them apart is one that
-- gets ignored.

DROP FUNCTION IF EXISTS public.abandoned_topos(int, int);

CREATE OR REPLACE FUNCTION public.abandoned_topos(
  inactive_days int DEFAULT 90,
  limit_count   int DEFAULT 50
)
RETURNS TABLE (
  "wallId"              text,
  "wallName"            text,
  "ownerId"             text,
  "ownerName"           text,
  "openSuggestions"     bigint,
  "oldestSuggestionAt"  bigint,
  "lastOwnerActivityAt" bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  now_ms    bigint := (extract(epoch FROM now()) * 1000)::bigint;
  cutoff_ms bigint;
BEGIN
  IF (auth.uid()) IS NULL OR NOT public.is_admin() THEN
    RAISE EXCEPTION 'not authorised' USING ERRCODE = '42501';
  END IF;

  -- Clamped rather than trusted: a caller passing 0 would report every topo
  -- with any open suggestion as abandoned, and a negative value would put the
  -- cutoff in the future and report ALL of them.
  inactive_days := greatest(1, least(coalesce(inactive_days, 90), 3650));
  limit_count   := greatest(1, least(coalesce(limit_count, 50), 200));
  cutoff_ms     := now_ms - (inactive_days::bigint * 86400000);

  RETURN QUERY
  WITH pending AS (
    SELECT s."wallId"                AS wall_id,
           count(*)                  AS open_count,
           min(s."createdAt")        AS oldest_at
      FROM public.topo_edit_suggestions s
     WHERE s.status = 'pending'
     GROUP BY s."wallId"
    HAVING min(s."createdAt") < cutoff_ms
  ),
  owner_activity AS (
    -- The most recent thing this owner did anywhere: resolved a suggestion on
    -- one of their topos, or edited any wall of their own. Either proves they
    -- are still around, which is the whole question.
    SELECT w."ownerId" AS owner_id,
           greatest(
             coalesce(max(w."updatedAt"), 0),
             coalesce((
               SELECT max(s2."resolvedAt")
                 FROM public.topo_edit_suggestions s2
                 JOIN public.walls w2 ON w2.id = s2."wallId"
                WHERE w2."ownerId" = w."ownerId" AND s2."resolvedAt" IS NOT NULL
             ), 0)
           ) AS last_at
      FROM public.walls w
     WHERE w."ownerId" IS NOT NULL
     GROUP BY w."ownerId"
  )
  SELECT w.id,
         w.name,
         w."ownerId",
         p."displayName",
         pend.open_count,
         pend.oldest_at,
         act.last_at
    FROM pending pend
    JOIN public.walls w  ON w.id = pend.wall_id
    JOIN public.wall_moderation m ON m."wallId" = w.id
    LEFT JOIN public.profiles p   ON p.id = w."ownerId"
    LEFT JOIN owner_activity act  ON act.owner_id = w."ownerId"
   WHERE m.state = 'published'
     AND w."deletedAt" IS NULL
     -- Nothing from the owner since the suggestion landed. A null activity
     -- timestamp (an owner with no walls at all, which should not happen) is
     -- treated as "no activity", i.e. abandoned — the row is worth an admin's
     -- eyes either way.
     AND coalesce(act.last_at, 0) < pend.oldest_at
   ORDER BY pend.oldest_at ASC
   LIMIT limit_count;
END;
$$;

REVOKE ALL ON FUNCTION public.abandoned_topos(int, int) FROM public;
GRANT EXECUTE ON FUNCTION public.abandoned_topos(int, int) TO authenticated;
