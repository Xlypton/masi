# MASI — Design Language

The visual system for Masi. **This file is the source of truth for all UI work.** When a screen is in doubt, it defers to the five principles at the bottom. Live reference (rendered): the "MASI Design Language" artifact.

Derived from the app mark: a faceted amethyst boulder split by a jagged white crack. The crack is a route line — that is the core idea.

**Platform stance:** iOS-first / Cupertino-flavored. We lean on the iOS vocabulary (large-title nav, grouped inset lists, action sheets, segmented controls, tinted text buttons, floating translucent chrome) rather than the Material vocabulary (opaque AppBars, elevation lines, Material dialogs, corner FABs as the primary action). The app is built on Flutter Material widgets, so we achieve the iOS feel by **theming Material hard** + using Cupertino widgets where they clearly win (`showCupertinoModalPopup` action sheets, `CupertinoSlidingSegmentedControl`, `CupertinoSwitch`). Keep it consistent — do not mix stock Material dialogs with Cupertino sheets.

---

## Color tokens

Define these once in `lib/app/theme.dart` as a `MasiColors` class (or `ThemeExtension`) and reference them everywhere — never hard-code hex in widgets.

### Brand ramp (from the logo)
| Token | Hex | Use |
|---|---|---|
| `amethyst100` | `#EFE9FA` | faint tint fills |
| `amethyst200` | `#DCD0F2` | light facet, selected tint |
| `amethyst300` | `#BDAEE4` | base facet, thumbnails |
| `amethyst400` | `#9A88CD` | mid facet |
| `amethyst500` | `#8C78C4` | deep facet |
| `accent` | `#6E56C6` | **action only** — buttons, links, active tool, FAB (light theme) |
| `accentPress` | `#5B45AD` | pressed accent |

### Grade bands (semantic — difficulty, NEVER used as the accent)
| Band | Hex | French |
|---|---|---|
| beginner | `#2F9E6B` | ≤ 4 |
| intermediate | `#3B82C4` | 5–6a |
| advanced | `#E08A2B` | 6a+–6c+ |
| hard | `#D6483B` | 7a–7c+ |
| elite | `#8A5CD1` | ≥ 8a |

(These map to the existing grade-band logic in `core/grades` — wire the color there to these hexes.)

### Light theme
| Token | Hex |
|---|---|
| `ground` (scaffold bg) | `#F3F1F9` |
| `surface` (cards, rows) | `#FFFFFF` |
| `surface2` | `#FBFAFE` |
| `chrome` (translucent bar fill) | `rgba(249,248,253,0.72)` + blur |
| `ink` (primary label) | `#1B1725` |
| `ink2` (secondary label) | `#6A6380` |
| `ink3` (tertiary/placeholder) | `#A29BB6` |
| `separator` | `rgba(60,48,96,0.12)` |
| `onAccent` | `#FFFFFF` |

### Dark theme
| Token | Hex |
|---|---|
| `ground` | `#100D17` |
| `surface` | `#1D1929` |
| `surface2` | `#251F34` |
| `chrome` | `rgba(23,19,33,0.68)` + blur |
| `ink` | `#F3F0FA` |
| `ink2` | `#ABA4C0` |
| `ink3` | `#766F8C` |
| `separator` | `rgba(200,190,235,0.14)` |
| `accent` (dark) | `#B7A2F0` (lighter amethyst for contrast) |
| `onAccent` (dark) | `#1A1226` |

Neutrals are **purple-biased**, never flat grey. Support light + dark from day one; the `ThemeData` seed uses `accent`, but override the surfaces/labels with the tokens above (don't rely on Material's generated palette).

---

## Typography — San Francisco, iOS scale

Use the OS font: on iOS this is San Francisco automatically (Flutter's default `.SF` on Cupertino / the default Material font on iOS resolves to SF). **Do not bundle a webfont.** Set `fontFamily` to the platform default and rely on iOS. Scale (logical pt / weight):

| Style | Size | Weight | Tracking | Use |
|---|---|---|---|---|
| Large Title | 34 | w700 | -0.5 | screen large titles (Topos, Sector) |
| Title 1 | 28 | w700 | -0.4 | section headers |
| Title 2 | 22 | w600 | -0.3 | sheet titles, "Add a route" |
| Headline | 17 | w600 | 0 | route name, row emphasis |
| Body | 17 | w400 | 0 | default text (one-handed reading) |
| Subhead | 15 | w400 | 0 | row subtitles ("3 routes · today") |
| Footnote | 13 | w400 | 0 | helper text |
| Caption | 12 | w500 | +0.4, UPPERCASE | labels (FRENCH · UIAA) |

Give large titles `w700` and tight negative tracking. Body stays 17. Expose as a `MasiText` helper or `TextTheme`.

---

## Form — spacing, radius, depth

- **Spacing:** 4 / 8 / 12 / 16 / 24 / 32 grid. Row padding 10–14 vertical, 14–16 horizontal. Screen margins 16–20.
- **Radius:** control `10`, card/list `14`, large card / sheet `20`, hero/big card `28`, app-icon squircle `33`. Prefer generous, continuous-feeling rounding.
- **Depth:** flat surfaces + **soft shadows**, not Material elevation lines. `shadow: 0 1px 2px rgba(38,26,72,.06), 0 8px 24px rgba(38,26,72,.08)` (light). Floating chrome uses a **backdrop blur** over the photo (`BackdropFilter` + translucent `chrome` fill), not an opaque bar.
- **Motion:** iOS-like spring/ease; short (120–260ms). Respect reduced-motion. Don't over-animate.

---

## Components

### Navigation — large title
Screen title as a **large title** below a slim bar. Back = chevron + previous title in `accent`. Trailing actions are `accent` text or `accent` glyphs, never a filled button in the bar. Title text must `overflow: ellipsis` and be `Flexible` so it never overflows when trailing icons appear (fixes the "Climb…" truncation — but more importantly the canvas title should be the **topo/wall name**, not "Masi").

### Topos home — grouped inset list (the new flat home)
- `/` is the **flat list of topos** (each topo = a wall + its original photo + route count). Drop the Area→Sector→Wall drill-down from the primary flow; keep it reachable via a trailing "Organize" action, and keep the data model intact.
- Row: 52×52 rounded (`9`) **photo thumbnail** (fallback = amethyst gradient), title (Headline), subtitle (Subhead) showing a grade **pill** (grade-band color, white text) + "N routes", trailing chevron in `ink3`.
- Primary action = a **filled amethyst button "New topo"** (pinned bottom, or a `+` in the trailing nav slot) → opens the photo-source action sheet → on capture, create the topo and push straight to the canvas. One tap + a photo.
- Empty state: friendly, centered — "No topos yet" + a "New topo" button.
- Rename / delete from the row (swipe or a context menu), reusing existing repo soft-delete.

### Buttons
- **Filled** (primary): `accent` bg, `onAccent` text, radius 13, weight w590, subtle accent-tinted shadow. Scale to .98 on press.
- **Tinted** (secondary): `accent` text on a `~16%` accent wash.
- **Plain** (tertiary/Cancel): `accent` text, no fill.
- **Destructive:** `hard` (#D6483B) text on a faint red wash (or plain red text in sheets).

### Photo source — iOS action sheet (the camera/library ask)
Use `showCupertinoModalPopup` → `CupertinoActionSheet`:
- Title: "Add a photo"
- Action "Take photo" (camera glyph) → `ImageSource.camera`
- Action "Choose from library" (photo glyph) → `ImageSource.gallery`
- Cancel action.
Reuse from both the Topos-home "New topo" flow and the canvas "replace photo". Requires `NSCameraUsageDescription` + `NSPhotoLibraryUsageDescription` in `ios/Runner/Info.plist`.

### Toast — the one transient message (`MasiToast`)
Every transient message in the app is a **`masiToast`**, shown through the ordinary
`ScaffoldMessenger` (`messenger.showMasiToast(...)` / `.showMasiSuccess` / `.showMasiError` /
`.showMasiWarning`). **Never construct a bare `SnackBar`** — that is what the app had before, ~95
unstyled Material bars where the words carried the entire distinction between "Cover photo updated"
and "Couldn't save your like".

- **Transport vs. appearance.** The `SnackBar` is kept only as the transport (it already solves
  queuing, swipe-to-dismiss, route changes, and the home-indicator safe-area fix in
  `MasiTheme.withSnackBarSafeArea`) and is stripped bare — transparent, elevation 0, zero padding.
  Everything visible is `MasiToastCard`: `surface` fill, `MasiRadii.card`, a hairline `separator`
  border, and the shared `kMasiAmbientShadow` — the same material as the account cards and the
  install banner.
- **Four kinds, one component.** `success` (`check`, `gradeBeginner`) · `error` (`warning`,
  `gradeHard`) · `warning` (`warning`, `gradeAdvanced`) · `info` (`info`, `ink2`, the default). The
  kind sets the leading chip's glyph and tint and nothing else, so a toast still reads as one
  component rather than four. Grade-band hues INFORM; `accent` stays reserved for action, which is
  why the optional action button is the only accent-coloured thing in the card.
- **Duration follows the kind**: error 6s, warning 5s, everything else 4s. An error is the only kind
  that asks something of the reader.
- **At most one action**, and it dismisses the toast before it runs.

### Segmented control
`CupertinoSlidingSegmentedControl` for grade system (French / UIAA) and similar binary/short choices.

### Topo canvas — the hero screen
- **The whole photo is visible on open** — CONTAIN-fit (`computeContainTransform`), never pre-cropped to
  fill the viewport: the user sees the entire wall first, then pans/zooms in from there (pinch/drag stay
  enabled in view mode; `minScale` always lets you zoom back out to the full wall). The image itself
  paints at `BoxFit.contain` sized to its own `imageSize`. Slice/crop framing is unaffected — this is the
  DEFAULT, no-slice framing only.
- **No black window.** The photo's own edges **softly feather to the app's `ground` surface color**
  (theme-aware — light in light theme, dark in dark theme; four gradient strips, one per edge) rather than
  stopping at a hard border or fading to a fixed dark matte, and that feather lives inside
  `InteractiveViewer`'s transformed content alongside the image — not as a static screen-space frame — so
  it **pans and zooms together with the photo**. The fixed viewport panel behind it is fully
  **transparent** (no fill, no border, no shadow of its own): the Scaffold's own `ground` shows straight
  through the CONTAIN-fit's letterbox margins, so "the image is naturally part of the app" instead of
  floating in a dark viewer chrome. A screen-space rounded-corner clip keeps the visible photo corners
  tidy.
- Chrome **floats on translucent glass** over the photo, all on the SAME glass material (`GlassChrome`) —
  no opaque bars, no reserved dead space: a slim top pill (back chevron + topo name; trailing draw/
  slice/AR glyphs, all gated on a photo actually being loaded) and, draw mode only, the symbol palette
  floating directly beneath it; plus a bottom pill (undo / redo / commit) + the `accent` capture/add FAB.
  Blur the photo behind the glass; don't cover it with opaque bars, and don't reserve height for chrome
  that isn't currently showing — view mode reclaims the full canvas.
- **Route lines** render at a **constant on-screen weight** (fixed), colored by grade band, with grabbable point handles. Selected route = thicker + handles shown. Routes are the liveliest thing on screen.
- Tools (draw mode, symbols) use `accent` for the active state.

---

## The five principles (the testament)

1. **The photo fills the frame.** A wall opens edge-to-edge and centered, re-fitting when layout settles. The rock is the interface — never a thumbnail in empty space.
2. **Chrome floats, content is king.** Tools live on translucent glass that blurs the photo beneath, within thumb reach. The image owns the rest of the screen.
3. **Amethyst is only for action.** The one saturated purple (`#6E56C6`) means "you can touch this." Facet-purples decorate; grade colors inform; the accent is spent on intent alone.
4. **Routes are the brand.** The logo's crack is a route line — constant on-screen weight, grade-colored, handles you can grab.
5. **Fewer taps to a line.** Open → photo → draw. Organization waits. Home is your topos; a new one is one tap and a camera away, not four levels deep.
