-- Community editing, Phase 5: the withdrawal cooldown and delete protection
-- (COMMUNITY_PLAN.md C-3, COMMUNITY_IMPL.md §0.1).
--
-- An owner may stop sharing a published topo, but not instantly: it stays
-- visible for 10 days, flagged to everyone, so people who planned a trip
-- around it get warning instead of finding a hole where the crag was.
--
-- The 10 days were already enforced — `is_wall_public()` has carried the
-- `withdrawRequestedAt` predicate since Phase 1, evaluated lazily inside the
-- visibility check rather than by a cron (§0.2). What was missing is both
-- ends of it: nothing could ever SET `withdrawRequestedAt` (the table has no
-- write policy at all), and nothing stopped an owner reaching the same
-- outcome by a route the predicate does not guard.
--
-- Idempotent, per this repo's migration convention.

-- ---------------------------------------------------------------------------
-- 1. The three ways to make a published topo vanish instantly
-- ---------------------------------------------------------------------------
--
-- A cooldown that only covers `visibility` is theatre. All three of these
-- reach exactly the same end state, and an owner has all three today:
--
--   a. visibility  → 'private'   (the obvious one)
--   b. deletedAt   → now         (the sync engine's soft delete)
--   c. accessState → 'sensitive' (Phase 2's suppression, which drops a topo
--                                 out of `is_wall_public` immediately)
--
-- (c) is the one that is easy to miss: Phase 2 added it for raptor nesting and
-- landowner sensitivity, where suppression is the correct outcome and an owner
-- should absolutely be able to ask for it. It just happens to also be a
-- one-tap bypass of this phase, so it is protected on a PUBLISHED topo and
-- freely settable on every other one.
--
-- IT REVERTS, IT DOES NOT RAISE. This is the resolution recorded in §0.1 and
-- it is not a stylistic choice:
--
--   `SupabaseSyncRemote.upsertOwnRows` batches per TABLE with one try/catch
--   around each (`sync_remote.dart:493-563`), so a trigger that RAISEs on one
--   wall row fails the ENTIRE `walls` push for that user — every unrelated
--   wall in the batch stays local too, and the client retries the same
--   poisoned batch forever. Reverting keeps the batch landing.
--
-- Bumping `updatedAt` is what makes it CONVERGE rather than ping-pong. The
-- client pushes state it believes; the server hands back something else; only
-- a strictly-newer server row causes the next pull's LWW to overwrite the
-- client's value instead of the client re-pushing it (`shouldPushLww`,
-- `sync_remote.dart:303-315`, local winning ties). Hence `GREATEST(..) + 1`
-- rather than plain `now()`: a client whose clock runs ahead of the server
-- would otherwise keep a strictly-newer local row and re-push it forever.
--
-- The user sees their unshare "bounce back", which is a poor experience — so
-- the CLIENT-SIDE guard is the primary path and offers the withdrawal flow
-- instead. This trigger is the backstop for a manipulated or stale client,
-- not the mechanism a normal user is ever meant to meet.

CREATE OR REPLACE FUNCTION public.protect_published_wall() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  now_ms    bigint := (extract(epoch FROM now()) * 1000)::bigint;
  mod_state text;
  mod_at    bigint;
  reverted  boolean := false;
BEGIN
  SELECT m.state, m."withdrawRequestedAt"
    INTO mod_state, mod_at
    FROM public.wall_moderation m
   WHERE m."wallId" = NEW.id;

  -- Nothing to protect unless it is actually live to the public. A draft is
  -- as freely deletable as it has always been (C-1: ninety percent of the app
  -- must not get slower because of the community feature), and a pending or
  -- rejected topo nobody else can see is the owner's to withdraw at will.
  IF mod_state IS DISTINCT FROM 'published' THEN
    RETURN NEW;
  END IF;

  -- A matured withdrawal IS the permission. Once the ten days have run, the
  -- topo is already out of `is_wall_public()` and the owner may finish the
  -- job — unshare it, delete it, whatever they meant to do ten days ago.
  IF mod_at IS NOT NULL AND mod_at <= now_ms - 864000000 THEN
    RETURN NEW;
  END IF;

  -- Admins are not who this is aimed at, and `remove_topo` exists for them.
  IF public.is_admin() THEN
    RETURN NEW;
  END IF;

  IF OLD.visibility = 'shared' AND NEW.visibility IS DISTINCT FROM 'shared' THEN
    NEW.visibility := OLD.visibility;
    reverted := true;
  END IF;

  -- Only a NEW deletion is refused. An already-deleted row staying deleted, or
  -- an undelete, both pass — this protects against destruction, not against
  -- restoration.
  IF NEW."deletedAt" IS NOT NULL AND OLD."deletedAt" IS NULL THEN
    NEW."deletedAt" := OLD."deletedAt";
    reverted := true;
  END IF;

  IF NEW."accessState" = 'sensitive'
     AND OLD."accessState" IS DISTINCT FROM 'sensitive' THEN
    NEW."accessState" := OLD."accessState";
    reverted := true;
  END IF;

  IF reverted THEN
    NEW."updatedAt" := GREATEST(COALESCE(NEW."updatedAt", 0), now_ms) + 1;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_protect_published_wall ON public.walls;
CREATE TRIGGER trg_protect_published_wall
  BEFORE UPDATE ON public.walls
  FOR EACH ROW EXECUTE FUNCTION public.protect_published_wall();

-- The same bypass, one and two levels up: `accessState = 'sensitive'` on a
-- sector or an area suppresses every topo beneath it (Phase 2 made the
-- suppression inherit, which is what makes hiding a whole crag one write).
-- An owner whose published topo is the only thing under their own area could
-- otherwise hide it instantly by closing the area.
--
-- Deliberately NOT extended to `deletedAt` on areas/sectors: `is_wall_public`
-- joins them only to read `accessState`, and does not check their `deletedAt`
-- at all, so deleting an area does not actually hide the walls under it. A
-- guard there would protect against nothing while making area deletion
-- mysteriously fail.
CREATE OR REPLACE FUNCTION public.protect_published_subtree() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  now_ms bigint := (extract(epoch FROM now()) * 1000)::bigint;
  guarded boolean;
BEGIN
  IF NEW."accessState" IS DISTINCT FROM 'sensitive'
     OR OLD."accessState" IS NOT DISTINCT FROM 'sensitive' THEN
    RETURN NEW;
  END IF;
  IF public.is_admin() THEN
    RETURN NEW;
  END IF;

  SELECT EXISTS (
    SELECT 1
      FROM public.walls w
      JOIN public.wall_moderation m ON m."wallId" = w.id
      LEFT JOIN public.sectors s ON s.id = w."sectorId"
     WHERE w."deletedAt" IS NULL
       AND m.state = 'published'
       AND (m."withdrawRequestedAt" IS NULL
            OR m."withdrawRequestedAt" > now_ms - 864000000)
       AND CASE TG_TABLE_NAME
             WHEN 'sectors' THEN w."sectorId" = NEW.id
             ELSE s."areaId" = NEW.id
           END
  ) INTO guarded;

  IF guarded THEN
    NEW."accessState" := OLD."accessState";
    NEW."updatedAt"   := GREATEST(COALESCE(NEW."updatedAt", 0), now_ms) + 1;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_protect_published_subtree ON public.sectors;
CREATE TRIGGER trg_protect_published_subtree
  BEFORE UPDATE ON public.sectors
  FOR EACH ROW EXECUTE FUNCTION public.protect_published_subtree();

DROP TRIGGER IF EXISTS trg_protect_published_subtree ON public.areas;
CREATE TRIGGER trg_protect_published_subtree
  BEFORE UPDATE ON public.areas
  FOR EACH ROW EXECUTE FUNCTION public.protect_published_subtree();

-- ---------------------------------------------------------------------------
-- 2. The withdrawal flow itself
-- ---------------------------------------------------------------------------
--
-- `wall_moderation` has a SELECT policy and no write policy at all, so these
-- RPCs are the only way the column can ever be set — the same shape every
-- other moderation mutation uses, and the reason an action and its audit-log
-- row cannot diverge.

-- Start the ten-day clock. Owner (or admin) only.
CREATE OR REPLACE FUNCTION public.request_withdrawal(wall_id text)
  RETURNS bigint
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  now_ms bigint := (extract(epoch FROM now()) * 1000)::bigint;
  actor  text   := (auth.uid())::text;
  owner  text;
  st     text;
  at_ms  bigint;
BEGIN
  IF actor IS NULL THEN
    RAISE EXCEPTION 'not authorised' USING ERRCODE = '42501';
  END IF;

  SELECT w."ownerId", m.state, m."withdrawRequestedAt"
    INTO owner, st, at_ms
    FROM public.walls w
    LEFT JOIN public.wall_moderation m ON m."wallId" = w.id
   WHERE w.id = wall_id;

  IF owner IS NULL AND st IS NULL THEN
    RAISE EXCEPTION 'unknown wall %', wall_id USING ERRCODE = 'P0002';
  END IF;
  IF owner IS DISTINCT FROM actor AND NOT public.is_admin() THEN
    RAISE EXCEPTION 'not authorised' USING ERRCODE = '42501';
  END IF;
  IF st IS DISTINCT FROM 'published' THEN
    -- Withdrawal is meaningless on anything else, and answering "fine" would
    -- leave the client showing a countdown for a topo that is not public.
    RAISE EXCEPTION 'topo is not published' USING ERRCODE = '22023';
  END IF;

  -- Idempotent: asking twice keeps the ORIGINAL deadline rather than
  -- restarting the clock. Restarting it would let a double tap silently cost
  -- the owner ten more days, and would let a retry after a flaky network do
  -- the same.
  IF at_ms IS NOT NULL THEN
    RETURN at_ms;
  END IF;

  UPDATE public.wall_moderation
     SET "withdrawRequestedAt" = now_ms,
         "updatedAt"           = now_ms
   WHERE "wallId" = wall_id;

  INSERT INTO public.moderation_log (id, "actorId", action, "targetType", "targetId", reason, "createdAt")
  VALUES (gen_random_uuid()::text, actor, 'withdraw_request', 'wall', wall_id, NULL, now_ms);

  RETURN now_ms;
END;
$$;

-- Stop the clock. Two genuinely different meanings depending on whether the
-- ten days have run, which is why the branch is here and not in the client:
--
--   * still running  → the withdrawal never happened. Straight back to
--                      published, no review, nothing lost.
--   * already matured → the topo is out of `is_wall_public()`; it is
--                      `withdrawn` in every sense a reader can observe. Coming
--                      back is a RE-SUBMISSION and goes through the queue
--                      again, per the state diagram in COMMUNITY_PLAN.md §1
--                      ("withdrawn | owner may re-submit").
--
-- Collapsing those two into one "just republish it" would hand anyone a way
-- to take a topo out of public view for a month and put it back unreviewed.
CREATE OR REPLACE FUNCTION public.cancel_withdrawal(wall_id text)
  RETURNS text
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  now_ms   bigint := (extract(epoch FROM now()) * 1000)::bigint;
  actor    text   := (auth.uid())::text;
  owner    text;
  st       text;
  at_ms    bigint;
  resubmit boolean;
BEGIN
  IF actor IS NULL THEN
    RAISE EXCEPTION 'not authorised' USING ERRCODE = '42501';
  END IF;

  SELECT w."ownerId", m.state, m."withdrawRequestedAt"
    INTO owner, st, at_ms
    FROM public.walls w
    LEFT JOIN public.wall_moderation m ON m."wallId" = w.id
   WHERE w.id = wall_id;

  IF owner IS NULL AND st IS NULL THEN
    RAISE EXCEPTION 'unknown wall %', wall_id USING ERRCODE = 'P0002';
  END IF;
  IF owner IS DISTINCT FROM actor AND NOT public.is_admin() THEN
    RAISE EXCEPTION 'not authorised' USING ERRCODE = '42501';
  END IF;
  IF at_ms IS NULL THEN
    -- Nothing running. Not an error: two taps on a slow connection must not
    -- produce a scary message for an outcome that is already what was wanted.
    RETURN COALESCE(st, 'draft');
  END IF;

  resubmit := at_ms <= now_ms - 864000000;

  UPDATE public.wall_moderation
     SET "withdrawRequestedAt" = NULL,
         state                 = CASE WHEN resubmit THEN 'pending' ELSE state END,
         "submittedAt"         = CASE WHEN resubmit THEN now_ms ELSE "submittedAt" END,
         "reviewedAt"          = CASE WHEN resubmit THEN NULL ELSE "reviewedAt" END,
         "rejectionReason"     = CASE WHEN resubmit THEN NULL ELSE "rejectionReason" END,
         "updatedAt"           = now_ms
   WHERE "wallId" = wall_id;

  INSERT INTO public.moderation_log (id, "actorId", action, "targetType", "targetId", reason, "createdAt")
  VALUES (gen_random_uuid()::text, actor,
          CASE WHEN resubmit THEN 'withdraw_resubmit' ELSE 'withdraw_cancel' END,
          'wall', wall_id, NULL, now_ms);

  RETURN CASE WHEN resubmit THEN 'pending' ELSE st END;
END;
$$;

-- ---------------------------------------------------------------------------
-- 3. Re-sharing a matured withdrawal goes back through review
-- ---------------------------------------------------------------------------
--
-- Without this there is a dead end. After the ten days, the trigger above lets
-- the owner unshare; `ensure_wall_moderation` only ever promotes a row sitting
-- in 'draft', so the row stays 'published' with a matured `withdrawRequestedAt`
-- — and re-sharing later does NOTHING observable. The topo is shared, the
-- state says published, and no reader can see it, with no error and no banner
-- to explain why.
--
-- Re-sharing after maturation is the same act as `cancel_withdrawal`'s
-- re-submit branch, so it lands in the same place: 'pending'.
CREATE OR REPLACE FUNCTION public.ensure_wall_moderation() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  now_ms bigint := (extract(epoch FROM now()) * 1000)::bigint;
BEGIN
  INSERT INTO public.wall_moderation ("wallId", state, "submittedAt", "updatedAt")
  VALUES (
    NEW.id,
    CASE WHEN NEW.visibility = 'shared' THEN 'pending' ELSE 'draft' END,
    CASE WHEN NEW.visibility = 'shared' THEN now_ms END,
    now_ms
  )
  ON CONFLICT ("wallId") DO UPDATE
    SET state         = 'pending',
        "submittedAt" = now_ms,
        -- Cleared so a re-submitted topo does not display a stale verdict from
        -- its previous life while it waits in the queue again.
        "reviewedAt"      = NULL,
        "rejectionReason" = NULL,
        "withdrawRequestedAt" = NULL,
        "updatedAt"   = now_ms
    WHERE NEW.visibility = 'shared'
      AND (
        -- Unchanged from Phase 3: a fresh submission.
        public.wall_moderation.state = 'draft'
        -- New in Phase 5: a matured withdrawal being re-shared.
        OR (public.wall_moderation.state = 'published'
            AND public.wall_moderation."withdrawRequestedAt" IS NOT NULL
            AND public.wall_moderation."withdrawRequestedAt" <= now_ms - 864000000)
      );
  RETURN NULL;
END;
$$;

-- ---------------------------------------------------------------------------
-- 4. Privileges
-- ---------------------------------------------------------------------------
GRANT EXECUTE ON FUNCTION public.request_withdrawal(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.cancel_withdrawal(text)  TO authenticated;
