-- ============================================================================
-- Feature #12 — public opt-in ascent logs. Apply once in the Supabase SQL
-- editor against the already-live database (Dashboard -> SQL Editor -> paste
-- this whole file -> Run).
--
-- Delta only (the full DDL lives in ../schema.sql, kept in sync for
-- fresh-run correctness): adds a "visibility"/"authorName" pair to ascents so
-- a logged ascent can optionally be published to the Community feed, and
-- lets likes/comments attach to an ascent instead of only a wall. Safe to
-- re-run: every ADD COLUMN uses IF NOT EXISTS and every policy change is a
-- DROP POLICY IF EXISTS + CREATE POLICY pair.
-- ============================================================================

ALTER TABLE public.ascents
  ADD COLUMN IF NOT EXISTS "visibility" TEXT NOT NULL DEFAULT 'private',
  ADD COLUMN IF NOT EXISTS "authorName" TEXT;

ALTER TABLE public.likes
  ADD COLUMN IF NOT EXISTS "ascentId" TEXT REFERENCES public.ascents("id");
ALTER TABLE public.likes ALTER COLUMN "wallId" DROP NOT NULL;

ALTER TABLE public.comments
  ADD COLUMN IF NOT EXISTS "ascentId" TEXT REFERENCES public.ascents("id");
ALTER TABLE public.comments ALTER COLUMN "wallId" DROP NOT NULL;

-- ---------- ROW POLICIES ----------
DROP POLICY IF EXISTS "ascents_shared_select" ON public.ascents;
CREATE POLICY "ascents_shared_select" ON public.ascents FOR SELECT TO authenticated
  USING ("visibility" = 'shared');

DROP POLICY IF EXISTS "likes_ascent_shared_select" ON public.likes;
CREATE POLICY "likes_ascent_shared_select" ON public.likes FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.ascents a
    WHERE a."id" = likes."ascentId" AND a."visibility" = 'shared'
  ));

DROP POLICY IF EXISTS "comments_ascent_shared_select" ON public.comments;
CREATE POLICY "comments_ascent_shared_select" ON public.comments FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.ascents a
    WHERE a."id" = comments."ascentId" AND a."visibility" = 'shared'
  ));
