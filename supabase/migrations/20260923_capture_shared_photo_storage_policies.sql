-- CAPTURE of live state — no behaviour change. Applied 2026-09-23 as a no-op
-- (every definition below was read back from the live project and is identical
-- to it; the apply only proves it parses).
--
-- Why it exists: the shared-photo Storage security on the live project had
-- drifted entirely out of the repo. `owns_shared_photo_object` and
-- `can_read_shared_photo_object` were defined NOWHERE in `supabase/`, and
-- `schema.sql` still showed the original wide-open policies (any signed-in user
-- could read, write or overwrite anything under `shared/`). A fresh run of the
-- repo's SQL would therefore have recreated a bucket with none of the
-- moderation-aware read rule and none of the owner-only overwrite rule. Found
-- while adding `display` to the INSERT policy
-- (20260923_shared_display_tier_insert.sql), which this supersedes as the
-- complete statement of the INSERT policy.
--
-- Depends on `public.is_admin()` and `public.is_wall_public(text)` from the
-- 2026-08-06 community migrations.

CREATE OR REPLACE FUNCTION public.can_read_shared_photo_object(object_name text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT public.is_admin() OR EXISTS (
    SELECT 1 FROM public.photos p JOIN public.walls w ON w.id = p."wallId"
     WHERE p.id = regexp_replace(storage.filename(object_name), '\.[^.]*$', '')
       AND p."deletedAt" IS NULL AND w."deletedAt" IS NULL
       AND ( public.is_wall_public(w.id) OR w."ownerId" = (auth.uid())::text )
  );
$function$
;

CREATE OR REPLACE FUNCTION public.owns_shared_photo_object(object_name text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT EXISTS (
    SELECT 1 FROM public.photos p JOIN public.walls w ON w.id = p."wallId"
     WHERE p.id = regexp_replace(storage.filename(object_name), '\.[^.]*$', '')
       AND ( w."ownerId" = (auth.uid())::text OR public.is_admin() )
  );
$function$
;

DROP POLICY IF EXISTS "topo_photos_shared_read"  ON storage.objects;
DROP POLICY IF EXISTS "topo_photos_shared_write" ON storage.objects;
DROP POLICY IF EXISTS "topo_photos_shared_upd"   ON storage.objects;

-- Readable by anyone who may see the PHOTO: a public (moderation-approved) wall,
-- or the caller's own. Keyed on the filename's photo id, so it covers the
-- original, `thumbs/` and `display/` alike.
CREATE POLICY "topo_photos_shared_read" ON storage.objects FOR SELECT TO authenticated
  USING (bucket_id = 'topo-photos' AND (storage.foldername(name))[1] = 'shared'
         AND public.can_read_shared_photo_object(name));

-- The original: owner only. A derivative (`thumbs/`, `display/`): any reader,
-- because the in-app backfill runs for whoever is viewing. INSERT only — the
-- first writer wins; overwriting is UPDATE, which is owner-only below.
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

CREATE POLICY "topo_photos_shared_upd" ON storage.objects FOR UPDATE TO authenticated
  USING (bucket_id = 'topo-photos' AND (storage.foldername(name))[1] = 'shared'
         AND public.owns_shared_photo_object(name))
  WITH CHECK (bucket_id = 'topo-photos' AND (storage.foldername(name))[1] = 'shared'
              AND public.owns_shared_photo_object(name));
