-- Community editing, Phase 7b: GEOMETRY suggestions
-- (COMMUNITY_PLAN.md C-5b).
--
-- Phase 7a shipped the metadata slice and deliberately stopped there. §C-5b
-- lists four things a geometry suggestion needs that a typo fix does not, and
-- three of them are server-shaped:
--
--   1. PIN TO A PHOTO. Points are stored in percent space normalised to the
--      image, so a line drawn against photo A is meaningless against photo B.
--      Every geometry suggestion therefore carries the `photoId` it was drawn
--      on, and is shown stale if that photo is gone.
--   2. USE THE DATABASE ID, NOT THE DOMAIN ID. `TopoRoute.id` is an int the
--      client reassigns 1..n on every load. The existing `"routeId"` column
--      already references `public.routes(id)` — the text uuid — and that is
--      the only identity allowed to cross the wire.
--   3. BOUNDS. A points array is the first thing in this whole feature that a
--      client sends by the hundred, so its size and range are checked here
--      rather than trusted.
--
-- The fourth (a propose-mode canvas, and a visual diff for the owner) is
-- entirely client-side and lands with this migration's client.
--
-- WHAT THIS DOES NOT ADD: a way to suggest DELETING a route. A suggestion is
-- an offer of help the owner may accept in one tap, and "accept" should never
-- be the gesture that removes work. Deleting stays the owner's own action.
--
-- Idempotent, per this repo's migration convention.

-- ---------------------------------------------------------------------------
-- 1. The photo a line was drawn on
-- ---------------------------------------------------------------------------
--
-- ON DELETE CASCADE: a geometry suggestion without its photo cannot be
-- rendered, reviewed or applied — there is nothing to keep. (Photos are
-- normally SOFT-deleted, so this fires only on a real row removal; the
-- soft-delete case is handled by the staleness test in §5.)
ALTER TABLE public.topo_edit_suggestions
  ADD COLUMN IF NOT EXISTS "photoId" text
  REFERENCES public.photos(id) ON DELETE CASCADE;

-- ---------------------------------------------------------------------------
-- 2. The new kind
-- ---------------------------------------------------------------------------
--
-- `points` is the line; `symbols` are the bolts/anchors/crux markers along it.
-- Both are shape-checked in §3.
--
-- Note the split of responsibility on `symbols[].type`: this function checks
-- that it is a STRING, and does not check it against a vocabulary. The client
-- owns that list (`SymbolType`), and its decoder already drops a type it does
-- not recognise rather than failing the load — that is what lets an old topo
-- survive a removed marker type. Duplicating the enum here would mean a new
-- marker could not ship without a migration, for no safety gained: an unknown
-- type is dropped on read either way. What the server enforces is the part a
-- client cannot be trusted with — size and coordinate range.
CREATE OR REPLACE FUNCTION public.suggestion_fields(kind text)
  RETURNS text[]
  LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE kind
    WHEN 'topo.metadata'  THEN ARRAY['name','latitude','longitude']
    WHEN 'route.metadata' THEN ARRAY['name','description','betaVideoUrl','style','styleTagsJson']
    WHEN 'route.geometry' THEN ARRAY['points','symbols']
    ELSE ARRAY[]::text[]
  END;
$$;

-- ---------------------------------------------------------------------------
-- 3. Validating a geometry payload
-- ---------------------------------------------------------------------------
--
-- Returns NULL when the patch is acceptable, or the reason it is not. A
-- returned message is shown to the person who drew the line, so it says what
-- is wrong in words rather than naming a constraint.
--
-- Written in plpgsql, not sql, on purpose: the checks are ORDERED, and
-- `jsonb_array_length` throws outright on a non-array, so the type test has to
-- be guaranteed to run first. A single boolean `AND` chain would leave that
-- ordering to the planner.
CREATE OR REPLACE FUNCTION public.geometry_patch_error(patch jsonb)
  RETURNS text
  LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  pts  jsonb := patch->'points';
  syms jsonb := patch->'symbols';
  bad  int;
BEGIN
  IF pts IS NULL OR jsonb_typeof(pts) <> 'array' THEN
    RETURN 'a proposed line needs its points';
  END IF;
  -- Two points is a line. One is a tap, and would render as a dot nobody can
  -- read as a route.
  IF jsonb_array_length(pts) < 2 THEN
    RETURN 'a line needs at least two points';
  END IF;
  IF jsonb_array_length(pts) > 200 THEN
    RETURN 'that line has too many points';
  END IF;

  SELECT count(*) INTO bad FROM jsonb_array_elements(pts) e
   WHERE jsonb_typeof(e) <> 'object'
      OR jsonb_typeof(e->'x') <> 'number'
      OR jsonb_typeof(e->'y') <> 'number'
      OR (e->>'x')::numeric < 0 OR (e->>'x')::numeric > 1
      OR (e->>'y')::numeric < 0 OR (e->>'y')::numeric > 1;
  IF bad > 0 THEN
    RETURN 'that line has points outside the photo';
  END IF;

  IF syms IS NOT NULL AND jsonb_typeof(syms) <> 'null' THEN
    IF jsonb_typeof(syms) <> 'array' THEN
      RETURN 'markers are not in a readable shape';
    END IF;
    IF jsonb_array_length(syms) > 64 THEN
      RETURN 'that line has too many markers';
    END IF;
    SELECT count(*) INTO bad FROM jsonb_array_elements(syms) e
     WHERE jsonb_typeof(e) <> 'object'
        OR jsonb_typeof(e->'type') <> 'string'
        OR jsonb_typeof(e->'x') <> 'number'
        OR jsonb_typeof(e->'y') <> 'number'
        OR (e->>'x')::numeric < 0 OR (e->>'x')::numeric > 1
        OR (e->>'y')::numeric < 0 OR (e->>'y')::numeric > 1;
    IF bad > 0 THEN
      RETURN 'markers are not in a readable shape';
    END IF;
  END IF;

  RETURN NULL;
END;
$$;

-- ---------------------------------------------------------------------------
-- 4. Making one
-- ---------------------------------------------------------------------------
--
-- `suggest_edit` grows a `photo_id` parameter. DROPPED FIRST, not replaced:
-- adding a defaulted parameter creates an OVERLOAD rather than replacing the
-- function, and then the 5-argument call every existing client makes matches
-- both signatures and Postgres refuses it as ambiguous (42725). One signature
-- only.
DROP FUNCTION IF EXISTS public.suggest_edit(text, text, jsonb, text, text);

CREATE OR REPLACE FUNCTION public.suggest_edit(
  wall_id  text,
  kind     text,
  patch    jsonb,
  note     text DEFAULT NULL,
  route_id text DEFAULT NULL,
  photo_id text DEFAULT NULL
) RETURNS text
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  now_ms   bigint := (extract(epoch FROM now()) * 1000)::bigint;
  actor    text   := (auth.uid())::text;
  allowed  text[];
  key      text;
  open_here int;
  today    int;
  base     text;
  new_id   text;
  problem  text;
  photo_ok boolean;
  route_photo text;
BEGIN
  IF actor IS NULL THEN
    RAISE EXCEPTION 'not authorised' USING ERRCODE = '42501';
  END IF;

  IF NOT public.is_wall_public(wall_id) THEN
    RAISE EXCEPTION 'unknown wall %', wall_id USING ERRCODE = 'P0002';
  END IF;

  allowed := public.suggestion_fields(kind);
  IF array_length(allowed, 1) IS NULL THEN
    RAISE EXCEPTION 'unknown suggestion kind %', kind USING ERRCODE = '22023';
  END IF;
  IF patch IS NULL OR jsonb_typeof(patch) <> 'object' OR patch = '{}'::jsonb THEN
    RAISE EXCEPTION 'empty patch' USING ERRCODE = '22023';
  END IF;
  IF kind = 'route.metadata' AND route_id IS NULL THEN
    RAISE EXCEPTION 'route.metadata needs a route' USING ERRCODE = '22023';
  END IF;

  FOR key IN SELECT jsonb_object_keys(patch) LOOP
    IF NOT (key = ANY(allowed)) THEN
      RAISE EXCEPTION 'field % cannot be suggested', key USING ERRCODE = '22023';
    END IF;
  END LOOP;

  -- Geometry-only checks.
  IF kind = 'route.geometry' THEN
    IF photo_id IS NULL THEN
      RAISE EXCEPTION 'a proposed line needs the photo it was drawn on'
        USING ERRCODE = '22023';
    END IF;

    -- The photo must be a LIVE photo of THIS wall. Without the wall check,
    -- a line could be pinned to a photo of somewhere else entirely and the
    -- owner would be shown a diff over a stranger's crag.
    SELECT true INTO photo_ok FROM public.photos p
     WHERE p.id = photo_id AND p."wallId" = wall_id AND p."deletedAt" IS NULL;
    IF photo_ok IS NOT TRUE THEN
      RAISE EXCEPTION 'that photo is not part of this topo' USING ERRCODE = 'P0002';
    END IF;

    problem := public.geometry_patch_error(patch);
    IF problem IS NOT NULL THEN
      RAISE EXCEPTION '%', problem USING ERRCODE = '22023';
    END IF;

    -- Targeting an existing route is optional: a NULL `route_id` means "here
    -- is a line that is missing", which is the more common contribution.
    -- But when a route IS named, it has to live on the same photo — replacing
    -- a line pinned to photo A with points drawn on photo B is exactly the
    -- meaningless case §C-5b opens with, and it would look correct right up
    -- until the owner accepted it.
    IF route_id IS NOT NULL THEN
      SELECT r."photoId" INTO route_photo FROM public.routes r
       WHERE r.id = route_id AND r."wallId" = wall_id AND r."deletedAt" IS NULL;
      IF route_photo IS NULL THEN
        RAISE EXCEPTION 'that route is not part of this topo' USING ERRCODE = 'P0002';
      END IF;
      IF route_photo IS DISTINCT FROM photo_id THEN
        RAISE EXCEPTION 'that route is drawn on a different photo'
          USING ERRCODE = '22023';
      END IF;
    END IF;
  END IF;

  SELECT count(*) INTO open_here
    FROM public.topo_edit_suggestions s
   WHERE s."wallId" = wall_id AND s."authorId" = actor AND s.status = 'open';
  IF open_here >= 3 THEN
    RAISE EXCEPTION 'too many open suggestions on this topo'
      USING ERRCODE = '53400';
  END IF;

  SELECT count(*) INTO today
    FROM public.topo_edit_suggestions s
   WHERE s."authorId" = actor AND s."createdAt" > now_ms - 86400000;
  IF today >= 20 THEN
    RAISE EXCEPTION 'too many suggestions today' USING ERRCODE = '53400';
  END IF;

  SELECT v.id INTO base
    FROM public.topo_versions v
   WHERE v."wallId" = wall_id
   ORDER BY v."createdAt" DESC
   LIMIT 1;

  new_id := gen_random_uuid()::text;
  INSERT INTO public.topo_edit_suggestions
    (id, "wallId", "routeId", "photoId", "authorId", kind, patch, note,
     "baseVersionId", status, "createdAt")
  VALUES (new_id, wall_id, route_id, photo_id, actor, kind, patch,
          nullif(btrim(coalesce(note, '')), ''), base, 'open', now_ms);

  RETURN new_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- 5. Reading them
-- ---------------------------------------------------------------------------
--
-- Adds `photoId` to the row, and a THIRD staleness test.
--
-- Phase 7a's two tests both ask "has the topo changed since this was written".
-- Geometry adds a question those cannot answer: is the thing this line was
-- drawn ON still there? A suggestion pinned to a photo the owner has since
-- removed, or targeting a route they have since deleted, is not merely stale —
-- it cannot be rendered or applied at all.
--
-- Note this is NOT the "primary photo has changed" test §C-5b's wording
-- suggests. A topo can carry several photos, each with its own independent set
-- of routes, so a line drawn on the second photo is perfectly current even
-- when the first is primary. The condition that actually matters is whether
-- the pinned photo itself is still live.
--
-- DROPPED and recreated rather than replaced: `CREATE OR REPLACE FUNCTION`
-- cannot change a function's OUT parameters, and this adds one.
DROP FUNCTION IF EXISTS public.suggestions_for_me(int);

CREATE OR REPLACE FUNCTION public.suggestions_for_me(limit_count int DEFAULT 50)
  RETURNS TABLE (
    id           text,
    "wallId"     text,
    "wallName"   text,
    "routeId"    text,
    "routeName"  text,
    "photoId"    text,
    "authorId"   text,
    "authorName" text,
    kind         text,
    patch        jsonb,
    note         text,
    "isStale"    boolean,
    "createdAt"  bigint
  )
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  me text := (auth.uid())::text;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'not authorised' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT s.id, s."wallId", w.name, s."routeId", r.name, s."photoId",
         s."authorId", pr."displayName", s.kind, s.patch, s.note,
         s."baseVersionId" IS DISTINCT FROM (
           SELECT v.id FROM public.topo_versions v
            WHERE v."wallId" = s."wallId"
            ORDER BY v."createdAt" DESC LIMIT 1
         )
         OR COALESCE((
           SELECT v."updatedAt" > s."createdAt" FROM public.topo_versions v
            WHERE v.id = s."baseVersionId"
         ), false)
         -- The pinned photo is gone, or the targeted route is.
         OR (s."photoId" IS NOT NULL AND NOT EXISTS (
              SELECT 1 FROM public.photos p
               WHERE p.id = s."photoId" AND p."deletedAt" IS NULL))
         OR (s."routeId" IS NOT NULL AND NOT EXISTS (
              SELECT 1 FROM public.routes r2
               WHERE r2.id = s."routeId" AND r2."deletedAt" IS NULL)),
         s."createdAt"
    FROM public.topo_edit_suggestions s
    JOIN public.walls w ON w.id = s."wallId"
    LEFT JOIN public.routes r    ON r.id = s."routeId"
    LEFT JOIN public.profiles pr ON pr."ownerId" = s."authorId"
   WHERE s.status = 'open'
     AND w."ownerId" = me
   ORDER BY s."createdAt" ASC
   LIMIT limit_count;
END;
$$;

GRANT EXECUTE ON FUNCTION public.suggest_edit(text, text, jsonb, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.suggestions_for_me(int)                           TO authenticated;
GRANT EXECUTE ON FUNCTION public.suggestion_fields(text)                           TO authenticated;
GRANT EXECUTE ON FUNCTION public.geometry_patch_error(jsonb)                       TO authenticated;
