-- Community editing, Phase 6b: reporting (COMMUNITY_PLAN.md C-7).
--
-- An approval queue only catches content at submission time. Content goes bad
-- LATER: a route is retro-bolted, a boulder is chipped, access is revoked, a
-- photo turns out to show someone's face. Without a report path the only
-- people who can act are the owner — who may be the problem — and an admin who
-- happens to look.
--
-- Together with version history (6a) this is what carries the weight now that
-- an owner's approval is final and nothing is re-reviewed after publication
-- (C-5c). Cut either and the answer to "what stops someone wrecking a topo
-- everyone relies on" is genuinely nothing.
--
-- Idempotent, per this repo's migration convention.

-- ---------------------------------------------------------------------------
-- 1. The table
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.content_reports (
  id           text PRIMARY KEY,
  "wallId"     text NOT NULL REFERENCES public.walls(id) ON DELETE CASCADE,
  "routeId"    text REFERENCES public.routes(id) ON DELETE CASCADE,
  "reporterId" text NOT NULL,
  reason       text NOT NULL,   -- inaccurate|unsafe|duplicate|access|inappropriate|not_yours
  body         text,
  status       text NOT NULL DEFAULT 'open',  -- open|upheld|dismissed
  "resolvedAt" bigint,
  "resolverId" text,
  resolution   text,
  "createdAt"  bigint NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_content_reports_open
  ON public.content_reports (status, "createdAt");
CREATE INDEX IF NOT EXISTS idx_content_reports_wall
  ON public.content_reports ("wallId", status);
CREATE INDEX IF NOT EXISTS idx_content_reports_reporter
  ON public.content_reports ("reporterId", "createdAt");

ALTER TABLE public.content_reports ENABLE ROW LEVEL SECURITY;

-- Readable by the person who filed it, and by admins. NOT by the topo's owner.
--
-- That exclusion is deliberate and it is the difference between a report
-- system people use and one they do not. A report is an accusation, several of
-- the reasons are ABOUT the owner ("not your content", "inappropriate"), and
-- handing the accused the reporter's identity is how you teach a community
-- that reporting invites retaliation. The owner learns through the admin's
-- decision, which is the same way it works on every platform in §3.1.
--
-- Note this is the opposite arrangement from `topo_hazards` (phase 4), and
-- that is on purpose too: a hazard is a public safety warning that everyone
-- including the owner must see, while a report is a private complaint about
-- the content itself.
DROP POLICY IF EXISTS content_reports_select ON public.content_reports;
CREATE POLICY content_reports_select ON public.content_reports FOR SELECT
  USING ("reporterId" = (auth.uid())::text OR public.is_admin());

-- No INSERT policy either — `report_content` is the only way in, so the rate
-- limits below cannot be bypassed by writing the table directly. No UPDATE or
-- DELETE policy at all: a report, once filed, is resolved rather than erased.

-- ---------------------------------------------------------------------------
-- 2. Filing a report
-- ---------------------------------------------------------------------------
--
-- Rate-limited, because reporting is the cheapest griefing vector in the whole
-- design: it costs the troll one tap and the admin one decision. Two limits,
-- doing different jobs:
--
--   * ONE OPEN REPORT per person per topo per reason. Tapping twice is not a
--     stronger signal, it is the same signal twice, and it is what turns one
--     annoyed user into twelve queue entries. Returns the existing report
--     rather than erroring — from the reporter's side the outcome they wanted
--     is already true.
--   * TWENTY PER DAY per person overall. Deliberately loose: a genuine user
--     walking a crag and finding six wrong grades must not be stopped, so this
--     is a wall against automation rather than a quota on diligence.
CREATE OR REPLACE FUNCTION public.report_content(
  wall_id  text,
  reason   text,
  body     text DEFAULT NULL,
  route_id text DEFAULT NULL
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

  -- Aliased, because the `reason` PARAMETER and the `reason` COLUMN would
  -- otherwise both be in scope and Postgres refuses the ambiguity outright
  -- (42702) rather than picking one.
  SELECT c.id INTO existing
    FROM public.content_reports c
   WHERE c."wallId" = wall_id
     AND c."reporterId" = actor
     AND c.reason = report_content.reason
     AND c.status = 'open'
     AND c."routeId" IS NOT DISTINCT FROM route_id
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
    (id, "wallId", "routeId", "reporterId", reason, body, status, "createdAt")
  VALUES (new_id, wall_id, route_id, actor, reason,
          nullif(btrim(coalesce(body, '')), ''), 'open', now_ms);

  RETURN new_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- 3. The admin queue for reports
-- ---------------------------------------------------------------------------
--
-- "Unsafe" is not just another category (C-12). This is climbing: a missing
-- loose-block warning, a wrong bolt count, a topo line drawn past a runout can
-- hurt someone. So an unsafe report sorts to the FRONT regardless of age,
-- rather than waiting behind twelve duplicate-listing complaints filed last
-- week. That is the whole of "escalated, not queued" made concrete, and it is
-- one ORDER BY term rather than a separate workflow.
CREATE OR REPLACE FUNCTION public.moderation_reports(limit_count int DEFAULT 50)
  RETURNS TABLE (
    id            text,
    "wallId"      text,
    "wallName"    text,
    "routeId"     text,
    "routeName"   text,
    "reporterId"  text,
    "reporterName" text,
    reason        text,
    body          text,
    urgent        boolean,
    "createdAt"   bigint
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
         c."createdAt"
    FROM public.content_reports c
    JOIN public.walls w ON w.id = c."wallId"
    LEFT JOIN public.routes r   ON r.id = c."routeId"
    LEFT JOIN public.profiles pr ON pr."ownerId" = c."reporterId"
   WHERE c.status = 'open'
   ORDER BY (c.reason = 'unsafe') DESC, c."createdAt" ASC
   LIMIT limit_count;
END;
$$;

-- Close a report. Admin-only.
--
-- `upheld` versus `dismissed` is recorded rather than collapsed into "closed"
-- because phase 8's trust levels need it in both directions: an account whose
-- reports are consistently upheld has earned weight, and one whose reports are
-- consistently dismissed has earned the opposite (C-7: "repeated frivolous
-- reports lower trust"). Nothing reads it yet; throwing the distinction away
-- now would mean having no history to compute from when something does.
CREATE OR REPLACE FUNCTION public.resolve_report(
  report_id text,
  uphold    boolean,
  note      text DEFAULT NULL
) RETURNS text
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  now_ms bigint := (extract(epoch FROM now()) * 1000)::bigint;
  actor  text   := (auth.uid())::text;
  wall   text;
  st     text;
BEGIN
  IF actor IS NULL OR NOT public.is_admin() THEN
    RAISE EXCEPTION 'not authorised' USING ERRCODE = '42501';
  END IF;

  SELECT "wallId" INTO wall FROM public.content_reports WHERE id = report_id;
  IF wall IS NULL THEN
    RAISE EXCEPTION 'unknown report %', report_id USING ERRCODE = 'P0002';
  END IF;

  st := CASE WHEN uphold THEN 'upheld' ELSE 'dismissed' END;

  UPDATE public.content_reports
     SET status       = st,
         "resolvedAt" = now_ms,
         "resolverId" = actor,
         resolution   = note
   WHERE id = report_id;

  INSERT INTO public.moderation_log
    (id, "actorId", action, "targetType", "targetId", reason, "createdAt")
  VALUES (gen_random_uuid()::text, actor,
          CASE WHEN uphold THEN 'report_upheld' ELSE 'report_dismissed' END,
          'report', report_id, note, now_ms);

  RETURN st;
END;
$$;

-- How many open reports stand against a topo, and whether any is unsafe.
--
-- Exposed to ADMINS ONLY — the owner cannot read it, for the same reason they
-- cannot read the reports themselves. It exists so the review queue can mark a
-- topo that is already under complaint, not so a count can be rendered next to
-- a like button.
CREATE OR REPLACE FUNCTION public.report_counts(wall_ids text[])
  RETURNS TABLE ("wallId" text, "openCount" bigint, urgent boolean)
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'not authorised' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  SELECT c."wallId", count(*), bool_or(c.reason = 'unsafe')
    FROM public.content_reports c
   WHERE c.status = 'open' AND c."wallId" = ANY(wall_ids)
   GROUP BY c."wallId";
END;
$$;

GRANT EXECUTE ON FUNCTION public.report_content(text, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.moderation_reports(int)                TO authenticated;
GRANT EXECUTE ON FUNCTION public.resolve_report(text, boolean, text)    TO authenticated;
GRANT EXECUTE ON FUNCTION public.report_counts(text[])                  TO authenticated;
