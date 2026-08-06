-- Community editing, Phase 2: access & closure as a first-class field (R-2).
--
-- Rationale in COMMUNITY_PLAN.md §3.6. theCrag treats this as core
-- infrastructure rather than a report category: a `Closed` tag plus an
-- `Access` field explaining why, warnings that INHERIT down the hierarchy, and
-- a sensitive mode that suppresses visibility entirely (raptor nesting,
-- private land, culturally significant sites). Their stated philosophy is
-- "model reality" — tell climbers a crag is closed, because otherwise they go
-- exploring.
--
-- Unlike moderation state, these columns live ON the synced tables and ARE
-- owner-writable. That is deliberate: access information is a fact about the
-- world that the community maintains, not the topo author's creative work
-- (R-1, COMMUNITY_PLAN.md §3.2). Gating "this crag is closed" behind a review
-- queue would be actively harmful.
--
-- They therefore need no sync-engine change at all: `toJson()`/`fromJson()`
-- round-trip them like every other column, exactly as `profiles.avatarUrl`
-- did.
--
-- Idempotent, per this repo's migration convention.

ALTER TABLE public.areas   ADD COLUMN IF NOT EXISTS "accessState" text;
ALTER TABLE public.areas   ADD COLUMN IF NOT EXISTS "accessNote"  text;
ALTER TABLE public.sectors ADD COLUMN IF NOT EXISTS "accessState" text;
ALTER TABLE public.sectors ADD COLUMN IF NOT EXISTS "accessNote"  text;
ALTER TABLE public.walls   ADD COLUMN IF NOT EXISTS "accessState" text;
ALTER TABLE public.walls   ADD COLUMN IF NOT EXISTS "accessNote"  text;

-- Values: NULL (nothing stated) | 'open' | 'restricted' | 'closed' | 'sensitive'.
-- Deliberately NOT a CHECK constraint or an enum type: a client running ahead
-- of the server must not have its whole row push rejected because it used a
-- value this schema has not heard of yet. The client parses defensively and
-- treats an unknown value as the most restrictive it understands.

-- ---------------------------------------------------------------------------
-- `sensitive` suppresses public visibility, inheriting down the hierarchy
-- ---------------------------------------------------------------------------
--
-- Replaces the Phase 1 definition. A wall is public only if neither it, nor
-- its sector, nor its area is marked sensitive — so hiding a whole crag is one
-- write on the Area, not a sweep over every wall beneath it.
--
-- The other three states (open/restricted/closed) do NOT affect visibility.
-- That is the point of theCrag's "model reality": a closed crag must still be
-- FINDABLE, prominently marked closed, or climbers go looking for it anyway.
-- Only `sensitive` — where the correct outcome is that the location is not
-- published at all — removes it from view.
CREATE OR REPLACE FUNCTION public.is_wall_public(wall text) RETURNS boolean
  LANGUAGE sql SECURITY DEFINER STABLE SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.walls w
    JOIN public.wall_moderation m ON m."wallId" = w.id
    LEFT JOIN public.sectors s ON s.id = w."sectorId"
    LEFT JOIN public.areas   a ON a.id = s."areaId"
    WHERE w.id = wall
      AND w.visibility = 'shared'
      AND w."deletedAt" IS NULL
      AND m.state = 'published'
      AND (
        m."withdrawRequestedAt" IS NULL
        OR m."withdrawRequestedAt"
             > (extract(epoch FROM now()) * 1000)::bigint - 864000000
      )
      AND coalesce(w."accessState", '') <> 'sensitive'
      AND coalesce(s."accessState", '') <> 'sensitive'
      AND coalesce(a."accessState", '') <> 'sensitive'
  );
$$;
