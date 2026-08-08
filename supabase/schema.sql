-- ============================================================================
-- Masi P0 backend: row-level cloud sync + topo sharing
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
  "longitude" DOUBLE PRECISION,
  -- Community editing phase 2 / R-2 (applied live 2026-08-06; delta in
  -- supabase/migrations/2026-08-06_community_phase2_access.sql). Access and
  -- closure state, inheriting down Area -> Sector -> Wall. See AccessColumns
  -- in lib/core/db/tables.dart.
  "accessState" TEXT,
  "accessNote" TEXT
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
  "sortOrder" INTEGER NOT NULL DEFAULT 0,
  "accessState" TEXT,
  "accessNote" TEXT
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
  "visibility" TEXT NOT NULL DEFAULT 'private',
  -- Local app schema v4 (see lib/core/db/tables.dart's Walls table):
  -- captured automatically from a freshly-picked photo's EXIF GPS tags
  -- (core/location/photo_gps.dart), so a topo can be placed on the
  -- Community map without the user entering coordinates by hand. `Wall`'s
  -- drift-generated toJson()/fromJson() already round-trip these two keys
  -- like every other column, so no sync-payload code change was needed —
  -- only this schema addition.
  "latitude" DOUBLE PRECISION,
  "longitude" DOUBLE PRECISION,
  "accessState" TEXT,
  "accessNote" TEXT
);

-- ---------- LIVE-DATABASE MIGRATION (P0 backend already applied) ----------
-- The block above is CREATE TABLE IF NOT EXISTS, so it no-ops against the
-- walls table already applied live (see MEMORY.md: "P0 backend
-- applied+verified live"). The two new columns above will NOT reach that
-- live table until this ALTER TABLE is run against it explicitly:
--
--   ALTER TABLE public.walls
--     ADD COLUMN IF NOT EXISTS "latitude" DOUBLE PRECISION,
--     ADD COLUMN IF NOT EXISTS "longitude" DOUBLE PRECISION;
--
-- NOT run here / by any agent — the user must run this against the live
-- Supabase project (Dashboard -> SQL Editor) themselves before wall
-- coordinates will sync.

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
  "cropWidthPct" DOUBLE PRECISION,
  "sortOrder" INTEGER NOT NULL DEFAULT 0,
  "isPrimary" BOOLEAN NOT NULL DEFAULT false
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
  "visible" BOOLEAN NOT NULL DEFAULT true,
  "betaVideoUrl" TEXT,
  "styleTagsJson" TEXT,
  "stars" INTEGER
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
DROP POLICY IF EXISTS "topo_photos_shared_delete" ON storage.objects;

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

-- W-2. Without this there is NO delete path for the shared prefix at all: the
-- three policies above cover SELECT/INSERT/UPDATE, and `topo_photos_own_all` is
-- scoped to `foldername[1] = auth.uid()`, which never matches `shared/...`. So
-- `SyncRemote.removeSharedPhoto` could not remove anything — and did not fail
-- either, because a Storage delete that RLS filtered to nothing returns HTTP
-- 200 and an empty list. Verified against the live project on 2026-08-08.
--
-- Deletion cannot be done server-side: Supabase's `storage.protect_delete()`
-- trigger raises on any direct DELETE from storage.objects, so RLS on this
-- policy is the only lever. See supabase/migrations/2026-08-08_w2_shared_photo_delete.sql.
CREATE POLICY "topo_photos_shared_delete" ON storage.objects FOR DELETE TO authenticated
  USING (
    bucket_id = 'topo-photos'
    AND (storage.foldername(name))[1] = 'shared'
    AND (
      public.is_admin()
      OR EXISTS (
        SELECT 1
          FROM public.photos p
          JOIN public.walls w ON w.id = p."wallId"
         WHERE p.id = regexp_replace(storage.filename(objects.name), '\.[^.]*$', '')
           AND w."ownerId" = (auth.uid())::text
      )
    )
  );

-- ============================================================================
-- Community features: comments, likes, ascents (personal logbook, optionally
-- shared publicly — Feature #12)
-- ============================================================================

-- ---------- TABLES ----------
-- ascents is created first in this section: comments/likes below carry an
-- "ascentId" FK into it, and a forward reference to a not-yet-created table
-- would fail Postgres's CREATE TABLE on a fresh run.
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
  "gradeOpinion" TEXT,
  "visibility" TEXT NOT NULL DEFAULT 'private',
  "authorName" TEXT
);

CREATE TABLE IF NOT EXISTS public.comments (
  "id" TEXT PRIMARY KEY NOT NULL,
  "createdAt" BIGINT NOT NULL,
  "updatedAt" BIGINT NOT NULL,
  "deletedAt" BIGINT,
  "remoteId" TEXT,
  "dirty" BOOLEAN NOT NULL DEFAULT false,
  "ownerId" TEXT,
  "wallId" TEXT,
  "ascentId" TEXT REFERENCES public.ascents("id"),
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
  "wallId" TEXT,
  "ascentId" TEXT REFERENCES public.ascents("id")
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
DROP POLICY IF EXISTS "comments_owner_all"          ON public.comments;
DROP POLICY IF EXISTS "comments_shared_select"       ON public.comments;
DROP POLICY IF EXISTS "comments_ascent_shared_select" ON public.comments;
CREATE POLICY "comments_owner_all" ON public.comments FOR ALL TO authenticated
  USING ("ownerId" = auth.uid()::text) WITH CHECK ("ownerId" = auth.uid()::text);
CREATE POLICY "comments_shared_select" ON public.comments FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.walls w
    WHERE w."id" = comments."wallId" AND w."visibility" = 'shared'
  ));
CREATE POLICY "comments_ascent_shared_select" ON public.comments FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.ascents a
    WHERE a."id" = comments."ascentId" AND a."visibility" = 'shared'
  ));

-- likes
DROP POLICY IF EXISTS "likes_owner_all"          ON public.likes;
DROP POLICY IF EXISTS "likes_shared_select"       ON public.likes;
DROP POLICY IF EXISTS "likes_ascent_shared_select" ON public.likes;
CREATE POLICY "likes_owner_all" ON public.likes FOR ALL TO authenticated
  USING ("ownerId" = auth.uid()::text) WITH CHECK ("ownerId" = auth.uid()::text);
CREATE POLICY "likes_shared_select" ON public.likes FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.walls w
    WHERE w."id" = likes."wallId" AND w."visibility" = 'shared'
  ));
CREATE POLICY "likes_ascent_shared_select" ON public.likes FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.ascents a
    WHERE a."id" = likes."ascentId" AND a."visibility" = 'shared'
  ));

-- ascents (private logbook by default; owner can opt a row into "shared" to
-- publish it to the Community feed)
DROP POLICY IF EXISTS "ascents_owner_all"     ON public.ascents;
DROP POLICY IF EXISTS "ascents_shared_select" ON public.ascents;
CREATE POLICY "ascents_owner_all" ON public.ascents FOR ALL TO authenticated
  USING ("ownerId" = auth.uid()::text) WITH CHECK ("ownerId" = auth.uid()::text);
-- NOTE: this is the P0 form, and it is NOT the policy that should end up live.
-- The community phase-1 migration introduces `is_wall_public(text)` and swaps
-- the sharing policies over to it; this one is hardened the same way at the end
-- of this file (see "SHARED ASCENTS MUST NOT OUTLIVE THEIR TOPO"). Left bare
-- here only so this section still runs before that function exists.
CREATE POLICY "ascents_shared_select" ON public.ascents FOR SELECT TO authenticated
  USING ("visibility" = 'shared');

-- ============================================================================
-- Profiles: editable, synced display name (Feature #18)
-- ============================================================================
--
-- Unlike every other table above, "id" here is NOT a caller-generated UUID —
-- it IS the owning user's auth uid (so "id" = "ownerId" always). This is a
-- deliberately WIDE-OPEN read policy relative to every other table: a
-- display name must be resolvable for ANY user shown anywhere in the app
-- (a shared topo's owner, an ascent's author, a comment's author, ...), not
-- just rows the requester owns or that hang off a shared wall/ascent — so
-- SELECT has no scoping condition at all beyond "authenticated". Writes stay
-- owner-only, same as every other table's owner policy.

-- ---------- TABLES ----------
CREATE TABLE IF NOT EXISTS public.profiles (
  "id" TEXT PRIMARY KEY NOT NULL,
  "createdAt" BIGINT NOT NULL,
  "updatedAt" BIGINT NOT NULL,
  "deletedAt" BIGINT,
  "remoteId" TEXT,
  "dirty" BOOLEAN NOT NULL DEFAULT false,
  "ownerId" TEXT,
  "displayName" TEXT,
  -- Applied live 2026-08-06; delta in
  -- supabase/migrations/2026-08-06_profiles_avatar_url.sql. Either an
  -- https:// avatar URL or an inline data:image/...;base64 URL — see
  -- `tables.dart`'s Profiles.avatarUrl.
  "avatarUrl" TEXT
);

-- ---------- PRIVILEGES (RLS still restricts WHICH rows) ----------
GRANT SELECT, INSERT, UPDATE, DELETE
  ON public.profiles
  TO authenticated;

-- ---------- ENABLE ROW LEVEL SECURITY ----------
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

-- ---------- ROW POLICIES ----------
DROP POLICY IF EXISTS "profiles_owner_write" ON public.profiles;
DROP POLICY IF EXISTS "profiles_any_select"  ON public.profiles;

-- Owner: full CRUD on their own row (matched by "id", which for this table
-- IS the owning uid — "ownerId" is kept in lockstep by the client but "id"
-- is the authoritative check here so a row can never be write-locked out by
-- a null/mismatched "ownerId").
CREATE POLICY "profiles_owner_write" ON public.profiles FOR ALL TO authenticated
  USING ("id" = auth.uid()::text) WITH CHECK ("id" = auth.uid()::text);

-- Any authenticated user can READ any profile row — permissive, no owner or
-- shared-topo check — so a display name can be resolved for whoever authored
-- whatever is currently on screen.
CREATE POLICY "profiles_any_select" ON public.profiles FOR SELECT TO authenticated
  USING (true);

-- ============================================================================
-- Full-snapshot cloud backup: public.backups
-- ============================================================================
--
-- This table was ABSENT from the live project until it was created by hand
-- on 2026-08-04 (Management API DDL against project ref
-- mnaipcqbkqzffgvxpato) and verified against information_schema +
-- pg_policies. It is now APPLIED and LIVE in this exact shape. The delta
-- script for existing projects is `migrations/20260804_backups_table.sql`,
-- kept byte-equivalent in effect to what was applied.
--
-- ONE ROW PER USER, keyed by the auth uid: `SupabaseBackupRemote.fetchSnapshot`
-- (`lib/features/backup/data/backup_remote.dart`) reads it with
-- `.eq('user_id', uid).maybeSingle()`, and `upsertSnapshot` overwrites in
-- place by primary key.
--
-- Column names are snake_case here, UNLIKE every camelCase table above. That
-- is not an inconsistency to "fix": those tables' columns must match Drift's
-- `toJson()` keys 1:1 because the row-level sync engine pushes rows
-- unfiltered, whereas these four keys are written by hand in
-- `SupabaseBackupRemote.upsertSnapshot` and renaming one would break the
-- client. The whole Drift snapshot (including its own camelCase
-- `schemaVersion` stamp) lives inside the `snapshot` JSONB blob.
CREATE TABLE IF NOT EXISTS public.backups (
  -- TEXT, compared via `(auth.uid())::text` by the policy below — matching
  -- the convention every OTHER policy in this database uses (e.g.
  -- `areas."ownerId" = (auth.uid())::text`), not the UUID-vs-uid() direct
  -- comparison this table used before the live shape was verified.
  user_id text PRIMARY KEY NOT NULL,
  -- `BackupRepository.exportSnapshot()`'s map, verbatim:
  -- `{schemaVersion: <int>, tables: {profiles: [...], areas: [...], ...}}`.
  snapshot jsonb NOT NULL,
  -- Duplicates the blob's own `schemaVersion` so the ceiling check can be
  -- applied without parsing megabytes of JSON. Intentionally NULLABLE: a
  -- missing or non-int value reads back as "no claim was made" and stays
  -- importable (see `RemoteSnapshot.schemaVersion`), matching
  -- `BackupRepository.assertRestorable` exactly — making this NOT NULL would
  -- reintroduce the hard-cast failure mode that nullability exists to avoid.
  schema_version integer,
  -- ISO-8601 UTC, written by the client on every upsert
  -- (`DateTime.now().toUtc().toIso8601String()`) and parsed back with
  -- `DateTime.parse`. DEFAULT now() only backstops rows inserted without an
  -- explicit value; the client always supplies one.
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- ---------- PRIVILEGES (RLS still restricts WHICH rows) ----------
GRANT SELECT, INSERT, UPDATE, DELETE
  ON public.backups
  TO authenticated;

-- ---------- ENABLE ROW LEVEL SECURITY ----------
-- Without this the snapshot blob — every topo, route and ascent the user
-- owns, private ones included — is readable by any authenticated user.
ALTER TABLE public.backups ENABLE ROW LEVEL SECURITY;

-- ---------- ROW POLICIES ----------
-- Owner-only, in BOTH directions and for every verb: there is no shared or
-- public read path for a full-library snapshot, unlike the sync tables where
-- a published wall grants SELECT to others.
DROP POLICY IF EXISTS "backups_owner_all" ON public.backups;
CREATE POLICY "backups_owner_all" ON public.backups FOR ALL TO authenticated
  USING (user_id = (auth.uid())::text) WITH CHECK (user_id = (auth.uid())::text);


-- ============================================================================
-- LOOKUP INDEXES (delta 2026-08-06 — see migrations/20260806_sync_lookup_indexes.sql)
--
-- Kept here so a project provisioned fresh from this file comes up identical
-- to live, which is the schema-drift bug class #64/#65/#72 exists to prevent.
-- Postgres indexes a PRIMARY KEY and a UNIQUE constraint automatically and
-- nothing else — not foreign keys — so before this delta every one of these
-- filters was a sequential scan.
--
-- "ownerId" is the RLS predicate on EVERY table
-- (USING ("ownerId" = (auth.uid())::text)), so it is evaluated on every row of
-- every access regardless of what the client asked for; `fetchOwnRows` then
-- filters on it explicitly across all nine sync tables at once.
--
-- These are deliberately NOT partial on "deletedAt", unlike their local Drift
-- counterparts in lib/core/db/tables.dart: the sync engine pulls TOMBSTONES ON
-- PURPOSE (a soft delete has to reach the other devices), so a
-- `WHERE "deletedAt" IS NULL` index would not apply to these queries at all.
-- See the migration file for the full derivation, including which columns are
-- left unindexed and why.
-- ============================================================================

CREATE INDEX IF NOT EXISTS idx_profiles_owner ON public.profiles ("ownerId");
CREATE INDEX IF NOT EXISTS idx_areas_owner    ON public.areas    ("ownerId");
CREATE INDEX IF NOT EXISTS idx_sectors_owner  ON public.sectors  ("ownerId");
CREATE INDEX IF NOT EXISTS idx_walls_owner    ON public.walls    ("ownerId");
CREATE INDEX IF NOT EXISTS idx_photos_owner   ON public.photos   ("ownerId");
CREATE INDEX IF NOT EXISTS idx_routes_owner   ON public.routes   ("ownerId");
CREATE INDEX IF NOT EXISTS idx_ascents_owner  ON public.ascents  ("ownerId");
CREATE INDEX IF NOT EXISTS idx_comments_owner ON public.comments ("ownerId");
CREATE INDEX IF NOT EXISTS idx_likes_owner    ON public.likes    ("ownerId");

CREATE INDEX IF NOT EXISTS idx_walls_shared
  ON public.walls ("visibility") WHERE "visibility" = 'shared';
CREATE INDEX IF NOT EXISTS idx_ascents_shared
  ON public.ascents ("visibility") WHERE "visibility" = 'shared';

CREATE INDEX IF NOT EXISTS idx_photos_wall   ON public.photos   ("wallId");
CREATE INDEX IF NOT EXISTS idx_routes_wall   ON public.routes   ("wallId");
CREATE INDEX IF NOT EXISTS idx_comments_wall ON public.comments ("wallId");
CREATE INDEX IF NOT EXISTS idx_likes_wall    ON public.likes    ("wallId");

-- ===========================================================================
-- COMMUNITY EDITING, PHASE 1 (applied live 2026-08-06; delta in
-- supabase/migrations/2026-08-06_community_phase1_foundations.sql).
--
-- See COMMUNITY_PLAN.md §0 for why moderation state must NOT be a column on
-- `walls`: the sync engine re-pushes whole rows with local-wins-ties LWW and
-- no outbox (D-4), so the owner's next push would silently revert a
-- moderator's decision. These tables are readable by the client and writable
-- only through the Management API / SECURITY DEFINER RPCs.
-- ===========================================================================

CREATE TABLE IF NOT EXISTS public.admins (
  "userId"    TEXT PRIMARY KEY NOT NULL,
  role        TEXT NOT NULL DEFAULT 'admin',
  "createdAt" BIGINT NOT NULL
);

CREATE TABLE IF NOT EXISTS public.wall_moderation (
  "wallId"              TEXT PRIMARY KEY NOT NULL REFERENCES public.walls(id) ON DELETE CASCADE,
  state                 TEXT NOT NULL,  -- draft|pending|published|rejected|withdrawn|removed
  "submittedAt"         BIGINT,
  "reviewedAt"          BIGINT,
  "reviewerId"          TEXT,
  "rejectionReason"     TEXT,
  "withdrawRequestedAt" BIGINT,
  "updatedAt"           BIGINT NOT NULL
);

CREATE TABLE IF NOT EXISTS public.moderation_log (
  id           TEXT PRIMARY KEY NOT NULL,
  "actorId"    TEXT NOT NULL,
  action       TEXT NOT NULL,
  "targetType" TEXT NOT NULL,
  "targetId"   TEXT NOT NULL,
  reason       TEXT,
  "createdAt"  BIGINT NOT NULL
);

-- `is_admin()` and `is_wall_public(text)` plus the RLS policy swap live in the
-- migration file; every `*_shared_select` policy now reads through
-- `is_wall_public(...)` rather than a bare `visibility = 'shared'` check.

-- ===========================================================================
-- COMMUNITY EDITING, PHASE 4 — community facts (applied live 2026-08-06;
-- delta in supabase/migrations/2026-08-06_community_phase4_facts.sql).
--
-- The layer that is deliberately NOT gated behind the owner's approval, nor
-- behind the admin queue (R-1, COMMUNITY_PLAN.md §3.2): the topo is the
-- author's work, but the grade, whether the drawing matches the rock, and
-- whether there is a loose block over the belay are facts about the world.
--
-- Anyone signed in may write, but only in their own name, and only the AUTHOR
-- of a statement (plus admins) may edit or delete it. In particular the topo
-- owner CANNOT delete a hazard report on their own topo — they can mark it
-- resolved via the `resolve_hazard` RPC, which is recorded rather than erased
-- (C-12). RLS is row-level only, which is why resolution needs an RPC instead
-- of a policy: there is no way to permit one column and forbid another.
--
-- Mirrored locally in Drift (schemaVersion 14) as a pull-only cache; writes go
-- straight to PostgREST, never through the sync engine, so none of these is in
-- `syncTableNames`.
-- ===========================================================================

CREATE TABLE IF NOT EXISTS public.route_grade_opinions (
  id             TEXT PRIMARY KEY NOT NULL,
  "routeId"      TEXT NOT NULL REFERENCES public.routes(id) ON DELETE CASCADE,
  "authorId"     TEXT NOT NULL,
  "gradeSystem"  TEXT NOT NULL,
  "gradeRaw"     TEXT NOT NULL,
  "gradeSortKey" DOUBLE PRECISION,
  "createdAt"    BIGINT NOT NULL,
  UNIQUE ("routeId", "authorId")
);

CREATE TABLE IF NOT EXISTS public.topo_verifications (
  id          TEXT PRIMARY KEY NOT NULL,
  "wallId"    TEXT NOT NULL REFERENCES public.walls(id) ON DELETE CASCADE,
  "authorId"  TEXT NOT NULL,
  accurate    BOOLEAN NOT NULL,
  note        TEXT,
  "createdAt" BIGINT NOT NULL,
  UNIQUE ("wallId", "authorId")
);

CREATE TABLE IF NOT EXISTS public.topo_hazards (
  id           TEXT PRIMARY KEY NOT NULL,
  "wallId"     TEXT NOT NULL REFERENCES public.walls(id) ON DELETE CASCADE,
  "routeId"    TEXT REFERENCES public.routes(id) ON DELETE CASCADE,
  "authorId"   TEXT NOT NULL,
  severity     TEXT NOT NULL,
  body         TEXT NOT NULL,
  "resolvedAt" BIGINT,
  "resolvedBy" TEXT,
  "createdAt"  BIGINT NOT NULL
);

-- `is_route_public(text)`, the twelve RLS policies and the `resolve_hazard`
-- RPC live in the migration file.

-- ---------------------------------------------------------------------------
-- Community editing, Phase 5 — withdrawal cooldown & delete protection (C-3)
-- See supabase/migrations/2026-08-06_community_phase5_withdrawal.sql
-- ---------------------------------------------------------------------------
--
-- No new tables: the cooldown rides `wall_moderation."withdrawRequestedAt"`,
-- which has existed since Phase 1 and was already being read by
-- `is_wall_public()`. Phase 5 added the two ends that were missing — the RPCs
-- that can SET it (`request_withdrawal`, `cancel_withdrawal`) and the triggers
-- that stop an owner reaching the same outcome by a route the visibility
-- predicate does not guard.
--
-- Three routes had to be closed, not one. All reach the same end state on a
-- published topo, and an owner had all three:
--   visibility  → 'private'
--   deletedAt   → now
--   accessState → 'sensitive'   (also on the SECTOR or AREA above it, since
--                                Phase 2 made suppression inherit downward)
--
-- The triggers REVERT rather than raise, and bump `updatedAt` past the client's
-- value so the next pull's LWW settles it. That is forced by the sync engine:
-- `upsertOwnRows` batches per table with one try/catch each, so a RAISE on one
-- wall row would fail the whole `walls` push and the client would retry the
-- same poisoned batch forever. The migration file carries the full argument.

-- ---------------------------------------------------------------------------
-- Community editing, Phase 6a — version history (C-8)
-- See supabase/migrations/2026-08-07_community_phase6a_versions.sql
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.topo_versions (
  id           TEXT PRIMARY KEY,
  "wallId"     TEXT NOT NULL REFERENCES public.walls(id) ON DELETE CASCADE,
  "actorId"    TEXT,
  payload      JSONB NOT NULL,
  "routeCount" INT NOT NULL DEFAULT 0,
  "createdAt"  BIGINT NOT NULL,
  "updatedAt"  BIGINT NOT NULL
);

-- `payload` holds the wall + its routes and photo METADATA as JSON. Never
-- photo bytes — which is what keeps the storage cost of this negligible (the
-- live snapshots measure 2-3 KB each).
--
-- Written only by `snapshot_topo()`, called from six statement-level triggers
-- (one per table per event; Postgres refuses a transition table on a trigger
-- with more than one event). Statement-level, not row-level, so a batched sync
-- push produces one snapshot attempt per table rather than one per row.
--
-- Three rules make the history actually usable, and all three are load-bearing:
--
--   * A draft is never snapshotted. Private topos are the owner's scratch
--     space and recording every keystroke of them would be the most expensive
--     thing in this schema (C-1).
--   * An UNCHANGED payload writes nothing. There is no outbox (D-4), so an
--     ordinary background sync re-UPDATEs every owned row even when the user
--     has touched nothing; without this a phone left open would push the last
--     real edit past the fifty-version cap within hours.
--   * A burst by the SAME actor within five minutes extends its version in
--     place; a DIFFERENT actor always opens a new one. That second half is
--     what guarantees a vandal cannot overwrite the payload recording how the
--     topo looked before they arrived.
--
-- `revert_topo(wall, version)` is admin-only, snapshots the current state
-- first (so a revert is itself revertible), soft-deletes routes created since
-- the snapshot, and bumps every `updatedAt` to GREATEST(local, now) + 1 so the
-- owner's client pulls the revert instead of re-pushing its vandalised copy.

-- ---------------------------------------------------------------------------
-- Community editing, Phase 6b — reporting (C-7)
-- See supabase/migrations/2026-08-07_community_phase6b_reports.sql
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.content_reports (
  id           TEXT PRIMARY KEY,
  "wallId"     TEXT NOT NULL REFERENCES public.walls(id) ON DELETE CASCADE,
  "routeId"    TEXT REFERENCES public.routes(id) ON DELETE CASCADE,
  "reporterId" TEXT NOT NULL,
  reason       TEXT NOT NULL,   -- inaccurate|unsafe|duplicate|access|inappropriate|not_yours
  body         TEXT,
  status       TEXT NOT NULL DEFAULT 'open',   -- open|upheld|dismissed
  "resolvedAt" BIGINT,
  "resolverId" TEXT,
  resolution   TEXT,
  "createdAt"  BIGINT NOT NULL
);

-- SELECT is the reporter or an admin. NOT the topo's owner — several reasons
-- are accusations ABOUT the owner, and handing the accused the reporter's
-- identity is how a community learns that reporting invites retaliation. Note
-- this is the opposite arrangement from `topo_hazards`, deliberately: a hazard
-- is a public safety warning everyone must see, a report is a private
-- complaint about the content.
--
-- No INSERT policy either, so `report_content` is the only way in and its two
-- rate limits cannot be bypassed: one OPEN report per person per topo per
-- reason (a second tap returns the first report's id), and twenty per person
-- per day.
--
-- `moderation_reports()` sorts `reason = 'unsafe'` to the FRONT regardless of
-- age. That is C-12's "escalated, not queued" in one ORDER BY term rather than
-- a separate workflow.
--
-- `resolve_report` records upheld vs dismissed rather than a flat "closed",
-- because phase 8's trust levels need both directions.

-- ---------------------------------------------------------------------------
-- Community editing, Phase 7a — suggested edits, METADATA slice (C-5)
-- See supabase/migrations/2026-08-07_community_phase7_suggestions.sql
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.topo_edit_suggestions (
  id              TEXT PRIMARY KEY,
  "wallId"        TEXT NOT NULL REFERENCES public.walls(id) ON DELETE CASCADE,
  "routeId"       TEXT REFERENCES public.routes(id) ON DELETE CASCADE,
  -- Phase 7b: the photo a proposed LINE was drawn on. NULL for every metadata
  -- suggestion, required for `route.geometry` — points are percent-space
  -- fractions of one specific image, so a line with no photo names nothing.
  "photoId"       TEXT REFERENCES public.photos(id) ON DELETE CASCADE,
  "authorId"      TEXT NOT NULL,
  kind            TEXT NOT NULL,   -- topo.metadata | route.metadata | route.geometry
  patch           JSONB NOT NULL,
  note            TEXT,
  "baseVersionId" TEXT REFERENCES public.topo_versions(id) ON DELETE SET NULL,
  status          TEXT NOT NULL DEFAULT 'open',  -- open|accepted|rejected
  "resolvedAt"    BIGINT,
  "resolverId"    TEXT,
  "resolution"    TEXT,
  "createdAt"     BIGINT NOT NULL
);

-- Non-owners still have ZERO write access to any content table. A suggestion
-- is a PATCH here; when the owner accepts, their own client applies it to
-- their own rows and syncs normally. No new write authority, no sync-engine
-- change, no merge algorithm.
--
-- SELECT is the author, the target topo's owner, and admins. The owner IS
-- included, unlike `content_reports` — a report is a complaint about the owner
-- and naming the reporter invites retaliation; a suggestion is an offer of
-- help only the owner can act on, and attribution is most of the reward.
--
-- `suggestion_fields()` is the whitelist and it is short. GRADE is absent on
-- purpose: phase 4 already lets anyone state a grade opinion with no approval
-- at all and renders the consensus beside the owner's, which is strictly
-- better than asking permission to disagree about a grade. `accessState` is
-- absent because phase 6b's "access problem" report reaches a moderator rather
-- than waiting on the owner who may not have noticed. `stars` is absent
-- because a rating is an opinion, not a fact to be corrected.
--
-- A patch mixing an allowed and a forbidden field is refused WHOLE, never
-- partly applied — a suggestion that silently drops half of what its author
-- wrote is worse than one that is turned down.
--
-- `suggestions_for_me().isStale` needs TWO tests, not one. Comparing the
-- pinned revision against the newest misses the common case, because
-- `snapshot_topo` coalesces: an owner editing within five minutes extends the
-- current version in place, so its id stays newest while its contents change
-- underneath the suggestion. The second test — was the pinned version touched
-- after the suggestion was filed — closes that.

-- ---------------------------------------------------------------------------
-- Community editing, Phase 8a — trust levels (C-4)
-- See supabase/migrations/2026-08-07_community_phase8_trust.sql
-- ---------------------------------------------------------------------------
--
-- No new tables. `trust_level(uid)` is COMPUTED from rows that already exist,
-- so there is no counter to drift and nothing to backfill.
--
-- Two levels: 0 = everything goes to the queue, 1 = publishes immediately.
-- Earned at three approvals; lost entirely by ONE upheld report. The asymmetry
-- is deliberate — wrongly trusting somebody costs unreviewed bad content on a
-- climbing topo, wrongly distrusting them costs a moderator one read.
--
-- THE CRITERION IS `reviewerId IS NOT NULL`, NOT `reviewedAt`. Phase 1b's
-- trigger stamped `reviewedAt` on every wall it promoted during the
-- behaviour-neutral backfill, so eight live topos carry a review timestamp no
-- moderator ever produced; a live query with the `reviewedAt` criterion read
-- the project owner as fully trusted on the strength of them. `reviewerId` is
-- set by exactly one thing — `review_topo`, to the admin who pressed the
-- button — and is deliberately left NULL by auto-approval, so nothing an
-- account publishes on its own recognisance feeds back into its own standing.
--
-- `ensure_wall_moderation` is rewritten once more (phases 1b, 3, 5, 8a): a
-- trusted owner's share lands in `published` with `reviewedAt` stamped and
-- `reviewerId` NULL; everyone else still lands in `pending`.

-- ---------------------------------------------------------------------------
-- Community editing, Phase 7b — GEOMETRY suggestions (C-5b)
-- See supabase/migrations/2026-08-07_community_phase7b_geometry.sql
-- ---------------------------------------------------------------------------
--
-- Adds the `route.geometry` kind (fields `points` and `symbols`) and the
-- `"photoId"` column above. Three of §C-5b's four requirements are enforced
-- here; the fourth (a propose-mode canvas and a visual diff) is client-side.
--
--  * PINNED TO A PHOTO. `suggest_edit` refuses a geometry proposal unless
--    `photo_id` is a LIVE photo of the same wall, and — when a route is also
--    named — unless that route lives on that same photo. Replacing a line
--    pinned to photo A with points drawn on photo B is the meaningless case
--    §C-5b opens with, and it looks correct until the owner accepts it.
--  * THE DATABASE ID, NEVER THE DOMAIN ID. `"routeId"` is `routes.id`, the
--    text uuid. `TopoRoute.id` is an int the client reassigns 1..n on every
--    load and never crosses the wire. A NULL `"routeId"` means "here is a
--    line this topo does not have", which is the more common contribution.
--  * BOUNDS. `geometry_patch_error(patch)` returns NULL or the reason: 2..200
--    points, ≤64 markers, every coordinate inside [0,1]. It checks that a
--    marker's `type` is a STRING and deliberately does NOT check it against a
--    vocabulary — the client owns that list and already drops what it does not
--    recognise, so duplicating the enum here would block a new marker type
--    behind a migration for no safety gained.
--
-- `suggest_edit` was DROPPED and recreated rather than replaced: adding a
-- defaulted parameter creates an overload, and the 5-argument call every
-- existing client makes would then match both signatures and be refused as
-- ambiguous (42725). `suggestions_for_me` likewise, because CREATE OR REPLACE
-- cannot change a function's OUT parameters.
--
-- `suggestions_for_me` gains a THIRD staleness test. Phase 7a's two both ask
-- "has the topo changed since this was written"; geometry adds a question they
-- cannot answer — is the thing this line was drawn ON still there? A proposal
-- pinned to a deleted photo, or targeting a deleted route, is not merely stale:
-- it cannot be rendered or applied at all. Note this is NOT the "primary photo
-- changed" test §C-5b's wording suggests. A topo can carry several photos, each
-- with its own independent routes, so a line on the second photo is perfectly
-- current while the first is primary; what matters is whether the PINNED photo
-- is still live.
--
-- What this deliberately does not add: a way to propose DELETING a route. A
-- suggestion is an offer of help the owner may accept in one tap, and "accept"
-- must never be the gesture that removes work.

-- ---------------------------------------------------------------------------
-- Community editing, Phase 8b — duplicate topos (C-6)
-- See supabase/migrations/2026-08-07_community_phase8b_duplicates.sql
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.topo_alternates (
  "wallId"      TEXT PRIMARY KEY NOT NULL REFERENCES public.walls(id) ON DELETE CASCADE,
  "canonicalId" TEXT NOT NULL REFERENCES public.walls(id) ON DELETE CASCADE,
  "linkedBy"    TEXT NOT NULL,
  note          TEXT,
  "linkedAt"    BIGINT NOT NULL,
  CONSTRAINT topo_alternates_not_self CHECK ("wallId" <> "canonicalId")
);

-- `content_reports` gains "duplicateOfId" (see the migration); the CREATE TABLE
-- above it is IF NOT EXISTS, so the ALTER in the migration is what lands on the
-- live database and this comment is what tells a fresh run the column exists.
--
-- THE WHOLE OF THIS PHASE IS ADDITIVE, and that is the property to preserve.
-- Nothing here removes, hides, downranks or reassigns a topo. §C-6 opens by
-- ruling out resolution-by-deletion outright — two people photographing the
-- same boulder in different light is useful, and the second submission is often
-- the better one. Drop `topo_alternates` entirely and every topo is exactly as
-- public, as owned and as editable as it was.
--
--  * DETECT (§C-6.1). `nearby_published_topos(lat, lng, radius_m, exclude)`
--    is shown to a submitter BEFORE they submit — "3 topos already exist here".
--    Plain haversine over a bounding box rather than PostGIS: no geography
--    column exists, 50 m is a tiny radius, and an extension would be the more
--    expensive decision. `radius_m` is CLAMPED to 2000 because the parameter is
--    caller-supplied and this is otherwise a scan of every published wall on
--    earth; the longitude half-window floors cos(lat) at 0.01 so a topo near a
--    pole cannot widen the box without bound. Each row is filtered through
--    `is_wall_public`, so it can only ever return topos the caller could
--    already find in the feed.
--  * NAME (§C-6.4). `content_reports."duplicateOfId"` carries WHICH topo is
--    duplicated. A report that says only "duplicate" makes an admin go and find
--    the other one by hand, which is how a queue stops being worked. The named
--    topo gets the same `is_wall_public` treatment as the reported one — naming
--    a private wall id would otherwise confirm it exists. `duplicateOfId` joins
--    the dedup key, so two reports naming two DIFFERENT topos are two claims
--    rather than one suppressed by the other.
--  * LINK (§C-6.4). `link_alternate(duplicate, canonical)` is admin-only and
--    reversible by `unlink_alternate(wall)`. Alternates, never a merge that
--    destroys a side (§3.3).
--
-- THE INVARIANT: a canonical is never itself an alternate. There are no chains,
-- so a group is one `WHERE "canonicalId" = me` and the client can group a feed
-- in one pass with no recursion. `link_alternate` maintains it in BOTH
-- directions, because an admin can link in either order — it re-points to the
-- canonical's own head if it has one, and adopts anything that was pointing at
-- the topo just demoted. Linking a pair that is already linked the other way
-- round returns the existing head rather than flipping it: the alternative is
-- deleting a link to write its mirror image, which changes no reader's view.
--
-- `report_content` was DROPPED and recreated for its fifth parameter, and
-- `moderation_reports` because CREATE OR REPLACE cannot change OUT parameters —
-- the same trap phase 7b hit. `moderation_reports` now also returns
-- `alreadyLinked`, so an admin is not offered a link on a pair that has one.
--
-- §C-6.3 (ranking) needs NO server change: every signal it uses is already
-- collected. It is a pure client-side function — see
-- lib/features/community/domain/topo_rank.dart, and Open Question 3.

-- ===========================================================================
-- COMMUNITY EDITING - C-11 (stalled topos) and C-5d (material changes)
-- See supabase/migrations/2026-08-08_c11_abandoned_topos.sql
-- and supabase/migrations/2026-08-08_c5d_material_change_notices.sql
-- ===========================================================================
--
-- C-11 adds NO table. `abandoned_topos(inactive_days, limit_count)` is a
-- read-only admin RPC over rows that already exist: a published topo with a
-- pending suggestion older than the cutoff whose owner has done nothing since.
-- The second half of that sentence is the whole design - without it an owner
-- who simply disagrees with one suggestion is indistinguishable from one who
-- deleted the app, and an admin list that cannot tell them apart is one nobody
-- reads. It reports and stops: no transfer of ownership, no auto-application of
-- suggestions, because both are irreversible acts against a real person's work.
--
-- C-5d adds the one table below. Approval is a ONE-TIME gate (C-5c), so the
-- review queue is bypassable by the obvious route - submit something clean, get
-- approved, then replace the content. A structural change to a PUBLISHED topo
-- therefore posts a notice and BLOCKS NOTHING: publication stays instant, the
-- owner is never interrupted, an admin simply gets to see that a published topo
-- changed shape.

CREATE TABLE IF NOT EXISTS public.material_change_notices (
  id            text PRIMARY KEY,
  "wallId"      text NOT NULL,
  "actorId"     text,
  "changesJson" jsonb  NOT NULL DEFAULT '{}'::jsonb,
  "changeCount" int    NOT NULL DEFAULT 1,
  "firstAt"     bigint NOT NULL,
  "lastAt"      bigint NOT NULL,
  "resolvedAt"  bigint,
  "resolvedBy"  text
);

-- THE ANTI-FLOOD GUARANTEE, and it is an index rather than application logic
-- so two concurrent writes to the same wall cannot both find "no open notice".
-- A vandal making fifty edits produces ONE row with changeCount 50, which is
-- the difference between a queue that gets read and one that gets abandoned.
CREATE UNIQUE INDEX IF NOT EXISTS material_change_notices_open_wall
  ON public.material_change_notices ("wallId") WHERE "resolvedAt" IS NULL;
CREATE INDEX IF NOT EXISTS material_change_notices_last_at
  ON public.material_change_notices ("lastAt" DESC);

ALTER TABLE public.material_change_notices ENABLE ROW LEVEL SECURITY;

-- Admins only, and NO write policy at all: every write goes through a SECURITY
-- DEFINER function so the notice and its audit-log entry cannot diverge. Owners
-- deliberately cannot read this - a notice is a moderator's working note about a
-- change that was already allowed to happen, and showing it to the person who
-- made the change turns "we keep an eye on this" into "you are under suspicion".
DROP POLICY IF EXISTS material_change_notices_admin_read
  ON public.material_change_notices;
CREATE POLICY material_change_notices_admin_read
  ON public.material_change_notices FOR SELECT TO authenticated
  USING (public.is_admin());

GRANT SELECT ON public.material_change_notices TO authenticated;

-- The detector lives in `snapshot_topo`, which the C-5d migration RE-APPLIES:
-- that function already had to read the previous version's payload to decide
-- whether anything changed at all, so C-5d costs one extra comparison on a
-- write that was already known to have altered the topo. Two consequences are
-- load-bearing and easy to lose in a later edit:
--
--   * The comparison filters to LIVE rows first. `topo_snapshot` projects
--     `deletedAt` rather than filtering on it, so a soft-deleted route leaves
--     the array length identical - a route-count check would report no change
--     for the single most important case this exists to catch.
--   * The call is wrapped in an exception block. A notice is a nice-to-have for
--     a moderator; the write in progress is a climber's work. Verified by fault
--     injection on 2026-08-08: with a detector that throws on every call, the
--     edit still lands and the version history is still cut.
--
-- What counts as material stops deliberately short: routes removed, a line
-- cleared, a route re-anchored to another photo, the cover photo swapped or its
-- file replaced. Renames, grades, descriptions, added routes and nudged lines
-- are ordinary work on a topo somebody owns. The failure mode of this feature is
-- not "we missed one", it is "the queue filled with normal editing".

-- ===========================================================================
-- SHARED ASCENTS MUST NOT OUTLIVE THEIR TOPO
-- See supabase/migrations/2026-08-08_shared_ascent_wall_visibility.sql
-- ===========================================================================
--
-- Re-applies `ascents_shared_select` in its hardened form. It has to live down
-- here rather than in the P0 section above because it depends on
-- `is_wall_public(text)`, which the community phase-1 migration creates.
--
-- The P0 rule was `visibility = 'shared'` and nothing else, while every table an
-- ascent POINTS AT is gated on `is_wall_public(...)`. That asymmetry caused two
-- separate defects, both observed on live on 2026-08-08:
--
--   * A LEAK PAST A MODERATION DECISION. The row carries wallId, routeId,
--     climbedAt, style, notes and gradeOpinion, so a topo an admin had just
--     taken down - or one whose owner marked it access-sensitive precisely so it
--     would stop being findable - stayed traceable straight off PostgREST. The
--     takedown removed the topo, its routes, its photos and its photo bytes
--     (W-2) and left the ascents pointing at them.
--
--   * PERMANENTLY BROKEN SYNC, FOR EVERY USER. `fetchSharedAscents` fetches the
--     ascents first and their ancestor chain afterwards, in separate queries,
--     each RLS-filtered on its own table. The ancestors correctly refused, so
--     the ascent arrived with no route and no wall - and `ascents.routeId` and
--     `ascents.wallId` are enforced NOT NULL FKs locally. The import deferred
--     the row and reported `shared rows deferred (parent row missing)`, which
--     the user saw as a red "Couldn't sync - Retry" banner on the feed that
--     could NEVER heal: the parent was soft-deleted server-side and was never
--     going to be returned.
--
-- `ascents_owner_all` is untouched, so whoever logged the climb keeps full
-- access to their own row whatever happened to the topo. This narrows only what
-- OTHER people can see, which is what `visibility` always meant. Measured before
-- applying: 2 live shared ascents, exactly 1 of them pointing at a wall that is
-- no longer public.
--
-- The client half is `consistentSharedAscentBatch` in sync_remote.dart, and it
-- is not redundant: these are two queries against a live database, so a topo
-- withdrawn BETWEEN them produces the same orphan with no bug at either end.

DROP POLICY IF EXISTS "ascents_shared_select" ON public.ascents;
CREATE POLICY "ascents_shared_select" ON public.ascents FOR SELECT TO authenticated
  USING ("visibility" = 'shared' AND public.is_wall_public("wallId"));
