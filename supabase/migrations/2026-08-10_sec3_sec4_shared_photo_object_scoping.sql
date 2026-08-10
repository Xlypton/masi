-- ============================================================================
-- SEC-3 + SEC-4: scope the `shared/` storage prefix to the photos it actually
-- represents, instead of to "any authenticated user".
-- Applied live: 2026-08-10. Idempotent (DROP POLICY IF EXISTS + CREATE,
-- CREATE OR REPLACE FUNCTION), so it is safe to re-run.
--
-- SUPERSEDES the never-applied draft `2026-08-10_sec3_shared_photo_write_owner_check.sql`.
-- Do NOT apply that file: it omits `TO authenticated` and it has no depth split,
-- so it would break the deliberately cross-owner `shared/thumbs/*` backfill.
--
-- ---------------------------------------------------------------------------
-- THE DEFECTS THIS FIXES
-- ---------------------------------------------------------------------------
-- SEC-3 (write) — `topo_photos_shared_write` (INSERT) and `topo_photos_shared_upd`
--   (UPDATE) checked only `(storage.foldername(name))[1] = 'shared'`. Any signed-in
--   user could therefore upload into the shared prefix under an arbitrary photo id,
--   and — worse — OVERWRITE another owner's published photo bytes in place. The
--   `topo_photos_shared_delete` policy (applied 2026-08-08) already carried the
--   correct owner check; INSERT and UPDATE never did.
--
-- SEC-4 (read) — `topo_photos_shared_read` (SELECT) checked only the same prefix
--   test, so every signed-in user could read EVERY byte ever pushed to `shared/`,
--   including photos of walls that were rejected by moderation, withdrawn past the
--   grace window, marked `accessState = 'sensitive'`, or soft-deleted. It also made
--   the whole `shared/` prefix LISTABLE (Storage list() is a SELECT on
--   storage.objects), which leaked the photo-id inventory of every account.
--
-- ---------------------------------------------------------------------------
-- WHAT WAS *NOT* WRONG (measured against the live project, 2026-08-10)
-- ---------------------------------------------------------------------------
-- * The `topo-photos` bucket is `public = false`. There is no `getPublicUrl` and no
--   `createSignedUrl` anywhere in `lib/`; every read is an authenticated `download()`.
-- * All five policies on `storage.objects` are `TO authenticated`, so the `anon`
--   role matched NO policy. There was therefore no ANONYMOUS exposure at any point
--   — the blast radius of SEC-3/SEC-4 was "any user with an account", not "the
--   internet". Every policy created below keeps `TO authenticated` for that reason.
-- * `topo_photos_own_all` (the `<uid>/...` private prefix) was and stays correct.
--   It is deliberately untouched here.
--
-- ---------------------------------------------------------------------------
-- SCOPE / RELATED WORK
-- ---------------------------------------------------------------------------
-- * SEC-2 — deleting the *bytes* when a topo is unpublished — is NOT in this file.
--   It cannot be done server-side at all: `storage.protect_delete()` is a
--   BEFORE DELETE statement trigger on `storage.objects` and is NOT
--   `SECURITY DEFINER`, so it raises even for a SECURITY DEFINER RPC. Byte deletion
--   must be a client Storage-API call. That work ships separately, in
--   `lib/features/backup/data/sync_service.dart`.
-- * THIS DATABASE IS NOT BRANCHED. The moment this file is applied it is live for
--   every user of the app and for the user's real topos. There is no staging copy.
--
-- ---------------------------------------------------------------------------
-- PATH SHAPES (both depths must work)
-- ---------------------------------------------------------------------------
--   <uid>/<photoId><ext>            private original   (topo_photos_own_all)
--   shared/<photoId><ext>           published original (depth 1)
--   shared/thumbs/<photoId>.jpg     published thumb    (depth 2)
-- `regexp_replace(storage.filename(name), '\.[^.]*$', '')` recovers the photo id at
-- BOTH depths, because storage.filename() returns only the last path segment.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- Helper 1: may the caller READ the shared object for this photo?
--
-- NOTE the leading is_admin() short-circuit: it is deliberate and load-bearing.
-- Without it, an object whose photos row is GONE (a true orphan) becomes
-- unreadable by everyone, and because Supabase's remove() returns the removed
-- rows (DELETE ... RETURNING, i.e. it needs SELECT), an unreadable orphan is
-- also UNDELETABLE. Admins must always be able to read, hence delete, any
-- shared object.
--
-- `storage.filename` is schema-qualified because of `SET search_path = public`.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.can_read_shared_photo_object(object_name text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT public.is_admin() OR EXISTS (
    SELECT 1 FROM public.photos p JOIN public.walls w ON w.id = p."wallId"
     WHERE p.id = regexp_replace(storage.filename(object_name), '\.[^.]*$', '')
       AND p."deletedAt" IS NULL AND w."deletedAt" IS NULL
       AND ( public.is_wall_public(w.id) OR w."ownerId" = (auth.uid())::text )
  );
$$;

-- ---------------------------------------------------------------------------
-- Helper 2: does the caller OWN the wall this shared object's photo belongs to?
--
-- Intentionally does NOT filter on "deletedAt": an owner (or an admin) must still
-- be able to write/replace bytes for a row that is mid-tombstone, otherwise a
-- delete-then-resync leaves unwritable garbage behind.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.owns_shared_photo_object(object_name text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.photos p JOIN public.walls w ON w.id = p."wallId"
     WHERE p.id = regexp_replace(storage.filename(object_name), '\.[^.]*$', '')
       AND ( w."ownerId" = (auth.uid())::text OR public.is_admin() )
  );
$$;

-- ---------------------------------------------------------------------------
-- Grants. CREATE FUNCTION auto-grants EXECUTE to PUBLIC, and on a Supabase
-- project `anon` additionally holds its own grant — `REVOKE ... FROM public`
-- does NOT remove that, so `anon` must be named explicitly.
-- (Same lesson as 2026-08-08_sec1_revoke_internal_helper_execute.sql.)
-- ---------------------------------------------------------------------------
REVOKE EXECUTE ON FUNCTION public.can_read_shared_photo_object(text) FROM public, anon;
REVOKE EXECUTE ON FUNCTION public.owns_shared_photo_object(text)     FROM public, anon;
GRANT  EXECUTE ON FUNCTION public.can_read_shared_photo_object(text) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.owns_shared_photo_object(text)     TO authenticated;


-- ---------------------------------------------------------------------------
-- SEC-4 — SELECT. Read a shared object only if the photo it names is live, its
-- wall is live, and either the wall is genuinely public (is_wall_public() carries
-- the whole moderation model: visibility='shared' AND state='published' AND the
-- 10-day withdrawRequestedAt grace AND the sensitive-accessState guards) or the
-- caller owns it. Admins always.
--
-- Side effect, and a wanted one: `shared/` is no longer blanket-listable.
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS "topo_photos_shared_read" ON storage.objects;
CREATE POLICY "topo_photos_shared_read" ON storage.objects FOR SELECT TO authenticated
  USING (
    bucket_id = 'topo-photos'
    AND (storage.foldername(name))[1] = 'shared'
    AND public.can_read_shared_photo_object(name)
  );

-- ---------------------------------------------------------------------------
-- SEC-3 — INSERT, split by path depth.
--
-- depth 1 (`shared/<id><ext>`, the ORIGINALS): owner (or admin) only.
--
-- depth 2 (`shared/thumbs/<id>.jpg`): can_read, not owns. This is deliberate.
--   `SharedThumbBackfill` is cross-owner BY DESIGN — it worklists thumbs that are
--   MISSING for photos the client can already see and manufactures them, so a
--   feed that predates thumbs still renders. Requiring ownership here would
--   silently kill that backfill. The relaxation is safe because (a) you may only
--   create a derivative of something you are already allowed to READ, and (b) it
--   is INSERT only — see the UPDATE policy below, which is owner-gated at both
--   depths. Net property: a foreign user may CREATE a missing thumb, and may
--   never REPLACE an existing object.
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS "topo_photos_shared_write" ON storage.objects;
CREATE POLICY "topo_photos_shared_write" ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (
    bucket_id = 'topo-photos'
    AND (storage.foldername(name))[1] = 'shared'
    AND (
      CASE
        WHEN array_length(storage.foldername(name), 1) = 1
          THEN public.owns_shared_photo_object(name)
        WHEN array_length(storage.foldername(name), 1) = 2
             AND (storage.foldername(name))[2] = 'thumbs'
          THEN public.can_read_shared_photo_object(name)
        ELSE false
      END
    )
  );

-- ---------------------------------------------------------------------------
-- SEC-3 — UPDATE. Owner (or admin) only, on BOTH sides, at every depth. This is
-- the half that closes the overwrite: without an owner check on UPDATE, an
-- attacker could replace the bytes of any published photo in place.
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS "topo_photos_shared_upd" ON storage.objects;
CREATE POLICY "topo_photos_shared_upd" ON storage.objects FOR UPDATE TO authenticated
  USING (
    bucket_id = 'topo-photos'
    AND (storage.foldername(name))[1] = 'shared'
    AND public.owns_shared_photo_object(name)
  )
  WITH CHECK (
    bucket_id = 'topo-photos'
    AND (storage.foldername(name))[1] = 'shared'
    AND public.owns_shared_photo_object(name)
  );

-- `topo_photos_shared_delete` and `topo_photos_own_all` are intentionally NOT
-- touched by this migration; both were already correct.


-- ============================================================================
-- VERBATIM ROLLBACK
--
-- The three CREATE POLICY statements below are the exact pre-change definitions.
-- Verified 2026-08-10 to be byte-equivalent between `supabase/schema.sql:221-229`
-- and the live `pg_policies` rows (which normalise to
--   ((bucket_id = 'topo-photos'::text) AND ((storage.foldername(name))[1] = 'shared'::text))
-- for all three, with `qual` NULL on the INSERT policy — i.e. the file and the
-- database agreed, and this is what was actually live).
--
-- To roll back, run everything between the BEGIN/END markers. Note that rolling
-- back REOPENS SEC-3 and SEC-4. It does not need the helper functions dropped;
-- if you want them gone too, add the two DROP FUNCTION lines at the end.
--
-- ---- ROLLBACK BEGIN ----
-- DROP POLICY IF EXISTS "topo_photos_shared_read"  ON storage.objects;
-- DROP POLICY IF EXISTS "topo_photos_shared_write" ON storage.objects;
-- DROP POLICY IF EXISTS "topo_photos_shared_upd"   ON storage.objects;
--
-- CREATE POLICY "topo_photos_shared_read" ON storage.objects FOR SELECT TO authenticated
--   USING (bucket_id = 'topo-photos' AND (storage.foldername(name))[1] = 'shared');
--
-- CREATE POLICY "topo_photos_shared_write" ON storage.objects FOR INSERT TO authenticated
--   WITH CHECK (bucket_id = 'topo-photos' AND (storage.foldername(name))[1] = 'shared');
--
-- CREATE POLICY "topo_photos_shared_upd" ON storage.objects FOR UPDATE TO authenticated
--   USING (bucket_id = 'topo-photos' AND (storage.foldername(name))[1] = 'shared')
--   WITH CHECK (bucket_id = 'topo-photos' AND (storage.foldername(name))[1] = 'shared');
--
-- -- optional:
-- -- DROP FUNCTION IF EXISTS public.can_read_shared_photo_object(text);
-- -- DROP FUNCTION IF EXISTS public.owns_shared_photo_object(text);
-- ---- ROLLBACK END ----
--
-- ============================================================================
-- PRE-APPLY IMPACT SIMULATION (run read-only against live data, 2026-08-10,
-- with the OLD wide policies still in force; the OLD verdict is `true` for every
-- pair by construction, so every row below is a NEW-verdict `false`).
--
-- Corpus: 30 objects under `shared/` x 11 rows in auth.users = 330 pairs.
--   losing read access:  46 pairs / 6 distinct objects
--   published topos:     24 objects x 11 uids = 264 pairs, 0 regressions
--
-- The 6 objects that lose readers:
--   shared/9bba54c2-....jpg              8 uids   photo+wall BOTH tombstoned (orphan) -> DELETED
--   shared/thumbs/9bba54c2-....jpg       8 uids   thumb manufactured after the delete -> DELETED
--   shared/thumbs/e2e-photo-pending-0001.jpg    8 uids   E2E fixture, no photos row  -> DELETED
--   shared/thumbs/e2e-photo-published-0001.jpg  8 uids   E2E fixture, no photos row  -> DELETED
--   shared/c9bac04d-....jpg              7 uids   wall_moderation.state = 'rejected'
--   shared/thumbs/c9bac04d-....jpg       7 uids   wall_moderation.state = 'rejected'
--
-- The four orphans were removed via the Storage REST API before SEC-4 was applied
-- (53 -> 49 objects; `shared/` 30 -> 26), so the only remaining behaviour change
-- is the two `rejected` objects — which is precisely the SEC-4 defect. Their
-- OWNER (kertichap@gmail.com / 109d8225-...) and all three admins retain access
-- through the `w."ownerId" = auth.uid()` and `is_admin()` branches; 7 unrelated
-- accounts correctly lose it.
-- ============================================================================
