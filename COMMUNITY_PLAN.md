# Community editing — requirements & design plan

Status: **proposal, nothing implemented.** Written 2026-08-06 against the live schema
(`mnaipcqbkqzffgvxpato`) and the sync engine as it exists on `main`.

Goal: make a *published* topo something other climbers can rely on, contribute to, and trust —
without handing any single account the power to break it, and without a moderator having to
babysit every change.

---

## 0. The finding that constrains every design below

**Today, the client is the authority. Every column on every row is writable by its owner, and
the sync engine re-pushes whole rows.**

Three facts, all verified rather than assumed:

1. **RLS gives the owner `ALL` on their own rows.** Live policy on `walls` is
   `walls_owner_all: USING ("ownerId" = auth.uid()::text)` with the same `WITH CHECK`. There is
   no column-level restriction — Postgres RLS is row-level only. An owner may set *any* column
   on their own wall, including `visibility` and `deletedAt`, with a single PostgREST call.
2. **Publishing is a plain client-side field write.** `publishTopo()` is
   `_setWallVisibility(wallId, 'shared')` (`library_crud_repository.dart:693`). Nothing reviews
   it; `walls_shared_select: USING (visibility = 'shared')` makes it world-readable the instant
   it syncs.
3. **There is no outbox — the engine re-reads and re-sends its own rows** (decision D-4), with
   client-side last-writer-wins where **local wins ties** (`shouldPushLww`,
   `sync_remote.dart:303-315`).

Fact 3 is the sharp one. It means **any moderation state stored on a synced table will be
overwritten by the next client push.** A moderator approves a topo; the owner's client, which
still holds its own stale copy of that row, re-pushes it on the next sync and — because local
wins ties — silently reverts the decision. Not maliciously; that is just what the engine does.

### The three rules that follow

> **G-1. Moderation state never lives on a synced table.** It lives in tables the client can
> `SELECT` and never `INSERT`/`UPDATE`. The sync engine must not know they exist.

> **G-2. Anything the community relies on must be enforced in Postgres, not in Dart.** A rule
> implemented only in the app is a rule that holds until someone opens the network tab. This is
> not paranoia about our own users — it is what makes the guarantee *statable*.

> **G-3. Admin status is not a profile field.** `profiles_owner_write` is
> `ALL USING (id = auth.uid()::text)`. An `isAdmin` column there could be set by the user on
> themselves. Admins live in their own table with no client write policy at all.

Everything below is designed to fit inside those three.

---

## 1. Lifecycle

Today a topo has two states, and one of them is a boolean the owner toggles freely:

```
private  ⇄  shared
```

Proposed:

```
                    ┌──────────── withdrawn (owner-initiated, after cooldown) ────────────┐
                    │                                                                     │
draft ──submit──▶ pending ──approve──▶ published ──flag+uphold──▶ removed                 │
  ▲                  │                     │                                              │
  └────reject────────┘                     └──────────────────────────────────────────────┘
```

| State | Who sees it | Who can change it |
|---|---|---|
| `draft` | owner only | owner (freely — this is today's `private`, unchanged) |
| `pending` | owner + admins | admin (approve/reject), owner (may cancel while pending) |
| `published` | everyone | admin; owner only via the withdrawal path (C-3) |
| `withdrawn` | owner + admins | owner may re-submit |
| `removed` | admins only | admin |

**C-1. `draft` behaviour is untouched.** A private topo stays exactly as fast and as
freely-editable/deletable as it is today. Every constraint in this document applies only from
`pending` onward. Ninety percent of the app must not get slower because of the community feature.

**C-2. "Publish" becomes "Submit".** Renaming the action is not cosmetic — it sets the
expectation that something happens next, and it is the honest word once approval exists.

---

## 2. Requirements

### C-3 — Withdrawal cooldown

> An owner may withdraw a published topo. It stays visible for **10 days**, clearly flagged, then
> disappears.

- `wall_moderation.withdrawRequestedAt` set by an RPC (not a direct write).
- The topo shows a banner to *everyone* while the timer runs: "The owner is withdrawing this topo
  on 16 Aug." — people relying on it get warning, and it creates social pressure not to withdraw
  spitefully.
- The owner may cancel the withdrawal at any point during the window.
- **The same window applies to deleting a published topo.** Otherwise the cooldown is theatre:
  `deletedAt = now` achieves instantly what the cooldown was meant to slow down. This is the case
  the current schema makes easiest to get wrong.
- After the window: state → `withdrawn`, rows stop being served, but the **content is retained**
  (see C-8) so an admin can restore it if the withdrawal turns out to be vandalism.

**Enforcement.** A `BEFORE UPDATE` trigger on `walls` rejects any owner-initiated change of
`visibility` away from `shared`, or any set of `deletedAt`, while the wall is `published` and no
matured withdrawal exists. It must **raise**, not silently coerce: a silent coercion plus
full-state re-push produces an endless client/server ping-pong (§0, fact 3). The client surfaces
the error as "Withdraw this topo instead" and offers the flow.

> ⚠️ **The hardest integration point in this whole plan.** The sync engine pushes dirty rows in
> bulk and treats an error as a failed push it will retry. A trigger that raises on one wall row
> must not fail the whole push. `SyncService.pushOwn` needs per-row error isolation before C-3
> can ship — verify this before committing to the design.

### C-4 — Admin review queue

> Only approved topos are visible to others. Admins review submissions in-app.

- New `admins` table (G-3). First row seeded manually via the Management API — that is you.
- New in-app `/admin` route, visible only when the signed-in uid is in `admins`. Hiding the route
  is a courtesy; the enforcement is that every admin RPC re-checks membership server-side.
- Queue shows: pending submissions (oldest first), then open reports (C-7).
- Actions: **Approve**, **Reject with reason**, **Request changes**. Rejection reason is shown to
  the owner — a silent rejection teaches nobody anything.
- Every action writes an immutable `moderation_log` row (C-9).

**Reviewing at scale is the thing that kills this feature.** One person cannot review everything
forever. Design the escape hatch now, even if it ships later:
- **Trust levels.** An account with *N* previously-approved topos and no upheld reports gets
  auto-approved, subject to spot checks. This is the single highest-leverage anti-burnout measure.
- Auto-approve trivial edits (typo in a description) while holding structural ones (route
  geometry, grades, GPS).

### C-5 — Suggested edits

> Anyone can suggest an edit to a published topo. The owner approves or rejects it.
> **DECIDED (2026-08-06): suggestions may edit route geometry, not just metadata.**
> **DECIDED (2026-08-06): an owner's approval is final — no admin re-review.**

Non-owners currently have **zero** write access to any content table, so this needs a new one:
`topo_edit_suggestions`.

- INSERT: any authenticated user, `WITH CHECK (authorId = auth.uid()::text)`.
- SELECT: author, the target wall's owner, or an admin.
- UPDATE: **target wall's owner only** (to set status) — plus admins.
- The payload is a **proposed patch**, not a whole topo.

**Why a patch and not a fork.** When the owner accepts, their own client applies the patch to
their own rows and syncs normally. The entire apply-path stays inside the existing
owner-writes-own-rows model — no new write authority, no change to the sync engine, no merge
algorithm. That is worth a lot, and geometry does not change it: an accepted line is still just
the owner's client writing the owner's own `routes` row.

#### C-5a — Suggestion kinds

| Kind | Payload |
|---|---|
| `topo.metadata` | `{field: newValue}` over wall name / description / coordinates |
| `route.metadata` | target `routeId` + `{field: newValue}` over name, grade, style tags, stars, description, beta URL |
| `route.geometry` | target `routeId` + proposed `points` / `symbols` |
| `route.add` | a whole proposed route (points, symbols, metadata) |
| `route.delete` | target `routeId` + reason |

#### C-5b — What geometry suggestions need that metadata ones do not

Four things, all of which fall out of how routes are actually stored:

1. **Pin to a photo.** `Routes.photoId` is a required FK and points are stored in **percent
   space, normalized to the image** (`topo_route.dart:46`). A line drawn against photo A is
   meaningless against photo B. Every geometry suggestion stores the `photoId` it was drawn on,
   and is shown as stale if the topo's primary photo has changed since.
2. **Use the database id, not the domain id.** `TopoRoute.id` is an `int` the repository
   **reassigns 1..n on every load** (`route_mapper.dart:91-93`) — it is not stable and never was.
   A payload referencing it would silently point at a different route after any reload. Target
   `Routes.id` (the text uuid) exclusively.
3. **A visual diff, not a JSON diff.** Nobody can review a line by reading coordinates. The owner
   sees the proposed line overlaid on the current one on the real photo — current in its normal
   colour, proposed highlighted. The existing `TopoPainter` already draws a list of routes, so
   this is mostly a matter of handing it two sets with different styling rather than new
   rendering work.
4. **A propose-mode canvas.** The suggester opens the topo in an editing surface that writes to a
   suggestion payload instead of to `routes`. `DrawController` already produces exactly the shape
   needed; the change is where the result is sent, not how it is captured. **This is the single
   largest piece of UI work in the whole plan** — budget for it accordingly and treat metadata
   suggestions as the shippable first slice.

**Guardrails.**
- Rate-limit suggestions per author per day, and per author per topo. Suggestion spam is the
  cheapest possible griefing vector: it costs the troll one tap and the owner one notification.
- A suggestion targets a **specific version** (C-8). If the topo changed underneath it, show the
  owner that it was written against an older version rather than applying it blind. This matters
  far more for geometry than for a typo fix.
- An owner who ignores suggestions is not a bug, but a topo with many accepted-elsewhere
  suggestions and an absent owner is a signal — surface it to admins (C-11).
- Attribution: accepted suggestions credit their author. This is most of the reward for
  contributing, and it costs one column.

### C-6 — Duplicate topos for the same place

> Multiple people publish the same boulder. Resolve it.

Do **not** resolve this by deletion or by refusing the second submission — two people
photographing the same boulder from different angles in different light is *useful*, and the
second submission is often better than the first.

Proposal, in order of cost:

1. **Detect and cluster.** At submission, find published walls within ~50 m
   (`walls.latitude/longitude` already exist and are EXIF-populated). Show the submitter: "3 topos
   already exist here" with thumbnails, before they submit. Many duplicates stop right there.
2. **Group in the UI.** The feed and map show one card per *place* with "4 topos", ordered by
   rank, rather than four near-identical cards.
3. **Rank, don't rate.** The user's suggestion was a per-topo star rating so users can pick the
   better one. My recommendation is to **rank by signals we already collect** rather than
   introducing a second star scale:
   - `likes` (exists), ascent count (exists), completeness (has routes / grades / GPS / description),
     recency of last verification (C-10), and the author's trust level.
   - Routes already carry `stars` for *climb quality*. A second star widget for *topo quality*
     will be conflated with it constantly — "3 stars" on a page that already shows stars means
     the wrong thing to a climber. If a manual signal is wanted, "👍 this topo is accurate" is
     unambiguous where a star is not.
   - **This one is genuinely arguable and it is your call** — see Open Question 3.
4. **Merge suggestion.** "This is the same boulder as X" as a report reason, resolved by an admin
   who can link them as alternates rather than deleting either.

### C-5c — What now carries the weight, given no re-review

Approval is a **one-time gate**. Once a topo is published, the owner — and anyone whose
suggestion the owner accepts — can change anything about it, forever, with no admin in the loop.

That is a defensible choice and it is how most UGC platforms work. But it should be made with
eyes open, because it moves the load:

- **The review queue does much less than it appears to.** It stops bad *submissions*. It does
  nothing about a good submission that becomes bad later, and it is fully bypassable by the
  obvious route: submit something clean, get approved, then replace the content.
- **C-7 (reporting) and C-8 (version history) become load-bearing**, not "nice additions". With
  no re-review they are the *only* thing standing between an approved topo and vandalism. If
  either is cut, the answer to "what stops someone wrecking a topo everyone relies on" is
  genuinely "nothing". I would not ship community editing without both.

**C-5d — Material-change signal.** The cheap middle ground, and my recommendation: a change to a
published topo that is *structural* — geometry replaced, routes deleted, primary photo swapped —
**posts a notice to the admin queue without blocking anything**. Publication is instant, exactly
as decided; an admin simply gets to see that a topo changed shape. It costs the owner nothing, it
catches bait-and-switch, and it is a row insert rather than a workflow.

### C-7 — Reporting

*(my addition — not in the original list, and I think it is required for C-4 to work)*

An approval queue only catches content at submission time. Content goes bad *later*: a route is
retro-bolted, a boulder is chipped, access is revoked, a photo turns out to show someone's face.
Without a report path, the only people who can act are the owner (who may be the problem) and an
admin who happens to look.

- Report reasons: inaccurate, unsafe, duplicate, access issue, inappropriate, not your content.
- Reports go to the admin queue alongside submissions.
- Rate-limited per reporter; repeated frivolous reports lower trust.
- **"Unsafe" is not just another category.** See C-12.

### C-8 — Version history

*(my addition, and the one I would argue hardest for)*

> Every change to a published topo is retained. Any state is restorable by an admin.

This is what actually makes the anti-troll requirement tractable. Rather than trying to enumerate
and block every destructive action — delete the topo, delete all its routes, blank the
description, replace the photo with garbage, drag every line off the rock — you make all of them
**reversible and attributed**. One `topo_versions` row per published change: the wall + its
routes/photos metadata as JSON, who changed it, when.

Consequences:
- A vandalised topo is a one-click admin revert, not an incident.
- C-5 suggestions can target a version.
- "What changed since I last climbed here" becomes possible, which is genuinely useful and not
  just a moderation feature.
- Storage cost is small — JSON metadata, not photo bytes.

Without this, C-3's cooldown protects against exactly one attack (withdrawal) and leaves the
other five open.

### C-9 — Audit log

Immutable, append-only `moderation_log`: actor, action, target, reason, timestamp. No client
write policy; written by the same RPCs that perform the actions. Admins can read it; admin actions
are as auditable as user actions. This matters more, not less, when there is exactly one admin.

### C-10 — "Last verified"

*(my addition)*

A topo with no signal of freshness is trusted exactly as much on day 1 as on day 900. Let any
signed-in climber tap "I climbed here, this is accurate" — one tap, no edit, no review. Feeds
ranking (C-6), gives readers a staleness cue, and is the cheapest possible contribution for
someone who does not want to write an edit.

### C-11 — Abandoned topos

An owner who stops using the app freezes their topos forever: suggestions pile up, nothing is
applied, the community cannot fix an error everyone can see. After a long inactivity window with
open suggestions, admins may transfer ownership or mark the topo community-maintained. Rare, but
without it "the owner approves edits" degrades to "nobody can fix this" over a few years.

### C-12 — Safety content is special

*(my addition, and I think the most important one here)*

This is climbing. A missing "loose block", a wrong bolt count, a topo line drawn past a runout —
these can hurt someone. That argues for a few rules that would be over-engineering in a photo app:

- Safety-relevant fields (protection notes, hazard warnings, descent info) are **never silently
  removed**. Removing one is a change the version history records prominently and, ideally, one
  that flags for review.
- An "unsafe" report is escalated, not queued behind twelve duplicate reports.
- Consider a standing disclaimer on published topos. This is a product/legal call, not a
  technical one, but it belongs in the same conversation.

I am not a lawyer and this is not legal advice — but a community-edited climbing guide is exactly
the kind of thing where the liability question is worth asking someone who is, *before* launch
rather than after.

---

## 3. Prior art

Researched 2026-08-06. Sources at the end of this document. Every platform below solves the
same problem we are solving, most of them for a decade or more, and several arrived at answers
that contradict things in this plan.

### 3.1 What everyone actually does

| Platform | Gate on edits | How it scales | Deletion |
|---|---|---|---|
| **theCrag** | Karma thresholds per action, **scaled by how developed the crag is** | 10 000 karma ⇒ standard updates almost anywhere; 100 000 ⇒ regions. Below that, "Request Permission", assessed manually, ~24 h | **Cannot delete routes.** Merge instead |
| **Mountain Project** | Regional admins (volunteers) review new areas/routes/photos | Geographic split — each admin owns a region | Admin-mediated |
| **UKClimbing** | Volunteer crag moderators | Geographic | Moderator-mediated |
| **Wikipedia** (pending changes) | Public sees the last **accepted** revision; logged-in users see pending | Autoconfirmed editors bypass review entirely | Revert, not delete — history is permanent |
| **Stack Overflow** | Anyone (even anonymous) may suggest; **2 000 rep** to review | Reputation. +2 rep per accepted edit, capped at 1 000 | Rollback |
| **Waze** | Rank 1–6; editable area = where you actually drove | L1–L3 automatic by edit count, **L4+ by community deliberation**. Area Manager = a permanent granted area | Rank-gated |
| **Google Maps** | Multi-signal trust: auto-accept, queue, request evidence, or revert | Editor history + acceptance rate + Local Guide tier | Algorithmic + human |
| **Discourse** | TL0–TL4 | Explicit stated goal: *sandbox new users so they cannot hurt themselves or others; grant experienced users rights over time so they help moderate* | TL3 flags can auto-hide |

**Not one of them gates edits on the original contributor's approval.** They all gate on
*earned trust*, usually scoped to a geographic area. That is the finding worth sitting with.

### 3.2 The thing that challenges our model: "nobody owns a route"

This is the settled position in the climbing world, not a fringe view:

- First-ascensionist rights are **a tradition of courtesy**, not ownership — the FA names and
  grades the route by convention, and that is the extent of it.
- The **EFF/OpenBeta vs Mountain Project** dispute settled the data question publicly: *facts,
  like the names and locations of climbing routes, cannot be copyrighted.* MP claimed it "owns
  all rights and interests in the user-generated work" and filed a DMCA takedown; the EFF pointed
  out MP's own terms simultaneously said "you own Your Content". Route descriptions may be
  copyrightable as prose; the route's existence, name, grade and location are not.

**So what does the Masi topo owner actually own?** Their photograph, their drawn lines, and their
words. Not the route. Not its grade. Not whether it is currently closed or has a loose block.

That distinction is not pedantry — it resolves the tension directly:

> **Owner-approval is right for the artefact and wrong for the facts.**
>
> The topo — photo, geometry, description — is a creative work with an author. Requiring the
> author's approval to change it is correct, defensible, and matches how they'd feel about someone
> redrawing their lines.
>
> But "this route is 7a not 6c", "there's a loose block at the third bolt", "the landowner has
> closed this crag", "I climbed here last week and it's accurate" are **facts about the world**.
> Gating those behind one person's inbox means a topo can be knowably wrong, with the correction
> written and waiting, because someone stopped opening the app.

**Recommended revision (R-1): split the data model along that line.**

| Layer | Who can change it | Gate |
|---|---|---|
| **Artefact** — photo, route geometry, name, description | Owner only | Owner approves suggestions (as decided) |
| **Community facts** — grade opinions, conditions, hazard notes, access status, "still accurate" | Anyone signed in | None, or trust-gated. Aggregated and displayed alongside the owner's values, never overwriting them |

The owner's grade stays the owner's grade; the community's consensus grade appears next to it,
the way every climbing platform already shows a "community grade" beside the guidebook grade. No
approval queue, no bottleneck, no argument about who is right — both numbers are visible.

This subsumes C-10 (last-verified) and much of C-7 (reporting) into one coherent mechanism, and
it is the single change I would most strongly recommend to the plan as it stands.

### 3.3 Never delete — merge

theCrag: *"There is only a very limited delete functionality on theCrag because routes may be
referenced elsewhere or climbers might have logged ascents against the route, all information that
should not be lost."* Duplicates are **merged**; the rare unmergeable case goes to a "purgatory"
area rather than being destroyed.

This validates C-8 and, more usefully, **answers Open Question 4** (what happens to ascents on a
withdrawn topo). The domain's answer is unambiguous: *the logged ascents are the reason you do
not delete in the first place.* Someone's send of a hard project is their record, not the topo
owner's to revoke. Ascents must outlive the topo.

### 3.4 Duplicates: flag for a human, never auto-resolve

OSM conflation's core principle: the tooling *"does not remove anything from the collected data;
instead it adds custom tags on what it finds"*, so a human decides. Probable duplicates are
surfaced, never silently merged.

Confirms C-6's approach and rules out any automatic same-place deduplication.

### 3.5 The reviewer backlog is the known way this dies

- Wikipedia's pending-changes backlog currently runs 1–2 days, and the documented primary
  criticism of the whole mechanism is **reviewer burden**.
- Research on volunteer moderators is blunt about the failure mode: *"a neverending queue of
  posts to review"*, burnout, attrition.
- The sharpest framing found: **a moderation queue is not a backlog problem, it is a routing
  problem.** If content does not land at the right review tier immediately, adding reviewers
  does not fix throughput.

**This settles Open Question 1.** Trust levels are not an optimisation to add later — they are
the load-bearing mechanism, and every single platform in §3.1 has them. Reviewing every
submission by hand is a design that works until the app succeeds, and then stops.

Concretely, adopting the shape they converge on (Discourse's rationale, theCrag's scaling,
Waze's automatic-then-deliberated split):

| Level | Reached by | Can |
|---|---|---|
| **New** | signing up | Draft freely; submit topos (reviewed); suggest edits (rate-limited) |
| **Contributor** | 1 approved topo, or *N* accepted suggestions | Publish with spot-check review rather than full review |
| **Trusted** | several approved topos, no upheld reports | Publish immediately; flag content for admin attention |
| **Moderator** | granted by an admin | Review queue, merge duplicates, revert, act on reports |

theCrag's extra twist is worth stealing: **permission difficulty scales with how developed the
area already is.** Editing a bare new crag is easy; editing a thoroughly documented one needs
more standing. That maps neatly onto our C-6 place-clustering.

### 3.6 Access and closure is a first-class field, not a report reason

theCrag treats this as core infrastructure, and my plan had it as a mere report category — that
is a real gap. What they do:

- A `Closed` tag plus an `Access` field explaining why, rather than a free-text warning.
- **Warnings inherit down the hierarchy**: a warning at crag level shows on every sector and route
  beneath it. Our Area → Sector → Wall tree gives us this for free.
- Visibility of topos, photos and descriptions can be **restricted entirely** for sensitive
  locations (raptor nesting, private land, culturally significant sites — the Grampians closures
  are the well-known case).
- Their stated philosophy: *model reality* — tell climbers a crag is explicitly closed rather than
  hiding it, because otherwise they go exploring.

**Recommended addition (R-2): `access` state on Areas/Sectors/Walls** — `open` / `restricted` /
`closed` / `sensitive`, with a reason, inheriting downward, and a `sensitive` mode that suppresses
public visibility of the topo entirely. Admin-settable; community-reportable. For a climbing app
this is arguably higher-value than half of the edit workflow, and it is much cheaper to build.

### 3.7 Reputation is the reward loop

Stack Overflow pays +2 reputation per accepted edit (capped at 1 000). theCrag pays karma for
every contribution, and that karma *is* the permission system. People do not suggest edits out of
altruism at scale — they do it because it visibly counts for something, and because it unlocks
things.

Our C-5 attribution line ("accepted suggestions credit their author") is the seed of this, but it
should be wired to the trust levels in §3.5 rather than left as a display string.

### 3.8 Liability: the disclaimers all say the same thing

Guidebook disclaimers converge on: users assume all risk; no warranty of accuracy; **not all
routes have been checked recently**; holds fall off and protection deteriorates, which can change
the grade or seriousness. There is active legal scholarship on route-developer liability, with
the policy argument running toward *limiting* it — because liability would discourage people from
equipping routes at all.

Two implications for us, beyond C-12:
- The staleness point is in every disclaimer, which is independent support for R-1's
  "still accurate" signal and for showing a last-verified date.
- Whatever disclaimer ships should say the same things these do. That is a lawyer's job, not
  mine, but the shape is well-established and worth copying rather than inventing.

---

## 4. Existing weaknesses this plan has to fix anyway

Found while reading the code for the above. All three block community editing at any real scale.

**W-1. The shared feed is unbounded and global.** `fetchSharedTopos()`
(`sync_remote.dart:623`) issues `.from('walls').select().eq('visibility','shared')` with **no
limit, no geo scope, no pagination**, then imports every row into local SQLite. At 100 shared
topos this is fine. At 10 000 it downloads the world onto a phone at a crag. It also means
"pending topos must not be visible" has to be enforced in that query *and* in RLS, or every
client pulls unreviewed content. Needs geo/paged scoping — and it is already flagged in-code as
a `TODO(P0 backend)` wanting a single RPC.

**W-2. Photo bytes outlive their rows.** Shared photos live at `shared/<photoId><ext>` in a
public bucket. Removing a topo removes rows; nothing removes the object. A moderator taking down
inappropriate imagery must be able to take down *the bytes*, not just the row pointing at them.

**W-3. Published photos carry EXIF.** The picker deliberately requests full metadata to read GPS
(`pickPhotoFrom`, `requestFullMetadata: true`). That is correct for placing a wall — but the
same bytes then go to a public bucket. Publishing should strip EXIF from the uploaded copy after
the coordinates have been extracted. (The avatar path added this week already does this, for the
same reason.)

---

## 5. Data model sketch

New tables, none of them in `syncTableNames`, none client-writable except where stated:

| Table | Client write | Purpose |
|---|---|---|
| `admins` | none | uid → role. Seeded by hand. |
| `wall_moderation` | none | state, submittedAt, reviewedAt, reviewerId, rejectionReason, withdrawRequestedAt |
| `topo_edit_suggestions` | INSERT (author), UPDATE (target owner) | proposed patch + status |
| `topo_reports` | INSERT (reporter) | reason, note, status |
| `topo_versions` | none | JSON snapshot per published change |
| `moderation_log` | none | append-only audit |
| `topo_verifications` | INSERT (any user, one per user per topo) | C-10 "still accurate" |

Writes to the none-write tables happen through `SECURITY DEFINER` RPCs that re-check admin
membership or ownership server-side. **`walls` itself gains no moderation column** (G-1).

Client-side: a `moderation` feature module, `/admin` route, and — the part that needs care — the
sync engine learning to pull `wall_moderation` for the walls it already fetches, without ever
pushing it.

---

## 6. Suggested phasing

Each phase is independently shippable and leaves the app in a coherent state.

1. **Foundations** — `admins`, `moderation_log`, `wall_moderation`, RPCs, RLS. No UI. Approve
   everything automatically so behaviour is unchanged. Proves the enforcement layer in isolation.
2. **Review queue** — submit/approve/reject, `/admin`, pending is invisible to others. This is
   the point of no return for the feed: fix W-1 here or not at all.
3. **Withdrawal cooldown + delete protection** (C-3). Needs the per-row push-error isolation
   noted above; verify that first.
4. **Version history** (C-8) — before edits, so edits are reversible from day one. Not optional
   now that owner approval is final (C-5c).
5. **Reports** (C-7) — moved ahead of edits for the same reason: with no admin re-review, these
   two are the whole safety net, and shipping the edit path before them leaves a window with no
   recourse at all.
6. **Metadata suggestions** (C-5, kinds `topo.metadata` / `route.metadata`) + attribution +
   the material-change notice (C-5d). Proves the propose → review → apply loop end to end on the
   cheap payloads.
7. **Geometry suggestions** (C-5, kinds `route.geometry` / `route.add` / `route.delete`) — the
   propose-a-line canvas and the overlay diff. Largest single piece of UI in the plan; it reuses
   `DrawController` and `TopoPainter` but earns its own phase.
8. **Trust levels** (C-4, §3.5), **duplicates & merging** (C-6, §3.4), **community facts layer**
   (R-1, §3.2 — subsumes last-verified/C-10).

Two items the research moved **earlier** than I originally had them, and one that is new:

- **Access/closure (R-2, §3.6)** can ship at any point — it depends on nothing else here, it is a
  field plus inheritance plus a banner, and for a climbing app it may be worth more than the
  entire edit workflow. Consider shipping it before phase 1.
- **Trust levels (§3.5)** were phase 8 as "an optimisation". They are not. They are what keeps
  phase 2 from becoming your second job. Bring the *plumbing* forward into phase 2 even if the
  thresholds start at "everything is reviewed".
- **Merge, never delete (§3.3)** is a constraint on every phase, not a phase of its own.

---

## 7. Open questions — these need your call

1. ~~**Is review per-topo or per-account?**~~ **Effectively settled by §3.5** — every platform
   researched gates on earned trust, and reviewer backlog is the documented way this feature
   dies. Adopt trust levels. The remaining call is only the *thresholds* (how many approved
   topos before spot-check-only, before immediate publish), and those are tunable at runtime
   rather than baked in.
2. ~~**What exactly can a suggestion change?**~~ **DECIDED 2026-08-06: geometry too.** See C-5a
   and C-5b. Ship metadata suggestions first; the propose-a-line canvas is the largest single
   piece of UI in this plan and should not gate the rest.
3. **Topo rating: new star scale, or rank by existing signals?** I lean strongly toward ranking
   (§C-6.3) because route `stars` already exist and mean something different. But if you want
   users to be able to *say* "this topo is better", a thumbs-up is clearer than a second star.
   §3.7 adds a reason to decide soon: whatever the signal is, it should feed trust levels.
4. ~~**What happens to comments, likes and ascents on a withdrawn topo?**~~ **Answered by §3.3.**
   theCrag's stated reason for having almost no delete functionality is precisely that climbers
   have logged ascents against routes and *"all information that should not be lost"*. Ascents
   outlive the topo. Someone's send is their record, not the topo owner's to revoke.
5. ~~**Does an approved topo need re-review after an edit?**~~ **DECIDED 2026-08-06: no —
   the owner's approval is final.** See C-5c for what that shifts onto reporting and version
   history, and C-5d for the non-blocking admin notice I would add to cover bait-and-switch.
6. **How public is the moderation?** Is a rejection reason private to the owner, or is the queue
   itself visible? Transparent moderation builds trust and costs you the ability to act quietly.
7. **NEW — do you accept R-1 (§3.2), splitting artefact from facts?** This is the biggest open
   item after the research, and it partly reopens your owner-approval decision: not to overturn
   it for the topo itself, but to carve grade opinions, conditions, hazards and access out from
   under it. My recommendation is yes, and the phasing below assumes it.
8. **NEW — do you accept R-2 (§3.6), access/closure as a first-class inheriting field?** Cheap to
   build, high value for a climbing app, and currently missing entirely.

---

## 8. What I would not build

- **Wiki-style open editing** (anyone edits directly, revert on abuse). It is the wrong default
  for safety-critical content, and it fights the ownership model the whole sync engine is built
  on.
- **Automatic merge of conflicting edits.** LWW is fine for one user across their own devices; it
  is not fine for two strangers editing the same topo line. Owner-approves-patch sidesteps this
  entirely, and that is a feature.
- **A second rating scale**, unless Open Question 3 says otherwise.
- **Moderation logic in Dart.** See G-2. Anything the app enforces alone is a suggestion.
- **A delete button on published content.** §3.3 — the domain's own platforms concluded this over
  a decade of operation. Merge, withdraw, or revert; never destroy something other people have
  logged ascents against.
- **Automatic duplicate merging.** §3.4 — flag for a human, always.
- **Claiming ownership of contributed route data.** §3.2 — Mountain Project tried exactly this
  and it went badly and publicly. Users own their photos and prose; nobody owns the route.

---

## Sources

Climbing platforms
- [theCrag — User permissions](https://www.thecrag.com/en/article/indexpermissions)
- [theCrag — Karma](https://www.thecrag.com/en/article/cragkarma)
- [theCrag — Adding and Editing Routes](https://www.thecrag.com/en/article/updatingdescriptions)
- [theCrag — Merging and deleting](https://www.thecrag.com/en/article/merging)
- [theCrag — Private, sensitive and closed crags](https://www.thecrag.com/en/article/sensitivecrags)
- [theCrag — Warnings](https://www.thecrag.com/en/article/warnings)
- [Mountain Project — Regional Admins](https://www.mountainproject.com/help/14/regional-admins)
- [Mountain Project — Adding New Climbing Areas & Routes](https://www.mountainproject.com/help/12/adding-new-climbing-areas-routes)
- [UKClimbing — Logbook moderators help](https://www.ukclimbing.com/logbook/help2.php)

Ownership and data rights
- [EFF — Rock Climber's Open Data Project Threatened by Bogus Copyright Claims](https://www.eff.org/deeplinks/2021/03/free-climbing-rock-climbers-open-data-project-threatened-bogus-copyright-claims)
- [Mountain Project forum — To What Extent Does a First Ascensionist Own Her/His Route?](https://www.mountainproject.com/forum/topic/119732104/to-what-extent-does-a-first-ascensionist-own-herhis-route)
- [UKC forum — The 'rights' of the first ascensionist](https://www.ukclimbing.com/forums/rock_talk/the_'rights'_of_the_first_ascensionist-643708)

Edit review and trust models
- [Wikipedia — Pending changes](https://en.wikipedia.org/wiki/Wikipedia:Pending_changes)
- [Wikipedia — Protection policy](https://en.wikipedia.org/wiki/Wikipedia:Protection_policy)
- [Stack Overflow Blog — Suggested Edits and Edit Review](https://stackoverflow.blog/2011/02/05/suggested-edits-and-edit-review/)
- [Discourse — Understanding Discourse Trust Levels](https://blog.discourse.org/2018/06/understanding-discourse-trust-levels/)
- [Discourse Meta — Trust Level Permissions Reference](https://meta.discourse.org/t/trust-level-permissions-reference/224824)
- [Wazeopedia — Ranks](https://www.waze.com/wiki/EAC/Ranks)
- [Google Local Guides — Why is my edit status "Pending" or "Not Applied"?](https://www.localguidesconnect.com/t5/Help-Desk/Why-is-my-edit-status-Pending-or-Not-Applied/ba-p/1079069)
- [iNaturalist — Data Quality Assessment / Research Grade](https://help.inaturalist.org/en/support/solutions/articles/151000169936-what-is-the-data-quality-assessment-and-how-do-observations-qualify-to-become-research-grade-)

Geodata versioning, reverts and duplicates
- [OSM Wiki — Change rollback](https://wiki.openstreetmap.org/wiki/Change_rollback)
- [OSM Wiki — Vandalism detection](https://wiki.openstreetmap.org/wiki/Detect_Vandalism)
- [OSM Wiki — Conflation](https://wiki.openstreetmap.org/wiki/Conflation)
- [HOT OSM — Data conflation](https://hotosm.github.io/osm-fieldwork/about/conflation/)
- [Attention-Based Vandalism Detection in OpenStreetMap (ACM)](https://dl.acm.org/doi/fullHtml/10.1145/3485447.3512224)

Moderation at scale
- [Why do volunteer content moderators quit? Burnout, conflict, and harmful behaviors (New Media & Society)](https://journals.sagepub.com/doi/full/10.1177/14614448221138529)
- ["Think about it like you're a firefighter": Understanding How Reddit Moderators Use the Modqueue (arXiv)](https://arxiv.org/html/2509.07314v2)

Liability
- [Arizona State Law Journal — Sport Climbing and Assumption of Risk](https://arizonastatelawjournal.org/2025/10/19/sport-climbing-and-assumption-of-risk-liability-for-climbing-on-private-bolts-and-land/)
- [VDiff — Disclaimer](https://www.vdiffclimbing.com/disclaimer/)
- [Idaho: A Climbing Guide — Disclaimer](https://www.idahoaclimbingguide.com/disclaimer/)
