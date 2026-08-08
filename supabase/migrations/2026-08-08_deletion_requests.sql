-- Deleting a published topo needs an admin's approval.
--
-- DECIDED 2026-08-08. Until now there was no approval anywhere, and it is worth
-- writing down what the protection actually WAS, because it is easy to assume
-- it was more than it is: `protect_published_wall` silently reverts an owner's
-- soft-delete of a published topo, so the owner must Withdraw, wait ten days,
-- and only then delete. That is a TIME LOCK, not a review. Nobody looks at it.
-- And the trigger returns early for admins, so an admin could always delete
-- outright with no second pair of eyes at all.
--
-- THE TWO GATES PROTECT DIFFERENT THINGS, so both apply and neither replaces
-- the other:
--
--   * the ten-day withdrawal protects READERS (C-3) - a topo people rely on
--     does not vanish from under them without notice. Unchanged here.
--   * admin approval protects THE RECORD (§3.3 - never destroy something people
--     have logged ascents against). New.
--
-- A published topo becomes deletable only when BOTH hold: it is no longer
-- publicly visible (the withdrawal matured, or it was never published) AND an
-- approved deletion request exists for it. The request can be filed at any
-- time, so the two clocks run in PARALLEL - this adds a review, not a second
-- waiting period.
--
-- WHAT IS DELIBERATELY LEFT ALONE: a draft, pending or rejected topo stays
-- freely and instantly deletable. It is the owner's scratch space, nobody else
-- can see it, and C-1 is explicit that the other ninety percent of the app must
-- not get slower or more ceremonious because of the community feature.
--
-- ADMINS NOW GO THROUGH THE SAME DOOR. The old early-return for admins is gone.
-- An admin deleting a published topo needs an approved request like anyone else
-- - it may be their own, so this is one extra deliberate step rather than a
-- blocker, and `remove_topo` (takedown, reversible, keeps the record) remains
-- the tool for moderation. The point is that no single tap from any account can
-- destroy a published topo.

-- ---------------------------------------------------------------------------
-- 1. The table
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.deletion_requests (
  id            text PRIMARY KEY,
  "wallId"      text   NOT NULL,
  "requesterId" text   NOT NULL,
  reason        text,
  -- pending | approved | rejected
  status        text   NOT NULL DEFAULT 'pending',
  "createdAt"   bigint NOT NULL,
  "resolvedAt"  bigint,
  "reviewerId"  text,
  resolution    text
);

-- One open request per topo. Without this an owner tapping twice queues the
-- same topo twice and an admin sees a duplicate they cannot tell apart.
CREATE UNIQUE INDEX IF NOT EXISTS deletion_requests_open_wall
  ON public.deletion_requests ("wallId") WHERE status = 'pending';

CREATE INDEX IF NOT EXISTS deletion_requests_created_at
  ON public.deletion_requests ("createdAt");

ALTER TABLE public.deletion_requests ENABLE ROW LEVEL SECURITY;

-- Readable by the requester and by admins. NO write policy at all: every
-- mutation goes through a SECURITY DEFINER RPC, so the decision and its
-- audit-log entry cannot diverge.
--
-- Unlike a report, the requester SHOULD see their own row - they are asking for
-- something and are entitled to know whether it was granted. A report is
-- different because several of its reasons are accusations about the owner.
DROP POLICY IF EXISTS deletion_requests_read ON public.deletion_requests;
CREATE POLICY deletion_requests_read
  ON public.deletion_requests
  FOR SELECT TO authenticated
  USING ("requesterId" = (auth.uid())::text OR public.is_admin());

GRANT SELECT ON public.deletion_requests TO authenticated;

-- ---------------------------------------------------------------------------
-- 2. Asking
-- ---------------------------------------------------------------------------

DROP FUNCTION IF EXISTS public.request_deletion(text, text);

-- Owner-only, and idempotent: asking twice returns the SAME pending request
-- rather than opening a second one or raising. A retap must not cost the owner
-- anything, and must not put two rows in front of an admin.
CREATE OR REPLACE FUNCTION public.request_deletion(wall_id text, reason text DEFAULT NULL)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE
  now_ms   bigint := (extract(epoch FROM now()) * 1000)::bigint;
  actor    text   := (auth.uid())::text;
  owner    text;
  st       text;
  existing text;
  new_id   text;
BEGIN
  IF actor IS NULL THEN
    RAISE EXCEPTION 'not authorised' USING ERRCODE = '42501';
  END IF;

  SELECT w."ownerId" INTO owner FROM public.walls w
   WHERE w.id = wall_id AND w."deletedAt" IS NULL;
  IF owner IS NULL THEN
    RAISE EXCEPTION 'unknown wall %', wall_id USING ERRCODE = 'P0002';
  END IF;
  IF owner IS DISTINCT FROM actor THEN
    RAISE EXCEPTION 'not authorised' USING ERRCODE = '42501';
  END IF;

  SELECT m.state INTO st FROM public.wall_moderation m WHERE m."wallId" = wall_id;
  -- Only a topo that HAS been public needs anyone's permission. Asking about a
  -- draft is a programming error on the client, not a request to queue - and
  -- answering it with a row would teach an admin that this queue is noise.
  --
  -- `removed` counts. A taken-down topo is out of public view but its record is
  -- exactly what §3.3 protects - people logged ascents against it, and letting
  -- the owner quietly delete it afterwards would destroy the evidence a
  -- takedown exists to preserve.
  IF st IS NULL OR st NOT IN ('published', 'removed') THEN
    RAISE EXCEPTION 'wall % was never public; delete it directly', wall_id
      USING ERRCODE = 'P0001';
  END IF;

  SELECT d.id INTO existing FROM public.deletion_requests d
   WHERE d."wallId" = wall_id AND d.status = 'pending' LIMIT 1;
  IF existing IS NOT NULL THEN
    RETURN existing;
  END IF;

  new_id := gen_random_uuid()::text;
  INSERT INTO public.deletion_requests
    (id, "wallId", "requesterId", reason, status, "createdAt")
  VALUES (new_id, wall_id, actor, reason, 'pending', now_ms)
  ON CONFLICT DO NOTHING;

  -- The index may have refused a concurrent duplicate; return whichever row is
  -- actually open, so two taps never report two different ids.
  SELECT d.id INTO existing FROM public.deletion_requests d
   WHERE d."wallId" = wall_id AND d.status = 'pending' LIMIT 1;
  RETURN coalesce(existing, new_id);
END;
$$;

REVOKE ALL ON FUNCTION public.request_deletion(text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.request_deletion(text, text) TO authenticated;

-- ---------------------------------------------------------------------------
-- 3. Deciding
-- ---------------------------------------------------------------------------

DROP FUNCTION IF EXISTS public.review_deletion(text, boolean, text);

-- Admin-only. Approving GRANTS PERMISSION; it does not delete anything.
--
-- That split is deliberate. The owner asked to destroy their own work, so the
-- act stays theirs - and an approval that deleted immediately would make an
-- admin's mis-tap unrecoverable, which is exactly what this whole mechanism
-- exists to prevent.
CREATE OR REPLACE FUNCTION public.review_deletion(
  request_id text,
  approve    boolean,
  note       text DEFAULT NULL
)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE
  now_ms    bigint := (extract(epoch FROM now()) * 1000)::bigint;
  actor     text   := (auth.uid())::text;
  wall      text;
  was       text;
  st        text;
  requester text;
BEGIN
  IF actor IS NULL OR NOT public.is_admin() THEN
    RAISE EXCEPTION 'not authorised' USING ERRCODE = '42501';
  END IF;

  SELECT d."wallId", d.status, d."requesterId" INTO wall, was, requester
    FROM public.deletion_requests d WHERE d.id = request_id;
  IF wall IS NULL THEN
    RAISE EXCEPTION 'unknown request %', request_id USING ERRCODE = 'P0002';
  END IF;

  -- AN ADMIN MAY NOT RUBBER-STAMP THEIR OWN REQUEST while another admin exists
  -- to ask. The whole value of this gate is a second pair of eyes, and an admin
  -- who owns the topo would otherwise have none - they would simply file and
  -- approve in two taps, which is the "casual deletion" this was built to stop.
  --
  -- Conditional on another admin EXISTING, deliberately. A hard self-approval
  -- ban would deadlock a single-admin project: the only admin could never
  -- delete their own topo and would have to recruit a second admin to escape.
  -- So the rule gives the strongest guarantee the population allows, and
  -- degrades to "approve your own" only when there is genuinely nobody else.
  IF requester = actor AND EXISTS (
    SELECT 1 FROM public.admins a WHERE a."userId" <> actor
  ) THEN
    RAISE EXCEPTION 'another admin has to review your own deletion request'
      USING ERRCODE = '42501';
  END IF;
  -- Already decided: report the standing decision rather than overwriting it.
  -- Flipping an approval back to rejected after the owner has acted on it would
  -- be a decision about something that no longer exists.
  IF was IS DISTINCT FROM 'pending' THEN
    RETURN was;
  END IF;

  st := CASE WHEN approve THEN 'approved' ELSE 'rejected' END;

  UPDATE public.deletion_requests
     SET status = st, "resolvedAt" = now_ms, "reviewerId" = actor, resolution = note
   WHERE id = request_id;

  INSERT INTO public.moderation_log
    (id, "actorId", action, "targetType", "targetId", reason, "createdAt")
  VALUES (gen_random_uuid()::text, actor,
          CASE WHEN approve THEN 'deletion_approved' ELSE 'deletion_rejected' END,
          'wall', wall, note, now_ms);

  RETURN st;
END;
$$;

REVOKE ALL ON FUNCTION public.review_deletion(text, boolean, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.review_deletion(text, boolean, text) TO authenticated;

-- ---------------------------------------------------------------------------
-- 4. The queue
-- ---------------------------------------------------------------------------

DROP FUNCTION IF EXISTS public.deletion_requests_queue(int);

-- Oldest first, like the submissions queue: somebody is waiting on this one,
-- and the number that matters is how long they have been kept waiting.
CREATE OR REPLACE FUNCTION public.deletion_requests_queue(limit_count int DEFAULT 50)
RETURNS TABLE (
  "id"            text,
  "wallId"        text,
  "wallName"      text,
  "requesterId"   text,
  "requesterName" text,
  "reason"        text,
  "routeCount"    bigint,
  "ascentCount"   bigint,
  "createdAt"     bigint
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
BEGIN
  IF (auth.uid()) IS NULL OR NOT public.is_admin() THEN
    RAISE EXCEPTION 'not authorised' USING ERRCODE = '42501';
  END IF;

  limit_count := greatest(1, least(coalesce(limit_count, 50), 200));

  RETURN QUERY
  SELECT d.id, d."wallId", w.name, d."requesterId", p."displayName", d.reason,
         (SELECT count(*) FROM public.routes r
           WHERE r."wallId" = w.id AND r."deletedAt" IS NULL),
         -- What the community loses if this is approved. An admin deciding
         -- whether to destroy a topo needs to know that eleven people logged
         -- ascents on it, and that number is the whole reason §3.3 exists.
         (SELECT count(*) FROM public.ascents a
           WHERE a."wallId" = w.id AND a."deletedAt" IS NULL),
         d."createdAt"
    FROM public.deletion_requests d
    JOIN public.walls w        ON w.id = d."wallId"
    LEFT JOIN public.profiles p ON p.id = d."requesterId"
   WHERE d.status = 'pending'
     AND w."deletedAt" IS NULL
   ORDER BY d."createdAt" ASC
   LIMIT limit_count;
END;
$$;

REVOKE ALL ON FUNCTION public.deletion_requests_queue(int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.deletion_requests_queue(int) TO authenticated;

-- ---------------------------------------------------------------------------
-- 5. The trigger, re-applied with the approval gate
-- ---------------------------------------------------------------------------
--
-- Identical to the phase-5 version except for two changes, both narrowing:
--
--   * a published topo's delete now ALSO needs an approved request, on top of
--     the matured withdrawal it already needed;
--   * the blanket admin early-return is gone, so no account can destroy a
--     published topo in one step.
--
-- Everything else - the draft passthrough, the unshare revert, the sensitive
-- revert, and the undelete passthrough (this protects against destruction, not
-- against restoration) - is unchanged.
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
  SELECT m.state, m."withdrawRequestedAt"
    INTO mod_state, mod_at
    FROM public.wall_moderation m
   WHERE m."wallId" = NEW.id;

  -- Nothing to protect unless it is, or has been, live to the public. A draft
  -- is as freely deletable as it has always been (C-1: ninety percent of the
  -- app must not get slower because of the community feature), and a pending or
  -- rejected topo nobody else can see is the owner's to withdraw at will.
  --
  -- `removed` is in the protected set, and was NOT before this migration. A
  -- takedown moves the state off `published`, so the old early-return handed a
  -- taken-down topo straight back to its owner to delete at will - destroying
  -- the record §3.3 protects, and the evidence the takedown was about. That was
  -- a hole from the day takedowns shipped.
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
  --
  -- BOTH gates, and note there is no admin exemption: the ten days protect the
  -- readers, the approved request protects the record, and an admin needs the
  -- second one exactly like everybody else. `remove_topo` is still the tool for
  -- moderation, and it takes a topo down without destroying it.
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
