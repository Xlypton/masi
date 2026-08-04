-- ============================================================================
-- public.backups — the full-snapshot cloud-backup table CloudBackupService
-- reads and writes.
--
-- WHY THIS EXISTS: the table was ABSENT on the live project (project ref
-- mnaipcqbkqzffgvxpato) until this DDL was applied by hand on 2026-08-04 via
-- the Management API (POST .../database/query), the same route the Dashboard
-- SQL editor uses. It has now been APPLIED to live and VERIFIED against
-- information_schema + pg_policies: `user_id text NOT NULL` (PK),
-- `snapshot jsonb NOT NULL`, `schema_version integer` (nullable),
-- `updated_at timestamptz NOT NULL DEFAULT now()`, RLS enabled, and policy
-- `backups_owner_all` reading exactly `USING (user_id = (auth.uid())::text)`.
-- This file is kept in sync with that live shape so a fresh project
-- provisioned from ../schema.sql (or a re-run of this delta) comes up
-- identical to it — the same schema-drift bug class as #64/#65/#72.
--
-- `user_id` is TEXT, not UUID, compared via `(auth.uid())::text` — matching
-- the convention every OTHER policy in this database uses (e.g.
-- `areas."ownerId" = (auth.uid())::text)`), even though this table's own
-- column is snake_case rather than camelCase (see below for why).
--
-- `schema_version` is intentionally NULLABLE: `RemoteSnapshot.schemaVersion`
-- is `int?` and a missing/non-int value means "no version claim was made",
-- which `BackupRepository.assertRestorable` treats as importable rather than
-- fatal. Making the column NOT NULL would reintroduce the exact hard-cast
-- failure mode that nullability was added to prevent.
--
-- Column names are snake_case here, UNLIKE every camelCase table elsewhere in
-- this database. That is not an inconsistency to "fix": these four keys are
-- written by hand in `SupabaseBackupRemote.upsertSnapshot` / read in
-- `fetchSnapshot` (lib/features/backup/data/backup_remote.dart), and renaming
-- one would break the client. The whole Drift snapshot (including its own
-- camelCase `schemaVersion` stamp) lives inside the `snapshot` JSONB blob.
--
-- Safe to re-run: CREATE TABLE IF NOT EXISTS, ADD COLUMN IF NOT EXISTS, and a
-- DROP POLICY IF EXISTS + CREATE POLICY pair.
--
-- Column shapes are derived from the client that reads/writes them:
--   lib/features/backup/data/backup_remote.dart
--     upsertSnapshot -> {'user_id', 'snapshot', 'schema_version', 'updated_at'}
--     fetchSnapshot  -> .eq('user_id', uid).maybeSingle()  (one row per user)
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.backups (
  user_id text PRIMARY KEY NOT NULL,
  snapshot jsonb NOT NULL,
  schema_version integer,
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- Belt-and-braces for a live table that predates one of these columns.
-- No DEFAULT/NOT NULL on the added forms (except updated_at's DEFAULT, which
-- only applies to rows inserted after the column exists): adding a NOT NULL
-- column to a table that already has rows would fail, and these are only
-- ever reached when the column is genuinely absent.
ALTER TABLE public.backups ADD COLUMN IF NOT EXISTS snapshot jsonb;
ALTER TABLE public.backups ADD COLUMN IF NOT EXISTS schema_version integer;
ALTER TABLE public.backups ADD COLUMN IF NOT EXISTS updated_at timestamptz;

GRANT SELECT, INSERT, UPDATE, DELETE
  ON public.backups
  TO authenticated;

ALTER TABLE public.backups ENABLE ROW LEVEL SECURITY;

-- ---------- ROW POLICIES ----------
-- Owner-only for every verb. No shared/public read path: a snapshot is the
-- user's WHOLE library, private topos included, so the shared-wall SELECT
-- policies the sync tables carry must NOT be mirrored here.
DROP POLICY IF EXISTS "backups_owner_all" ON public.backups;
CREATE POLICY "backups_owner_all" ON public.backups FOR ALL TO authenticated
  USING (user_id = (auth.uid())::text) WITH CHECK (user_id = (auth.uid())::text);
