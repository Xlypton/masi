-- ============================================================================
-- Lookup indexes for the columns the sync engine and RLS actually filter on.
--
-- WHY THIS EXISTS: as of 2026-08-06 the live project (ref mnaipcqbkqzffgvxpato)
-- had exactly TEN indexes — one primary key per table and nothing else.
-- Verified with:
--   SELECT tablename, indexname FROM pg_indexes WHERE schemaname='public';
-- Postgres creates an index for a PRIMARY KEY and for a UNIQUE constraint, but
-- NOT for a foreign key or for any other column, so every filter below was a
-- sequential scan.
--
-- That is not just a query-shape nicety here, because "ownerId" is on the RLS
-- path: every policy in this database reads
--   USING ("ownerId" = (auth.uid())::text)
-- so the predicate is evaluated for EVERY row of EVERY access, by every user,
-- on every table — not only when the client happens to filter by owner. The
-- client then filters by it again explicitly: `SyncRemote.fetchOwnRows` issues
-- `.eq('ownerId', uid)` against all nine sync tables (now concurrently), so a
-- single pull is nine owner-scoped reads at once.
--
-- SCOPE — deliberately only what the client actually queries. Adding an index
-- is not free: every INSERT/UPDATE maintains it, and the push path writes far
-- more often than the pull path reads. Derived by reading every filter in
-- `lib/features/backup/data/sync_remote.dart`:
--
--   .eq('ownerId', uid)              -> all 9 sync tables    (fetchOwnRows + RLS)
--   .eq('visibility', 'shared')      -> walls, ascents       (fetchSharedTopos /
--                                                             fetchSharedAscents)
--   .inFilter('wallId', wallIds)     -> photos, routes, comments, likes
--   .inFilter('id', ids)             -> already the primary key, skipped
--
-- Columns NOT indexed on purpose, because nothing queries them remotely even
-- though the LOCAL Drift schema does index them: sectors."areaId",
-- walls."sectorId", photos."parentPhotoId", routes."photoId",
-- comments/likes."ascentId", ascents."wallId"/"routeId". Remotely those rows
-- are all reached by primary key via `.inFilter('id', ...)`.
--
-- NOT PARTIAL ON "deletedAt", unlike the local Drift indexes. This is the one
-- place the two schemas must differ: local reads are live-rows-only and pair
-- every FK filter with `deletedAt IS NULL`, but the sync engine pulls
-- TOMBSTONES ON PURPOSE — a soft-delete has to propagate to the other devices.
-- A `WHERE "deletedAt" IS NULL` index would silently not apply to the very
-- queries this migration exists to speed up.
--
-- Idempotent (`IF NOT EXISTS` throughout), so it is safe to re-run and safe to
-- apply to a project provisioned fresh from ../schema.sql.
--
-- APPLIED to live and VERIFIED on 2026-08-06 via the Management API
-- (POST https://api.supabase.com/v1/projects/{ref}/database/query), re-reading
-- pg_indexes afterwards to confirm all fifteen landed.
-- ============================================================================

-- --------------------------------------------------------------------------
-- "ownerId" — the RLS predicate on every table, and fetchOwnRows' filter.
-- --------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_profiles_owner ON public.profiles ("ownerId");
CREATE INDEX IF NOT EXISTS idx_areas_owner    ON public.areas    ("ownerId");
CREATE INDEX IF NOT EXISTS idx_sectors_owner  ON public.sectors  ("ownerId");
CREATE INDEX IF NOT EXISTS idx_walls_owner    ON public.walls    ("ownerId");
CREATE INDEX IF NOT EXISTS idx_photos_owner   ON public.photos   ("ownerId");
CREATE INDEX IF NOT EXISTS idx_routes_owner   ON public.routes   ("ownerId");
CREATE INDEX IF NOT EXISTS idx_ascents_owner  ON public.ascents  ("ownerId");
CREATE INDEX IF NOT EXISTS idx_comments_owner ON public.comments ("ownerId");
CREATE INDEX IF NOT EXISTS idx_likes_owner    ON public.likes    ("ownerId");

-- --------------------------------------------------------------------------
-- "visibility" — the cross-owner discovery queries. PARTIAL on 'shared'
-- because that is the only value ever selected on (the default is 'private',
-- which will be the overwhelming majority of rows), so the index stays
-- proportional to what is actually shared rather than to the whole table.
-- --------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_walls_shared
  ON public.walls ("visibility") WHERE "visibility" = 'shared';
CREATE INDEX IF NOT EXISTS idx_ascents_shared
  ON public.ascents ("visibility") WHERE "visibility" = 'shared';

-- --------------------------------------------------------------------------
-- "wallId" — the wall-keyed children fetchSharedTopos pulls in one wave.
-- --------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_photos_wall   ON public.photos   ("wallId");
CREATE INDEX IF NOT EXISTS idx_routes_wall   ON public.routes   ("wallId");
CREATE INDEX IF NOT EXISTS idx_comments_wall ON public.comments ("wallId");
CREATE INDEX IF NOT EXISTS idx_likes_wall    ON public.likes    ("wallId");
