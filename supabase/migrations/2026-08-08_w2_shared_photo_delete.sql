-- W-2: photo bytes outlive their rows.
--
-- THE BUG, measured rather than inferred (2026-08-08): there is no DELETE
-- policy on `storage.objects` covering the `shared/` prefix at all. The three
-- existing shared policies grant SELECT, UPDATE and INSERT; `topo_photos_own_all`
-- is FOR ALL but is scoped to `foldername[1] = auth.uid()`, which by
-- construction never matches `shared/...`.
--
-- So `SyncRemote.removeSharedPhoto` — the call the client already makes when a
-- photo is tombstoned — has never been able to delete anything. Worse, it does
-- not fail: the Storage API returns `[]` and HTTP 200 for a delete that RLS
-- filtered to nothing, so the client sees success. Verified end to end against
-- the E2E fixture: DELETE returned `[]`, and a subsequent GET of the same
-- object still returned 200.
--
-- That is the whole of W-2. It was recorded as "a moderator must be able to
-- take down the bytes", which is true but understates it: nobody could, and the
-- code that looked like it did was a no-op.
--
-- WHY A POLICY AND NOT A SECURITY DEFINER RPC. Supabase installs a
-- `storage.protect_delete()` trigger that raises on ANY direct
-- `DELETE FROM storage.objects` ("Direct deletion from storage tables is not
-- allowed. Use the Storage API instead."). So the database cannot remove an
-- object no matter how it is privileged, and the whole "do it server-side in
-- the review RPC" shape is unavailable. Deletion must go through the Storage
-- API as an authenticated user, which makes RLS the only lever.
--
-- RESIDUAL RISK, stated rather than hidden: because the delete is issued by a
-- client, an admin whose device dies between `remove_topo` and the Storage call
-- leaves the bytes behind. Self-healing that needs a server-side sweep (an Edge
-- Function or pg_net against the Storage API), which is deliberately not built
-- here. The takedown is still correct in the DB, so the topo is unreachable in
-- the app either way; this is about the bytes, not about visibility.

-- Idempotent.
DROP POLICY IF EXISTS topo_photos_shared_delete ON storage.objects;

CREATE POLICY topo_photos_shared_delete ON storage.objects
  FOR DELETE TO authenticated
  USING (
    bucket_id = 'topo-photos'
    AND (storage.foldername(name))[1] = 'shared'
    AND (
      -- A moderator taking down inappropriate imagery. Checked FIRST so the
      -- admin path never depends on being able to see the owner's rows.
      public.is_admin()
      -- ...or the owner of the wall this photo belongs to, which is the
      -- ordinary tombstone path that has silently been failing.
      OR EXISTS (
        SELECT 1
          FROM public.photos p
          JOIN public.walls w ON w.id = p."wallId"
         -- Objects are named `shared/<photoId><ext>`; strip the extension to
         -- recover the id. Slices share their original's file, so this is the
         -- CANONICAL photo id — the same one the uploader used.
         WHERE p.id = regexp_replace(storage.filename(objects.name), '\.[^.]*$', '')
           AND w."ownerId" = (auth.uid())::text
      )
    )
  );

-- Note on the id lookup and impersonation: `photos.id` is a primary key, so a
-- malicious client cannot insert a row claiming somebody else's photo id in
-- order to gain delete rights over their published bytes — the insert would
-- collide. The join to `walls` is what ties the id to an owner.
