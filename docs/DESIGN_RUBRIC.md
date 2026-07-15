# MASI — Visual Design Rubric

Scoreable checklist the **end-of-run visual judge** uses to critique screenshots.
Source of truth for tokens is `DESIGN.md` + `lib/app/theme.dart`; this file makes them *checkable*.

Two layers:
- **§A Objective checks** — mechanical, token-derived. A screenshot either passes or it doesn't.
- **§B Per-screen taste** — *filled by the human during calibration.* This is where "what good looks like"
  for each screen is captured. Until a screen has entries here, the judge scores it on §A only and flags
  that it is **uncalibrated**.

Severity: **blocker** (broken/unusable/overflow) · **major** (clearly ugly, violates a DESIGN mandate) ·
**minor** (polish) · **nit** (subjective preference).

---

## §A — Objective checks (apply to every screen)

### A1. Spacing on the 4/8/12/16/24/32 grid
- Gaps/paddings/margins read as multiples of the `MasiSpacing` scale (xs4 sm8 md12 lg16 xl24 xxl32).
- Screen margins 16–20. List-row padding ~10–14 vertical / 14–16 horizontal.
- **DON'T:** arbitrary off-grid gaps; cramped (<8) or accidental (uneven) spacing between sibling elements.

### A2. Corner radii from `MasiRadii`
- control 10 · card/list 14 · large card/sheet 20 · hero 28 · icon squircle 33.
- **DON'T:** sharp 0-radius rectangles on cards/sheets; mismatched radii on nested/adjacent surfaces.

### A3. Grade-band colors are the 5 canonical hexes — semantic only
- beginner `#2F9E6B` · intermediate `#3B82C4` · advanced `#E08A2B` · hard `#D6483B` · elite `#8A5CD1`.
- Used ONLY for route difficulty (lines, legend, grade chips). **NEVER** as a UI accent.

### A4. Accent (amethyst) is for ACTION ONLY
- `accent` #6E56C6 (light) / #B7A2F0 (dark) appears only on buttons, links, active tool/tab, FAB.
- **DON'T:** accent used as decoration, background fill, or on non-interactive text.

### A5. Typography = iOS SF scale, correct weights
- Large Title 34/700 · Title1 28/700 · Title2 22/600 · Headline 17/600 · Body 17/400 · Subhead 15 ·
  Footnote 13 · Caption 12/500 UPPERCASE.
- Titles use `overflow: ellipsis` — never wrap to a second line or clip mid-glyph.
- **DON'T:** body text that's too small (<15) for primary content; inconsistent weights for the same role.

### A6. Depth = soft shadows, not Material elevation lines
- Flat surfaces + soft ambient shadow (`0 1px 2px rgba(38,26,72,.06), 0 8px 24px rgba(38,26,72,.08)`).
- **DON'T:** hard 1px borders standing in for elevation; Material drop-shadow "cards with lines".

### A7. Purple-biased neutrals, never flat grey; light + dark both correct
- Backgrounds/text use the amethyst-biased neutral ramp (`ground/surface/ink/ink2/ink3`).
- **DON'T:** pure #808080 greys; a screen that only looks right in one theme.

### A8. iOS sheet consistency
- Confirmations/pickers are Cupertino action sheets; forms are the app's styled dialog/sheet.
- **DON'T:** mix stock Material AlertDialog styling with Cupertino sheets in the same flow.

### A9. Touch targets & reachability
- Interactive controls ≥ 44×44 (iOS) effective hit area; bottom controls clear of the home indicator.
- **DON'T:** buttons crowding each other (<8 gap); tap targets that overlap or sit under a safe-area inset.

### A10. Canvas-specific (the hero screen)
- Photo fills the frame edge-to-edge, centered, `BoxFit.contain`, with **clean, sharp edges** (no feather/
  vignette of any kind — removed 2026-07-13, see B-CANVAS) against the transparent frame's app-color
  letterbox margins.
- Fixed viewport panel behind photo = flat rounded `kCanvasBackdrop` backing, **no border/shadow of its own**.
- Chrome **floats on translucent backdrop-blur glass** over the photo — never opaque bars.
- Route lines render at **constant on-screen weight**, grade-band colored, with grabbable point handles.
- Trailing chrome actions are accent text/glyphs, never a filled button in the bar.

### A11. No overflow / no clipping / no jank artifacts
- No RenderFlex overflow stripes; no text clipped by its container; no element bleeding off-screen.
- Content region doesn't jump/resize when transient chrome (symbol bar, slice selector) appears.

---

## §B — Per-screen taste (CALIBRATION — filled by the human)

> For each screen: a short "**what good looks like**" statement, then any specific rules the judge must
> enforce for THIS screen. Empty = uncalibrated (judge scores §A only + flags it).

### B-CANVAS · Topo canvas (view / draw / slice / metadata)
_Status: **calibrated 2026-07-13** (user, from on-device screenshot); **re-calibrated same day** (user,
after seeing the edge-feather fade + trying the draw gesture on-device)_

**What good looks like (user's words):** "I just want the image to naturally be part of the
application — to be able to move around an image. Not have any background, just the image, blurred on the
side." The photo IS the screen; chrome floats over it on consistent glass.

**Rules:**
- **No black window / no separate backdrop.** Kill the `kCanvasBackdrop` black frame + the rounded black
  "window" the photo currently sits inside. The photo is full-bleed edge-to-edge.
- **Photo is freely pannable/zoomable** and fills the frame; the rock is the interface (never a thumbnail
  floating in empty bands — the current shrink-to-center-thumbnail is the #1 defect).
- **NO edge feather — clean sharp image edges against the app surface** (user reversed the fade
  2026-07-13). An earlier round of this calibration asked for a soft-fade-to-app-color edge feather (the
  photo's edges dissolving into the app `ground`); on-device the user found that feather ugly and asked
  for it removed entirely. The frame stays transparent (margins are still plain app-color, never black,
  never a blurred photo copy) but the photo itself is left sharp/uncut — no gradient, no vignette, on any
  edge. This SUPERSEDES the earlier "soft fade to app surface color" rule above and the corresponding
  `DESIGN.md` "feather to `MasiColors.ground`" text — DESIGN.md must be updated to match.
- **Gesture model while drawing:** two-finger pinch/drag pans and zooms the photo (same as view mode);
  single-finger TAP adds a route point; single-finger drag that STARTS ON an existing point handle moves
  that handle; a single-finger drag starting on empty space does nothing (no point, no pan — panning is
  reserved for two fingers while drawing, so it's never ambiguous with placing a point).
- **Chrome is one consistent glass treatment.** The title pill and the symbol palette must share the same
  floating-glass background and must NOT collide with each other or with the photo edge. Today the title is
  on grey glass while the symbol palette is on an opaque white strip that abuts the photo — that's the bug.
- Route lines stay constant on-screen weight, grade-band colored, grabbable handles (unchanged).
- **Slice/cut tool must be more discoverable/self-explanatory** — adding cut lines is not obvious today.
  _(Exact direction pending — user's description was cut off; revisit next round.)_

### B-HOME · Topos home (flat list)
_Status: **uncalibrated**_
- What good looks like: _(to fill)_
- Rules: _(to fill)_

### B-LIBRARY · Areas / Sectors / Walls lists + CRUD dialogs
_Status: **uncalibrated**_
- What good looks like: _(to fill)_
- Rules: _(to fill)_

### B-METADATA · Route metadata sheet
_Status: **uncalibrated**_
- What good looks like: _(to fill)_
- Rules: _(to fill)_

### B-AR · AR screen
_Status: **uncalibrated**_
- What good looks like: _(to fill)_
- Rules: _(to fill)_

---

## §C — Judge output format (one block per screen)

```
### <NN-label>  —  <screen name>   [calibrated | uncalibrated]
SEES:      2–4 sentences describing the actual composition, hierarchy, spacing, color — what's on screen.
VERDICT:   ship | needs-work
FINDINGS:
  - [severity] <problem>  — cites the rubric item (e.g. A6, B-HOME) — why it's wrong.
FIX (per finding): concrete instruction + file:line / widget where it lives, when known.
```

The judge reads the actual PNGs (it is vision-capable), scores against §A + the screen's §B, and ranks
findings most-severe first. It never weakens the app to pass a check; it reports what it sees.
