# Community editing — implementation plan

Companion to `COMMUNITY_PLAN.md` (the *why*). This is the *what and how*: concrete schema, RPCs,
RLS, client modules, and per-phase acceptance criteria.

Decided 2026-08-06: **R-1 accepted** (split the artefact from the facts) and **R-2 accepted**
(access/closure as a first-class inheriting field).

Live dev environment at the time of writing: **12 live walls, 8 shared, 26 routes, 5 distinct
owners, 2 profiles.** Small enough that backfills are trivial and destructive mistakes are
cheap — this is the moment to make structural changes, not later.

---

## 0. Two resolved design problems

### 0.1 The trigger-vs-push deadlock, resolved

`COMMUNITY_PLAN.md` flagged C-3's protective trigger as the hardest integration point. Verified:
`SupabaseSyncRemote.upsertOwnRows` batches **per table**, with one `try/catch` around each
(`sync_remote.dart:493-563`, `rowsFailed: rows.length` on failure). So a trigger that `RAISE`s on
one wall row fails the **entire `walls` push** for that user — every other wall in the batch stays
local too.

**Resolution: the trigger silently reverts the protected columns and bumps `updatedAt` to server
time.** It never raises.

- No error ⇒ the batch lands ⇒ no poisoned push, and `pushOwn` needs no per-row isolation work.
- Bumping `updatedAt` is what makes it converge: the server row becomes strictly newer than the
  client's, so the next pull's LWW overwrites the client's local value instead of the client
  re-pushing forever. Without the bump this ping-pongs indefinitely.
- The user sees their unpublish "bounce back", which is why the **client-side guard is the
  primary UX path** — it offers the withdrawal flow instead. The trigger is the backstop for a
  manipulated client, not the mechanism a normal user ever meets.

### 0.2 How `published` is decided — lazily, not by a cron

The 10-day withdrawal window is evaluated **inside the visibility predicate**, not by a scheduled
job that flips state. No `pg_cron`, no clock drift, no job that can fail silently, and the answer
is correct at every instant.

```sql
-- 10 days in ms
m."withdrawRequestedAt" IS NULL
  OR m."withdrawRequestedAt" > (extract(epoch from now()) * 1000)::bigint - 864000000
```

---

## 1. Server schema

All new tables live **outside `syncTableNames`** (G-1). The sync engine must never push them.

### 1.1 Authority

```sql
CREATE TABLE public.admins (
  "userId"    text PRIMARY KEY,
  role        text NOT NULL DEFAULT 'admin',      -- 'admin' | 'moderator'
  "createdAt" bigint NOT NULL
);
```

RLS: **SELECT only your own row** — `USING ("userId" = (auth.uid())::text)`. That answers "am I an
admin?" for the client without letting anyone enumerate the admin list. No INSERT/UPDATE/DELETE
policy at all, so the only way in is the Management API (G-3).

```sql
CREATE FUNCTION public.is_admin() RETURNS boolean
  LANGUAGE sql SECURITY DEFINER STABLE SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM public.admins WHERE "userId" = (auth.uid())::text);
$$;
```

`SECURITY DEFINER` so other policies can call it without needing their own read access to
`admins`.

### 1.2 Moderation state

```sql
CREATE TABLE public.wall_moderation (
  "wallId"              text PRIMARY KEY REFERENCES public.walls(id) ON DELETE CASCADE,
  state                 text NOT NULL,   -- draft|pending|published|rejected|withdrawn|removed
  "submittedAt"         bigint,
  "reviewedAt"          bigint,
  "reviewerId"          text,
  "rejectionReason"     text,
  "withdrawRequestedAt" bigint,
  "updatedAt"           bigint NOT NULL
);
CREATE INDEX idx_wall_moderation_state ON public.wall_moderation (state, "wallId");
```

RLS SELECT: `state = 'published' OR <owner of the wall> OR public.is_admin()`. **No write policy** —
every mutation goes through an RPC.

### 1.3 Audit

```sql
CREATE TABLE public.moderation_log (
  id           text PRIMARY KEY,
  "actorId"    text NOT NULL,
  action       text NOT NULL,
  "targetType" text NOT NULL,        -- 'wall' | 'suggestion' | 'report' | 'user'
  "targetId"   text NOT NULL,
  reason       text,
  "createdAt"  bigint NOT NULL
);
```

RLS SELECT: `is_admin()`. No write policy; written by the same `SECURITY DEFINER` RPCs that
perform the actions, so an action and its log entry cannot diverge.

### 1.4 The gate itself

```sql
CREATE FUNCTION public.is_wall_public(wall text) RETURNS boolean
  LANGUAGE sql SECURITY DEFINER STABLE SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.walls w
    JOIN public.wall_moderation m ON m."wallId" = w.id
    WHERE w.id = wall
      AND w.visibility = 'shared'
      AND w."deletedAt" IS NULL
      AND m.state = 'published'
      AND (m."withdrawRequestedAt" IS NULL
           OR m."withdrawRequestedAt" > (extract(epoch from now()) * 1000)::bigint - 864000000)
  );
$$;
```

Then **every `*_shared_select` policy swaps `visibility = 'shared'` for this function**:
`walls`, `photos`, `routes`, `sectors`, `areas`, `comments`, `likes`. That is the single
enforcement point for "only approved topos are visible", and it is in Postgres where a client
cannot reach it (G-2).

> `visibility` keeps its current meaning — the owner's *intent*. `wall_moderation.state` is the
> *gate*. Public read needs both. This is deliberately additive: no existing column changes
> meaning, so no client code is silently wrong.

### 1.5 Access & closure (R-2)

```sql
ALTER TABLE public.areas   ADD COLUMN "accessState" text, ADD COLUMN "accessNote" text;
ALTER TABLE public.sectors ADD COLUMN "accessState" text, ADD COLUMN "accessNote" text;
ALTER TABLE public.walls   ADD COLUMN "accessState" text, ADD COLUMN "accessNote" text;
-- null | 'open' | 'restricted' | 'closed' | 'sensitive'
```

These **are** on synced tables and **are** owner-writable — an owner marking their own crag closed
is exactly right, and matches theCrag's model where the community maintains access info. Only
`sensitive` (which suppresses public visibility entirely) is admin-only, enforced by the same
trigger as §0.1.

Inheritance is resolved **client-side, at read time**, walking Wall → Sector → Area and taking the
most restrictive value. Nothing is denormalised, so a crag-level closure needs one write and
appears on every route beneath it.

### 1.6 Community facts (R-1)

The layer that is *not* gated behind the owner's approval, because these are facts about the
world rather than the owner's creative work (`COMMUNITY_PLAN.md` §3.2).

```sql
CREATE TABLE public.route_grade_opinions (
  id           text PRIMARY KEY,
  "routeId"    text NOT NULL REFERENCES public.routes(id) ON DELETE CASCADE,
  "authorId"   text NOT NULL,
  "gradeSystem" text NOT NULL,
  "gradeRaw"   text NOT NULL,
  "gradeSortKey" double precision,
  "createdAt"  bigint NOT NULL,
  UNIQUE ("routeId", "authorId")          -- one opinion per person per route
);

CREATE TABLE public.topo_verifications (
  id          text PRIMARY KEY,
  "wallId"    text NOT NULL REFERENCES public.walls(id) ON DELETE CASCADE,
  "authorId"  text NOT NULL,
  accurate    boolean NOT NULL,
  note        text,
  "createdAt" bigint NOT NULL,
  UNIQUE ("wallId", "authorId")
);

CREATE TABLE public.topo_hazards (
  id           text PRIMARY KEY,
  "wallId"     text NOT NULL REFERENCES public.walls(id) ON DELETE CASCADE,
  "routeId"    text REFERENCES public.routes(id) ON DELETE CASCADE,
  "authorId"   text NOT NULL,
  severity     text NOT NULL,          -- 'note' | 'caution' | 'danger'
  body         text NOT NULL,
  "resolvedAt" bigint,
  "createdAt"  bigint NOT NULL
);
```

RLS on all three: SELECT if `is_wall_public(...)` or owner or admin; INSERT by any authenticated
user with `WITH CHECK ("authorId" = auth.uid()::text)`; UPDATE/DELETE by the author only (and
admins). The topo owner **cannot delete a hazard report on their own topo** — that is the entire
point of the split, and C-12's "safety content is never silently removed" made concrete. They can
mark it resolved, which is recorded, not erased.

The owner's grade stays authoritative for display; the consensus grade renders beside it.

### 1.7 Suggestions, reports, versions (phases 4–7)

Sketched in `COMMUNITY_PLAN.md` §C-5a and §5; specified when their phase starts, so this document
does not commit to a shape before the phases that inform it have shipped.

---

## 2. Client architecture

New feature module `lib/features/moderation/`, mirroring the existing feature layout:

```
moderation/
  data/          moderation_remote.dart, moderation_repository.dart
  domain/        moderation_state.dart, access_state.dart
  application/   moderation_providers.dart, admin_providers.dart
  presentation/  admin_queue_screen.dart, moderation_banner.dart, access_banner.dart
```

**Local Drift additions** (schema v12), all **excluded from `syncTableNames`**:

- `WallModeration` — pull-only mirror of §1.2, so state survives offline and the banner renders
  from cold.
- `RouteGradeOpinions`, `TopoVerifications`, `TopoHazards` — these *do* sync, but through their own
  paths, not the owner-scoped `pushOwn` loop (the author pushes their own rows; everyone pulls the
  public ones).

**Sync engine changes, minimal by design:**

- `SyncRemote.fetchWallModeration(Set<String> wallIds)` — pulled alongside `fetchSharedTopos`.
- **No push path for moderation state at all.** That is the whole point of G-1.
- `fetchSharedTopos` needs no filter change: RLS (§1.4) already stops unapproved walls being
  returned, so the client cannot see them even if it asks. Belt and braces, with the braces in
  Postgres.

---

## 3. Phases

Each is independently shippable and leaves the app coherent.

### Phase 1 — Foundations *(server only, no behaviour change)*

Tables, functions, RLS swap, backfill. Everything currently shared is backfilled to
`state='published'` so **nothing disappears on deploy** — with 8 shared walls live, verify this by
count before and after, not by assumption.

**Done when:** all 8 shared walls still readable anonymously; a wall with no `wall_moderation` row
is *not* publicly readable; `is_admin()` returns false for a normal user and true for the seeded
admin; a non-admin `INSERT` into `admins` is rejected by RLS.

### Phase 2 — Access & closure (R-2)

Ships alone, depends on nothing. Columns, client inheritance resolution, banner on Wall/Sector/Area
and in the topo detail. `sensitive` suppresses public visibility.

**Done when:** closing an Area shows the closure on every wall beneath it; a `sensitive` area's
topos are absent from an anonymous feed query.

### Phase 3 — Submission & review queue

`submit_topo` / `review_topo` RPCs, `/admin` route, pending state invisible to others, rejection
reason shown to the owner. Trust-level **plumbing** lands here even if every account starts at
"review everything" (`COMMUNITY_PLAN.md` §3.5 — this is what stops phase 3 becoming a second job).

Fix **W-1** here or not at all: the unbounded global `fetchSharedTopos` becomes geo/paged.

### Phase 4 — Community facts (R-1)

Grade opinions, verifications, hazards. No approval queue anywhere in this phase — that is the
point.

### Phase 5 — Withdrawal cooldown & delete protection (C-3)

The trigger from §0.1, the client-side guard, the countdown banner.

### Phase 6 — Version history (C-8), then reports (C-7)

Both before the edit path, because with owner-approval final they are the only safety net
(`COMMUNITY_PLAN.md` §C-5c).

### Phase 7 — Metadata suggestions, then geometry suggestions

Split as in §C-5b: the propose-a-line canvas earns its own phase.

### Phase 8 — Trust thresholds, duplicates & merging, ranking

---

## 4. Standing constraints

- **Never delete published content.** Merge, withdraw, or revert (`COMMUNITY_PLAN.md` §3.3).
  Applies to every phase.
- **Ascents outlive the topo.** They are the user's own record.
- **Moderation state never enters `syncTableNames`.**
- **Every guarantee is enforced in Postgres.** Dart-side checks are UX, not enforcement.
- Each phase keeps `flutter analyze` at 0 and the suite green, and ships its own migration file
  applied to live **before** the client that needs it.
