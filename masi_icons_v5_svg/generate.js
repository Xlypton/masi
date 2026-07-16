// masi icon set v2 — iOS-first design language
// 24x24 grid | stroke 1.8 | round caps (soft iOS ends) + miter joins (sharp masi facets)
// iOS conventions: share = square+arrow-up, more = ellipsis, filter = decrease lines, sort = up/down arrows
// _fill variants for iOS tab-bar selected states (pure paths / evenodd, no masks -> max flutter_svg compat)
const fs = require('fs');
const path = require('path');
const sharp = require('sharp');

// ---- helper: convert a stroked polyline into a filled band polygon (flat caps, miter joins)
function band(pts, w) {
  const h = w / 2;
  const off = (sign) => {
    const lines = [];
    for (let i = 0; i < pts.length - 1; i++) {
      const [x1, y1] = pts[i], [x2, y2] = pts[i + 1];
      const dx = x2 - x1, dy = y2 - y1, L = Math.hypot(dx, dy);
      const nx = (-dy / L) * h * sign, ny = (dx / L) * h * sign;
      lines.push([x1 + nx, y1 + ny, x2 + nx, y2 + ny]);
    }
    const out = [[lines[0][0], lines[0][1]]];
    for (let i = 0; i < lines.length - 1; i++) {
      const [ax, ay, bx, by] = lines[i], [cx, cy, dx2, dy2] = lines[i + 1];
      const d1x = bx - ax, d1y = by - ay, d2x = dx2 - cx, d2y = dy2 - cy;
      const den = d1x * d2y - d1y * d2x;
      if (Math.abs(den) < 1e-9) out.push([bx, by]);
      else {
        const t = ((cx - ax) * d2y - (cy - ay) * d2x) / den;
        out.push([ax + d1x * t, ay + d1y * t]);
      }
    }
    const last = lines[lines.length - 1];
    out.push([last[2], last[3]]);
    return out;
  };
  const L = off(1), R = off(-1).reverse();
  const all = L.concat(R);
  return 'M' + all.map(p => `${p[0].toFixed(2)},${p[1].toFixed(2)}`).join(' L') + ' Z';
}

const circlePath = (cx, cy, r) =>
  `M${cx},${cy - r} A${r},${r} 0 1 1 ${cx},${cy + r} A${r},${r} 0 1 1 ${cx},${cy - r} Z`;

const I = {};
// duotone helpers: facet layers as opacities of currentColor (survive single-color tinting via srcIn)
const U = (inner, o) => `<g fill="currentColor" stroke="none" fill-opacity="${o}">${inner}</g>`;
const S = (cx, rx, cy, o) => `<ellipse cx="${cx}" cy="${cy}" rx="${rx}" ry="0.9" fill="currentColor" stroke="none" fill-opacity="${o}"/>`;

/* ============ (B) CLIMBING SYMBOLS — priority set ============ */
I['bolt'] = `<line x1="6.5" y1="6.5" x2="9.6" y2="9.6"/><line x1="17.5" y1="17.5" x2="14.4" y2="14.4"/><g stroke-opacity=".55"><line x1="17.5" y1="6.5" x2="14.4" y2="9.6"/><line x1="6.5" y1="17.5" x2="9.6" y2="14.4"/></g><circle cx="12" cy="12" r="2.2" fill="currentColor" stroke="none"/>`;
I['anchor'] = U('<circle cx="12" cy="15" r="4.6"/>', .25) + `<line x1="6.5" y1="4" x2="12" y2="10.2"/><line x1="17.5" y1="4" x2="12" y2="10.2"/><circle cx="12" cy="15" r="4.6"/><circle cx="12" cy="15" r="0.9" fill="currentColor" stroke="none" fill-opacity=".5"/>`;
I['route_start'] = `<line x1="4.5" y1="20.5" x2="19.5" y2="20.5"/>` + U('<polygon points="12,9.5 12,17 7.4,17"/>', 1) + U('<polygon points="12,9.5 16.6,17 12,17"/>', .55);
I['sit_start'] = U('<circle cx="7.5" cy="6.8" r="2.1"/>', .25) + `<circle cx="7.5" cy="6.8" r="2.1"/><polyline points="7.5,9.5 7.5,15 13.5,15 13.5,19"/><line x1="4" y1="19" x2="20" y2="19"/>`;
I['crux'] = U('<polygon points="12,2.8 12,21.2 2.8,12"/>', .26) + U('<polygon points="12,2.8 21.2,12 12,21.2"/>', .12) + `<polygon points="12,2.8 21.2,12 12,21.2 2.8,12"/><line x1="12" y1="8" x2="12" y2="13"/><circle cx="12" cy="16.2" r="1.3" fill="currentColor" stroke="none"/>`;
I['finish_flag'] = S(8.2,3,22.2,.15) + `<line x1="7" y1="21.5" x2="7" y2="3"/>` + U('<polygon points="7,4 17.5,4 14.8,7 7,7"/>', 1) + U('<polygon points="7,7 14.8,7 17.5,10 7,10"/>', .55);
I['route'] = `<circle cx="5.5" cy="20" r="1.8" fill="currentColor" stroke="none"/><polyline points="5.5,20 10,13.5 13,16 16.4,7.5"/><circle cx="10" cy="13.5" r="1.05" fill="currentColor" stroke="none"/><circle cx="13" cy="16" r="1.05" fill="currentColor" stroke="none"/>` + U('<circle cx="17.3" cy="5" r="2.1"/>', .25) + `<circle cx="17.3" cy="5" r="2.1"/>`;
I['boulder'] = S(12,8,20.7,.15) + U('<path d="M4.5,10.5 L9,4.5 L13.6,4.4 L11.6,8.4 L13.6,10.6 L11.2,15 Z"/>', .28) + U('<path d="M3,19.5 L4.5,10.5 L11.2,15 L12.8,19.5 Z"/>', .5) + U('<path d="M15.1,4.4 L13.1,8.4 L15.1,10.6 L12.7,15 L14.3,19.5 L19,19.5 L21,13 L19.5,7.5 L15,3.5 Z"/>', 1);
I['mountain'] = S(12,8.5,21.4,.14) + U('<polygon points="2.5,20.5 8.8,6.5 12.4,13 12.4,20.5"/>', .2) + U('<polygon points="12.4,20.5 12.4,13 15.4,8 21.5,20.5"/>', .45) + `<path d="M2.5,20.5 L8.8,6.5 L12.4,13 L15.4,8 L21.5,20.5 Z"/><circle cx="18.8" cy="5.6" r="1.2" fill="currentColor" stroke="none" fill-opacity=".45"/>`;
I['wall'] = S(12,7.5,21.9,.13) + U('<polygon points="4,21 4,8 10,3.5 10.5,21"/>', .42) + U('<polygon points="10,3.5 20,7 20,21 10.5,21"/>', .18) + `<path d="M4,21 L4,8 L10,3.5 L20,7 L20,21 Z"/><line x1="10" y1="3.5" x2="10.5" y2="21"/><circle cx="7.1" cy="10.2" r="0.85" fill="currentColor" stroke="none" fill-opacity=".6"/><circle cx="7.4" cy="14.8" r="0.85" fill="currentColor" stroke="none" fill-opacity=".6"/>`;

/* ============ (C) NAVIGATION & ACTIONS ============ */
I['folder'] = U('<path fill-rule="evenodd" d="M3,19.5 V5.5 H9.2 L11.4,8 H21 V19.5 Z"/>', .18) + U('<polygon points="3,5.5 9.2,5.5 11.4,8 3,8"/>', .3) + `<path d="M3,19.5 V5.5 H9.2 L11.4,8 H21 V19.5 Z"/><line x1="5.8" y1="11.8" x2="13" y2="11.8" stroke-opacity=".45"/>`;
I['folder_move'] = U('<path d="M3,19.5 V5.5 H9.2 L11.4,8 H21 V19.5 Z"/>', .18) + U('<polygon points="3,5.5 9.2,5.5 11.4,8 3,8"/>', .3) + `<path d="M3,19.5 V5.5 H9.2 L11.4,8 H21 V19.5 Z"/><line x1="8" y1="13.7" x2="14.6" y2="13.7"/><polyline points="12.2,11.2 14.8,13.7 12.2,16.2"/>`;
I['compass'] = U('<circle cx="12" cy="12" r="9"/>', .14) + `<circle cx="12" cy="12" r="9"/>` + `<g stroke-opacity=".5"><line x1="12" y1="4.6" x2="12" y2="6.4"/><line x1="12" y1="17.6" x2="12" y2="19.4"/><line x1="4.6" y1="12" x2="6.4" y2="12"/><line x1="17.6" y1="12" x2="19.4" y2="12"/></g>` + U('<polygon points="16.2,7.8 13.7,13.7 7.8,16.2"/>', 1) + U('<polygon points="16.2,7.8 7.8,16.2 10.3,10.3"/>', .5) + `<circle cx="12" cy="12" r="1" fill="currentColor" stroke="none"/>`;
I['logbook'] = U('<rect x="4.5" y="3" width="3.5" height="18"/>', .4) + U('<rect x="8" y="3" width="11.5" height="18"/>', .12) + U('<polygon points="14.8,3 17.2,3 17.2,7.4 16,6.1 14.8,7.4"/>', .55) + `<rect x="4.5" y="3" width="15" height="18" rx="1.5"/><line x1="8" y1="3.4" x2="8" y2="20.6"/><polyline points="10.8,12.2 12.8,14.2 16.6,9.8"/>`;
I['person'] = U('<circle cx="12" cy="6.9" r="3.5"/><path d="M4.6,20.6 A7.4,7.4 0 0 1 19.4,20.6 Z"/>', .25) + `<circle cx="12" cy="6.9" r="3.5"/><path d="M4.6,20.6 A7.4,7.4 0 0 1 19.4,20.6"/>`;
I['search'] = U('<circle cx="10.8" cy="10.8" r="6.8"/>', .14) + `<circle cx="10.8" cy="10.8" r="6.8"/><line x1="15.7" y1="15.7" x2="21" y2="21"/><line x1="7.6" y1="8.9" x2="9.2" y2="7.3" stroke-opacity=".5"/>`;
I['filter'] = `<line x1="4.5" y1="7" x2="19.5" y2="7"/><line x1="7" y1="12" x2="17" y2="12"/><line x1="9.5" y1="17" x2="14.5" y2="17"/>`;
I['filter_active'] = `<line x1="4.5" y1="7" x2="19.5" y2="7"/><line x1="7" y1="12" x2="17" y2="12"/><line x1="9.5" y1="17" x2="14.5" y2="17"/><circle cx="20.2" cy="3.8" r="2.1" fill="currentColor" stroke="none"/>`;
I['chevron_left'] = `<polyline points="14.6,4.5 8.4,12 14.6,19.5"/>`;
I['chevron_right'] = `<polyline points="9.4,4.5 15.6,12 9.4,19.5"/>`;
I['chevron_up'] = `<polyline points="4.5,14.6 12,8.4 19.5,14.6"/>`;
I['chevron_down'] = `<polyline points="4.5,9.4 12,15.6 19.5,9.4"/>`;
I['more_horiz'] = `<circle cx="5" cy="12" r="1.9" fill="currentColor" stroke="none"/><circle cx="12" cy="12" r="1.9" fill="currentColor" stroke="none"/><circle cx="19" cy="12" r="1.9" fill="currentColor" stroke="none"/>`;
I['more_vert'] = `<circle cx="12" cy="5" r="1.9" fill="currentColor" stroke="none"/><circle cx="12" cy="12" r="1.9" fill="currentColor" stroke="none"/><circle cx="12" cy="19" r="1.9" fill="currentColor" stroke="none"/>`;
I['edit'] = U('<path d="M4,20 L4.8,16.2 L16.1,4.9 L19.1,7.9 L7.8,19.2 Z"/>', .2) + U('<polygon points="14.3,6.7 16.1,4.9 19.1,7.9 17.3,9.7"/>', .5) + `<path d="M4,20 L4.8,16.2 L16.1,4.9 L19.1,7.9 L7.8,19.2 Z"/><line x1="14.3" y1="6.7" x2="17.3" y2="9.7"/>`;
I['edit_note'] = U('<path d="M11.5,20.5 L12.1,17.7 L18.2,11.6 L20.9,14.3 L14.8,20.4 Z"/>', .25) + `<line x1="3.5" y1="6.5" x2="13.5" y2="6.5"/><line x1="3.5" y1="10.5" x2="10.5" y2="10.5"/><line x1="3.5" y1="14.5" x2="8.5" y2="14.5"/><path d="M11.5,20.5 L12.1,17.7 L18.2,11.6 L20.9,14.3 L14.8,20.4 Z"/>`;
I['delete'] = U('<polygon points="6.3,6.5 17.7,6.5 16.7,20.5 7.3,20.5"/>', .14) + U('<rect x="5.2" y="6.5" width="13.6" height="1.9"/>', .28) + `<line x1="4.5" y1="6.5" x2="19.5" y2="6.5"/><polyline points="9.5,6.5 9.5,3.8 14.5,3.8 14.5,6.5"/><path d="M6.3,6.5 L7.3,20.5 H16.7 L17.7,6.5"/><line x1="10.3" y1="10" x2="10.3" y2="17"/><line x1="13.7" y1="10" x2="13.7" y2="17"/>`;
I['globe'] = U('<path d="M12,3 A9,9 0 0 0 12,21 Z"/>', .2) + U('<path d="M12,3 A9,9 0 0 1 12,21 Z"/>', .1) + `<circle cx="12" cy="12" r="9"/><ellipse cx="12" cy="12" rx="4.2" ry="9"/><line x1="3" y1="12" x2="21" y2="12"/><ellipse cx="12" cy="12" rx="8.2" ry="3.6" stroke-opacity=".45"/>`;
I['lock'] = U('<rect x="5.5" y="10.8" width="13" height="9.7" rx="1.5"/>', .25) + `<rect x="5.5" y="10.8" width="13" height="9.7" rx="1.5"/><polyline points="8.3,10.8 8.3,7 12,4.2 15.7,7 15.7,10.8"/><circle cx="12" cy="15.2" r="1.6" fill="currentColor" stroke="none"/><line x1="12" y1="15.2" x2="12" y2="18"/>`;
I['lock_open'] = U('<rect x="5.5" y="10.8" width="13" height="9.7" rx="1.5"/>', .25) + `<rect x="5.5" y="10.8" width="13" height="9.7" rx="1.5"/><polyline points="8.3,10.8 8.3,6.8 12.3,4 16.3,6.8 16.3,8.6"/><circle cx="12" cy="15.2" r="1.6" fill="currentColor" stroke="none"/><line x1="12" y1="15.2" x2="12" y2="18"/>`;
I['ar_cube'] = U('<polygon points="12,3.2 18.8,6.9 12,10.6 5.2,6.9"/>', .45) + U('<polygon points="5.2,6.9 12,10.6 12,18.9 5.2,15.2"/>', .26) + U('<polygon points="12,10.6 18.8,6.9 18.8,15.2 12,18.9"/>', .13) + `<polygon points="12,3.2 18.8,6.9 12,10.6 5.2,6.9"/><line x1="5.2" y1="6.9" x2="5.2" y2="15.2"/><line x1="18.8" y1="6.9" x2="18.8" y2="15.2"/><polyline points="5.2,15.2 12,18.9 18.8,15.2"/><line x1="12" y1="10.6" x2="12" y2="18.9"/>`;
I['eye'] = U('<polygon points="2.8,12 8,7.6 16,7.6 21.2,12"/>', .26) + U('<polygon points="2.8,12 21.2,12 16,16.4 8,16.4"/>', .1) + `<polygon points="2.8,12 8,7.6 16,7.6 21.2,12 16,16.4 8,16.4"/><circle cx="12" cy="12" r="2.6"/><circle cx="12" cy="12" r="1.1" fill="currentColor" stroke="none"/>`;
I['scissors'] = U('<circle cx="6" cy="6.5" r="2.6"/><circle cx="6" cy="17.5" r="2.6"/>', .25) + `<circle cx="6" cy="6.5" r="2.6"/><circle cx="6" cy="17.5" r="2.6"/><line x1="8.2" y1="8" x2="20.5" y2="17"/><line x1="8.2" y1="16" x2="20.5" y2="7"/>`;
I['close'] = `<line x1="5.8" y1="5.8" x2="18.2" y2="18.2"/><line x1="18.2" y1="5.8" x2="5.8" y2="18.2"/>`;
I['check'] = `<polyline points="4.2,12.6 9.8,18.2 19.8,6.6"/>`;
I['image'] = U('<rect x="3.2" y="4.5" width="17.6" height="15" rx="1.5"/>', .1) + U('<polygon points="5.5,16.5 9.7,11.3 12.2,14 12.2,16.5"/>', .25) + U('<polygon points="12.2,16.5 12.2,14 15.2,10 18.5,16.5"/>', .42) + `<rect x="3.2" y="4.5" width="17.6" height="15" rx="1.5"/><polyline points="5.5,16.5 9.7,11.3 12.2,14 15.2,10 18.5,16.5"/><circle cx="8" cy="8.3" r="1.4" fill="currentColor" stroke="none"/>`;
I['image_add'] = U('<rect x="3" y="6" width="14" height="14" rx="1.5"/>', .12) + U('<polygon points="5,17 8.6,12.4 10.8,14.7 13.3,11.4 15,14"/>', .3) + `<rect x="3" y="6" width="14" height="14" rx="1.5"/><polyline points="5,17 8.6,12.4 10.8,14.7 13.3,11.4 15,14"/><circle cx="6.6" cy="9.4" r="1.1" fill="currentColor" stroke="none"/><line x1="20.4" y1="3.3" x2="20.4" y2="8.7"/><line x1="17.7" y1="6" x2="23.1" y2="6"/>`;
I['image_broken'] = U('<polygon points="3.2,4.5 12.6,4.5 10.8,8.6 13.2,10.6 10.6,14.9 12.4,19.5 3.2,19.5"/>', .22) + `<rect x="3.2" y="4.5" width="17.6" height="15" rx="1.5"/><polyline points="12.6,4.5 10.8,8.6 13.2,10.6 10.6,14.9 12.4,19.5"/>`;
I['image_off'] = U('<rect x="3.2" y="4.5" width="17.6" height="15" rx="1.5"/>', .1) + `<rect x="3.2" y="4.5" width="17.6" height="15" rx="1.5"/><line x1="3.2" y1="3.5" x2="20.8" y2="20.5"/>`;
I['pin'] = S(12,3.2,22.1,.18) + U('<polygon points="12,2.6 12,21.4 5.6,11.9 5.6,6.9"/>', .5) + U('<polygon points="12,2.6 18.4,6.9 18.4,11.9 12,21.4"/>', .2) + `<polygon points="12,2.6 18.4,6.9 18.4,11.9 12,21.4 5.6,11.9 5.6,6.9"/><circle cx="12" cy="9.4" r="2.5"/>`;
I['phone_off'] = U('<rect x="7.2" y="3" width="9.6" height="18" rx="2"/>', .16) + `<rect x="7.2" y="3" width="9.6" height="18" rx="2"/><line x1="10.5" y1="17.8" x2="13.5" y2="17.8"/><line x1="3.8" y1="3.8" x2="20.2" y2="20.2"/>`;
I['scan'] = `<polyline points="4,8.5 4,4 8.5,4"/><polyline points="15.5,4 20,4 20,8.5"/><polyline points="20,15.5 20,20 15.5,20"/><polyline points="8.5,20 4,20 4,15.5"/>` + U('<path d="M12,8.6 A3.4,3.4 0 0 0 12,15.4 Z"/>', 1) + U('<path d="M12,8.6 A3.4,3.4 0 0 1 12,15.4 Z"/>', .55);
I['restart'] = `<path d="M16,6.1 A8,8 0 1 0 19.7,10.6"/><polyline points="20.5,3 20.5,8.5 15,8.5"/>`;
I['undo'] = `<polyline points="8.7,6.3 4,11 8.7,15.7"/><path d="M4,11 H13.5 A6,6 0 0 1 19.5,17 V20.5"/>`;
I['redo'] = `<polyline points="15.3,6.3 20,11 15.3,15.7"/><path d="M20,11 H10.5 A6,6 0 0 0 4.5,17 V20.5"/>`;
I['my_location'] = U('<circle cx="12" cy="12" r="7"/>', .12) + `<circle cx="12" cy="12" r="7"/><line x1="12" y1="1.8" x2="12" y2="4.6"/><line x1="12" y1="19.4" x2="12" y2="22.2"/><line x1="1.8" y1="12" x2="4.6" y2="12"/><line x1="19.4" y1="12" x2="22.2" y2="12"/>` + U('<path d="M12,9.6 A2.4,2.4 0 0 0 12,14.4 Z"/>', 1) + U('<path d="M12,9.6 A2.4,2.4 0 0 1 12,14.4 Z"/>', .55);

/* ============ FUTURE ICONS ============ */
I['send_check'] = U('<circle cx="12" cy="12" r="9"/>', .16) + U('<path d="' + band([[7.4,12.4],[10.8,15.8],[16.8,8.6]], 3.8) + '"/>', .22) + `<circle cx="12" cy="12" r="9"/><polyline points="7.4,12.4 10.8,15.8 16.8,8.6"/>`;
I['flash'] = U('<polygon points="13.4,2.4 6.8,13 11,13 9.6,21.6"/>', 1) + U('<polygon points="9.6,21.6 17.2,10.6 12.6,10.6 13.4,2.4"/>', .55) + `<g stroke-opacity=".5"><line x1="4.2" y1="7.6" x2="6.4" y2="7.6"/><line x1="3.4" y1="11.2" x2="5.6" y2="11.2"/></g>`;
I['project'] = `<circle cx="12" cy="12" r="8.6" stroke-dasharray="3.6 3.15"/>` + U('<path d="M12,10 A2,2 0 0 0 12,14 Z"/>', 1) + U('<path d="M12,10 A2,2 0 0 1 12,14 Z"/>', .55);
I['star'] = U('<polygon points="12,3 9.3,8.9 3,9.5 7.7,13.8 6.3,20.2 12,16.9"/>', .35) + U('<polygon points="12,3 14.7,8.9 21,9.5 16.3,13.8 17.7,20.2 12,16.9"/>', .15) + `<polygon points="12,3 14.7,8.9 21,9.5 16.3,13.8 17.7,20.2 12,16.9 6.3,20.2 7.7,13.8 3,9.5 9.3,8.9"/>`;
I['bookmark'] = U('<polygon points="6.2,3 12,3 12,16.4 6.2,21"/>', .45) + U('<polygon points="12,3 17.8,3 17.8,21 12,16.4"/>', .2) + `<polygon points="6.2,3 17.8,3 17.8,21 12,16.4 6.2,21"/>`;
I['share'] = U('<polygon points="5.5,9.2 18.5,9.2 18.5,20.5 5.5,20.5"/>', .14) + `<path d="M9,9.2 H5.5 V20.5 H18.5 V9.2 H15"/><line x1="12" y1="3.4" x2="12" y2="13.6"/><polyline points="8.7,6.6 12,3.3 15.3,6.6"/>`;
I['download'] = U('<rect x="10.3" y="3.4" width="3.4" height="9.4"/>', .18) + U('<polygon points="4,15.5 20,15.5 20,20.5 4,20.5"/>', .16) + `<line x1="12" y1="3.2" x2="12" y2="13.6"/><polyline points="7.6,9.6 12,14 16.4,9.6"/><polyline points="4,15.5 4,20.5 20,20.5 20,15.5"/>`;
I['upload'] = U('<rect x="10.3" y="4.2" width="3.4" height="9.4"/>', .18) + U('<polygon points="4,15.5 20,15.5 20,20.5 4,20.5"/>', .16) + `<polyline points="7.6,7.6 12,3.2 16.4,7.6"/><line x1="12" y1="3.6" x2="12" y2="14"/><polyline points="4,15.5 4,20.5 20,20.5 20,15.5"/>`;
I['sync'] = `<path d="M3.5,12 A8.5,8.5 0 0 1 17.7,5.7 L20.5,8.3"/><polyline points="20.5,3.5 20.5,8.3 15.7,8.3"/><path d="M20.5,12 A8.5,8.5 0 0 1 6.3,18.3 L3.5,15.7"/><polyline points="3.5,20.5 3.5,15.7 8.3,15.7"/>`;
I['settings'] = `<path fill="currentColor" stroke="none" fill-opacity=".2" fill-rule="evenodd" d="${circlePath(12,12,6.2)} ${circlePath(12,12,2.4)}"/>` + `<circle cx="12" cy="12" r="6.2"/><circle cx="12" cy="12" r="2.4"/><line x1="18.2" y1="12" x2="21.4" y2="12"/><line x1="2.6" y1="12" x2="5.8" y2="12"/><line x1="12" y1="2.6" x2="12" y2="5.8"/><line x1="12" y1="18.2" x2="12" y2="21.4"/><line x1="16.38" y1="7.62" x2="18.65" y2="5.35"/><line x1="7.62" y1="7.62" x2="5.35" y2="5.35"/><line x1="16.38" y1="16.38" x2="18.65" y2="18.65"/><line x1="7.62" y1="16.38" x2="5.35" y2="18.65"/><circle cx="12" cy="12" r=".9" fill="currentColor" stroke="none" fill-opacity=".55"/>`;
I['info'] = U('<circle cx="12" cy="12" r="9"/>', .14) + `<circle cx="12" cy="12" r="9"/><circle cx="12" cy="7.9" r="1.35" fill="currentColor" stroke="none"/><line x1="12" y1="11.2" x2="12" y2="16.6"/>`;
I['warning'] = U('<polygon points="12,3.4 12,20.2 2.4,20.2"/>', .24) + U('<polygon points="12,3.4 21.6,20.2 12,20.2"/>', .12) + `<path stroke-linejoin="round" d="M12,3.4 L21.6,20.2 H2.4 Z"/><line x1="12" y1="9.6" x2="12" y2="14.4"/><circle cx="12" cy="17.1" r="1.3" fill="currentColor" stroke="none"/>`;
I['sun'] = U('<path d="M12,7.4 A4.6,4.6 0 0 0 12,16.6 Z"/>', .5) + U('<path d="M12,7.4 A4.6,4.6 0 0 1 12,16.6 Z"/>', .25) + `<circle cx="12" cy="12" r="4.6"/><line x1="19.2" y1="12" x2="21.9" y2="12"/><line x1="4.8" y1="12" x2="2.1" y2="12"/><line x1="12" y1="4.8" x2="12" y2="2.1"/><line x1="12" y1="19.2" x2="12" y2="21.9"/><line x1="17.1" y1="6.9" x2="19" y2="5"/><line x1="6.9" y1="6.9" x2="5" y2="5"/><line x1="17.1" y1="17.1" x2="19" y2="19"/><line x1="6.9" y1="17.1" x2="5" y2="19"/>`;
I['cloud_rain'] = U('<polygon points="3.8,14.5 5.3,9.5 9,7 14,6.5 14,14.5"/>', .2) + U('<polygon points="14,6.5 18,8.5 20.2,12 19.2,14.5 14,14.5"/>', .42) + `<polygon points="3.8,14.5 5.3,9.5 9,7 14,6.5 18,8.5 20.2,12 19.2,14.5"/><line x1="8" y1="17" x2="6.8" y2="20"/><line x1="12.6" y1="17" x2="11.4" y2="20"/><line x1="17.2" y1="17" x2="16" y2="20"/>`;
I['parking'] = U('<rect x="3.8" y="3.8" width="16.4" height="16.4" rx="3"/>', .12) + `<rect x="3.8" y="3.8" width="16.4" height="16.4" rx="3"/><path d="M9.8,16.8 V7.2 H13.4 A2.9,2.9 0 0 1 13.4,13 H9.8"/>`;
I['signpost'] = S(10.5,2.6,22.2,.14) + U('<polygon points="10,5 18.6,5 21.3,8 10,8"/>', .38) + U('<polygon points="10,8 21.3,8 18.6,11 10,11"/>', .18) + `<line x1="10" y1="21.5" x2="10" y2="3.5"/><polygon points="10,5 18.6,5 21.3,8 18.6,11 10,11"/>`;
I['carabiner'] = `<g transform="rotate(-18 12 12)">` + U('<path d="' + band([[16.2,6.4],[12.6,3.2],[8.8,3.8],[6.8,7.6],[6.6,16],[8.6,20],[13,20.8],[16.4,17.6]], 3.6) + '"/>', .3) + `<polyline points="16.2,6.4 12.6,3.2 8.8,3.8 6.8,7.6 6.6,16 8.6,20 13,20.8 16.4,17.6"/><line x1="17.1" y1="8.2" x2="17" y2="15.9"/><circle cx="17.1" cy="8.6" r="0.8" fill="currentColor" stroke="none" fill-opacity=".6"/></g>` + S(12,5,22.2,.13);
I['ruler'] = U('<rect x="9" y="2.8" width="6.4" height="18.4" rx="1.2"/>', .16) + `<rect x="9" y="2.8" width="6.4" height="18.4" rx="1.2"/><line x1="9" y1="6.2" x2="12" y2="6.2"/><line x1="9" y1="9.4" x2="10.8" y2="9.4"/><line x1="9" y1="12.6" x2="12" y2="12.6"/><line x1="9" y1="15.8" x2="10.8" y2="15.8"/><line x1="9" y1="19" x2="12" y2="19"/>`;
I['sort'] = `<line x1="8" y1="19.5" x2="8" y2="4.8"/><polyline points="4.9,7.9 8,4.7 11.1,7.9"/><line x1="16" y1="4.5" x2="16" y2="19.2"/><polyline points="12.9,16.1 16,19.3 19.1,16.1"/>`;
I['add'] = `<line x1="12" y1="4.8" x2="12" y2="19.2"/><line x1="4.8" y1="12" x2="19.2" y2="12"/>`;
I['grid_view'] = U('<rect x="4" y="4" width="8" height="8"/><rect x="12" y="12" width="8" height="8"/>', .22) + `<rect x="4" y="4" width="16" height="16" rx="1.5"/><line x1="12" y1="4" x2="12" y2="20"/><line x1="4" y1="12" x2="20" y2="12"/>`;
I['list_view'] = `<circle cx="5" cy="6.5" r="1.5" fill="currentColor" stroke="none"/><circle cx="5" cy="12" r="1.5" fill="currentColor" stroke="none"/><circle cx="5" cy="17.5" r="1.5" fill="currentColor" stroke="none"/><line x1="9" y1="6.5" x2="20" y2="6.5"/><line x1="9" y1="12" x2="20" y2="12"/><line x1="9" y1="17.5" x2="20" y2="17.5"/>`;
I['camera'] = U('<rect x="3.5" y="7.6" width="17" height="11.4" rx="1.8"/>', .12) + U('<rect x="4.2" y="7.6" width="15.6" height="2.6"/>', .2) + U('<circle cx="12" cy="13.2" r="3.3"/>', .26) + `<rect x="3.5" y="7.6" width="17" height="11.4" rx="1.8"/><path d="M8.6,7.6 L10.2,5.3 H13.8 L15.4,7.6"/><circle cx="12" cy="13.2" r="3.3"/><circle cx="18" cy="9.9" r=".9" fill="currentColor" stroke="none" fill-opacity=".6"/><circle cx="12" cy="13.2" r="1.1" fill="currentColor" stroke="none" fill-opacity=".55"/>`;
I['location_off'] = U('<polygon points="12,2.6 12,21.4 5.6,11.9 5.6,6.9"/>', .4) + U('<polygon points="12,2.6 18.4,6.9 18.4,11.9 12,21.4"/>', .16) + `<polygon points="12,2.6 18.4,6.9 18.4,11.9 12,21.4 5.6,11.9 5.6,6.9"/><line x1="3.5" y1="3.5" x2="20.5" y2="20.5"/>`;

I['topo_map'] = S(12,8,21.9,.12) + U('<polygon points="3.5,6.5 9,5 9,18.5 3.5,20"/>', .34) + U('<polygon points="9,5 15,6.5 15,20 9,18.5"/>', .14) + U('<polygon points="15,6.5 20.5,5 20.5,18.5 15,20"/>', .34) + `<path d="M3.5,6.5 L9,5 L15,6.5 L20.5,5 L20.5,18.5 L15,20 L9,18.5 L3.5,20 Z"/><line x1="9" y1="5" x2="9" y2="18.5"/><line x1="15" y1="6.5" x2="15" y2="20"/><polyline points="5.5,16 8,13.2 10.5,14.8 13.5,10.2 16.5,12 18.3,8.8"/><circle cx="5.5" cy="16" r="1" fill="currentColor" stroke="none"/><circle cx="18.9" cy="7.6" r="1.2"/><polygon points="5.3,9.8 6.5,7.9 7.7,9.8" fill="currentColor" stroke="none" fill-opacity=".55"/>`;

/* ============ FILLED VARIANTS — iOS tab bar / selected states ============ */
const F = (d, extra = '') => `<path fill="currentColor" stroke="none" fill-rule="evenodd" d="${d}"/>${extra}`;

I['folder_fill'] = U('<path fill-rule="evenodd" d="M3,19.5 V5.5 H9.2 L11.4,8 H21 V19.5 Z M3.6,8.2 H20.4 V8.9 H3.6 Z"/>', .82) + U('<polygon points="3,5.5 9.2,5.5 11.1,7.8 3,7.8"/>', 1);
I['person_fill'] = U('<path d="M12,3.4 A3.5,3.5 0 0 0 12,10.4 Z"/>', .85) + U('<path d="M12,3.4 A3.5,3.5 0 0 1 12,10.4 Z"/>', 1) + U('<path d="M4.6,20.6 A7.4,7.4 0 0 1 12,13.2 L12,20.6 Z"/>', .85) + U('<path d="M12,13.2 A7.4,7.4 0 0 1 19.4,20.6 L12,20.6 Z"/>', 1);
I['compass_fill'] = U('<path fill-rule="evenodd" d="M18.36,5.64 A9,9 0 0 0 5.64,18.36 Z M16.2,7.8 L7.8,16.2 L10.3,10.3 Z"/>', .8) + U('<path fill-rule="evenodd" d="M18.36,5.64 A9,9 0 0 1 5.64,18.36 Z M16.2,7.8 L13.7,13.7 L7.8,16.2 Z"/>', 1) + `<circle cx="12" cy="12" r="1" fill="currentColor" stroke="none"/>`;
I['pin_fill'] = S(12,3.2,22.1,.18) + U('<path fill-rule="evenodd" d="M12,2.6 L12,21.4 L5.6,11.9 L5.6,6.9 Z M12,6.7 A2.7,2.7 0 0 0 12,12.1 Z"/>', .8) + U('<path fill-rule="evenodd" d="M12,2.6 L18.4,6.9 L18.4,11.9 L12,21.4 Z M12,6.7 A2.7,2.7 0 0 1 12,12.1 Z"/>', 1);
I['star_fill'] = U('<polygon points="12,3 9.3,8.9 3,9.5 7.7,13.8 6.3,20.2 12,16.9"/>', .82) + U('<polygon points="12,3 14.7,8.9 21,9.5 16.3,13.8 17.7,20.2 12,16.9"/>', 1);
I['bookmark_fill'] = U('<polygon points="6.2,3 12,3 12,16.4 6.2,21"/>', .82) + U('<polygon points="12,3 17.8,3 17.8,21 12,16.4"/>', 1);
I['logbook_fill'] = U('<rect x="4.5" y="3" width="2.6" height="18"/>', 1) + U('<path fill-rule="evenodd" d="M8.9,3 H19.5 V21 H8.9 Z M14.8,3 L17.2,3 L17.2,7.4 L16,6.1 L14.8,7.4 Z ' + band([[10.9,12.6],[12.9,14.6],[16.7,10.2]], 2) + '"/>', .85);
I['send_check_fill'] = U('<circle cx="12" cy="12" r="10.3"/>', .25) + `<path fill="currentColor" stroke="none" fill-rule="evenodd" d="` + circlePath(12,12,8.9) + ' ' + band([[7.4,12.4],[10.8,15.8],[16.8,8.6]], 2.1) + `"/>`;
I['boulder_fill'] = S(12,8,20.7,.18) + U('<path d="M4.5,10.5 L9,4.5 L13.6,4.4 L11.6,8.4 L13.6,10.6 L11.2,15 Z"/>', .62) + U('<path d="M3,19.5 L4.5,10.5 L11.2,15 L12.8,19.5 Z"/>', .82) + U('<path d="M15.1,4.4 L13.1,8.4 L15.1,10.6 L12.7,15 L14.3,19.5 L19,19.5 L21,13 L19.5,7.5 L15,3.5 Z"/>', 1);

const outDir = path.join(__dirname, 'svg');
const pngDir = path.join(__dirname, 'png96');
fs.rmSync(outDir, { recursive: true, force: true });
fs.rmSync(pngDir, { recursive: true, force: true });
fs.mkdirSync(outDir, { recursive: true });
fs.mkdirSync(pngDir, { recursive: true });

const wrap = (inner) =>
  `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="24" height="24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="miter">${inner}</svg>\n`;

(async () => {
  const names = Object.keys(I);
  for (const name of names) {
    const svg = wrap(I[name]);
    fs.writeFileSync(path.join(outDir, `masi_${name}.svg`), svg);
    const previewSvg = svg.replace(/currentColor/g, '#5B4A9E');
    await sharp(Buffer.from(previewSvg)).resize(96, 96).png().toFile(path.join(pngDir, `${name}.png`));
  }
  fs.writeFileSync(path.join(__dirname, 'names.txt'), names.join('\n'));
  console.log(`generated ${names.length} icons`);
})().catch((e) => { console.error(e); process.exit(1); });
