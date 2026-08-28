-- Face Layout System (local schema v15 -> v16).
--
-- Three additive things, all idempotent, none of which rewrites a single
-- existing row:
--
--   1. Per-face capture sensors and the manual layout pin on `photos`, and
--      the authored baseline stroke on `walls`.
--   2. `route_lines` — the same climb drawn on another photo of the same rock.
--   3. NOTHING about route numbering. The client renumbers each wall's routes
--      per-wall in its own v16 migration and pushes the result through the
--      ordinary sync path, so there is deliberately no server-side renumber
--      here: two of them would race, and the server has no way to break the
--      tie that the client's deterministic ordering already settles.
--
-- The live project is shared and NOT branched, so applying this is effectively
-- merging it: every agent and the user's real data see it immediately. That is
-- safe here precisely because it is additive — a build that predates v16 keeps
-- working against these columns, since every one of them is nullable and no
-- existing constraint changes.

-- ---------- 1. walls: the authored baseline ----------
ALTER TABLE public.walls
  ADD COLUMN IF NOT EXISTS "baselineJson" TEXT;

-- ---------- 1. photos: per-face capture sensors + the manual pin ----------
ALTER TABLE public.photos
  ADD COLUMN IF NOT EXISTS "captureLatitude" DOUBLE PRECISION,
  ADD COLUMN IF NOT EXISTS "captureLongitude" DOUBLE PRECISION,
  ADD COLUMN IF NOT EXISTS "captureAccuracyMeters" DOUBLE PRECISION,
  ADD COLUMN IF NOT EXISTS "captureBearingDegrees" DOUBLE PRECISION,
  ADD COLUMN IF NOT EXISTS "layoutPinnedT" DOUBLE PRECISION;

-- ---------- 2. route_lines ----------
CREATE TABLE IF NOT EXISTS public.route_lines (
  "id" TEXT PRIMARY KEY NOT NULL,
  "createdAt" BIGINT NOT NULL,
  "updatedAt" BIGINT NOT NULL,
  "deletedAt" BIGINT,
  "remoteId" TEXT,
  "dirty" BOOLEAN NOT NULL DEFAULT false,
  "ownerId" TEXT,
  "routeId" TEXT NOT NULL,
  "photoId" TEXT NOT NULL,
  "pointsJson" TEXT NOT NULL DEFAULT '[]',
  "symbolsJson" TEXT NOT NULL DEFAULT '[]'
);

-- Matches the local partial indexes. Live rows only, so a tombstoned line
-- never blocks the same climb being redrawn on the same photo later.
CREATE UNIQUE INDEX IF NOT EXISTS route_lines_route_photo_live
  ON public.route_lines ("routeId", "photoId") WHERE "deletedAt" IS NULL;
CREATE INDEX IF NOT EXISTS route_lines_photo_live
  ON public.route_lines ("photoId") WHERE "deletedAt" IS NULL;
CREATE INDEX IF NOT EXISTS route_lines_route_live
  ON public.route_lines ("routeId") WHERE "deletedAt" IS NULL;

GRANT SELECT, INSERT, UPDATE, DELETE ON public.route_lines TO authenticated;
ALTER TABLE public.route_lines ENABLE ROW LEVEL SECURITY;

-- Same two-policy shape as `routes`: the owner does anything to their own,
-- and anyone may READ a line belonging to a published topo. The shared-select
-- predicate walks route -> wall rather than trusting anything on the line
-- itself, so publishing state has exactly one home.
DROP POLICY IF EXISTS "route_lines_owner_all"     ON public.route_lines;
DROP POLICY IF EXISTS "route_lines_shared_select" ON public.route_lines;
CREATE POLICY "route_lines_owner_all" ON public.route_lines FOR ALL TO authenticated
  USING ("ownerId" = auth.uid()::text) WITH CHECK ("ownerId" = auth.uid()::text);
CREATE POLICY "route_lines_shared_select" ON public.route_lines FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.routes r
    JOIN public.walls w ON w."id" = r."wallId"
    WHERE r."id" = route_lines."routeId" AND w."visibility" = 'shared'
  ));
