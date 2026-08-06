-- Community editing, Phase 4: community facts (R-1).
--
-- The layer that is deliberately NOT gated behind the owner's approval, nor
-- behind the admin queue. Rationale in COMMUNITY_PLAN.md §3.2: the topo — the
-- photo, the drawn line, the prose — is the author's work and they curate it.
-- The grade, whether the drawing matches the rock, and whether there is a
-- loose block over the belay are facts about the world. Every platform
-- surveyed treats the second category as community-owned, and EFF's position
-- in the OpenBeta matter is that route facts are not copyrightable at all.
--
-- So: no approval queue anywhere in this file. Anyone signed in may state an
-- opinion; the author of a statement owns that statement and nobody else can
-- rewrite it.
--
-- Idempotent, per this repo's migration convention.

-- ---------------------------------------------------------------------------
-- Visibility helper for route-scoped facts
-- ---------------------------------------------------------------------------
--
-- Grade opinions hang off a route, but visibility is a property of the wall
-- that route belongs to — so this defers to is_wall_public() rather than
-- duplicating its (already subtle) definition. SECURITY DEFINER for the same
-- reason is_wall_public is: the policies below must be able to see rows the
-- calling user cannot.
CREATE OR REPLACE FUNCTION public.is_route_public(route text) RETURNS boolean
  LANGUAGE sql SECURITY DEFINER STABLE SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.routes r
    WHERE r.id = route
      AND r."deletedAt" IS NULL
      AND public.is_wall_public(r."wallId")
  );
$$;

-- ---------------------------------------------------------------------------
-- Grade opinions
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.route_grade_opinions (
  id             text PRIMARY KEY,
  "routeId"      text NOT NULL REFERENCES public.routes(id) ON DELETE CASCADE,
  "authorId"     text NOT NULL,
  "gradeSystem"  text NOT NULL,
  "gradeRaw"     text NOT NULL,
  "gradeSortKey" double precision,
  "createdAt"    bigint NOT NULL,
  UNIQUE ("routeId", "authorId")   -- one opinion per person per route
);

CREATE INDEX IF NOT EXISTS route_grade_opinions_route_idx
  ON public.route_grade_opinions ("routeId");

-- ---------------------------------------------------------------------------
-- Verifications ("I was there, the topo matches the rock")
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.topo_verifications (
  id          text PRIMARY KEY,
  "wallId"    text NOT NULL REFERENCES public.walls(id) ON DELETE CASCADE,
  "authorId"  text NOT NULL,
  accurate    boolean NOT NULL,
  note        text,
  "createdAt" bigint NOT NULL,
  UNIQUE ("wallId", "authorId")
);

CREATE INDEX IF NOT EXISTS topo_verifications_wall_idx
  ON public.topo_verifications ("wallId");

-- ---------------------------------------------------------------------------
-- Hazards
-- ---------------------------------------------------------------------------
--
-- `resolvedBy` is not in the COMMUNITY_IMPL.md §1.6 sketch; it is added here
-- because that section requires resolution to be "recorded, not erased", and a
-- resolution with no author on it is not a record of anything. It also lets the
-- UI distinguish "the reporter withdrew this" from "the topo owner says it is
-- dealt with", which are very different claims.
CREATE TABLE IF NOT EXISTS public.topo_hazards (
  id           text PRIMARY KEY,
  "wallId"     text NOT NULL REFERENCES public.walls(id) ON DELETE CASCADE,
  "routeId"    text REFERENCES public.routes(id) ON DELETE CASCADE,
  "authorId"   text NOT NULL,
  severity     text NOT NULL,          -- 'note' | 'caution' | 'danger'
  body         text NOT NULL,
  "resolvedAt" bigint,
  "resolvedBy" text,
  "createdAt"  bigint NOT NULL
);

ALTER TABLE public.topo_hazards ADD COLUMN IF NOT EXISTS "resolvedBy" text;

CREATE INDEX IF NOT EXISTS topo_hazards_wall_idx ON public.topo_hazards ("wallId");
CREATE INDEX IF NOT EXISTS topo_hazards_route_idx ON public.topo_hazards ("routeId");

-- `severity` carries no CHECK constraint, for the same reason `accessState`
-- does not (phase 2): a client running ahead of this schema must not have its
-- write rejected for using a value the server has not heard of. The client
-- parses defensively and treats an unknown severity as the most serious it
-- understands, so an unrecognised value fails loud rather than silent.

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------
ALTER TABLE public.route_grade_opinions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.topo_verifications   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.topo_hazards         ENABLE ROW LEVEL SECURITY;

-- SELECT: visible wherever the underlying topo is visible, plus its owner and
-- admins (so an owner can see feedback on a topo that is still pending).
DROP POLICY IF EXISTS route_grade_opinions_select ON public.route_grade_opinions;
CREATE POLICY route_grade_opinions_select ON public.route_grade_opinions FOR SELECT
  USING (
    public.is_route_public("routeId")
    OR public.is_admin()
    OR EXISTS (
      SELECT 1 FROM public.routes r
      WHERE r.id = "routeId" AND r."ownerId" = (auth.uid())::text
    )
  );

DROP POLICY IF EXISTS topo_verifications_select ON public.topo_verifications;
CREATE POLICY topo_verifications_select ON public.topo_verifications FOR SELECT
  USING (
    public.is_wall_public("wallId")
    OR public.is_admin()
    OR EXISTS (
      SELECT 1 FROM public.walls w
      WHERE w.id = "wallId" AND w."ownerId" = (auth.uid())::text
    )
  );

DROP POLICY IF EXISTS topo_hazards_select ON public.topo_hazards;
CREATE POLICY topo_hazards_select ON public.topo_hazards FOR SELECT
  USING (
    public.is_wall_public("wallId")
    OR public.is_admin()
    OR EXISTS (
      SELECT 1 FROM public.walls w
      WHERE w.id = "wallId" AND w."ownerId" = (auth.uid())::text
    )
  );

-- INSERT: anyone signed in, but only ever in their own name. This is the whole
-- of the "no approval queue" promise — there is no state column to gate on.
DROP POLICY IF EXISTS route_grade_opinions_insert ON public.route_grade_opinions;
CREATE POLICY route_grade_opinions_insert ON public.route_grade_opinions FOR INSERT
  WITH CHECK ("authorId" = (auth.uid())::text);

DROP POLICY IF EXISTS topo_verifications_insert ON public.topo_verifications;
CREATE POLICY topo_verifications_insert ON public.topo_verifications FOR INSERT
  WITH CHECK ("authorId" = (auth.uid())::text);

DROP POLICY IF EXISTS topo_hazards_insert ON public.topo_hazards;
CREATE POLICY topo_hazards_insert ON public.topo_hazards FOR INSERT
  WITH CHECK ("authorId" = (auth.uid())::text);

-- UPDATE / DELETE: the author of the statement, and admins. NOT the topo
-- owner.
--
-- This is the load-bearing asymmetry of the whole phase. The topo owner can
-- delete their topo, their photo and their lines, because those are theirs.
-- They CANNOT delete a hazard report someone else filed on it, because the
-- one thing a climber must be able to trust is that "no hazards reported"
-- means nobody reported one — not that the owner tidied it away
-- (COMMUNITY_PLAN.md C-12: safety content is never silently removed).
--
-- Postgres RLS is row-level only, so there is no way to let the owner update
-- `resolvedAt` while forbidding them `body`. Resolution therefore goes through
-- the SECURITY DEFINER RPC below, which can touch exactly two columns. Same
-- reasoning as G-1.
DROP POLICY IF EXISTS route_grade_opinions_author_write ON public.route_grade_opinions;
CREATE POLICY route_grade_opinions_author_write ON public.route_grade_opinions
  FOR UPDATE USING ("authorId" = (auth.uid())::text OR public.is_admin())
  WITH CHECK ("authorId" = (auth.uid())::text OR public.is_admin());

DROP POLICY IF EXISTS route_grade_opinions_author_delete ON public.route_grade_opinions;
CREATE POLICY route_grade_opinions_author_delete ON public.route_grade_opinions
  FOR DELETE USING ("authorId" = (auth.uid())::text OR public.is_admin());

DROP POLICY IF EXISTS topo_verifications_author_write ON public.topo_verifications;
CREATE POLICY topo_verifications_author_write ON public.topo_verifications
  FOR UPDATE USING ("authorId" = (auth.uid())::text OR public.is_admin())
  WITH CHECK ("authorId" = (auth.uid())::text OR public.is_admin());

DROP POLICY IF EXISTS topo_verifications_author_delete ON public.topo_verifications;
CREATE POLICY topo_verifications_author_delete ON public.topo_verifications
  FOR DELETE USING ("authorId" = (auth.uid())::text OR public.is_admin());

DROP POLICY IF EXISTS topo_hazards_author_write ON public.topo_hazards;
CREATE POLICY topo_hazards_author_write ON public.topo_hazards
  FOR UPDATE USING ("authorId" = (auth.uid())::text OR public.is_admin())
  WITH CHECK ("authorId" = (auth.uid())::text OR public.is_admin());

DROP POLICY IF EXISTS topo_hazards_author_delete ON public.topo_hazards;
CREATE POLICY topo_hazards_author_delete ON public.topo_hazards
  FOR DELETE USING ("authorId" = (auth.uid())::text OR public.is_admin());

-- ---------------------------------------------------------------------------
-- resolve_hazard() — the owner's only write on someone else's hazard report
-- ---------------------------------------------------------------------------
--
-- Sets `resolvedAt`/`resolvedBy` and nothing else. Callable by the hazard's
-- author (withdrawing their own report), the owner of the topo it sits on
-- (saying it has been dealt with), or an admin. The body is never touched, so
-- the report itself survives its own resolution and stays readable.
CREATE OR REPLACE FUNCTION public.resolve_hazard(hazard text, resolved boolean)
  RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  uid text := (auth.uid())::text;
  allowed boolean;
BEGIN
  IF uid IS NULL THEN
    RAISE EXCEPTION 'not signed in';
  END IF;

  SELECT h."authorId" = uid
         OR public.is_admin()
         OR EXISTS (SELECT 1 FROM public.walls w
                    WHERE w.id = h."wallId" AND w."ownerId" = uid)
    INTO allowed
    FROM public.topo_hazards h
   WHERE h.id = hazard;

  IF allowed IS NULL THEN
    RAISE EXCEPTION 'no such hazard';
  END IF;
  IF NOT allowed THEN
    RAISE EXCEPTION 'not permitted to resolve this hazard';
  END IF;

  UPDATE public.topo_hazards
     SET "resolvedAt" = CASE WHEN resolved
                             THEN (extract(epoch FROM now()) * 1000)::bigint
                             ELSE NULL END,
         "resolvedBy" = CASE WHEN resolved THEN uid ELSE NULL END
   WHERE id = hazard;
END;
$$;

REVOKE ALL ON FUNCTION public.resolve_hazard(text, boolean) FROM public;
GRANT EXECUTE ON FUNCTION public.resolve_hazard(text, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_route_public(text) TO authenticated, anon;
