-- ===========================================================================
-- Community editing, Phase 8b — duplicate topos: detect, name, link (C-6)
--
-- The problem, restated from COMMUNITY_PLAN.md §C-6: multiple people publish
-- the same boulder. The plan is explicit that this is NOT resolved by deleting
-- one of them and NOT by refusing the second submission — "two people
-- photographing the same boulder from different angles in different light is
-- *useful*, and the second submission is often better than the first."
--
-- So nothing in this migration can remove, hide, or downrank a topo. It is
-- PURELY ADDITIVE, and that is the property to preserve if it is ever edited:
--
--   * `topo_alternates` records that two topos are the same PLACE. It changes
--     no visibility, no ownership and no moderation state. Drop the whole
--     table and every topo is exactly as public as it was.
--   * `nearby_published_topos` only ever returns topos the caller could
--     already see.
--   * `link_alternate` is admin-only and reversible by `unlink_alternate`.
--
-- Three pieces, in the order COMMUNITY_PLAN.md §C-6 lists them:
--   1. DETECT   — `nearby_published_topos`, so the submitter is shown "3 topos
--                  already exist here" BEFORE they submit. §C-6.1's whole claim
--                  is "many duplicates stop right there", and a duplicate that
--                  is never created costs nobody a moderation decision.
--   2. NAME     — `content_reports."duplicateOfId"`, so "this is the same
--                  boulder as X" carries X. §C-6.4 makes the duplicate report
--                  the merge request; a report that only says "duplicate" makes
--                  an admin go and find the other one by hand, which is how
--                  this queue stops being worked.
--   4. LINK     — `link_alternate`, the admin's resolution. Alternates, never
--                  a merge that destroys a side (§3.3).
--
-- (§C-6.3, ranking, needs no server change: every signal it uses is already
-- collected. It is computed client-side — see `lib/features/community/domain/
-- topo_rank.dart`.)
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. The link table
-- ---------------------------------------------------------------------------
--
-- One row per NON-canonical wall, pointing at the canonical one. The canonical
-- has no row of its own, so "is this a group head?" is `NOT EXISTS (a row for
-- me)` and a group is `SELECT ... WHERE "canonicalId" = me`.
--
-- The invariant that makes that work is: **a canonical is never itself an
-- alternate.** There are no chains. `link_alternate` maintains it in both
-- directions (see below); without it, grouping a feed would need a recursive
-- walk and two admins linking in opposite orders could split one place into
-- two groups.
--
-- Not a column on `walls`, for the same reason moderation state is not (§0):
-- the sync engine re-pushes whole owned rows with local-wins-ties LWW and no
-- outbox (D-4), so the owner's next push would silently undo an admin's link.
CREATE TABLE IF NOT EXISTS public.topo_alternates (
  "wallId"      TEXT PRIMARY KEY NOT NULL REFERENCES public.walls(id) ON DELETE CASCADE,
  "canonicalId" TEXT NOT NULL REFERENCES public.walls(id) ON DELETE CASCADE,
  "linkedBy"    TEXT NOT NULL,
  note          TEXT,
  "linkedAt"    BIGINT NOT NULL,
  CONSTRAINT topo_alternates_not_self CHECK ("wallId" <> "canonicalId")
);

CREATE INDEX IF NOT EXISTS topo_alternates_canonical_idx
  ON public.topo_alternates ("canonicalId");

ALTER TABLE public.topo_alternates ENABLE ROW LEVEL SECURITY;

-- Readable when BOTH ends are public — `AND`, not `OR`, deliberately. A link
-- whose other end is a private or pending topo would otherwise be a way to
-- learn that a specific unpublished wall id exists, which is exactly the leak
-- `report_content`'s `is_wall_public` check closes on the way in.
DROP POLICY IF EXISTS topo_alternates_public_select ON public.topo_alternates;
CREATE POLICY topo_alternates_public_select ON public.topo_alternates
  FOR SELECT USING (
    public.is_wall_public("wallId") AND public.is_wall_public("canonicalId")
  );

-- No INSERT/UPDATE/DELETE policy at all: `link_alternate`/`unlink_alternate`
-- are the only ways in, so the admin check and the chain-flattening cannot be
-- bypassed by writing the table directly.

-- ---------------------------------------------------------------------------
-- 2. DETECT — what is already here (§C-6.1)
-- ---------------------------------------------------------------------------
--
-- Plain haversine over a bounding-box prefilter rather than PostGIS: this
-- project has no geography column, ~50 m is a tiny radius, and the box makes
-- the index-less scan cheap enough that adding an extension for it would be
-- the more expensive decision.
--
-- Two limits are load-bearing rather than tidy:
--   * `radius_m` is CLAMPED to 2000. The parameter is caller-supplied and this
--     is otherwise a "scan every published wall on earth" query with a
--     trigonometric filter.
--   * At most 10 rows. The caller is a confirmation sheet; a submitter shown
--     forty near-misses learns nothing and taps through.
--
-- `is_wall_public` is applied per row, so this can never surface a pending,
-- withdrawn or private topo — it answers only with things the caller could
-- have found in the feed anyway.
CREATE OR REPLACE FUNCTION public.nearby_published_topos(
  lat          double precision,
  lng          double precision,
  radius_m     double precision DEFAULT 50,
  exclude_wall text DEFAULT NULL
) RETURNS TABLE (
    "wallId"    text,
    name        text,
    "ownerId"   text,
    "ownerName" text,
    "photoId"   text,
    "routeCount" bigint,
    "distanceM" double precision,
    "createdAt" bigint
  )
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  r      double precision := least(greatest(coalesce(radius_m, 50), 1), 2000);
  dlat   double precision;
  dlng   double precision;
BEGIN
  IF lat IS NULL OR lng IS NULL THEN
    RETURN;
  END IF;

  dlat := r / 111320.0;
  -- Near the poles cos(lat) collapses and the longitude window explodes toward
  -- infinity. Flooring the cosine bounds the box instead of letting one topo at
  -- 89.9° turn this into a full scan; the exact haversine below still decides.
  dlng := r / (111320.0 * greatest(cos(radians(lat)), 0.01));

  RETURN QUERY
  SELECT w.id,
         w.name,
         w."ownerId",
         pr."displayName",
         (SELECT p.id FROM public.photos p
            WHERE p."wallId" = w.id AND p."deletedAt" IS NULL
            ORDER BY p."createdAt" DESC, p.id DESC LIMIT 1),
         (SELECT count(*) FROM public.routes rt
            WHERE rt."wallId" = w.id AND rt."deletedAt" IS NULL),
         d.meters,
         w."createdAt"
    FROM public.walls w
    LEFT JOIN public.profiles pr ON pr."ownerId" = w."ownerId"
    CROSS JOIN LATERAL (
      SELECT 6371000.0 * 2 * asin(sqrt(
               power(sin(radians(w.latitude - lat) / 2), 2) +
               cos(radians(lat)) * cos(radians(w.latitude)) *
               power(sin(radians(w.longitude - lng) / 2), 2)
             )) AS meters
    ) d
   WHERE w."deletedAt" IS NULL
     AND w.latitude IS NOT NULL AND w.longitude IS NOT NULL
     AND w.latitude  BETWEEN lat - dlat AND lat + dlat
     AND w.longitude BETWEEN lng - dlng AND lng + dlng
     AND (exclude_wall IS NULL OR w.id <> exclude_wall)
     AND d.meters <= r
     AND public.is_wall_public(w.id)
   ORDER BY d.meters ASC, w."createdAt" ASC
   LIMIT 10;
END;
$$;

GRANT EXECUTE ON FUNCTION
  public.nearby_published_topos(double precision, double precision, double precision, text)
  TO authenticated;

-- ---------------------------------------------------------------------------
-- 3. NAME — which topo it duplicates (§C-6.4)
-- ---------------------------------------------------------------------------

ALTER TABLE public.content_reports
  ADD COLUMN IF NOT EXISTS "duplicateOfId" TEXT REFERENCES public.walls(id) ON DELETE SET NULL;

-- `report_content` gains a fifth parameter. It has to be DROPPED first: adding
-- a defaulted parameter to an existing function creates an OVERLOAD rather
-- than replacing it, and every existing four-argument call then fails as
-- ambiguous (42725). Same trap as phase 7b's `suggest_edit`.
DROP FUNCTION IF EXISTS public.report_content(text, text, text, text);

CREATE OR REPLACE FUNCTION public.report_content(
  wall_id         text,
  reason          text,
  body            text DEFAULT NULL,
  route_id        text DEFAULT NULL,
  duplicate_of_id text DEFAULT NULL
) RETURNS text
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  now_ms    bigint := (extract(epoch FROM now()) * 1000)::bigint;
  actor     text   := (auth.uid())::text;
  day_ago   bigint;
  existing  text;
  today     int;
  new_id    text;
BEGIN
  IF actor IS NULL THEN
    RAISE EXCEPTION 'not authorised' USING ERRCODE = '42501';
  END IF;
  IF reason IS NULL OR reason NOT IN
     ('inaccurate','unsafe','duplicate','access','inappropriate','not_yours') THEN
    RAISE EXCEPTION 'unknown reason %', reason USING ERRCODE = '22023';
  END IF;

  -- You may only report content you can actually see. Without this, the id of
  -- any private topo — guessable or leaked — becomes a way to put a stranger's
  -- unpublished work in front of a moderator.
  IF NOT public.is_wall_public(wall_id) THEN
    RAISE EXCEPTION 'unknown wall %', wall_id USING ERRCODE = 'P0002';
  END IF;

  -- Phase 8b. The named duplicate gets the SAME treatment as the reported
  -- topo, for the same reason: naming a private wall id would confirm it
  -- exists, and an admin who follows the link would be shown work its owner
  -- has not published.
  IF duplicate_of_id IS NOT NULL THEN
    IF reason <> 'duplicate' THEN
      RAISE EXCEPTION 'only a duplicate report names another topo'
        USING ERRCODE = '22023';
    END IF;
    IF duplicate_of_id = wall_id THEN
      RAISE EXCEPTION 'a topo cannot duplicate itself' USING ERRCODE = '22023';
    END IF;
    IF NOT public.is_wall_public(duplicate_of_id) THEN
      RAISE EXCEPTION 'unknown wall %', duplicate_of_id USING ERRCODE = 'P0002';
    END IF;
  END IF;

  -- Aliased, because the `reason` PARAMETER and the `reason` COLUMN would
  -- otherwise both be in scope and Postgres refuses the ambiguity outright
  -- (42702) rather than picking one.
  --
  -- `duplicateOfId` joins the dedup key rather than being ignored by it: two
  -- reports saying this topo duplicates two DIFFERENT topos are two distinct
  -- claims, and collapsing the second into the first would silently discard
  -- the more useful one.
  SELECT c.id INTO existing
    FROM public.content_reports c
   WHERE c."wallId" = wall_id
     AND c."reporterId" = actor
     AND c.reason = report_content.reason
     AND c.status = 'open'
     AND c."routeId" IS NOT DISTINCT FROM route_id
     AND c."duplicateOfId" IS NOT DISTINCT FROM duplicate_of_id
   LIMIT 1;
  IF existing IS NOT NULL THEN
    RETURN existing;
  END IF;

  day_ago := now_ms - 86400000;
  SELECT count(*) INTO today
    FROM public.content_reports
   WHERE "reporterId" = actor AND "createdAt" > day_ago;
  IF today >= 20 THEN
    RAISE EXCEPTION 'too many reports today' USING ERRCODE = '53400';
  END IF;

  new_id := gen_random_uuid()::text;
  INSERT INTO public.content_reports
    (id, "wallId", "routeId", "reporterId", reason, body, status, "createdAt",
     "duplicateOfId")
  VALUES (new_id, wall_id, route_id, actor, reason,
          nullif(btrim(coalesce(body, '')), ''), 'open', now_ms,
          duplicate_of_id);

  RETURN new_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.report_content(text, text, text, text, text)
  TO authenticated;

-- The admin queue has to SHOW the named topo, or naming it achieved nothing.
-- `CREATE OR REPLACE` cannot change a function's OUT parameters, so this is a
-- DROP and recreate as well.
DROP FUNCTION IF EXISTS public.moderation_reports(int);

CREATE OR REPLACE FUNCTION public.moderation_reports(limit_count int DEFAULT 50)
  RETURNS TABLE (
    id               text,
    "wallId"         text,
    "wallName"       text,
    "routeId"        text,
    "routeName"      text,
    "reporterId"     text,
    "reporterName"   text,
    reason           text,
    body             text,
    urgent           boolean,
    "createdAt"      bigint,
    "duplicateOfId"   text,
    "duplicateOfName" text,
    "alreadyLinked"   boolean
  )
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'not authorised' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT c.id, c."wallId", w.name, c."routeId", r.name,
         c."reporterId", pr."displayName", c.reason, c.body,
         c.reason = 'unsafe',
         c."createdAt",
         c."duplicateOfId",
         dup.name,
         -- So the admin is not offered "Link as alternates" on a pair that is
         -- already linked — the RPC is idempotent, but a button that appears to
         -- do something and does nothing is how a queue loses its meaning.
         EXISTS (
           SELECT 1 FROM public.topo_alternates a
            WHERE (a."wallId" = c."wallId"      AND a."canonicalId" = c."duplicateOfId")
               OR (a."wallId" = c."duplicateOfId" AND a."canonicalId" = c."wallId")
         )
    FROM public.content_reports c
    JOIN public.walls w ON w.id = c."wallId"
    LEFT JOIN public.routes r    ON r.id = c."routeId"
    LEFT JOIN public.walls dup   ON dup.id = c."duplicateOfId"
    LEFT JOIN public.profiles pr ON pr."ownerId" = c."reporterId"
   WHERE c.status = 'open'
   ORDER BY (c.reason = 'unsafe') DESC, c."createdAt" ASC
   LIMIT limit_count;
END;
$$;

GRANT EXECUTE ON FUNCTION public.moderation_reports(int) TO authenticated;

-- ---------------------------------------------------------------------------
-- 4. LINK — the admin's resolution (§C-6.4)
-- ---------------------------------------------------------------------------
--
-- "Resolved by an admin who can link them as alternates rather than deleting
-- either." Note what this function does NOT do: it does not unpublish, delete,
-- reassign or edit either topo. Both remain exactly as public, as owned and as
-- editable as before. The only thing that changes is that a reader is shown
-- one card for the place instead of two.
--
-- Chain-flattening is the whole of the complexity, and it runs in both
-- directions because an admin can link in either order:
--
--   * If `canonical_id` is ITSELF an alternate of something, the link is made
--     to its canonical instead. Otherwise linking B→C after C→A would leave B
--     pointing at a non-head.
--   * Anything already pointing at `duplicate_id` is re-pointed to the new
--     canonical. Otherwise linking C→A after B→C would strand B under a head
--     that is no longer a head.
--
-- Together those keep the no-chains invariant true inductively, which is what
-- lets the client group a feed with one pass and no recursion.
CREATE OR REPLACE FUNCTION public.link_alternate(
  duplicate_id text,
  canonical_id text,
  note         text DEFAULT NULL
) RETURNS text
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  now_ms bigint := (extract(epoch FROM now()) * 1000)::bigint;
  actor  text   := (auth.uid())::text;
  head   text;
BEGIN
  IF actor IS NULL OR NOT public.is_admin() THEN
    RAISE EXCEPTION 'not authorised' USING ERRCODE = '42501';
  END IF;
  IF duplicate_id IS NULL OR canonical_id IS NULL THEN
    RAISE EXCEPTION 'both topos are required' USING ERRCODE = '22023';
  END IF;
  IF duplicate_id = canonical_id THEN
    RAISE EXCEPTION 'a topo cannot be an alternate of itself'
      USING ERRCODE = '22023';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.walls WHERE id = duplicate_id
                                              AND "deletedAt" IS NULL) THEN
    RAISE EXCEPTION 'unknown wall %', duplicate_id USING ERRCODE = 'P0002';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.walls WHERE id = canonical_id
                                              AND "deletedAt" IS NULL) THEN
    RAISE EXCEPTION 'unknown wall %', canonical_id USING ERRCODE = 'P0002';
  END IF;

  -- Flatten forwards: link to the canonical's own head, if it has one.
  SELECT a."canonicalId" INTO head
    FROM public.topo_alternates a WHERE a."wallId" = canonical_id;
  head := coalesce(head, canonical_id);

  IF head = duplicate_id THEN
    -- A and B are already the same place, named from the other side. Doing
    -- nothing is the right answer: the alternative is deleting an existing
    -- link to write its mirror image, which changes no reader's experience.
    RETURN head;
  END IF;

  INSERT INTO public.topo_alternates
    ("wallId", "canonicalId", "linkedBy", note, "linkedAt")
  VALUES (duplicate_id, head, actor, nullif(btrim(coalesce(note, '')), ''), now_ms)
  ON CONFLICT ("wallId") DO UPDATE
    SET "canonicalId" = EXCLUDED."canonicalId",
        "linkedBy"    = EXCLUDED."linkedBy",
        note          = EXCLUDED.note,
        "linkedAt"    = EXCLUDED."linkedAt";

  -- Flatten backwards: adopt anything that was pointing at the topo we just
  -- demoted.
  UPDATE public.topo_alternates
     SET "canonicalId" = head, "linkedAt" = now_ms
   WHERE "canonicalId" = duplicate_id;

  INSERT INTO public.moderation_log
    (id, "actorId", action, "targetType", "targetId", reason, "createdAt")
  VALUES (gen_random_uuid()::text, actor, 'alternate_linked', 'wall',
          duplicate_id, 'canonical=' || head, now_ms);

  RETURN head;
END;
$$;

-- Undo. Detaches ONE wall from its group; the rest of the group is untouched,
-- which is why this takes the alternate rather than the canonical — unlinking
-- a head would silently dissolve a group somebody else built.
CREATE OR REPLACE FUNCTION public.unlink_alternate(wall_id text)
  RETURNS void
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  now_ms bigint := (extract(epoch FROM now()) * 1000)::bigint;
  actor  text   := (auth.uid())::text;
BEGIN
  IF actor IS NULL OR NOT public.is_admin() THEN
    RAISE EXCEPTION 'not authorised' USING ERRCODE = '42501';
  END IF;

  DELETE FROM public.topo_alternates WHERE "wallId" = wall_id;

  INSERT INTO public.moderation_log
    (id, "actorId", action, "targetType", "targetId", reason, "createdAt")
  VALUES (gen_random_uuid()::text, actor, 'alternate_unlinked', 'wall',
          wall_id, NULL, now_ms);
END;
$$;

GRANT EXECUTE ON FUNCTION public.link_alternate(text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.unlink_alternate(text)           TO authenticated;
