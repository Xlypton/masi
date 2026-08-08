-- C-5d: material-change notices.
--
-- Approval is a ONE-TIME gate (C-5c). Once a topo is published, the owner - and
-- anyone whose suggestion the owner accepts - can change anything about it,
-- forever, with no admin in the loop. That means the review queue is fully
-- bypassable by the obvious route: submit something clean, get approved, then
-- replace the content.
--
-- This is the plan's cheap middle ground (COMMUNITY_PLAN.md, C-5d): a change to
-- a published topo that is STRUCTURAL posts a notice to the admin queue and
-- BLOCKS NOTHING. Publication stays instant, the owner is not interrupted, and
-- an admin simply gets to see that a published topo changed shape. It is a row
-- insert, not a workflow.
--
-- WHAT COUNTS AS MATERIAL, and why the list stops where it does:
--   * routes removed        - a route a reader could see is gone
--   * geometry cleared      - a route's line was emptied, not adjusted
--   * routes re-anchored    - a route's lines moved to a different photo
--   * cover photo swapped   - a different photo is now the one people see
--   * cover photo replaced  - the SAME photo row now points at different bytes
--
-- Everything else is deliberately excluded, because the failure mode of this
-- feature is not "we missed one", it is "the queue filled with normal editing
-- and admins stopped reading it". Renames, grade corrections, descriptions,
-- adding routes, and nudging an existing line are all ordinary work on a topo
-- somebody owns. Moving the wall's coordinates is arguably material and is
-- still left out for the first version: GPS refinement is a common, legitimate
-- correction, and there is no threshold that separates it from vandalism
-- without guessing.
--
-- Note what the last two entries catch that a route-count check cannot. The
-- purest bait-and-switch keeps every route, every name and every grade, and
-- changes only the image underneath. `coverPhotoReplaced` is that case.
--
-- TWO THINGS THIS MUST NEVER DO, in order of importance:
--
--  1. Fail a user's write. The detector is called from `snapshot_topo`, which
--     runs inside AFTER triggers on every sync push. It is wrapped in an
--     exception block there, so a bug here degrades to "no notice", never to
--     "the climber's edits would not save".
--  2. Flood. A vandal making fifty edits is exactly the scenario this exists
--     for, and fifty rows in the queue would be worse than one. At most ONE
--     unresolved notice exists per wall (enforced by a partial unique index);
--     further material changes merge into it, summing the counts and bumping
--     `lastAt`.
--
-- KNOWN, ACCEPTED: an admin revert can itself post a notice. `revert_topo`
-- soft-deletes routes the vandal added, which is a genuine route removal, and
-- the trigger cannot tell it apart from any other write. Suppressing it would
-- mean rewriting `revert_topo` to set a transaction-local flag, and that whole
-- function would have to be re-applied to do it - a worse risk than one
-- redundant row that merges into the wall's existing open notice, names the
-- admin as the actor, and is dismissed in one tap.
--
-- ALSO BY DESIGN: a topo taken down and later re-published compares against the
-- version from before the takedown, so changes made while it was out of public
-- view all surface at once. That is the correct answer to "this came back
-- looking different", not a bug.

-- ---------------------------------------------------------------------------
-- 1. The table
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.material_change_notices (
  id            text PRIMARY KEY,
  "wallId"      text NOT NULL,
  -- The actor of the MOST RECENT material change folded into this notice. The
  -- version history is the authority on who did what; this is a starting
  -- point, not an accusation.
  "actorId"     text,
  -- {"routesRemoved": 3, "coverPhotoSwapped": true, ...}. Counts are summed
  -- across merged changes; flags stay flags.
  "changesJson" jsonb  NOT NULL DEFAULT '{}'::jsonb,
  "changeCount" int    NOT NULL DEFAULT 1,
  "firstAt"     bigint NOT NULL,
  "lastAt"      bigint NOT NULL,
  "resolvedAt"  bigint,
  "resolvedBy"  text
);

-- At most one OPEN notice per wall. This is the anti-flood guarantee, and it is
-- an index rather than application logic so a concurrent pair of writes cannot
-- both find "no open notice" and both insert.
CREATE UNIQUE INDEX IF NOT EXISTS material_change_notices_open_wall
  ON public.material_change_notices ("wallId")
  WHERE "resolvedAt" IS NULL;

CREATE INDEX IF NOT EXISTS material_change_notices_last_at
  ON public.material_change_notices ("lastAt" DESC);

ALTER TABLE public.material_change_notices ENABLE ROW LEVEL SECURITY;

-- Admins only, and no write policy at all - every write goes through a
-- SECURITY DEFINER function so the notice and its audit-log entry cannot
-- diverge. Owners deliberately cannot read this: a notice is a moderator's
-- working note about a change that has already been allowed to happen, and
-- showing it to the person who made the change turns "we keep an eye on this"
-- into "you are under suspicion".
DROP POLICY IF EXISTS material_change_notices_admin_read
  ON public.material_change_notices;
CREATE POLICY material_change_notices_admin_read
  ON public.material_change_notices
  FOR SELECT TO authenticated
  USING (public.is_admin());

GRANT SELECT ON public.material_change_notices TO authenticated;

-- ---------------------------------------------------------------------------
-- 2. The detector (pure)
-- ---------------------------------------------------------------------------
--
-- Pure and IMMUTABLE so it can be tested by calling it with two literals, with
-- no wall, no trigger and no transaction to set up. Returns '{}' when nothing
-- material happened, which is the overwhelmingly common answer.
--
-- Both snapshots INCLUDE tombstones - `topo_snapshot` projects `deletedAt`
-- rather than filtering on it - so every comparison here filters to live rows
-- first. Missing that is not a small bug: a soft-deleted route keeps the array
-- length identical, so a route-count comparison would report no change for the
-- single most important case this function exists to catch.
CREATE OR REPLACE FUNCTION public.material_change_kinds(prev jsonb, next jsonb)
  RETURNS jsonb
  LANGUAGE sql IMMUTABLE AS $$
  WITH pr AS (
    SELECT e->>'id' AS id, e->>'photoId' AS photo_id, e->>'pointsJson' AS points
      FROM jsonb_array_elements(COALESCE(prev->'routes', '[]'::jsonb)) e
     WHERE e->>'deletedAt' IS NULL
  ),
  nx AS (
    SELECT e->>'id' AS id, e->>'photoId' AS photo_id, e->>'pointsJson' AS points
      FROM jsonb_array_elements(COALESCE(next->'routes', '[]'::jsonb)) e
     WHERE e->>'deletedAt' IS NULL
  ),
  -- The photo a reader actually sees: the primary one, or failing that the
  -- first by sort order. Derived the same way on both sides, so a topo that
  -- never marked a primary still gets a meaningful comparison.
  pcover AS (
    SELECT e->>'id' AS id, e->>'localPath' AS path
      FROM jsonb_array_elements(COALESCE(prev->'photos', '[]'::jsonb)) e
     WHERE e->>'deletedAt' IS NULL
     ORDER BY (COALESCE(e->>'isPrimary','false') = 'true') DESC,
              e->'sortOrder', e->>'id'
     LIMIT 1
  ),
  ncover AS (
    SELECT e->>'id' AS id, e->>'localPath' AS path
      FROM jsonb_array_elements(COALESCE(next->'photos', '[]'::jsonb)) e
     WHERE e->>'deletedAt' IS NULL
     ORDER BY (COALESCE(e->>'isPrimary','false') = 'true') DESC,
              e->'sortOrder', e->>'id'
     LIMIT 1
  ),
  c AS (
    SELECT
      (SELECT count(*) FROM pr
        WHERE NOT EXISTS (SELECT 1 FROM nx WHERE nx.id = pr.id)) AS removed,
      -- Cleared, not "changed". Redrawing a line is ordinary work; emptying it
      -- leaves a route nobody can find on the photo.
      (SELECT count(*) FROM pr JOIN nx ON nx.id = pr.id
        WHERE COALESCE(pr.points, '') NOT IN ('', '[]', 'null', '{}')
          AND COALESCE(nx.points, '') IN ('', '[]', 'null', '{}')) AS cleared,
      (SELECT count(*) FROM pr JOIN nx ON nx.id = pr.id
        WHERE pr.photo_id IS DISTINCT FROM nx.photo_id) AS rephotoed
  )
  SELECT jsonb_strip_nulls(jsonb_build_object(
    'routesRemoved',   CASE WHEN c.removed   > 0 THEN to_jsonb(c.removed)   END,
    'geometryCleared', CASE WHEN c.cleared   > 0 THEN to_jsonb(c.cleared)   END,
    'routesReanchored',CASE WHEN c.rephotoed > 0 THEN to_jsonb(c.rephotoed) END,
    -- Both sides must have a cover for a swap to mean anything. A topo that
    -- had no photo and now has one has gained something, not had its identity
    -- changed underneath it.
    'coverPhotoSwapped', CASE
      WHEN (SELECT id FROM pcover) IS NOT NULL
       AND (SELECT id FROM ncover) IS NOT NULL
       AND (SELECT id FROM pcover) <> (SELECT id FROM ncover)
      THEN to_jsonb(true) END,
    'coverPhotoReplaced', CASE
      WHEN (SELECT id FROM pcover) IS NOT NULL
       AND (SELECT id FROM pcover) = (SELECT id FROM ncover)
       AND (SELECT path FROM pcover) IS DISTINCT FROM (SELECT path FROM ncover)
      THEN to_jsonb(true) END
  ))
  FROM c;
$$;

-- Fold a new set of kinds into an existing notice: counts add up, flags stay
-- set. Generic over the keys so adding a kind above needs no edit here.
CREATE OR REPLACE FUNCTION public.merge_change_kinds(older jsonb, newer jsonb)
  RETURNS jsonb
  LANGUAGE sql IMMUTABLE AS $$
  SELECT COALESCE(jsonb_object_agg(t.k, t.v), '{}'::jsonb)
    FROM (
      SELECT ks.k AS k,
             CASE
               WHEN jsonb_typeof(COALESCE(older->ks.k, newer->ks.k)) = 'number'
                 THEN to_jsonb(COALESCE((older->>ks.k)::bigint, 0)
                             + COALESCE((newer->>ks.k)::bigint, 0))
               ELSE to_jsonb(true)
             END AS v
        FROM (
          SELECT jsonb_object_keys(
                   COALESCE(older, '{}'::jsonb) || COALESCE(newer, '{}'::jsonb)
                 ) AS k
        ) ks
    ) t;
$$;

-- ---------------------------------------------------------------------------
-- 3. Recording a notice
-- ---------------------------------------------------------------------------
--
-- Called only from `snapshot_topo`, which runs as SECURITY DEFINER, so the
-- EXECUTE grant is revoked from everyone: a client that could call this could
-- manufacture accusations about someone else's topo.
CREATE OR REPLACE FUNCTION public.note_material_change(
  wall  text,
  actor text,
  prev  jsonb,
  next  jsonb
)
  RETURNS void
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  now_ms  bigint := (extract(epoch FROM now()) * 1000)::bigint;
  kinds   jsonb;
  open_id text;
BEGIN
  kinds := public.material_change_kinds(prev, next);
  IF kinds IS NULL OR kinds = '{}'::jsonb THEN
    RETURN;
  END IF;

  SELECT n.id INTO open_id
    FROM public.material_change_notices n
   WHERE n."wallId" = wall AND n."resolvedAt" IS NULL
   LIMIT 1;

  IF open_id IS NOT NULL THEN
    UPDATE public.material_change_notices n
       SET "changesJson" = public.merge_change_kinds(n."changesJson", kinds),
           "changeCount" = n."changeCount" + 1,
           "actorId"     = actor,
           "lastAt"      = now_ms
     WHERE n.id = open_id;
    RETURN;
  END IF;

  INSERT INTO public.material_change_notices
    (id, "wallId", "actorId", "changesJson", "changeCount", "firstAt", "lastAt")
  VALUES (gen_random_uuid()::text, wall, actor, kinds, 1, now_ms, now_ms)
  -- Belt and braces with the partial unique index: two concurrent writes to
  -- the same wall must produce one notice, not one error.
  ON CONFLICT DO NOTHING;
END;
$$;

-- SEC-1 (2026-08-08): this originally read `FROM public` only, which revokes
-- the PUBLIC pseudo-role but does NOT remove Supabase's default-privilege
-- grant made directly to the `anon` and `authenticated` roles on every
-- CREATE FUNCTION — so despite this REVOKE already being here, the function
-- was still callable by a fully anonymous REST caller to forge change
-- notices. Naming the roles explicitly is the fix. See
-- 2026-08-08_sec1_revoke_internal_helper_execute.sql.
REVOKE ALL ON FUNCTION public.note_material_change(text, text, jsonb, jsonb)
  FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. `snapshot_topo`, re-applied with the detector wired in
-- ---------------------------------------------------------------------------
--
-- Identical to the phase-6a version except that it now keeps the previous
-- payload (it already had to read it, to decide whether anything changed) and
-- hands it to the detector. Everything else - the published-only gate, the
-- unchanged short-circuit, five-minute coalescing by actor, the fifty-version
-- cap - is unchanged.
CREATE OR REPLACE FUNCTION public.snapshot_topo(wall text, actor text)
  RETURNS void
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  now_ms     bigint := (extract(epoch FROM now()) * 1000)::bigint;
  window_ms  bigint := 300000;   -- 5 minutes
  keep       int    := 50;
  recent     text;
  snap       jsonb;
  prev       jsonb;
BEGIN
  -- Only published topos have a history worth keeping. A draft is the owner's
  -- scratch space and nobody can be harmed by a change to it (C-1: ninety
  -- percent of the app must not get slower because of the community feature),
  -- and snapshotting every keystroke of every private topo would be the
  -- single most expensive thing in this schema.
  IF NOT EXISTS (
    SELECT 1 FROM public.wall_moderation
     WHERE "wallId" = wall AND state = 'published'
  ) THEN
    RETURN;
  END IF;

  snap := public.topo_snapshot(wall);
  IF snap IS NULL OR snap->'wall' IS NULL OR snap->'wall' = 'null'::jsonb THEN
    RETURN;   -- the wall is gone; nothing coherent to record
  END IF;

  -- NOTHING CHANGED means no version. This is not an optimisation, it is what
  -- makes the history survive at all.
  --
  -- There is no outbox (decision D-4): the sync engine re-reads and re-sends
  -- whole rows, so an ordinary background sync issues a full UPDATE of every
  -- row it owns even when the user has not touched the app. Every one of
  -- those fires these triggers. Without this check, a phone left open would
  -- mint a fresh identical version every five minutes and push the last real
  -- edit out past the fifty-version cap within about four hours - the history
  -- would be technically present and completely useless.
  --
  -- It is also what keeps C-5d quiet: the detector below is only ever reached
  -- by a write that genuinely altered the topo.
  SELECT v.payload INTO prev
    FROM public.topo_versions v
   WHERE v."wallId" = wall
   ORDER BY v."createdAt" DESC
   LIMIT 1;
  IF prev IS NOT NULL AND prev = snap THEN
    RETURN;
  END IF;

  -- C-5d. Wrapped, because a notice is a nice-to-have for a moderator and the
  -- write in progress is a climber's work: no defect in the detector may ever
  -- be able to fail somebody's sync push. `prev IS NULL` is the topo's first
  -- version, which has nothing to be a change FROM.
  IF prev IS NOT NULL THEN
    BEGIN
      PERFORM public.note_material_change(wall, actor, prev, snap);
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
  END IF;

  -- Coalesce a burst by the SAME actor into one version. The actor check is
  -- what protects the pre-vandalism state: a second person editing always
  -- opens a new version, so their change can never overwrite the payload that
  -- records how the topo looked before they arrived. The window runs from the
  -- version's `createdAt`, not its last touch, so a long editing session
  -- cannot extend one version indefinitely.
  SELECT v.id INTO recent
    FROM public.topo_versions v
   WHERE v."wallId" = wall
     AND v."createdAt" > now_ms - window_ms
     AND v."actorId" IS NOT DISTINCT FROM actor
   ORDER BY v."createdAt" DESC
   LIMIT 1;

  IF recent IS NOT NULL THEN
    UPDATE public.topo_versions
       SET payload      = snap,
           "routeCount" = jsonb_array_length(snap->'routes'),
           "updatedAt"  = now_ms
     WHERE id = recent;
    RETURN;
  END IF;

  INSERT INTO public.topo_versions
    (id, "wallId", "actorId", payload, "routeCount", "createdAt", "updatedAt")
  VALUES (gen_random_uuid()::text, wall, actor, snap,
          jsonb_array_length(snap->'routes'), now_ms, now_ms);

  -- Bounded retention. Unbounded history on a table that grows with every
  -- editing session is a slow leak, and fifty versions is far more than any
  -- revert has ever needed. Pruned here rather than by a job, for the same
  -- reason the withdrawal deadline is evaluated lazily: nothing to schedule,
  -- nothing to fail silently.
  DELETE FROM public.topo_versions
   WHERE "wallId" = wall
     AND id NOT IN (
       SELECT id FROM public.topo_versions
        WHERE "wallId" = wall
        ORDER BY "createdAt" DESC
        LIMIT keep
     );
END;
$$;

-- ---------------------------------------------------------------------------
-- 5. Reading and clearing notices
-- ---------------------------------------------------------------------------

DROP FUNCTION IF EXISTS public.material_changes(int);

-- Newest first, unlike the submissions queue.
--
-- Submissions are worked oldest-first because the number that matters is how
-- long somebody has been kept waiting. Nobody is waiting on this one: it is a
-- watch list, and the topo that changed shape an hour ago is the one that might
-- still be being changed right now.
CREATE OR REPLACE FUNCTION public.material_changes(limit_count int DEFAULT 50)
RETURNS TABLE (
  "id"          text,
  "wallId"      text,
  "wallName"    text,
  "ownerId"     text,
  "ownerName"   text,
  "actorId"     text,
  "actorName"   text,
  "changesJson" jsonb,
  "changeCount" int,
  "firstAt"     bigint,
  "lastAt"      bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  IF (auth.uid()) IS NULL OR NOT public.is_admin() THEN
    RAISE EXCEPTION 'not authorised' USING ERRCODE = '42501';
  END IF;

  limit_count := greatest(1, least(coalesce(limit_count, 50), 200));

  RETURN QUERY
  SELECT n.id, n."wallId", w.name, w."ownerId", po."displayName",
         n."actorId", pa."displayName",
         n."changesJson", n."changeCount", n."firstAt", n."lastAt"
    FROM public.material_change_notices n
    JOIN public.walls w            ON w.id = n."wallId"
    JOIN public.wall_moderation m  ON m."wallId" = w.id
    LEFT JOIN public.profiles po   ON po.id = w."ownerId"
    LEFT JOIN public.profiles pa   ON pa.id = n."actorId"
   WHERE n."resolvedAt" IS NULL
     AND w."deletedAt" IS NULL
     -- A notice about a topo that is no longer public is not actionable: the
     -- content it describes is already out of view, and whatever took it down
     -- is recorded elsewhere. It stays in the table, it just leaves the list.
     AND m.state = 'published'
   ORDER BY n."lastAt" DESC
   LIMIT limit_count;
END;
$$;

REVOKE ALL ON FUNCTION public.material_changes(int) FROM public;
GRANT EXECUTE ON FUNCTION public.material_changes(int) TO authenticated;

DROP FUNCTION IF EXISTS public.resolve_material_change(text);

-- "I have looked at this." There is deliberately no verdict attached - no
-- upheld/dismissed pair like a report has - because a material change is not an
-- accusation and nothing follows from clearing it. If the change was in fact
-- vandalism, the tools for that already exist and are the ones that carry a
-- consequence: revert (C-8) and take down (C-7).
CREATE OR REPLACE FUNCTION public.resolve_material_change(notice_id text)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  now_ms bigint := (extract(epoch FROM now()) * 1000)::bigint;
  actor  text   := (auth.uid())::text;
  wall   text;
  was    bigint;
BEGIN
  IF actor IS NULL OR NOT public.is_admin() THEN
    RAISE EXCEPTION 'not authorised' USING ERRCODE = '42501';
  END IF;

  SELECT n."wallId", n."resolvedAt" INTO wall, was
    FROM public.material_change_notices n WHERE n.id = notice_id;
  IF wall IS NULL THEN
    RAISE EXCEPTION 'unknown notice %', notice_id USING ERRCODE = 'P0002';
  END IF;

  -- Idempotent: two admins clearing the same row must not write two log
  -- entries, and the second one must not be shown an error for a race they
  -- could not have seen.
  IF was IS NOT NULL THEN
    RETURN 'resolved';
  END IF;

  UPDATE public.material_change_notices
     SET "resolvedAt" = now_ms, "resolvedBy" = actor
   WHERE id = notice_id;

  INSERT INTO public.moderation_log
    (id, "actorId", action, "targetType", "targetId", reason, "createdAt")
  VALUES (gen_random_uuid()::text, actor, 'material_change_reviewed',
          'wall', wall, NULL, now_ms);

  RETURN 'resolved';
END;
$$;

REVOKE ALL ON FUNCTION public.resolve_material_change(text) FROM public;
GRANT EXECUTE ON FUNCTION public.resolve_material_change(text) TO authenticated;
