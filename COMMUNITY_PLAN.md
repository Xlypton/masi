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

## 3. Existing weaknesses this plan has to fix anyway

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

## 4. Data model sketch

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

## 5. Suggested phasing

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
8. **Trust levels** (C-4), **duplicates & ranking** (C-6), **last-verified** (C-10).

---

## 6. Open questions — these need your call

1. **Is review per-topo or per-account?** Reviewing every submission forever does not scale past
   your own free evenings. My recommendation: review the first *N* submissions per account, then
   auto-approve with spot checks. Which *N*?
2. ~~**What exactly can a suggestion change?**~~ **DECIDED 2026-08-06: geometry too.** See C-5a
   and C-5b. Ship metadata suggestions first; the propose-a-line canvas is the largest single
   piece of UI in this plan and should not gate the rest.
3. **Topo rating: new star scale, or rank by existing signals?** I lean strongly toward ranking
   (§C-6.3) because route `stars` already exist and mean something different. But if you want
   users to be able to *say* "this topo is better", a thumbs-up is clearer than a second star.
4. **What happens to comments, likes and ascents on a withdrawn topo?** People logged real climbs
   against it. My instinct: ascents survive the topo — they are the user's own record.
5. ~~**Does an approved topo need re-review after an edit?**~~ **DECIDED 2026-08-06: no —
   the owner's approval is final.** See C-5c for what that shifts onto reporting and version
   history, and C-5d for the non-blocking admin notice I would add to cover bait-and-switch.
6. **How public is the moderation?** Is a rejection reason private to the owner, or is the queue
   itself visible? Transparent moderation builds trust and costs you the ability to act quietly.

---

## 7. What I would not build

- **Wiki-style open editing** (anyone edits directly, revert on abuse). It is the wrong default
  for safety-critical content, and it fights the ownership model the whole sync engine is built
  on.
- **Automatic merge of conflicting edits.** LWW is fine for one user across their own devices; it
  is not fine for two strangers editing the same topo line. Owner-approves-patch sidesteps this
  entirely, and that is a feature.
- **A second rating scale**, unless Open Question 3 says otherwise.
- **Moderation logic in Dart.** See G-2. Anything the app enforces alone is a suggestion.
