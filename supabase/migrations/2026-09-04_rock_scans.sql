-- Rock scans: the video a climber records at the crag, and the 3D
-- reconstruction a worker builds from it.
--
-- Idempotent, per this repo's migration convention: safe to re-apply.
--
-- TWO WRITERS, and the column split below is the whole design. The app owns
-- the capture half; a reconstruction worker (service_role, so RLS does not
-- apply to it) owns the result half. The client's sync engine is a full-state
-- re-push under last-writer-wins, so it MUST NOT send the worker's columns —
-- it strips them (`serverOwnedSyncColumns` in `sync_remote.dart`) and relies
-- on `ON CONFLICT DO UPDATE` leaving an omitted column untouched. If you add
-- a worker-written column here, add it there too.

CREATE TABLE IF NOT EXISTS public.rock_scans (
  "id"               TEXT PRIMARY KEY,
  "createdAt"        BIGINT  NOT NULL,
  "updatedAt"        BIGINT  NOT NULL,
  "deletedAt"        BIGINT,
  "remoteId"         TEXT,
  "dirty"            BOOLEAN NOT NULL DEFAULT false,
  "ownerId"          TEXT,

  -- Client-owned.
  "wallId"           TEXT    NOT NULL,
  "uploadState"      TEXT    NOT NULL DEFAULT 'pending',
  "videoObjectPath"  TEXT,
  "durationMs"       BIGINT,
  "sizeBytes"        BIGINT,

  -- Worker-owned. Never present in a client upsert body.
  "status"           TEXT    NOT NULL DEFAULT 'pending',
  "progressPct"      BIGINT,
  "cloudObjectPath"  TEXT,
  "manifestJson"     TEXT,
  "failureReason"    TEXT
);

-- No FK on "wallId", matching every other table here (`route_lines` included).
-- The client pushes tables in dependency order, and a hard FK would make one
-- out-of-order row fail an entire batch rather than one row.

-- The worker's claim query, and the only index that is not just a convenience:
-- it reads exactly the rows whose video has landed and whose reconstruction
-- has not started. Partial, so it stays small however many finished scans
-- accumulate.
CREATE INDEX IF NOT EXISTS idx_rock_scans_claimable
  ON public.rock_scans ("createdAt")
  WHERE "uploadState" = 'uploaded'
    AND "status" = 'pending'
    AND "deletedAt" IS NULL;

CREATE INDEX IF NOT EXISTS idx_rock_scans_wall
  ON public.rock_scans ("wallId")
  WHERE "deletedAt" IS NULL;

ALTER TABLE public.rock_scans ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS rock_scans_owner_all ON public.rock_scans;
CREATE POLICY rock_scans_owner_all ON public.rock_scans
  FOR ALL
  USING ("ownerId" = (auth.uid())::text)
  WITH CHECK ("ownerId" = (auth.uid())::text);

-- A scan of a SHARED wall is readable by anyone, exactly as that wall's
-- photos and route lines already are. Mirrors `route_lines_shared_select`.
DROP POLICY IF EXISTS rock_scans_shared_select ON public.rock_scans;
CREATE POLICY rock_scans_shared_select ON public.rock_scans
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.walls w
      WHERE w.id = rock_scans."wallId"
        AND w.visibility = 'shared'
    )
  );

-- Storage: source videos and reconstructed point clouds.
--
-- A SEPARATE bucket from `topo-photos`, deliberately. A scan video is one to
-- two orders of magnitude larger than a photo, and the two have completely
-- different retention stories — the photos are the user's irreplaceable work
-- (never evicted, D-5), while a source video is regenerable by walking back
-- to the crag and is a candidate for deletion once its reconstruction lands.
-- Sharing one bucket would make that distinction a filename convention.
INSERT INTO storage.buckets (id, name, public, file_size_limit)
VALUES ('rock-scans', 'rock-scans', false, 524288000)
ON CONFLICT (id) DO UPDATE SET file_size_limit = EXCLUDED.file_size_limit;

-- Same owner-prefix shape as `topo_photos_own_all`: everything a user can
-- touch lives under `<uid>/`. The worker writes reconstruction artifacts with
-- the service role, which bypasses RLS entirely, so it needs no policy of its
-- own — and consequently no anonymous write path exists into this bucket.
DROP POLICY IF EXISTS rock_scans_own_all ON storage.objects;
CREATE POLICY rock_scans_own_all ON storage.objects
  FOR ALL
  USING (
    bucket_id = 'rock-scans'
    AND (storage.foldername(name))[1] = (auth.uid())::text
  )
  WITH CHECK (
    bucket_id = 'rock-scans'
    AND (storage.foldername(name))[1] = (auth.uid())::text
  );
