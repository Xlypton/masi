-- Let `shared/display/<photoId>.jpg` be written — the 2048px display tier.
--
-- APPLIED TO THE LIVE PROJECT on 2026-09-23 (it is live the moment it runs;
-- the Supabase project is not branched).
--
-- Why this exists: the app started publishing a third object per shared photo
-- on 2026-09-12 (`SupabaseSyncRemote._publishDisplayBestEffort`) and
-- backfilling it for older photos (`SharedDerivativeBackfill`), but this INSERT
-- policy admitted exactly two shapes — `shared/<file>` for the owner and
-- `shared/thumbs/<file>` for any reader — and sent every other path to
-- `ELSE false`. So every display upload was refused by RLS. Both writers are
-- best-effort BY DESIGN (a missing derivative degrades to the original, never
-- fails a push), so the refusal was completely silent: the tier would have
-- stayed empty forever and the pull would have kept falling back to 5.5 MB
-- originals with nothing anywhere going red.
--
-- `display` gets EXACTLY the rule `thumbs` has, for the same reason: the
-- backfill is deliberately not scoped to the caller's own photos (a legacy
-- photo whose owner never returns would otherwise cost every viewer the
-- original forever), so the writer is "anyone who may read the photo", not the
-- owner. The exposure is the one `thumbs` already carries and no wider: INSERT
-- only (the first writer wins; overwriting needs UPDATE, which stays
-- owner-only via `owns_shared_photo_object`), and only at a key whose photo the
-- writer can already read. SELECT, UPDATE and DELETE key on the filename's
-- photo id regardless of folder, so they already cover `display/` unchanged.
--
-- Idempotent: DROP + CREATE.
DROP POLICY IF EXISTS "topo_photos_shared_write" ON storage.objects;
CREATE POLICY "topo_photos_shared_write" ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (
    bucket_id = 'topo-photos'
    AND (storage.foldername(name))[1] = 'shared'
    AND CASE
      WHEN array_length(storage.foldername(name), 1) = 1
        THEN public.owns_shared_photo_object(name)
      WHEN array_length(storage.foldername(name), 1) = 2
       AND (storage.foldername(name))[2] IN ('thumbs', 'display')
        THEN public.can_read_shared_photo_object(name)
      ELSE false
    END
  );
