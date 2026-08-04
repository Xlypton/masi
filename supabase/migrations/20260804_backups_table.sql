-- ============================================================================
-- public.backups — the full-snapshot cloud-backup table CloudBackupService
-- reads and writes. Apply once in the Supabase SQL editor against the
-- already-live database (Dashboard -> SQL Editor -> paste this whole file ->
-- Run).
--
-- Delta only (the full DDL lives in ../schema.sql, kept in sync for fresh-run
-- correctness). Safe to re-run: CREATE TABLE IF NOT EXISTS, ADD COLUMN IF NOT
-- EXISTS, and a DROP POLICY IF EXISTS + CREATE POLICY pair.
--
-- WHY THIS EXISTS: the table was created live but never recorded in
-- ../schema.sql, so a fresh project provisioned from that file would come up
-- WITHOUT it and every backup push/pull would fail. That is the same
-- schema-drift bug class as #64/#65/#72. Against the live project this script
-- is expected to be a near-complete no-op — its job is to make "live" and
-- "schema.sql" provably the same shape, and to add the RLS policy if it was
-- ever missing (a snapshot blob holds every private topo the user owns).
--
-- Column shapes are derived from the client that reads/writes them:
--   lib/features/backup/data/backup_remote.dart
--     upsertSnapshot -> {'user_id', 'snapshot', 'schema_version', 'updated_at'}
--     fetchSnapshot  -> .eq('user_id', uid).maybeSingle()  (one row per user)
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.backups (
  user_id UUID PRIMARY KEY NOT NULL,
  snapshot JSONB NOT NULL,
  schema_version INTEGER NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL
);

-- Belt-and-braces for a live table that predates one of the four columns.
-- No DEFAULT/NOT NULL on the added forms: adding a NOT NULL column to a table
-- that already has rows would fail, and these are only ever reached when the
-- column is genuinely absent.
ALTER TABLE public.backups
  ADD COLUMN IF NOT EXISTS snapshot JSONB,
  ADD COLUMN IF NOT EXISTS schema_version INTEGER,
  ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ;

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
  USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());
