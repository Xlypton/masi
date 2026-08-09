-- An admin can delete ANY topo, and any feed item, from the app.
--
-- DECIDED 2026-08-09. Until now an admin's strongest tool against a topo was
-- `remove_topo` — a takedown, which changes `wall_moderation.state` and hides
-- the topo from the public feed but leaves the row alive in its owner's
-- library and on every device that already pulled it. There was no way at all
-- to reach a foreign ASCENT or a foreign COMMENT: `ascents`/`comments`/`likes`
-- carry an owner policy and nothing else, so an admin looking at abusive text
-- under someone's ascent had literally no control to press.
--
-- WHY SOFT DELETE, NOT HARD DELETE. This is the whole of the design and it is
-- forced by the sync engine, not chosen for taste. Sync is a dirty-scoped
-- full-state re-push with tombstoned soft-delete and NO OUTBOX (decision D-4):
-- a delete travels to other devices as `deletedAt` on a row that is still
-- there. `DELETE FROM walls WHERE id = ...` would remove the row from Postgres
-- and tell nobody — every device that already holds it keeps it forever,
-- because the pull sees an absence and an absence means nothing. A hard delete
-- is therefore not a stronger delete here; it is a delete that does not
-- propagate. Tombstoning is the only shape that actually reaches the people
-- looking at the content.
--
-- The tombstone is also what keeps this compatible with §3.3 ("merge or
-- withdraw, never destroy"): the row, its routes, its ascents and its version
-- history all still exist in Postgres, so `admin_restore_topo` below can undo
-- the whole sweep. An admin gets a power that removes content from every
-- client and destroys no record.
--
-- WHY THE WITHDRAWAL COOLDOWN HAD TO BE TOUCHED. `protect_published_wall`
-- (phase 5, re-applied by 2026-08-08_deletion_requests.sql) silently REVERTS a
-- new `deletedAt` on a published or removed topo unless the withdrawal has
-- matured AND an approved deletion request exists — and it deliberately has no
-- admin exemption, so this RPC would have appeared to work and quietly undone
-- itself on the next pull. That trigger is correct for the flow it guards (an
-- OWNER destroying their own published work, which needs a second pair of
-- eyes), so it is not weakened: it gains ONE exemption, and the exemption
-- requires BOTH `public.is_admin()` AND a transaction-local GUC that only
-- `admin_delete_topo` sets, naming the exact wall being deleted. An ordinary
-- delete — by anyone, admin included, through any other path — never sets that
-- GUC and is still refused. The GUC alone is not authority; `is_admin()` is
-- checked alongside it, so even a caller who could somehow set it gains
-- nothing.
--
-- Idempotent, per this repo's migration convention.

-- ---------------------------------------------------------------------------
-- 1. The one exemption in the withdrawal/approval guard
-- ---------------------------------------------------------------------------
--
-- Byte-identical to the 2026-08-08_deletion_requests.sql version except for the
-- new first block. Reproduced in full rather than ALTERed because a Postgres
-- function has no partial edit, and keeping the body verbatim is what makes the
-- diff between the two migrations readable.
CREATE OR REPLACE FUNCTION public.protect_published_wall()
  RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  now_ms    bigint := (extract(epoch FROM now()) * 1000)::bigint;
  mod_state text;
  mod_at    bigint;
  reverted  boolean := false;
  approved  boolean;
  matured   boolean;
BEGIN
  -- THE ADMIN-DELETE EXEMPTION. Both halves are required: the caller must be
  -- an admin, AND this transaction must be inside `admin_delete_topo` for THIS
  -- wall. `set_config(..., is_local => true)` scopes the second half to the one
  -- statement-batch PostgREST runs for that RPC call, so it cannot leak into a
  -- later request, and naming the wall id means one admin delete cannot carry a
  -- second, unrelated wall through the guard in the same transaction.
  IF public.is_admin()
     AND current_setting('masi.admin_delete_wall', true) = NEW.id THEN
    RETURN NEW;
  END IF;

  SELECT m.state, m."withdrawRequestedAt"
    INTO mod_state, mod_at
    FROM public.wall_moderation m
   WHERE m."wallId" = NEW.id;

  -- Nothing to protect unless it is, or has been, live to the public. A draft
  -- is as freely deletable as it has always been (C-1: ninety percent of the
  -- app must not get slower because of the community feature), and a pending or
  -- rejected topo nobody else can see is the owner's to withdraw at will.
  IF mod_state IS NULL OR mod_state NOT IN ('published', 'removed') THEN
    RETURN NEW;
  END IF;

  -- A removed topo has no withdrawal to wait out - it is already out of public
  -- view, so the ten days would protect nobody. Its gate is the approval alone.
  matured := mod_state = 'removed'
          OR (mod_at IS NOT NULL AND mod_at <= now_ms - 864000000);

  SELECT EXISTS (
    SELECT 1 FROM public.deletion_requests d
     WHERE d."wallId" = NEW.id AND d.status = 'approved'
  ) INTO approved;

  -- Unsharing is NOT destruction, and it is what the withdrawal is for. A
  -- matured withdrawal is still the whole permission for taking a topo out of
  -- public view; only DELETION now asks for more.
  IF OLD.visibility = 'shared' AND NEW.visibility IS DISTINCT FROM 'shared'
     AND NOT matured AND NOT public.is_admin() THEN
    NEW.visibility := OLD.visibility;
    reverted := true;
  END IF;

  -- Only a NEW deletion is refused. An already-deleted row staying deleted, or
  -- an undelete, both pass - this protects against destruction, not against
  -- restoration.
  IF NEW."deletedAt" IS NOT NULL AND OLD."deletedAt" IS NULL
     AND NOT (matured AND approved) THEN
    NEW."deletedAt" := OLD."deletedAt";
    reverted := true;
  END IF;

  IF NEW."accessState" = 'sensitive'
     AND OLD."accessState" IS DISTINCT FROM 'sensitive'
     AND NOT public.is_admin() THEN
    NEW."accessState" := OLD."accessState";
    reverted := true;
  END IF;

  IF reverted THEN
    NEW."updatedAt" := GREATEST(COALESCE(NEW."updatedAt", 0), now_ms) + 1;
  END IF;

  RETURN NEW;
END;
$$;

-- ---------------------------------------------------------------------------
-- 2. Deleting a topo
-- ---------------------------------------------------------------------------
--
-- The cascade is a deliberate copy of the CLIENT's own
-- `LibraryCrudRepository._cascadeSoftDeleteWallSubtree`: photos, routes,
-- ascents, comments, likes, then the wall. Same rows, same order, same single
-- timestamp. Two different sweeps for "delete this topo" is how a topo ends up
-- gone from the list with its ascents still in someone's logbook — which is
-- bug #5, already fixed once on the client side.
--
-- It takes OTHER PEOPLE'S ascents/comments/likes on this topo with it, and that
-- is intentional: they reference a wall that no longer exists anywhere, and
-- leaving them is precisely the dangling-logbook-entry bug the client cascade
-- was written to fix. It is also why this is a tombstone — `admin_restore_topo`
-- puts every one of them back.
--
-- Returns the deletion instant in epoch ms. Idempotent: deleting an
-- already-deleted topo returns its EXISTING `deletedAt` and writes no second
-- log entry, so a double tap on a slow connection costs nothing and does not
-- put two identical rows in the audit log.
CREATE OR REPLACE FUNCTION public.admin_delete_topo(
  wall_id text,
  reason  text DEFAULT NULL
) RETURNS bigint
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  now_ms  bigint := (extract(epoch FROM now()) * 1000)::bigint;
  actor   text   := (auth.uid())::text;
  already bigint;
  found   boolean;
BEGIN
  IF actor IS NULL OR NOT public.is_admin() THEN
    RAISE EXCEPTION 'not authorised' USING ERRCODE = '42501';
  END IF;

  SELECT true, w."deletedAt" INTO found, already
    FROM public.walls w WHERE w.id = wall_id;
  IF found IS NOT TRUE THEN
    RAISE EXCEPTION 'unknown wall %', wall_id USING ERRCODE = 'P0002';
  END IF;
  IF already IS NOT NULL THEN
    RETURN already;
  END IF;

  -- Opens the one door in `protect_published_wall`, for this wall, for this
  -- transaction only.
  PERFORM set_config('masi.admin_delete_wall', wall_id, true);

  UPDATE public.photos
     SET "deletedAt" = now_ms, "updatedAt" = now_ms
   WHERE "wallId" = wall_id AND "deletedAt" IS NULL;

  UPDATE public.routes
     SET "deletedAt" = now_ms, "updatedAt" = now_ms
   WHERE "wallId" = wall_id AND "deletedAt" IS NULL;

  UPDATE public.ascents
     SET "deletedAt" = now_ms, "updatedAt" = now_ms
   WHERE "wallId" = wall_id AND "deletedAt" IS NULL;

  UPDATE public.comments
     SET "deletedAt" = now_ms, "updatedAt" = now_ms
   WHERE "wallId" = wall_id AND "deletedAt" IS NULL;

  UPDATE public.likes
     SET "deletedAt" = now_ms, "updatedAt" = now_ms
   WHERE "wallId" = wall_id AND "deletedAt" IS NULL;

  UPDATE public.walls
     SET "deletedAt" = now_ms, "updatedAt" = now_ms
   WHERE id = wall_id AND "deletedAt" IS NULL;

  -- Moderation state follows, so a restored topo does not come back publicly
  -- visible with nobody having decided that. A DRAFT is left alone on purpose:
  -- it was never public, "removed" would be a lie about it, and
  -- `ensure_wall_moderation` only ever re-enters the queue from 'draft' — so
  -- overwriting it would strand a restored draft outside the review flow
  -- forever.
  UPDATE public.wall_moderation
     SET state        = 'removed',
         "reviewedAt" = now_ms,
         "reviewerId" = actor,
         "updatedAt"  = now_ms
   WHERE "wallId" = wall_id AND state <> 'draft';

  INSERT INTO public.moderation_log
    (id, "actorId", action, "targetType", "targetId", reason, "createdAt")
  VALUES (gen_random_uuid()::text, actor, 'admin_delete', 'wall', wall_id,
          reason, now_ms);

  -- Shut the door behind us. `is_local => true` scopes the setting to the
  -- TRANSACTION, not the statement, and while PostgREST gives each request its
  -- own transaction — so nothing else in the app could ever observe it set —
  -- leaving it open means any later statement in this transaction inherits the
  -- exemption. Measured, not assumed: the rollback-safe live test for this
  -- migration caught exactly that, with a plain UPDATE after the RPC sailing
  -- through the guard.
  PERFORM set_config('masi.admin_delete_wall', '', true);

  RETURN now_ms;
END;
$$;

-- Undo one `admin_delete_topo` sweep.
--
-- This is what makes the delete above safe to give to one person with no
-- second pair of eyes: it is reversible, exactly, and by the same tap count.
--
-- Scoped by the wall's own `deletedAt` INSTANT rather than "everything
-- currently deleted under this wall". A topo usually has rows the owner
-- deleted themselves months earlier — a retired route, a replaced photo — and
-- resurrecting those would make a restore hand back something that was never
-- taken away.
--
-- The moderation state stays 'removed'. Restoring the rows gives the owner
-- their topo back; putting it in front of the public again is a separate
-- decision with a separate control (`review_topo(..., approve => true)`).
CREATE OR REPLACE FUNCTION public.admin_restore_topo(
  wall_id text,
  reason  text DEFAULT NULL
) RETURNS bigint
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  now_ms bigint := (extract(epoch FROM now()) * 1000)::bigint;
  actor  text   := (auth.uid())::text;
  at_ms  bigint;
  found  boolean;
BEGIN
  IF actor IS NULL OR NOT public.is_admin() THEN
    RAISE EXCEPTION 'not authorised' USING ERRCODE = '42501';
  END IF;

  SELECT true, w."deletedAt" INTO found, at_ms
    FROM public.walls w WHERE w.id = wall_id;
  IF found IS NOT TRUE THEN
    RAISE EXCEPTION 'unknown wall %', wall_id USING ERRCODE = 'P0002';
  END IF;
  -- Not deleted: nothing to undo, and saying so with an error would make a
  -- double tap look like a failure.
  IF at_ms IS NULL THEN
    RETURN NULL;
  END IF;

  -- An undelete needs no exemption — `protect_published_wall` passes it
  -- already ("this protects against destruction, not against restoration") —
  -- but the GUC is set anyway so the restore path never depends on that
  -- reading of somebody else's trigger staying true.
  PERFORM set_config('masi.admin_delete_wall', wall_id, true);

  UPDATE public.walls
     SET "deletedAt" = NULL, "updatedAt" = now_ms
   WHERE id = wall_id;

  UPDATE public.photos   SET "deletedAt" = NULL, "updatedAt" = now_ms
   WHERE "wallId" = wall_id AND "deletedAt" = at_ms;
  UPDATE public.routes   SET "deletedAt" = NULL, "updatedAt" = now_ms
   WHERE "wallId" = wall_id AND "deletedAt" = at_ms;
  UPDATE public.ascents  SET "deletedAt" = NULL, "updatedAt" = now_ms
   WHERE "wallId" = wall_id AND "deletedAt" = at_ms;
  UPDATE public.comments SET "deletedAt" = NULL, "updatedAt" = now_ms
   WHERE "wallId" = wall_id AND "deletedAt" = at_ms;
  UPDATE public.likes    SET "deletedAt" = NULL, "updatedAt" = now_ms
   WHERE "wallId" = wall_id AND "deletedAt" = at_ms;

  INSERT INTO public.moderation_log
    (id, "actorId", action, "targetType", "targetId", reason, "createdAt")
  VALUES (gen_random_uuid()::text, actor, 'admin_restore', 'wall', wall_id,
          reason, now_ms);

  -- Same reasoning as `admin_delete_topo`'s closing line.
  PERFORM set_config('masi.admin_delete_wall', '', true);

  RETURN now_ms;
END;
$$;

-- ---------------------------------------------------------------------------
-- 3. Deleting a feed item
-- ---------------------------------------------------------------------------
--
-- An ascent and its thread. The comments and likes hanging off it go too,
-- because a comment whose ascent is gone is unreachable text that still
-- notifies people and still counts, and the client's own wall cascade already
-- treats the three as one unit.
--
-- Note what is NOT here: a standalone `admin_delete_like`. A like carries no
-- content, so there is nothing in one to moderate; the only reason to remove
-- one is that the thing it points at is going, and that is the cascade above.
CREATE OR REPLACE FUNCTION public.admin_delete_ascent(
  ascent_id text,
  reason    text DEFAULT NULL
) RETURNS bigint
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  now_ms  bigint := (extract(epoch FROM now()) * 1000)::bigint;
  actor   text   := (auth.uid())::text;
  already bigint;
  found   boolean;
BEGIN
  IF actor IS NULL OR NOT public.is_admin() THEN
    RAISE EXCEPTION 'not authorised' USING ERRCODE = '42501';
  END IF;

  SELECT true, a."deletedAt" INTO found, already
    FROM public.ascents a WHERE a.id = ascent_id;
  IF found IS NOT TRUE THEN
    RAISE EXCEPTION 'unknown ascent %', ascent_id USING ERRCODE = 'P0002';
  END IF;
  IF already IS NOT NULL THEN
    RETURN already;
  END IF;

  UPDATE public.comments
     SET "deletedAt" = now_ms, "updatedAt" = now_ms
   WHERE "ascentId" = ascent_id AND "deletedAt" IS NULL;

  UPDATE public.likes
     SET "deletedAt" = now_ms, "updatedAt" = now_ms
   WHERE "ascentId" = ascent_id AND "deletedAt" IS NULL;

  UPDATE public.ascents
     SET "deletedAt" = now_ms, "updatedAt" = now_ms
   WHERE id = ascent_id;

  INSERT INTO public.moderation_log
    (id, "actorId", action, "targetType", "targetId", reason, "createdAt")
  VALUES (gen_random_uuid()::text, actor, 'admin_delete', 'ascent', ascent_id,
          reason, now_ms);

  RETURN now_ms;
END;
$$;

-- One comment, in either thread (a topo comment carries `wallId`, an ascent
-- comment carries `ascentId`; this needs to know neither).
CREATE OR REPLACE FUNCTION public.admin_delete_comment(
  comment_id text,
  reason     text DEFAULT NULL
) RETURNS bigint
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  now_ms  bigint := (extract(epoch FROM now()) * 1000)::bigint;
  actor   text   := (auth.uid())::text;
  already bigint;
  found   boolean;
BEGIN
  IF actor IS NULL OR NOT public.is_admin() THEN
    RAISE EXCEPTION 'not authorised' USING ERRCODE = '42501';
  END IF;

  SELECT true, c."deletedAt" INTO found, already
    FROM public.comments c WHERE c.id = comment_id;
  IF found IS NOT TRUE THEN
    RAISE EXCEPTION 'unknown comment %', comment_id USING ERRCODE = 'P0002';
  END IF;
  IF already IS NOT NULL THEN
    RETURN already;
  END IF;

  UPDATE public.comments
     SET "deletedAt" = now_ms, "updatedAt" = now_ms
   WHERE id = comment_id;

  INSERT INTO public.moderation_log
    (id, "actorId", action, "targetType", "targetId", reason, "createdAt")
  VALUES (gen_random_uuid()::text, actor, 'admin_delete', 'comment',
          comment_id, reason, now_ms);

  RETURN now_ms;
END;
$$;

-- ---------------------------------------------------------------------------
-- 4. Privileges
-- ---------------------------------------------------------------------------
--
-- SEC-1/SEC-2's rule, applied without being asked twice: `REVOKE ... FROM
-- public` does NOT remove Supabase's default-privilege grant to `anon` and
-- `authenticated`, which are real roles rather than members of the PUBLIC
-- pseudo-role. Every role is named. Each function also carries its own
-- `is_admin()` guard as its first statement, so the grant is the second line
-- of defence rather than the only one.
REVOKE ALL ON FUNCTION public.admin_delete_topo(text, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_delete_topo(text, text) TO authenticated;

REVOKE ALL ON FUNCTION public.admin_restore_topo(text, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_restore_topo(text, text) TO authenticated;

REVOKE ALL ON FUNCTION public.admin_delete_ascent(text, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_delete_ascent(text, text) TO authenticated;

REVOKE ALL ON FUNCTION public.admin_delete_comment(text, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_delete_comment(text, text) TO authenticated;
