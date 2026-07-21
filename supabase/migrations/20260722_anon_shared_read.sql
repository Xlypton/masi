-- ============================================================================
-- Feature #15 (Wave 1) — anon shareable topo landing. Apply once in the
-- Supabase SQL editor against the already-live database (Dashboard -> SQL
-- Editor -> paste this whole file -> Run).
--
-- Purpose: today only `authenticated` clients can read a published (shared)
-- topo (see the `*_shared_select` policies in ../schema.sql). This migration
-- adds the `anon`-role mirror of those same SELECT-only policies so a
-- signed-OUT visitor hitting a shared topo landing link (anon Supabase key,
-- no session) can read: the shared wall + its photos/routes, its ancestor
-- sector/area, its Storage photo objects under the `shared/` folder, and the
-- shared wall's OWNER's profile row (so a display name can be shown). This
-- intentionally exposes shared topos + their authors' display names to
-- unauthenticated clients — every policy below is SELECT-only and every
-- non-wall policy is gated through an EXISTS on a wall with
-- "visibility" = 'shared' (own row from a NON-shared wall stays invisible
-- to anon; anon can never write anything). The `topo-photos` Storage bucket
-- stays PRIVATE — this only adds a scoped SELECT policy on storage.objects,
-- it does not flip the bucket to public.
--
-- Delta only (the full DDL lives in ../schema.sql, kept in sync for
-- fresh-run correctness). Safe to re-run: every policy change is a
-- DROP POLICY IF EXISTS + CREATE POLICY pair.
--
-- Follow-up fix: soft-deleting a wall sets "deletedAt" but does NOT reset
-- "visibility" back off 'shared', so a deleted-but-formerly-shared wall's
-- photos/routes/sectors/areas were still readable via these tables' own
-- shared-select policies, which gated their EXISTS-a-shared-wall subquery
-- only on w."visibility" = 'shared' (missing the deletedAt check the wall's
-- OWN row policy already applies to itself). Every such policy below now
-- also requires w."deletedAt" IS NULL — both the anon policies added by
-- this migration AND their pre-existing authenticated mirrors (added here
-- too, as re-runnable DROP+CREATE pairs, so applying this migration tightens
-- both roles at once).
-- ============================================================================

-- ---------- PRIVILEGES (RLS still restricts WHICH rows) ----------
-- Table-level grants are a precondition to RLS: without a table-level SELECT
-- grant, PostgREST returns "permission denied" for the anon role before RLS
-- policies are even consulted. authenticated already has these grants (see
-- schema.sql); anon has none yet, so it's added here, scoped to SELECT only.
GRANT USAGE ON SCHEMA public TO anon;
GRANT SELECT
  ON public.areas, public.sectors, public.walls, public.photos, public.routes, public.profiles
  TO anon;

-- ---------- ROW POLICIES ----------

-- areas
DROP POLICY IF EXISTS "areas_anon_shared_select" ON public.areas;
CREATE POLICY "areas_anon_shared_select" ON public.areas FOR SELECT TO anon
  USING (EXISTS (
    SELECT 1 FROM public.walls w
    JOIN public.sectors s ON w."sectorId" = s."id"
    WHERE s."areaId" = areas."id" AND w."visibility" = 'shared' AND w."deletedAt" IS NULL
  ));

DROP POLICY IF EXISTS "areas_shared_select" ON public.areas;
CREATE POLICY "areas_shared_select" ON public.areas FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.walls w
    JOIN public.sectors s ON w."sectorId" = s."id"
    WHERE s."areaId" = areas."id" AND w."visibility" = 'shared' AND w."deletedAt" IS NULL
  ));

-- sectors
DROP POLICY IF EXISTS "sectors_anon_shared_select" ON public.sectors;
CREATE POLICY "sectors_anon_shared_select" ON public.sectors FOR SELECT TO anon
  USING (EXISTS (
    SELECT 1 FROM public.walls w
    WHERE w."sectorId" = sectors."id" AND w."visibility" = 'shared' AND w."deletedAt" IS NULL
  ));

DROP POLICY IF EXISTS "sectors_shared_select" ON public.sectors;
CREATE POLICY "sectors_shared_select" ON public.sectors FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.walls w
    WHERE w."sectorId" = sectors."id" AND w."visibility" = 'shared' AND w."deletedAt" IS NULL
  ));

-- walls
DROP POLICY IF EXISTS "walls_anon_shared_select" ON public.walls;
CREATE POLICY "walls_anon_shared_select" ON public.walls FOR SELECT TO anon
  USING ("visibility" = 'shared' AND "deletedAt" IS NULL);

-- photos
DROP POLICY IF EXISTS "photos_anon_shared_select" ON public.photos;
CREATE POLICY "photos_anon_shared_select" ON public.photos FOR SELECT TO anon
  USING (EXISTS (
    SELECT 1 FROM public.walls w
    WHERE w."id" = photos."wallId" AND w."visibility" = 'shared' AND w."deletedAt" IS NULL
  ));

DROP POLICY IF EXISTS "photos_shared_select" ON public.photos;
CREATE POLICY "photos_shared_select" ON public.photos FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.walls w
    WHERE w."id" = photos."wallId" AND w."visibility" = 'shared' AND w."deletedAt" IS NULL
  ));

-- routes
DROP POLICY IF EXISTS "routes_anon_shared_select" ON public.routes;
CREATE POLICY "routes_anon_shared_select" ON public.routes FOR SELECT TO anon
  USING (EXISTS (
    SELECT 1 FROM public.walls w
    WHERE w."id" = routes."wallId" AND w."visibility" = 'shared' AND w."deletedAt" IS NULL
  ));

DROP POLICY IF EXISTS "routes_shared_select" ON public.routes;
CREATE POLICY "routes_shared_select" ON public.routes FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.walls w
    WHERE w."id" = routes."wallId" AND w."visibility" = 'shared' AND w."deletedAt" IS NULL
  ));

-- profiles (gated: only the display name of an owner who has >=1 shared wall
-- is exposed to anon — NOT a blanket "true" like profiles_any_select is for
-- authenticated clients)
DROP POLICY IF EXISTS "profiles_anon_shared_select" ON public.profiles;
CREATE POLICY "profiles_anon_shared_select" ON public.profiles FOR SELECT TO anon
  USING (EXISTS (
    SELECT 1 FROM public.walls w
    WHERE w."ownerId" = profiles."id" AND w."visibility" = 'shared' AND w."deletedAt" IS NULL
  ));

-- ---------- STORAGE POLICIES (bucket: topo-photos) ----------
-- Bucket stays PRIVATE (no UPDATE storage.buckets ... public = true). This
-- SELECT-only policy lets anon read objects under the "shared/" folder only
-- (mirrors topo_photos_shared_read's authenticated version) — anon gets no
-- insert/update/delete policy on storage.objects.
DROP POLICY IF EXISTS "topo_photos_anon_shared_read" ON storage.objects;
CREATE POLICY "topo_photos_anon_shared_read" ON storage.objects FOR SELECT TO anon
  USING (bucket_id = 'topo-photos' AND (storage.foldername(name))[1] = 'shared');
