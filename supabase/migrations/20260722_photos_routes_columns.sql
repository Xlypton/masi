-- ============================================================================
-- Photos/Routes column backfill — the local Drift schema has 5 columns that
-- were never added to the Supabase backend, so sync push (which sends the
-- full Drift row.toJson()) is rejected by PostgREST for `photos`/`routes`
-- rows containing them. Apply once in the Supabase SQL editor against the
-- already-live database (Dashboard -> SQL Editor -> paste this whole file ->
-- Run).
--
-- Delta only (the full DDL lives in ../schema.sql, kept in sync for
-- fresh-run correctness). Safe to re-run: every ADD COLUMN uses IF NOT
-- EXISTS.
-- ============================================================================

ALTER TABLE public.photos
  ADD COLUMN IF NOT EXISTS "sortOrder" INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS "isPrimary" BOOLEAN NOT NULL DEFAULT false;

ALTER TABLE public.routes
  ADD COLUMN IF NOT EXISTS "betaVideoUrl" TEXT,
  ADD COLUMN IF NOT EXISTS "styleTagsJson" TEXT,
  ADD COLUMN IF NOT EXISTS "stars" INTEGER;
