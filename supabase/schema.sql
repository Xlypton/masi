-- ============================================================================
-- ClimbTopo P0 backend: row-level cloud sync + topo sharing
-- Run ONCE: Supabase Dashboard -> SQL Editor -> paste this whole file -> Run.
-- Safe to re-run (idempotent: IF NOT EXISTS + DROP POLICY IF EXISTS).
--
-- Column names are camelCase (quoted) to match the Flutter app's Drift
-- `toJson()` keys 1:1, so sync pushes/pulls need no field mapping. The
-- `topo-photos` Storage bucket already exists (created via the API).
--
-- Authorization model:
--   * You have full CRUD over rows where "ownerId" = your auth uid.
--   * Every authenticated user can READ (only) rows that belong to a
--     published topo (a Wall with "visibility" = 'shared', plus its photos,
--     routes, and ancestor sector/area). Non-owners can never write them.
-- ============================================================================

-- ---------- TABLES ----------
CREATE TABLE IF NOT EXISTS public.areas (
  "id" TEXT PRIMARY KEY NOT NULL,
  "createdAt" BIGINT NOT NULL,
  "updatedAt" BIGINT NOT NULL,
  "deletedAt" BIGINT,
  "remoteId" TEXT,
  "dirty" BOOLEAN NOT NULL DEFAULT false,
  "ownerId" TEXT,
  "name" TEXT NOT NULL,
  "description" TEXT,
  "latitude" DOUBLE PRECISION,
  "longitude" DOUBLE PRECISION
);

CREATE TABLE IF NOT EXISTS public.sectors (
  "id" TEXT PRIMARY KEY NOT NULL,
  "createdAt" BIGINT NOT NULL,
  "updatedAt" BIGINT NOT NULL,
  "deletedAt" BIGINT,
  "remoteId" TEXT,
  "dirty" BOOLEAN NOT NULL DEFAULT false,
  "ownerId" TEXT,
  "areaId" TEXT NOT NULL,
  "name" TEXT NOT NULL,
  "sortOrder" INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS public.walls (
  "id" TEXT PRIMARY KEY NOT NULL,
  "createdAt" BIGINT NOT NULL,
  "updatedAt" BIGINT NOT NULL,
  "deletedAt" BIGINT,
  "remoteId" TEXT,
  "dirty" BOOLEAN NOT NULL DEFAULT false,
  "ownerId" TEXT,
  "sectorId" TEXT NOT NULL,
  "name" TEXT NOT NULL,
  "sortOrder" INTEGER NOT NULL DEFAULT 0,
  "visibility" TEXT NOT NULL DEFAULT 'private'
);

CREATE TABLE IF NOT EXISTS public.photos (
  "id" TEXT PRIMARY KEY NOT NULL,
  "createdAt" BIGINT NOT NULL,
  "updatedAt" BIGINT NOT NULL,
  "deletedAt" BIGINT,
  "remoteId" TEXT,
  "dirty" BOOLEAN NOT NULL DEFAULT false,
  "ownerId" TEXT,
  "wallId" TEXT NOT NULL,
  "localPath" TEXT NOT NULL,
  "kind" TEXT NOT NULL,
  "width" INTEGER NOT NULL,
  "height" INTEGER NOT NULL,
  "parentPhotoId" TEXT,
  "cropXpct" DOUBLE PRECISION,
  "cropWidthPct" DOUBLE PRECISION
);

CREATE TABLE IF NOT EXISTS public.routes (
  "id" TEXT PRIMARY KEY NOT NULL,
  "createdAt" BIGINT NOT NULL,
  "updatedAt" BIGINT NOT NULL,
  "deletedAt" BIGINT,
  "remoteId" TEXT,
  "dirty" BOOLEAN NOT NULL DEFAULT false,
  "ownerId" TEXT,
  "wallId" TEXT NOT NULL,
  "photoId" TEXT NOT NULL,
  "number" INTEGER NOT NULL,
  "name" TEXT,
  "gradeSystem" TEXT,
  "gradeRaw" TEXT,
  "gradeSortKey" DOUBLE PRECISION,
  "style" TEXT,
  "description" TEXT,
  "colorIndex" INTEGER NOT NULL DEFAULT 0,
  "pointsJson" TEXT NOT NULL DEFAULT '[]',
  "symbolsJson" TEXT NOT NULL DEFAULT '[]',
  "sortOrder" INTEGER NOT NULL DEFAULT 0,
  "visible" BOOLEAN NOT NULL DEFAULT true
);

-- ---------- PRIVILEGES (RLS still restricts WHICH rows) ----------
GRANT USAGE ON SCHEMA public TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE
  ON public.areas, public.sectors, public.walls, public.photos, public.routes
  TO authenticated;

-- ---------- ENABLE ROW LEVEL SECURITY ----------
ALTER TABLE public.areas   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sectors ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.walls   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.photos  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.routes  ENABLE ROW LEVEL SECURITY;

-- ---------- ROW POLICIES ----------
-- Owner: full CRUD on own rows. Shared: SELECT-only on rows of a published topo.
-- (Permissive policies OR together, so SELECT = own OR shared; writes = own only.)

-- areas
DROP POLICY IF EXISTS "areas_owner_all"     ON public.areas;
DROP POLICY IF EXISTS "areas_shared_select" ON public.areas;
CREATE POLICY "areas_owner_all" ON public.areas FOR ALL TO authenticated
  USING ("ownerId" = auth.uid()::text) WITH CHECK ("ownerId" = auth.uid()::text);
CREATE POLICY "areas_shared_select" ON public.areas FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.walls w
    JOIN public.sectors s ON w."sectorId" = s."id"
    WHERE s."areaId" = areas."id" AND w."visibility" = 'shared'
  ));

-- sectors
DROP POLICY IF EXISTS "sectors_owner_all"     ON public.sectors;
DROP POLICY IF EXISTS "sectors_shared_select" ON public.sectors;
CREATE POLICY "sectors_owner_all" ON public.sectors FOR ALL TO authenticated
  USING ("ownerId" = auth.uid()::text) WITH CHECK ("ownerId" = auth.uid()::text);
CREATE POLICY "sectors_shared_select" ON public.sectors FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.walls w
    WHERE w."sectorId" = sectors."id" AND w."visibility" = 'shared'
  ));

-- walls
DROP POLICY IF EXISTS "walls_owner_all"     ON public.walls;
DROP POLICY IF EXISTS "walls_shared_select" ON public.walls;
CREATE POLICY "walls_owner_all" ON public.walls FOR ALL TO authenticated
  USING ("ownerId" = auth.uid()::text) WITH CHECK ("ownerId" = auth.uid()::text);
CREATE POLICY "walls_shared_select" ON public.walls FOR SELECT TO authenticated
  USING ("visibility" = 'shared');

-- photos
DROP POLICY IF EXISTS "photos_owner_all"     ON public.photos;
DROP POLICY IF EXISTS "photos_shared_select" ON public.photos;
CREATE POLICY "photos_owner_all" ON public.photos FOR ALL TO authenticated
  USING ("ownerId" = auth.uid()::text) WITH CHECK ("ownerId" = auth.uid()::text);
CREATE POLICY "photos_shared_select" ON public.photos FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.walls w
    WHERE w."id" = photos."wallId" AND w."visibility" = 'shared'
  ));

-- routes
DROP POLICY IF EXISTS "routes_owner_all"     ON public.routes;
DROP POLICY IF EXISTS "routes_shared_select" ON public.routes;
CREATE POLICY "routes_owner_all" ON public.routes FOR ALL TO authenticated
  USING ("ownerId" = auth.uid()::text) WITH CHECK ("ownerId" = auth.uid()::text);
CREATE POLICY "routes_shared_select" ON public.routes FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.walls w
    WHERE w."id" = routes."wallId" AND w."visibility" = 'shared'
  ));

-- ---------- STORAGE POLICIES (bucket: topo-photos) ----------
-- Private objects live under "<uid>/..."; shared (published) photos under "shared/...".
DROP POLICY IF EXISTS "topo_photos_own_all"      ON storage.objects;
DROP POLICY IF EXISTS "topo_photos_shared_read"  ON storage.objects;
DROP POLICY IF EXISTS "topo_photos_shared_write" ON storage.objects;
DROP POLICY IF EXISTS "topo_photos_shared_upd"   ON storage.objects;

CREATE POLICY "topo_photos_own_all" ON storage.objects FOR ALL TO authenticated
  USING (bucket_id = 'topo-photos' AND (storage.foldername(name))[1] = auth.uid()::text)
  WITH CHECK (bucket_id = 'topo-photos' AND (storage.foldername(name))[1] = auth.uid()::text);

CREATE POLICY "topo_photos_shared_read" ON storage.objects FOR SELECT TO authenticated
  USING (bucket_id = 'topo-photos' AND (storage.foldername(name))[1] = 'shared');

CREATE POLICY "topo_photos_shared_write" ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'topo-photos' AND (storage.foldername(name))[1] = 'shared');

CREATE POLICY "topo_photos_shared_upd" ON storage.objects FOR UPDATE TO authenticated
  USING (bucket_id = 'topo-photos' AND (storage.foldername(name))[1] = 'shared')
  WITH CHECK (bucket_id = 'topo-photos' AND (storage.foldername(name))[1] = 'shared');

-- ============================================================================
-- Community features: comments, likes, ascents (personal logbook)
-- ============================================================================

-- ---------- TABLES ----------
CREATE TABLE IF NOT EXISTS public.comments (
  "id" TEXT PRIMARY KEY NOT NULL,
  "createdAt" BIGINT NOT NULL,
  "updatedAt" BIGINT NOT NULL,
  "deletedAt" BIGINT,
  "remoteId" TEXT,
  "dirty" BOOLEAN NOT NULL DEFAULT false,
  "ownerId" TEXT,
  "wallId" TEXT NOT NULL,
  "body" TEXT NOT NULL,
  "authorName" TEXT
);

CREATE TABLE IF NOT EXISTS public.likes (
  "id" TEXT PRIMARY KEY NOT NULL,
  "createdAt" BIGINT NOT NULL,
  "updatedAt" BIGINT NOT NULL,
  "deletedAt" BIGINT,
  "remoteId" TEXT,
  "dirty" BOOLEAN NOT NULL DEFAULT false,
  "ownerId" TEXT,
  "wallId" TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS public.ascents (
  "id" TEXT PRIMARY KEY NOT NULL,
  "createdAt" BIGINT NOT NULL,
  "updatedAt" BIGINT NOT NULL,
  "deletedAt" BIGINT,
  "remoteId" TEXT,
  "dirty" BOOLEAN NOT NULL DEFAULT false,
  "ownerId" TEXT,
  "routeId" TEXT NOT NULL,
  "wallId" TEXT NOT NULL,
  "climbedAt" BIGINT NOT NULL,
  "style" TEXT NOT NULL,
  "notes" TEXT,
  "gradeOpinion" TEXT
);

-- ---------- PRIVILEGES (RLS still restricts WHICH rows) ----------
GRANT SELECT, INSERT, UPDATE, DELETE
  ON public.comments, public.likes, public.ascents
  TO authenticated;

-- ---------- ENABLE ROW LEVEL SECURITY ----------
ALTER TABLE public.comments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.likes    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ascents  ENABLE ROW LEVEL SECURITY;

-- ---------- ROW POLICIES ----------
-- comments
DROP POLICY IF EXISTS "comments_owner_all"     ON public.comments;
DROP POLICY IF EXISTS "comments_shared_select" ON public.comments;
CREATE POLICY "comments_owner_all" ON public.comments FOR ALL TO authenticated
  USING ("ownerId" = auth.uid()::text) WITH CHECK ("ownerId" = auth.uid()::text);
CREATE POLICY "comments_shared_select" ON public.comments FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.walls w
    WHERE w."id" = comments."wallId" AND w."visibility" = 'shared'
  ));

-- likes
DROP POLICY IF EXISTS "likes_owner_all"     ON public.likes;
DROP POLICY IF EXISTS "likes_shared_select" ON public.likes;
CREATE POLICY "likes_owner_all" ON public.likes FOR ALL TO authenticated
  USING ("ownerId" = auth.uid()::text) WITH CHECK ("ownerId" = auth.uid()::text);
CREATE POLICY "likes_shared_select" ON public.likes FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.walls w
    WHERE w."id" = likes."wallId" AND w."visibility" = 'shared'
  ));

-- ascents (private logbook — owner-only, no shared select)
DROP POLICY IF EXISTS "ascents_owner_all" ON public.ascents;
CREATE POLICY "ascents_owner_all" ON public.ascents FOR ALL TO authenticated
  USING ("ownerId" = auth.uid()::text) WITH CHECK ("ownerId" = auth.uid()::text);
