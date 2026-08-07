-- Community editing, Phase 7a: suggested edits, metadata slice
-- (COMMUNITY_PLAN.md C-5 / C-5a / C-5b).
--
-- Non-owners currently have ZERO write access to any content table, which is
-- the property that makes this app's sync engine simple, and it is not being
-- given up. A suggestion is a PROPOSED PATCH in its own table; when the owner
-- accepts, their own client applies it to their own rows and syncs normally.
-- The entire apply-path stays inside the existing owner-writes-own-rows model:
-- no new write authority, no change to the sync engine, no merge algorithm.
--
-- METADATA ONLY here, per §C-5b. Geometry suggestions need four things this
-- does not have — a photo to pin the line to, the database id rather than the
-- reassigned domain id, a visual diff, and a propose-mode canvas — and that
-- last one is the single largest piece of UI work in the whole plan. It gets
-- its own phase; this is the shippable first slice.
--
-- Idempotent, per this repo's migration convention.

-- ---------------------------------------------------------------------------
-- 1. The table
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.topo_edit_suggestions (
  id              text PRIMARY KEY,
  "wallId"        text NOT NULL REFERENCES public.walls(id) ON DELETE CASCADE,
  "routeId"       text REFERENCES public.routes(id) ON DELETE CASCADE,
  "authorId"      text NOT NULL,
  kind            text NOT NULL,   -- topo.metadata | route.metadata
  patch           jsonb NOT NULL,  -- {field: newValue}, whitelisted below
  note            text,
  -- Which revision this was written against (C-8). If the topo has changed
  -- underneath it, the owner is shown that rather than applying it blind.
  "baseVersionId" text REFERENCES public.topo_versions(id) ON DELETE SET NULL,
  status          text NOT NULL DEFAULT 'open',  -- open|accepted|rejected
  "resolvedAt"    bigint,
  "resolverId"    text,
  "resolution"    text,
  "createdAt"     bigint NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_suggestions_wall
  ON public.topo_edit_suggestions ("wallId", status, "createdAt");
CREATE INDEX IF NOT EXISTS idx_suggestions_author
  ON public.topo_edit_suggestions ("authorId", "createdAt");

ALTER TABLE public.topo_edit_suggestions ENABLE ROW LEVEL SECURITY;

-- Readable by its author, the target topo's owner, and admins.
--
-- The OWNER is included here, unlike `content_reports` next door, and the
-- difference is the whole point of the two features. A report is a complaint
-- ABOUT the owner and naming the reporter would invite retaliation; a
-- suggestion is an offer OF HELP that the owner is the only person who can
-- act on, and attribution is most of the reward for making one (C-5).
DROP POLICY IF EXISTS suggestions_select ON public.topo_edit_suggestions;
CREATE POLICY suggestions_select ON public.topo_edit_suggestions FOR SELECT
  USING (
    "authorId" = (auth.uid())::text
    OR EXISTS (SELECT 1 FROM public.walls w
                WHERE w.id = "wallId" AND w."ownerId" = (auth.uid())::text)
    OR public.is_admin()
  );

-- No INSERT/UPDATE/DELETE policy. Everything goes through the RPCs below, so
-- the field whitelist and the rate limits cannot be bypassed by writing the
-- table directly — which is the same reason `content_reports` has none.

-- ---------------------------------------------------------------------------
-- 2. What may be suggested
-- ---------------------------------------------------------------------------
--
-- A whitelist, enforced server-side, and deliberately short.
--
-- GRADE IS NOT ON IT, which is the interesting omission. Phase 4 already lets
-- anyone state a grade opinion with no approval step at all, and renders the
-- community consensus beside the owner's grade — that is strictly better than
-- asking the owner's permission to disagree with them about a grade. Adding a
-- grade suggestion here would give the same job two mechanisms with different
-- politics.
--
-- `accessState` is off it for the same reason: phase 2 makes it owner-writable
-- and inheriting, and a reader who thinks a crag is closed has the "access
-- problem" report (phase 6b), which reaches a moderator rather than waiting on
-- the owner who may be the one who has not noticed.
--
-- `stars` is off it because a quality rating is not a fact about the world to
-- be corrected; it is an opinion, and opinions belong in the facts layer (R-1)
-- if they belong anywhere.
CREATE OR REPLACE FUNCTION public.suggestion_fields(kind text)
  RETURNS text[]
  LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE kind
    WHEN 'topo.metadata'  THEN ARRAY['name','latitude','longitude']
    WHEN 'route.metadata' THEN ARRAY['name','description','betaVideoUrl','style','styleTagsJson']
    ELSE ARRAY[]::text[]
  END;
$$;

-- ---------------------------------------------------------------------------
-- 3. Making a suggestion
-- ---------------------------------------------------------------------------
--
-- Rate-limited two ways, because suggestion spam is the cheapest griefing
-- vector in the whole design: it costs the troll one tap and the owner one
-- notification (C-5, Guardrails).
--
--   * THREE OPEN per author per topo. Someone with three unanswered
--     suggestions on one topo does not need a fourth; they need the owner to
--     look. This is the limit that protects an individual owner.
--   * TWENTY PER DAY per author overall. This is the limit that protects
--     everyone else from one account.
CREATE OR REPLACE FUNCTION public.suggest_edit(
  wall_id  text,
  kind     text,
  patch    jsonb,
  note     text DEFAULT NULL,
  route_id text DEFAULT NULL
) RETURNS text
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  now_ms   bigint := (extract(epoch FROM now()) * 1000)::bigint;
  actor    text   := (auth.uid())::text;
  allowed  text[];
  key      text;
  open_here int;
  today    int;
  base     text;
  new_id   text;
BEGIN
  IF actor IS NULL THEN
    RAISE EXCEPTION 'not authorised' USING ERRCODE = '42501';
  END IF;

  -- Only PUBLIC topos, for the same reason reports are: without this, a
  -- guessed or leaked id becomes a way to push notifications at the owner of
  -- something they have never published.
  IF NOT public.is_wall_public(wall_id) THEN
    RAISE EXCEPTION 'unknown wall %', wall_id USING ERRCODE = 'P0002';
  END IF;

  allowed := public.suggestion_fields(kind);
  IF array_length(allowed, 1) IS NULL THEN
    RAISE EXCEPTION 'unknown suggestion kind %', kind USING ERRCODE = '22023';
  END IF;
  IF patch IS NULL OR jsonb_typeof(patch) <> 'object' OR patch = '{}'::jsonb THEN
    RAISE EXCEPTION 'empty patch' USING ERRCODE = '22023';
  END IF;
  IF kind = 'route.metadata' AND route_id IS NULL THEN
    RAISE EXCEPTION 'route.metadata needs a route' USING ERRCODE = '22023';
  END IF;

  -- Every key must be on the whitelist. Rejecting the WHOLE patch rather than
  -- dropping the offending key: a suggestion that silently applies half of
  -- what its author wrote is worse than one that is refused, because nobody
  -- ever finds out the other half went missing.
  FOR key IN SELECT jsonb_object_keys(patch) LOOP
    IF NOT (key = ANY(allowed)) THEN
      RAISE EXCEPTION 'field % cannot be suggested', key USING ERRCODE = '22023';
    END IF;
  END LOOP;

  SELECT count(*) INTO open_here
    FROM public.topo_edit_suggestions s
   WHERE s."wallId" = wall_id AND s."authorId" = actor AND s.status = 'open';
  IF open_here >= 3 THEN
    RAISE EXCEPTION 'too many open suggestions on this topo'
      USING ERRCODE = '53400';
  END IF;

  SELECT count(*) INTO today
    FROM public.topo_edit_suggestions s
   WHERE s."authorId" = actor AND s."createdAt" > now_ms - 86400000;
  IF today >= 20 THEN
    RAISE EXCEPTION 'too many suggestions today' USING ERRCODE = '53400';
  END IF;

  -- Pin it to the revision it was written against, so the owner can be shown
  -- "this was written before your last change" rather than applying a patch
  -- to something the author never saw.
  SELECT v.id INTO base
    FROM public.topo_versions v
   WHERE v."wallId" = wall_id
   ORDER BY v."createdAt" DESC
   LIMIT 1;

  new_id := gen_random_uuid()::text;
  INSERT INTO public.topo_edit_suggestions
    (id, "wallId", "routeId", "authorId", kind, patch, note,
     "baseVersionId", status, "createdAt")
  VALUES (new_id, wall_id, route_id, actor, kind, patch,
          nullif(btrim(coalesce(note, '')), ''), base, 'open', now_ms);

  RETURN new_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- 4. Answering one
-- ---------------------------------------------------------------------------
--
-- The TOPO OWNER decides, and their decision is final — no admin re-review
-- (decided 2026-08-06). Admins can also act, for the abandoned-owner case
-- (C-11).
--
-- NOTE WHAT THIS DOES NOT DO: it does not apply the patch. It records the
-- decision, and the owner's own client performs the write against its own
-- rows, exactly as if the owner had typed the change themselves. That is the
-- whole reason a patch beats a fork here.
--
-- The client applies FIRST and calls this SECOND. If this call then fails, the
-- edit has landed and the suggestion stays open — the owner sees it again and
-- accepting a second time re-applies the same values, which is a no-op. The
-- other order would leave a suggestion marked accepted with nothing changed,
-- and nothing anywhere to notice it.
CREATE OR REPLACE FUNCTION public.resolve_suggestion(
  suggestion_id text,
  accept        boolean,
  note          text DEFAULT NULL
) RETURNS text
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  now_ms bigint := (extract(epoch FROM now()) * 1000)::bigint;
  actor  text   := (auth.uid())::text;
  wall   text;
  owner  text;
  st     text;
BEGIN
  IF actor IS NULL THEN
    RAISE EXCEPTION 'not authorised' USING ERRCODE = '42501';
  END IF;

  SELECT s."wallId" INTO wall
    FROM public.topo_edit_suggestions s WHERE s.id = suggestion_id;
  IF wall IS NULL THEN
    RAISE EXCEPTION 'unknown suggestion %', suggestion_id USING ERRCODE = 'P0002';
  END IF;

  SELECT w."ownerId" INTO owner FROM public.walls w WHERE w.id = wall;
  IF owner IS DISTINCT FROM actor AND NOT public.is_admin() THEN
    RAISE EXCEPTION 'not authorised' USING ERRCODE = '42501';
  END IF;

  st := CASE WHEN accept THEN 'accepted' ELSE 'rejected' END;

  -- `resolve_suggestion.note` qualified: the table has a `note` column of its
  -- own (the AUTHOR's message) and the parameter is the RESOLVER's, so an
  -- unqualified reference is ambiguous and Postgres refuses it outright
  -- (42702) rather than guessing.
  UPDATE public.topo_edit_suggestions
     SET status       = st,
         "resolvedAt" = now_ms,
         "resolverId" = actor,
         "resolution" = resolve_suggestion.note
   WHERE id = suggestion_id;

  INSERT INTO public.moderation_log
    (id, "actorId", action, "targetType", "targetId", reason, "createdAt")
  VALUES (gen_random_uuid()::text, actor,
          CASE WHEN accept THEN 'suggestion_accepted' ELSE 'suggestion_rejected' END,
          'suggestion', suggestion_id, resolve_suggestion.note, now_ms);

  RETURN st;
END;
$$;

-- ---------------------------------------------------------------------------
-- 5. Reading them
-- ---------------------------------------------------------------------------

-- Suggestions waiting on the signed-in user, as an OWNER. Oldest first: a
-- suggestion nobody answers is the failure mode C-11 describes, and working
-- oldest-first is what stops the pile becoming permanent.
--
-- `isStale` answers "was this written against something other than what is
-- there now" (C-5, Guardrails), and it needs TWO tests, not one.
--
-- The obvious test — is the pinned revision still the newest — misses the
-- common case entirely, because `snapshot_topo` coalesces: an owner editing
-- within five minutes of their last change EXTENDS the current version in
-- place rather than opening a new one. So the id keeps pointing at the newest
-- revision while its contents change underneath the suggestion, and a patch
-- written against the old name would be applied with nothing flagged. (Caught
-- against live: a rename right after publishing reported `isStale = false`.)
--
-- The second test closes it: if the pinned version has been TOUCHED since the
-- suggestion was filed, the suggestion predates whatever that touch did.
CREATE OR REPLACE FUNCTION public.suggestions_for_me(limit_count int DEFAULT 50)
  RETURNS TABLE (
    id           text,
    "wallId"     text,
    "wallName"   text,
    "routeId"    text,
    "routeName"  text,
    "authorId"   text,
    "authorName" text,
    kind         text,
    patch        jsonb,
    note         text,
    "isStale"    boolean,
    "createdAt"  bigint
  )
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  me text := (auth.uid())::text;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'not authorised' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT s.id, s."wallId", w.name, s."routeId", r.name,
         s."authorId", pr."displayName", s.kind, s.patch, s.note,
         s."baseVersionId" IS DISTINCT FROM (
           SELECT v.id FROM public.topo_versions v
            WHERE v."wallId" = s."wallId"
            ORDER BY v."createdAt" DESC LIMIT 1
         )
         OR COALESCE((
           SELECT v."updatedAt" > s."createdAt" FROM public.topo_versions v
            WHERE v.id = s."baseVersionId"
         ), false),
         s."createdAt"
    FROM public.topo_edit_suggestions s
    JOIN public.walls w ON w.id = s."wallId"
    LEFT JOIN public.routes r    ON r.id = s."routeId"
    LEFT JOIN public.profiles pr ON pr."ownerId" = s."authorId"
   WHERE s.status = 'open'
     AND w."ownerId" = me
   ORDER BY s."createdAt" ASC
   LIMIT limit_count;
END;
$$;

GRANT EXECUTE ON FUNCTION public.suggest_edit(text, text, jsonb, text, text)  TO authenticated;
GRANT EXECUTE ON FUNCTION public.resolve_suggestion(text, boolean, text)      TO authenticated;
GRANT EXECUTE ON FUNCTION public.suggestions_for_me(int)                      TO authenticated;
GRANT EXECUTE ON FUNCTION public.suggestion_fields(text)                      TO authenticated;
