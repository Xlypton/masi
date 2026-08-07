-- Community editing, Phase 8a: trust levels (COMMUNITY_PLAN.md C-4).
--
-- "Reviewing at scale is the thing that kills this feature. One person cannot
-- review everything forever." Trust levels are named there as the single
-- highest-leverage measure against that, and phase 3 deliberately landed the
-- plumbing with every account pinned at "review everything" so this could be
-- one migration rather than a rewrite.
--
-- COMPUTED, NOT STORED. `trust_level()` derives the answer from rows that
-- already exist — approved submissions, upheld reports — instead of keeping a
-- counter somewhere that drifts. Nothing to backfill, nothing to invalidate,
-- and no way for the number to disagree with the history it claims to
-- summarise. It is called once per submission, on a handful of indexed rows.
--
-- Idempotent, per this repo's migration convention.

-- ---------------------------------------------------------------------------
-- 1. What earns trust, and what loses it
-- ---------------------------------------------------------------------------
--
-- Level 0 — everything goes to the queue. Every new account starts here.
-- Level 1 — submissions publish immediately, subject to spot checks.
--
-- Two levels, not six. Every platform in §3.1 that runs a ladder (Waze's 1-6,
-- Discourse's TL0-4) has a community large enough to need the granularity;
-- this one has five distinct owners. A ladder nobody climbs is a ladder that
-- only ever hides how the thing actually works.
--
-- `kTrustApprovals = 3`. The number is a judgement, and the judgement is that
-- three topos a moderator has actually looked at and approved is enough
-- evidence that a fourth is not going to be spam. It is deliberately reachable
-- — a threshold nobody meets does not reduce anyone's review load.
--
-- What LOSES it is the interesting half:
--
--  * ANY upheld report against your content drops you to 0. Not a ratio, not a
--    decay — one. The asymmetry is on purpose: the cost of wrongly trusting
--    somebody is unreviewed bad content on a climbing topo, and the cost of
--    wrongly distrusting them is that a moderator reads their next submission.
--    Those are not comparable, so the thresholds should not be symmetric.
--
--  * Being rejected recently does NOT drop you. Rejection is the queue working
--    — the person submitted something, a moderator looked, it was not right.
--    Punishing that would teach people to stop submitting rather than to
--    submit better, and the whole point of showing a rejection reason (phase 3)
--    is that the next attempt is better.
CREATE OR REPLACE FUNCTION public.trust_level(uid text)
  RETURNS int
  LANGUAGE sql SECURITY DEFINER STABLE SET search_path = public AS $$
  SELECT CASE
    WHEN uid IS NULL THEN 0
    -- One upheld report against anything they own, ever, and they are back to
    -- being read by a human.
    WHEN EXISTS (
      SELECT 1 FROM public.content_reports c
        JOIN public.walls w ON w.id = c."wallId"
       WHERE w."ownerId" = uid AND c.status = 'upheld'
    ) THEN 0
    WHEN (
      SELECT count(*) FROM public.wall_moderation m
        JOIN public.walls w ON w.id = m."wallId"
       WHERE w."ownerId" = uid
         AND m.state = 'published'
         -- `reviewerId`, NOT `reviewedAt`, and the difference is not cosmetic.
         --
         -- Phase 1b's trigger stamped `reviewedAt` on every wall it promoted
         -- during the behaviour-neutral backfill, so eight already-shared
         -- topos carry a review timestamp that no moderator ever produced. A
         -- live query confirmed it: the criterion `reviewedAt IS NOT NULL`
         -- read the project owner as fully trusted on the strength of topos
         -- nobody had looked at. `reviewerId` is set by exactly one thing —
         -- `review_topo`, to the admin who pressed the button.
         --
         -- It is deliberately left NULL by the auto-approval below, so an
         -- auto-approved topo does not count towards its own owner's total
         -- either. That costs nothing (they are already at the top level) and
         -- means trust revoked by an upheld report has to be re-earned from
         -- genuine reviews rather than from the account's own output.
         AND m."reviewerId" IS NOT NULL
    ) >= 3 THEN 1
    ELSE 0
  END;
$$;

GRANT EXECUTE ON FUNCTION public.trust_level(text) TO authenticated;

-- What the signed-in user has earned, and what is still between them and the
-- next level. Their OWN row only — this deliberately cannot be used to
-- enumerate anyone else's standing.
CREATE OR REPLACE FUNCTION public.my_trust()
  RETURNS TABLE (
    level      int,
    approved   bigint,
    "needed"   int,
    "blocked"  boolean
  )
  LANGUAGE sql SECURITY DEFINER STABLE SET search_path = public AS $$
  SELECT
    public.trust_level((auth.uid())::text),
    -- Same criterion as `trust_level`, and it has to be: a progress readout
    -- that counted something the threshold does not would tell the user they
    -- are two away when they are five away.
    (SELECT count(*) FROM public.wall_moderation m
       JOIN public.walls w ON w.id = m."wallId"
      WHERE w."ownerId" = (auth.uid())::text
        AND m.state = 'published' AND m."reviewerId" IS NOT NULL),
    3,
    EXISTS (
      SELECT 1 FROM public.content_reports c
        JOIN public.walls w ON w.id = c."wallId"
       WHERE w."ownerId" = (auth.uid())::text AND c.status = 'upheld'
    );
$$;

GRANT EXECUTE ON FUNCTION public.my_trust() TO authenticated;

-- ---------------------------------------------------------------------------
-- 2. Applying it at submission time
-- ---------------------------------------------------------------------------
--
-- The ONLY behavioural change in this migration, and it is four lines inside
-- the function phase 3 already rewrote. A trusted owner's topo lands in
-- `published` with `reviewedAt` stamped; everyone else still lands in
-- `pending`.
--
-- `reviewerId` is left NULL, which is what tells an auto-approval apart from a
-- human one — and, because `trust_level` counts `reviewerId IS NOT NULL`, it
-- also means auto-approved topos are not themselves evidence of trust. Trust
-- is earned from reviews a person actually performed, and nothing an account
-- publishes on its own recognisance feeds back into its own standing.
CREATE OR REPLACE FUNCTION public.ensure_wall_moderation() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  now_ms  bigint := (extract(epoch FROM now()) * 1000)::bigint;
  trusted boolean := public.trust_level(NEW."ownerId") >= 1;
  state   text;
BEGIN
  state := CASE
    WHEN NEW.visibility <> 'shared' THEN 'draft'
    WHEN trusted THEN 'published'
    ELSE 'pending'
  END;

  INSERT INTO public.wall_moderation
    ("wallId", state, "submittedAt", "reviewedAt", "updatedAt")
  VALUES (
    NEW.id,
    state,
    CASE WHEN NEW.visibility = 'shared' THEN now_ms END,
    CASE WHEN NEW.visibility = 'shared' AND trusted THEN now_ms END,
    now_ms
  )
  ON CONFLICT ("wallId") DO UPDATE
    SET state         = CASE WHEN trusted THEN 'published' ELSE 'pending' END,
        "submittedAt" = now_ms,
        "reviewedAt"  = CASE WHEN trusted THEN now_ms ELSE NULL END,
        -- Cleared so a re-submitted topo does not display a stale verdict
        -- from its previous life while it waits in the queue again.
        "rejectionReason"     = NULL,
        "withdrawRequestedAt" = NULL,
        "updatedAt"   = now_ms
    WHERE NEW.visibility = 'shared'
      AND (
        -- A fresh submission.
        public.wall_moderation.state = 'draft'
        -- A matured withdrawal being re-shared (phase 5).
        OR (public.wall_moderation.state = 'published'
            AND public.wall_moderation."withdrawRequestedAt" IS NOT NULL
            AND public.wall_moderation."withdrawRequestedAt" <= now_ms - 864000000)
      );
  RETURN NULL;
END;
$$;
