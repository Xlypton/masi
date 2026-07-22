# masi icon set — v5 "hierarchical duotone++", iOS-first

80 glyphs for Masi with real brand character (facets, depth, the crack) that still behave technically like Material icons: 24×24 grid, no background shape, **tintable with exactly one runtime color**.

## How faceted icons stay single-color tintable

Each icon is layered like Apple's *hierarchical* SF Symbols:

- **Primary layer** — strokes and key facets at full `currentColor`
- **Secondary facets** — the same `currentColor` at reduced `fill-opacity` (≈ .45 / .25 / .14)
- **Crack & cutouts** — negative space (transparent), so they show whatever is behind

When Flutter applies `ColorFilter.mode(color, BlendMode.srcIn)`, the RGB is replaced but **alpha is preserved** — so a 45%-opacity facet becomes 45% of *your* color. One tint in → full faceted rendering out, on any background, in any theme (see `tint_demo.png`).

**The honest limitation you asked about:** a literal icon *font* (`IconData` + .ttf) is one flat color per glyph — fonts cannot carry opacity layers, so this look is impossible there. SVG assets via `flutter_svg` (the `MasiIcon` widget below) keep it, with identical usage ergonomics. This is the same trade-off Apple makes: SF Symbols' monochrome mode is flat; their hierarchical mode is exactly this layered-alpha technique.

## Design language

- 1.8px strokes, **round caps** (iOS softness) + **miter joins** (masi facets): "soft ends, sharp facets"
- Faceted two-tone fills on brand & object shapes: boulder, mountain, wall, pin, cloud, cube, flag, flash, bookmark, compass needle, sun, folder flap, logbook spine…
- iOS conventions: `share` = square+arrow-up, `more_horiz` ellipsis, `filter` = decreasing lines, `sort` = up/down arrows, SF-proportioned chevrons
- Solid `_fill` variants for iOS tab-bar selected states: folder, compass, logbook, person, pin, star, bookmark, send_check, boulder (`tabbar_demo.png`)

## Flutter integration

```yaml
dependencies:
  flutter_svg: ^2.0.0
flutter:
  assets:
    - assets/icons/masi/
```

```dart
class MasiIcon extends StatelessWidget {
  const MasiIcon(this.name, {super.key, this.size, this.color});
  final String name;
  final double? size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = IconTheme.of(context);
    final c = color ?? theme.color ?? Theme.of(context).colorScheme.onSurface;
    final s = size ?? theme.size ?? 24;
    return SvgPicture.asset(
      'assets/icons/masi/masi_$name.svg',
      width: s, height: s,
      colorFilter: ColorFilter.mode(c, BlendMode.srcIn),
    );
  }
}
// Tab bar: icon: MasiIcon('logbook'), activeIcon: MasiIcon('logbook_fill')
```

## Migration map

### Climbing symbols (unify toolbar + canvas)
bolt → `masi_bolt` · anchor → `masi_anchor` · start → `masi_route_start` · sit start → `masi_sit_start` · crux → `masi_crux` · finish → `masi_finish_flag` · route → `masi_route` · boulder marker twin → `masi_boulder` · crag → `masi_mountain` · wall/sector → `masi_wall`

### Navigation & actions
folder_outlined → `masi_folder` (+`_fill`) · explore_outlined → `masi_compass` (+`_fill`) · menu_book_outlined → `masi_logbook` (+`_fill`) · person_outline → `masi_person` (+`_fill`) · search → `masi_search` · tune → `masi_filter`, tune+dot → `masi_filter_active` · CupertinoIcons.chevron_down → `masi_chevron_down` · chevron_left/right → `masi_chevron_left/right` · keyboard_arrow_up/down → `masi_chevron_up/down` · more_vert → `masi_more_horiz` (iOS) or `masi_more_vert` · edit(_outlined) → `masi_edit` · edit_note → `masi_edit_note` · pan_tool_alt_outlined → `masi_eye` · drive_file_move_outlined → `masi_folder_move` · delete_outline → `masi_delete` · public → `masi_globe` · lock/lock_outline → `masi_lock`/`masi_lock_open` · view_in_ar_outlined → `masi_ar_cube` · content_cut(_outlined) → `masi_scissors` · clear/close → `masi_close` · check → `masi_check` · add_photo_alternate_outlined → `masi_image_add` · undo/redo → `masi_undo`/`masi_redo` · photo_size_select_actual_outlined → `masi_image` · broken_image_outlined → `masi_image_broken` · image_not_supported_outlined → `masi_image_off` · place → `masi_pin` (+`_fill`) · phonelink_off_outlined → `masi_phone_off` · center_focus_strong → `masi_scan` · restart_alt → `masi_restart` · my_location → `masi_my_location`

### Future
All glyphs previously listed here (`send_check(_fill)`, `flash`, `project`, `star(_fill)`,
`bookmark(_fill)`, `share`, `download`/`upload`, `sync`, `settings`, `info`/`warning`,
`sun`/`cloud_rain`, `parking`/`signpost`, `carabiner`, `ruler`, `sort`, `add`, `grid_view`/`list_view`,
`camera`, `location_off`) shipped in v5 — see `assets/icons/masi/` for the full 80-glyph set.

## Extending

`generate.js` is the source of truth (`node generate.js`). Recipe for new glyphs: strokes at full color; facet fills via `U(shape, opacity)` at .45/.25/.14; keep facet edges sharp, container corners rounded (rx 1.5–3); use `band()` to punch stroked shapes out of `_fill` variants.

The generator writes to `masi_icons_v5_svg/svg/`, not directly to the app — newly generated glyphs must be copied from there into `assets/icons/masi/` before `MasiIcon` can reference them.

## v4 additions — liveness pass

- **Third tonal facet** on hero shapes (boulder is now 3 tones + crack, like the brand marker)
- **Ground shadows** (thin `fill-opacity ≈ .14` ellipses) under grounded objects: boulder, mountain, wall, pin, carabiner, flag, signpost, topo_map
- **Micro-details**: compass ticks + center cap, logbook bookmark ribbon, bolt dots on the route line, two-tone image peaks, camera flash + lens dots, lock keyhole stem, eye pupil + lid tones, split star/crux/warning/globe, check echo-band in send_check, lens glint in search, carabiner body under-band, dimensional bolt arms
- **New icon `masi_topo_map`** — the folded topo with route line, start dot and anchor ring, straight from the brand tile set
- Note: `masi_boulder_fill` currently aliases the faceted boulder; if you want a flat solid boulder for tab bars, say so and I'll split them.

All still single-`currentColor`: every facet, shadow and detail is an opacity of the one tint you pass in.

## v5 — faceted fills + second detail pass

**Fill variants are now faceted solids**, not flat silhouettes: split-tone halves (1.0 / ~.82) with evenodd cutouts — compass_fill has half-disc facets, a needle cutout and a center cap; pin_fill two-tone with the hole; logbook_fill gets its spine, ribbon and punched-out check; send_check_fill a soft halo ring; person/star/bookmark/folder two-tone with a fold seam; boulder_fill is the three-facet solid with shadow (now distinct from the outline boulder).

**Outline details added:** globe latitude ring, bolt dots on the wall, sun over the mountain, speed dashes on flash, document line in the folder, sun in image_add, arrow backing-bands in download/upload, alternating ruler ticks, anchor center dot, carabiner hinge dot, peak marker on topo_map.
