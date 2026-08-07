-- Community editing, Phase 6a: version history (COMMUNITY_PLAN.md C-8).
--
-- The argument for this is C-5c. An owner's approval of a suggested edit is
-- final, and there is no re-review after publication, so the review queue
-- stops bad SUBMISSIONS and does nothing about a good submission that becomes
-- bad later. With no re-review, version history and reporting are the only
-- things standing between an approved topo and vandalism.
--
-- What makes it tractable is that it inverts the problem. Rather than trying
-- to enumerate and block every destructive act — delete the topo, delete its
-- routes, blank the description, swap the photo for garbage, drag every line
-- off the rock — you make all of them reversible and attributed. A vandalised
-- topo becomes a one-click admin revert instead of an incident.
--
-- Idempotent, per this repo's migration convention.

-- ---------------------------------------------------------------------------
-- 1. The table
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.topo_versions (
  id          text PRIMARY KEY,
  "wallId"    text NOT NULL REFERENCES public.walls(id) ON DELETE CASCADE,
  "actorId"   text,
  payload     jsonb  NOT NULL,
  "routeCount" int   NOT NULL DEFAULT 0,
  "createdAt" bigint NOT NULL,
  "updatedAt" bigint NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_topo_versions_wall
  ON public.topo_versions ("wallId", "createdAt" DESC);

ALTER TABLE public.topo_versions ENABLE ROW LEVEL SECURITY;

-- Readable by anyone who can see the topo, plus its owner and admins.
--
-- Public rather than owner-only because every version's content WAS public
-- when it was captured — the snapshot trigger below only fires for a wall in
-- `state = 'published'`, so a version can never carry a draft or a rejected
-- revision. That makes "what changed here since I last climbed" safe to
-- expose, which C-8 names as the genuinely useful side effect of building
-- this for moderation reasons.
--
-- No INSERT/UPDATE/DELETE policy at all. Versions are written by the
-- SECURITY DEFINER trigger below and by nothing else; an append-only history a
-- client could edit would be worth very little.
DROP POLICY IF EXISTS topo_versions_select ON public.topo_versions;
CREATE POLICY topo_versions_select ON public.topo_versions FOR SELECT
  USING (
    public.is_wall_public("wallId")
    OR EXISTS (SELECT 1 FROM public.walls w
                WHERE w.id = "wallId" AND w."ownerId" = (auth.uid())::text)
    OR public.is_admin()
  );

-- ---------------------------------------------------------------------------
-- 2. What a snapshot contains
-- ---------------------------------------------------------------------------
--
-- Metadata as JSON, never photo bytes — which is what makes the storage cost
-- of this small enough to not think about. A reverted photo points at the same
-- object it always did; only which photo is primary, how it is cropped and
-- where it sorts can change, and those are columns.
--
-- `dirty` and `remoteId` are deliberately excluded. Both are sync bookkeeping
-- that belongs to whichever client wrote the row, and restoring one client's
-- bookkeeping onto the server would be meaningless at best.
--
-- `deletedAt` is deliberately INCLUDED. Deleting every route on a topo is one
-- of the destructive acts this exists to undo, and a snapshot that dropped
-- soft-deleted rows could not put them back.
CREATE OR REPLACE FUNCTION public.topo_snapshot(wall text) RETURNS jsonb
  LANGUAGE sql SECURITY DEFINER STABLE SET search_path = public AS $$
  SELECT jsonb_build_object(
    'wall', (
      SELECT to_jsonb(x) FROM (
        SELECT w.id, w."sectorId", w.name, w."sortOrder", w.visibility,
               w.latitude, w.longitude, w."accessState", w."accessNote",
               w."deletedAt"
          FROM public.walls w WHERE w.id = wall
      ) x
    ),
    'routes', COALESCE((
      SELECT jsonb_agg(to_jsonb(x) ORDER BY x."sortOrder", x.id) FROM (
        SELECT r.id, r."wallId", r."photoId", r.number, r.name,
               r."gradeSystem", r."gradeRaw", r."gradeSortKey", r.style,
               r.description, r."colorIndex", r."pointsJson", r."symbolsJson",
               r."sortOrder", r.visible, r."betaVideoUrl", r."styleTagsJson",
               r.stars, r."deletedAt", r."ownerId", r."createdAt"
          FROM public.routes r WHERE r."wallId" = wall
      ) x
    ), '[]'::jsonb),
    'photos', COALESCE((
      SELECT jsonb_agg(to_jsonb(x) ORDER BY x."sortOrder", x.id) FROM (
        SELECT p.id, p."wallId", p."localPath", p.kind, p.width, p.height,
               p."parentPhotoId", p."cropXpct", p."cropWidthPct", p."sortOrder",
               p."isPrimary", p."deletedAt", p."ownerId", p."createdAt"
          FROM public.photos p WHERE p."wallId" = wall
      ) x
    ), '[]'::jsonb)
  );
$$;

-- ---------------------------------------------------------------------------
-- 3. Cutting a version
-- ---------------------------------------------------------------------------
--
-- COALESCING is the whole difficulty. This app has no "save" event: the sync
-- engine re-pushes whole rows (decision D-4, no outbox), so one editing
-- session arrives as a burst of upserts, and a naive per-row trigger would
-- write twenty near-identical versions for one afternoon of drawing.
--
-- So a burst by the same actor within `_window_ms` EXTENDS the current version
-- in place rather than opening a new one. Note which direction that goes: the
-- version ends up holding the state at the END of the burst, not the start.
-- That is required for a revert to restore something coherent — a snapshot
-- taken mid-burst would have the wall row updated and its routes not.
--
-- Consequence worth stating plainly: a version's content is mutable for as
-- long as its window is open. It is not "the change that was made at 14:03",
-- it is "where this topo stood after the editing session around 14:03". That
-- is the more useful thing to be able to restore.
CREATE OR REPLACE FUNCTION public.snapshot_topo(wall text, actor text)
  RETURNS void
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  now_ms     bigint := (extract(epoch FROM now()) * 1000)::bigint;
  window_ms  bigint := 300000;   -- 5 minutes
  keep       int    := 50;
  recent     text;
  snap       jsonb;
  unchanged  boolean;
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

  -- NOTHING CHANGED ⇒ no version. This is not an optimisation, it is what
  -- makes the history survive at all.
  --
  -- There is no outbox (decision D-4): the sync engine re-reads and re-sends
  -- whole rows, so an ordinary background sync issues a full UPDATE of every
  -- row it owns even when the user has not touched the app. Every one of
  -- those fires these triggers. Without this check, a phone left open would
  -- mint a fresh identical version every five minutes and push the last real
  -- edit out past the fifty-version cap within about four hours — the history
  -- would be technically present and completely useless.
  SELECT v.payload = snap INTO unchanged
    FROM public.topo_versions v
   WHERE v."wallId" = wall
   ORDER BY v."createdAt" DESC
   LIMIT 1;
  IF unchanged THEN
    RETURN;
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

-- STATEMENT-level triggers with transition tables, not row-level ones.
--
-- This is the difference between three snapshot attempts per sync push and one
-- per row pushed. `upsertOwnRows` sends one batched statement per table, so a
-- transition table gives exactly the set of walls touched by that statement,
-- once, however many rows it carried.
CREATE OR REPLACE FUNCTION public.snapshot_touched_walls() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  actor text := (auth.uid())::text;
  w     text;
BEGIN
  -- Two separate queries, not one with a `CASE TG_TABLE_NAME` picking the
  -- column. Postgres resolves column references in BOTH arms of a CASE at
  -- parse time, so the single-query form raises `column "wallId" does not
  -- exist` on every wall write — including inserts, which is to say it takes
  -- the entire app down rather than just this feature.
  IF TG_TABLE_NAME = 'walls' THEN
    FOR w IN SELECT DISTINCT id FROM changed LOOP
      IF w IS NOT NULL THEN PERFORM public.snapshot_topo(w, actor); END IF;
    END LOOP;
  ELSE
    FOR w IN SELECT DISTINCT "wallId" FROM changed LOOP
      IF w IS NOT NULL THEN PERFORM public.snapshot_topo(w, actor); END IF;
    END LOOP;
  END IF;
  RETURN NULL;
END;
$$;

-- One trigger per (table, event). Postgres refuses a transition table on a
-- trigger with more than one event — `AFTER INSERT OR UPDATE ... REFERENCING
-- NEW TABLE` fails with "transition tables cannot be specified for triggers
-- with more than one event" — so the six below are not redundancy, they are
-- the only shape this can take.
DROP TRIGGER IF EXISTS trg_snapshot_walls ON public.walls;
DROP TRIGGER IF EXISTS trg_snapshot_walls_ins ON public.walls;
CREATE TRIGGER trg_snapshot_walls_ins
  AFTER INSERT ON public.walls
  REFERENCING NEW TABLE AS changed
  FOR EACH STATEMENT EXECUTE FUNCTION public.snapshot_touched_walls();

DROP TRIGGER IF EXISTS trg_snapshot_walls_upd ON public.walls;
CREATE TRIGGER trg_snapshot_walls_upd
  AFTER UPDATE ON public.walls
  REFERENCING NEW TABLE AS changed
  FOR EACH STATEMENT EXECUTE FUNCTION public.snapshot_touched_walls();

DROP TRIGGER IF EXISTS trg_snapshot_routes ON public.routes;
DROP TRIGGER IF EXISTS trg_snapshot_routes_ins ON public.routes;
CREATE TRIGGER trg_snapshot_routes_ins
  AFTER INSERT ON public.routes
  REFERENCING NEW TABLE AS changed
  FOR EACH STATEMENT EXECUTE FUNCTION public.snapshot_touched_walls();

DROP TRIGGER IF EXISTS trg_snapshot_routes_upd ON public.routes;
CREATE TRIGGER trg_snapshot_routes_upd
  AFTER UPDATE ON public.routes
  REFERENCING NEW TABLE AS changed
  FOR EACH STATEMENT EXECUTE FUNCTION public.snapshot_touched_walls();

DROP TRIGGER IF EXISTS trg_snapshot_photos ON public.photos;
DROP TRIGGER IF EXISTS trg_snapshot_photos_ins ON public.photos;
CREATE TRIGGER trg_snapshot_photos_ins
  AFTER INSERT ON public.photos
  REFERENCING NEW TABLE AS changed
  FOR EACH STATEMENT EXECUTE FUNCTION public.snapshot_touched_walls();

DROP TRIGGER IF EXISTS trg_snapshot_photos_upd ON public.photos;
CREATE TRIGGER trg_snapshot_photos_upd
  AFTER UPDATE ON public.photos
  REFERENCING NEW TABLE AS changed
  FOR EACH STATEMENT EXECUTE FUNCTION public.snapshot_touched_walls();

-- ---------------------------------------------------------------------------
-- 4. Reverting
-- ---------------------------------------------------------------------------
--
-- Admin-only, and the single reason all of the above is worth building.
--
-- Two things here are load-bearing and easy to get wrong:
--
--  1. IT SNAPSHOTS FIRST. A revert that is not itself revertible turns one
--     mistaken click into exactly the unrecoverable data loss this phase
--     exists to prevent.
--
--  2. IT BUMPS `updatedAt` PAST THE CLIENT'S. The owner's device still holds
--     the vandalised rows and will push them again. `shouldPushLww` skips a
--     local row only when the remote one is STRICTLY newer (local wins ties,
--     `sync_remote.dart:303-315`), so a revert that wrote a server-now
--     timestamp would be quietly re-vandalised by the next push from a client
--     whose clock ran a second fast. `GREATEST(local, now) + 1` is what makes
--     the revert stick — the same reasoning as the phase 5 trigger.
CREATE OR REPLACE FUNCTION public.revert_topo(wall_id text, version_id text)
  RETURNS int
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  now_ms  bigint := (extract(epoch FROM now()) * 1000)::bigint;
  actor   text   := (auth.uid())::text;
  snap    jsonb;
  owner   text;
  touched int    := 0;
  item    jsonb;
BEGIN
  IF actor IS NULL OR NOT public.is_admin() THEN
    RAISE EXCEPTION 'not authorised' USING ERRCODE = '42501';
  END IF;

  SELECT v.payload INTO snap
    FROM public.topo_versions v
   WHERE v.id = version_id AND v."wallId" = wall_id;
  IF snap IS NULL THEN
    RAISE EXCEPTION 'unknown version % for wall %', version_id, wall_id
      USING ERRCODE = 'P0002';
  END IF;

  SELECT w."ownerId" INTO owner FROM public.walls w WHERE w.id = wall_id;
  IF owner IS NULL THEN
    RAISE EXCEPTION 'unknown wall %', wall_id USING ERRCODE = 'P0002';
  END IF;

  -- (1) Preserve where we are before changing it.
  PERFORM public.snapshot_topo(wall_id, actor);

  UPDATE public.walls w SET
      name          = snap->'wall'->>'name',
      "sortOrder"   = (snap->'wall'->>'sortOrder')::int,
      visibility    = snap->'wall'->>'visibility',
      latitude      = (snap->'wall'->>'latitude')::double precision,
      longitude     = (snap->'wall'->>'longitude')::double precision,
      "accessState" = snap->'wall'->>'accessState',
      "accessNote"  = snap->'wall'->>'accessNote',
      "deletedAt"   = (snap->'wall'->>'deletedAt')::bigint,
      "updatedAt"   = GREATEST(w."updatedAt", now_ms) + 1
    WHERE w.id = wall_id;

  -- Upsert rather than update: a route that was hard-deleted between the
  -- snapshot and now has to come BACK, and an update would silently restore
  -- nothing while reporting success.
  FOR item IN SELECT jsonb_array_elements(snap->'routes') LOOP
    INSERT INTO public.routes (
      id, "ownerId", "wallId", "photoId", number, name, "gradeSystem",
      "gradeRaw", "gradeSortKey", style, description, "colorIndex",
      "pointsJson", "symbolsJson", "sortOrder", visible, "betaVideoUrl",
      "styleTagsJson", stars, "deletedAt", "createdAt", "updatedAt", dirty
    ) VALUES (
      item->>'id', COALESCE(item->>'ownerId', owner), wall_id, item->>'photoId',
      (item->>'number')::int, item->>'name', item->>'gradeSystem',
      item->>'gradeRaw', (item->>'gradeSortKey')::double precision,
      item->>'style', item->>'description', (item->>'colorIndex')::int,
      item->>'pointsJson', item->>'symbolsJson', (item->>'sortOrder')::int,
      (item->>'visible')::boolean, item->>'betaVideoUrl',
      item->>'styleTagsJson', (item->>'stars')::int,
      (item->>'deletedAt')::bigint, COALESCE((item->>'createdAt')::bigint, now_ms),
      now_ms, false
    )
    ON CONFLICT (id) DO UPDATE SET
      "photoId"       = EXCLUDED."photoId",
      number          = EXCLUDED.number,
      name            = EXCLUDED.name,
      "gradeSystem"   = EXCLUDED."gradeSystem",
      "gradeRaw"      = EXCLUDED."gradeRaw",
      "gradeSortKey"  = EXCLUDED."gradeSortKey",
      style           = EXCLUDED.style,
      description     = EXCLUDED.description,
      "colorIndex"    = EXCLUDED."colorIndex",
      "pointsJson"    = EXCLUDED."pointsJson",
      "symbolsJson"   = EXCLUDED."symbolsJson",
      "sortOrder"     = EXCLUDED."sortOrder",
      visible         = EXCLUDED.visible,
      "betaVideoUrl"  = EXCLUDED."betaVideoUrl",
      "styleTagsJson" = EXCLUDED."styleTagsJson",
      stars           = EXCLUDED.stars,
      "deletedAt"     = EXCLUDED."deletedAt",
      "updatedAt"     = GREATEST(public.routes."updatedAt", now_ms) + 1;
    touched := touched + 1;
  END LOOP;

  -- A route created AFTER the snapshot is not in the payload at all, so the
  -- upsert loop above cannot touch it. Soft-delete it, rather than leaving it
  -- behind: "revert to this version" that silently keeps the vandal's twelve
  -- new junk routes is not a revert. Soft, never hard — nothing published is
  -- ever destroyed (COMMUNITY_PLAN.md §3.3), so this is itself undoable.
  UPDATE public.routes r
     SET "deletedAt" = now_ms,
         "updatedAt" = GREATEST(r."updatedAt", now_ms) + 1
   WHERE r."wallId" = wall_id
     AND r."deletedAt" IS NULL
     AND NOT EXISTS (
       SELECT 1 FROM jsonb_array_elements(snap->'routes') e
        WHERE e->>'id' = r.id
     );

  FOR item IN SELECT jsonb_array_elements(snap->'photos') LOOP
    UPDATE public.photos p SET
        "sortOrder"    = (item->>'sortOrder')::int,
        "isPrimary"    = (item->>'isPrimary')::boolean,
        "cropXpct"     = (item->>'cropXpct')::double precision,
        "cropWidthPct" = (item->>'cropWidthPct')::double precision,
        "deletedAt"    = (item->>'deletedAt')::bigint,
        "updatedAt"    = GREATEST(p."updatedAt", now_ms) + 1
      WHERE p.id = item->>'id';
  END LOOP;

  INSERT INTO public.moderation_log
    (id, "actorId", action, "targetType", "targetId", reason, "createdAt")
  VALUES (gen_random_uuid()::text, actor, 'revert', 'wall', wall_id,
          version_id, now_ms);

  RETURN touched;
END;
$$;

-- The history list, without the payloads. A version's JSON is large and a
-- client listing twenty of them wants dates and authors, not twenty full
-- topos; the payload is fetched only when one is actually being inspected.
CREATE OR REPLACE FUNCTION public.topo_version_list(wall_id text, limit_count int DEFAULT 30)
  RETURNS TABLE (
    id           text,
    "actorId"    text,
    "actorName"  text,
    "routeCount" int,
    "wallName"   text,
    "createdAt"  bigint,
    "updatedAt"  bigint
  )
  LANGUAGE sql SECURITY DEFINER STABLE SET search_path = public AS $$
  SELECT v.id, v."actorId", pr."displayName", v."routeCount",
         v.payload->'wall'->>'name', v."createdAt", v."updatedAt"
    FROM public.topo_versions v
    -- Joined on `ownerId`, not `id`: a profile row's own id is its local
    -- record id, while `ownerId` is the auth uid, which is what `actorId`
    -- holds. Joining on `id` returns a name for nobody, silently.
    LEFT JOIN public.profiles pr ON pr."ownerId" = v."actorId"
   WHERE v."wallId" = wall_id
     AND (
       public.is_wall_public(wall_id)
       OR EXISTS (SELECT 1 FROM public.walls w
                   WHERE w.id = wall_id AND w."ownerId" = (auth.uid())::text)
       OR public.is_admin()
     )
   ORDER BY v."createdAt" DESC
   LIMIT limit_count;
$$;

GRANT EXECUTE ON FUNCTION public.revert_topo(text, text)          TO authenticated;
GRANT EXECUTE ON FUNCTION public.topo_version_list(text, int)     TO authenticated;

-- ---------------------------------------------------------------------------
-- 5. Baseline
-- ---------------------------------------------------------------------------
--
-- Without this, the first version of every existing topo is the state AFTER
-- whatever change happens to come next — so the one revision you most want to
-- restore, the good one that exists right now, would never be recorded. Every
-- currently-published topo gets a version representing today.
INSERT INTO public.topo_versions
  (id, "wallId", "actorId", payload, "routeCount", "createdAt", "updatedAt")
SELECT gen_random_uuid()::text, m."wallId", NULL,
       public.topo_snapshot(m."wallId"),
       jsonb_array_length(public.topo_snapshot(m."wallId")->'routes'),
       (extract(epoch FROM now()) * 1000)::bigint,
       (extract(epoch FROM now()) * 1000)::bigint
  FROM public.wall_moderation m
  JOIN public.walls w ON w.id = m."wallId"
 WHERE m.state = 'published'
   AND w."deletedAt" IS NULL
   AND NOT EXISTS (
     SELECT 1 FROM public.topo_versions v WHERE v."wallId" = m."wallId"
   );
