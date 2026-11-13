/* Builds mockup/stage-two-decks.svg from the same grid as stage-two-decks.html.
   Chassis points are 1:1 SVG units inside a 1174 × 476 panel, placed at (10, 338)
   on the 1194 × 834 iPad canvas. Effects that only exist as CSS shadows are drawn
   as flat layers, so Illustrator opens the file with live geometry and text. */

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const png = fs.readFileSync(path.join(here, 'stage-two-top.png')).toString('base64');

const FONT = 'Avenir Next Condensed, Helvetica Neue Condensed, Helvetica, Arial, sans-serif';
const W = 1174, H = 476, EDGE = 18;
const CHIP = { w: 90, h: 50 };
const COL = { A: 403, B: 681 };
const CHIPS_Y = { hi: 76, mid: 137, low: 198, fx: 264, foot: 330 };
const FOOT = { y: 333, h: 44 };
const FACE = { x: 259, y: 66, w: 656, h: 324 };
const LEVEL = { cx: 331, y: 76, w: 60, h: 172 };
const TEMPO = { x: 18, y: 76, w: 60, h: 206 };
const PLATTER = { cx: 214, cy: 196, size: 262 };
const METER = {
  x: 505, y: 76, w: 164, h: 238, barTop: 118, barBottom: 306,
  ladder: [-30, -27, -24, -21, -18, -15, -12, -9, -6, -3, 0, 3, 6],
  amber: 6, red: 10, still: { A: -2.0, L: -3.8, R: -4.3, B: -90 },
  hold: { A: -1.0, L: -2.8, R: -3.2, B: -90 }
};
const ROW = { y: 400, key: 66 };
const XF = { x: 470, w: 234, cy: 433 };
const CAP = 28, SLOT = 4;

const DECK = {
  A: { accent: '#276fff', mt: true, sync: false, master: true, tempo: 0, level: 0.78, cue: true, playing: true, jump: 1, loop: 8, loopOn: true,
       trim: { title: 'TRIM', value: '+1.0', fill: 54, auto: 44, kind: 'green' }, eq: { hi: 100, mid: 100, low: 62 }, foot: { title: 'CUE/MST', value: '50/50', fill: 50 } },
  B: { accent: '#ff8a1f', mt: false, sync: true, master: false, tempo: 2.31, level: 0.78, cue: true, playing: false, jump: 1, loop: 16, loopOn: false,
       trim: { title: 'AUTO TRIM', value: '+1.2', fill: 55, kind: 'auto' }, eq: { hi: 100, mid: 100, low: 62 }, foot: { title: 'PHONES', value: '60%', fill: 60 } }
};

const f = (v) => +(+v).toFixed(2);
const esc = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
const mx = (x, w) => W - x - w;

function T(x, y, str, o = {}) {
  const { size = 11, fill = '#d6d7db', anchor = 'middle', ls = 0, weight = 700, opacity = 1, tabular = false } = o;
  return `<text x="${f(x)}" y="${f(y)}" font-family="${FONT}" font-size="${size}" font-weight="${weight}" fill="${fill}" text-anchor="${anchor}" letter-spacing="${f(ls)}"${tabular ? ' font-variant-numeric="tabular-nums"' : ''}${opacity !== 1 ? ` opacity="${f(opacity)}"` : ''}>${esc(str)}</text>`;
}

function box(x, y, w, h, o = {}) {
  const { rx = 0, fill = 'none', stroke = 'none', sw = 1, opacity = 1 } = o;
  return `<rect x="${f(x)}" y="${f(y)}" width="${f(w)}" height="${f(h)}"${rx ? ` rx="${f(rx)}"` : ''} fill="${fill}"${stroke !== 'none' ? ` stroke="${stroke}" stroke-width="${f(sw)}"` : ''}${opacity !== 1 ? ` opacity="${f(opacity)}"` : ''}/>`;
}

/* CSS radial-gradient(ellipse closest-side, …) → objectBoundingBox gradient whose
   r covers the box corner (0.7071); stop percentages are scaled onto that radius. */
function ellipseGrad(id, stops) {
  const R = 0.7071;
  const s = stops.map(([c, p]) => `<stop offset="${(p * 0.5 / 100 / R).toFixed(4)}" stop-color="${c}"/>`).join('');
  return `<radialGradient id="${id}" cx="0.5" cy="0.5" r="${R}">${s}</radialGradient>`;
}

const defs = `
  <pattern id="brush" width="3" height="3" patternUnits="userSpaceOnUse">
    <rect width="1" height="3" fill="#ffffff" opacity="0.016"/>
  </pattern>
  <pattern id="stipple" width="3" height="3" patternUnits="userSpaceOnUse">
    <circle cx="1.5" cy="1.5" r="0.7" fill="#ffffff" opacity="0.14"/>
  </pattern>
  <pattern id="comb" width="19.4" height="9" patternUnits="userSpaceOnUse">
    <rect width="1" height="9" fill="#ffffff" opacity="0.26"/>
  </pattern>
  ${ellipseGrad('lit-blue', [['#02adee', 0], ['#05a4f1', 65], ['#1491f6', 95], ['#2573fe', 125], ['#276fff', 135]])}
  ${ellipseGrad('lit-sync', [['#ffffff', 0], ['#f3f3f3', 65], ['#e6e6e6', 85], ['#d2d2d2', 105], ['#d1d1d1', 110]])}
  ${ellipseGrad('lit-master', [['#cd9c04', 0], ['#d49210', 65], ['#dc8519', 85], ['#e87022', 105], ['#f05a27', 125]])}
  ${ellipseGrad('lit-mt', [['#ff7a5c', 0], ['#f8654a', 45], ['#f0553d', 70], ['#e64634', 95], ['#d93a2b', 115], ['#cc3024', 135]])}
  ${ellipseGrad('lit-auto', [['#8be596', 0], ['#74da82', 45], ['#62cf72', 70], ['#55c467', 95], ['#49ba60', 115], ['#3fae56', 135]])}
  <clipPath id="screen"><rect x="10" y="10" width="1174" height="814" rx="12"/></clipPath>
`;

/* ---------- panel ---------- */
const panel = `
  ${box(0, 0, W, H, { fill: '#101013' })}
  ${box(0, 0, W, H, { fill: 'url(#brush)' })}
  ${box(0, 0, W, 1, { fill: '#000000' })}
  ${box(0, 1, W, 1, { fill: '#ffffff', opacity: 0.1 })}
`;

const faceplate = `
  ${box(FACE.x, FACE.y + 4, FACE.w, FACE.h, { rx: 3, fill: '#000000', opacity: 0.4 })}
  ${box(FACE.x, FACE.y, FACE.w, FACE.h, { rx: 3, fill: '#16161a', stroke: '#000000' })}
  ${box(FACE.x + 0.5, FACE.y + 0.5, FACE.w - 1, 1, { fill: '#ffffff', opacity: 0.06 })}
`;

/* ---------- platters ---------- */
function platter(cx, cy, accent) {
  const S = PLATTER.size, R = S / 2;
  const r = (v) => (v / 100) * S;
  const at = (v) => (v - 50) * (S / 100);
  const dAt = (v) => (v - 50) * 1.04; // the 104 px cue display, 100 units wide
  const grooves = [];
  for (let rad = 16; rad <= 129; rad += 3) {
    grooves.push(`<circle cx="${cx}" cy="${cy}" r="${f(rad)}" fill="none" stroke="#ffffff" stroke-width="1" opacity="0.026"/>`);
  }
  const dimples = Array.from({ length: 34 }, (_, i) => {
    const a = ((i * (360 / 34) - 90) * Math.PI) / 180;
    const x = cx + Math.cos(a) * r(44.6), y = cy + Math.sin(a) * r(44.6);
    return `<circle cx="${f(x)}" cy="${f(y)}" r="${f(r(3.05))}" fill="#3d3e44" stroke="#9a9ba1" stroke-width="1.05" stroke-opacity="0.3"/>`;
  }).join('');
  const ticks = Array.from({ length: 40 }, (_, i) => {
    if (i < 4) return ''; // the cue display's gap mask
    return `<g transform="rotate(${i * 9} ${cx} ${cy})" stroke="#e4e8ed" stroke-width="2.5">
      <line x1="${cx}" y1="${f(cy + dAt(7))}" x2="${cx}" y2="${f(cy + dAt(11))}"/>
      <line x1="${cx}" y1="${f(cy + dAt(13))}" x2="${cx}" y2="${f(cy + dAt(16))}"/>
      <line x1="${cx}" y1="${f(cy + dAt(18))}" x2="${cx}" y2="${f(cy + dAt(21))}"/>
    </g>`;
  }).join('');
  return `<g id="Jog-${cx < W / 2 ? 'A' : 'B'}">
    <circle cx="${cx}" cy="${cy}" r="${R}" fill="#0c0c0e"/>
    ${grooves.join('')}
    <circle cx="${cx}" cy="${cy}" r="${f(r(44.6))}" fill="none" stroke="#5b5c62" stroke-width="${f(r(11))}"/>
    <circle cx="${cx}" cy="${cy}" r="${f(r(49.3))}" fill="none" stroke="#050506" stroke-width="${f(r(1.4))}"/>
    <circle cx="${cx}" cy="${cy}" r="${f(r(39.2))}" fill="none" stroke="#000000" stroke-width="${f(r(1.6))}" opacity="0.9"/>
    <circle cx="${cx}" cy="${cy}" r="${f(r(49.8))}" fill="none" stroke="#ffffff" stroke-width="${f(r(0.5))}" opacity="0.22"/>
    ${dimples}
    <circle cx="${cx}" cy="${cy}" r="${f(r(23))}" fill="#4e4f55"/>
    <circle cx="${cx}" cy="${cy}" r="${f(r(23))}" fill="none" stroke="#25262b" stroke-width="${f(r(0.8))}"/>
    <circle cx="${cx}" cy="${cy}" r="${f(r(21.6))}" fill="none" stroke="#ffffff" stroke-width="${f(r(0.5))}" opacity="0.12"/>
    <circle cx="${cx}" cy="${cy}" r="54" fill="none" stroke="#000000" stroke-width="4" opacity="0.55"/>
    <circle cx="${cx}" cy="${cy}" r="52" fill="#06070a"/>
    <circle cx="${cx}" cy="${cy}" r="51.5" fill="none" stroke="#2a2c31" stroke-width="1"/>
    <circle cx="${cx}" cy="${cy}" r="49.9" fill="none" stroke="#14171c" stroke-width="1.04"/>
    ${ticks}
    <circle cx="${cx}" cy="${cy}" r="24.96" fill="none" stroke="${accent}" stroke-width="1.87"/>
    <circle cx="${cx}" cy="${cy}" r="19.76" fill="none" stroke="#9da4ad" stroke-width="1.87" stroke-dasharray="26 5.04" transform="rotate(-45 ${cx} ${cy})"/>
    <circle cx="${cx}" cy="${cy}" r="15.6" fill="#0b0c0f" stroke="#16191d" stroke-width="1.04"/>
  </g>`;
}

const platters = `${platter(PLATTER.cx, PLATTER.cy, DECK.A.accent)}${platter(W - PLATTER.cx, PLATTER.cy, DECK.B.accent)}`;

/* ---------- deck keys ---------- */
const PILL = {
  mt: { key: '#ec4a37', grad: 'lit-mt', border: '#a03225', size: 12, ls: 1.2, lines: ['MASTER', 'TEMPO'] },
  sync: { key: '#f2f4f3', grad: 'lit-sync', border: '#a5a6a5', size: 15, ls: 1.35, lines: ['SYNC'] },
  master: { key: '#e18400', grad: 'lit-master', border: '#995a00', size: 15, ls: 1.35, lines: ['MASTER'] },
  hot: { key: '#276fff', grad: 'lit-blue', border: '#1a4cad', size: 15, ls: 1.35, lines: ['HOT', 'CUE'] }
};

function pills(deck) {
  const d = DECK[deck];
  const order = deck === 'A' ? ['mt', 'sync', 'master', 'hot'] : ['sync', 'master', 'hot', 'mt'];
  const on = { mt: d.mt, sync: d.sync, master: d.master, hot: false };
  const left = deck === 'A' ? EDGE : W - EDGE - (4 * 78 + 3 * 8);
  return order.map((k, i) => {
    const p = PILL[k], lit = on[k];
    const x = left + i * (78 + 8), y = 14;
    const label = p.lines.length === 2
      ? T(x + 39, y + 17.5, p.lines[0], { size: p.size, ls: p.ls, fill: lit ? '#000000' : p.key })
        + T(x + 39, y + 30.5, p.lines[1], { size: p.size, ls: p.ls, fill: lit ? '#000000' : p.key })
      : T(x + 39, y + 25.3, p.lines[0], { size: p.size, ls: p.ls, fill: lit ? '#000000' : p.key });
    return `<g id="Key-${deck}-${k}">
      ${box(x, y, 78, 40, { rx: 5, fill: lit ? `url(#${p.grad})` : '#1b1b1f', stroke: lit ? '#000000' : p.border, sw: 1.25 })}
      ${lit ? box(x + 1.5, y + 1.5, 75, 1, { fill: '#ffffff', opacity: 0.5 }) : box(x + 1.5, y + 1.5, 75, 1, { fill: '#ffffff', opacity: 0.1 })}
      <circle cx="${x + 71}" cy="${y + 7}" r="2" fill="${p.key}" opacity="${lit ? 0.18 : 0.55}"/>
      ${label}
    </g>`;
  }).join('');
}

const deckKeys = `${pills('A')}${pills('B')}`;

/* ---------- chips ---------- */
function chip(x, y, o) {
  const { title, value, ring = '#55555b', tint = 0.12, bg = '#16161a', titleColor = '#c6c7cc',
          valueColor = '#eef0f3', gradient = null, auto = null, fx = false,
          titleSize = 10.5, valueSize = 19 } = o;
  const fillH = Math.max(0, Math.min(100, o.fill || 0)) * 0.5;
  const isAuto = !!gradient;
  const slug = `${title}-${value}-${x}`.replace(/[^A-Za-z0-9_-]+/g, '-');
  return `<g id="Chip-${slug}">
    ${box(x, y, CHIP.w, CHIP.h, { rx: 6, fill: isAuto ? `url(#${gradient})` : bg, stroke: '#000000' })}
    ${fillH > 0 && !isAuto ? box(x + 1, y + CHIP.h - fillH, CHIP.w - 2, fillH, { fill: ring, opacity: tint }) : ''}
    ${fillH > 0 && !isAuto ? box(x + 1, y + CHIP.h - fillH, CHIP.w - 2, 1.5, { fill: ring, opacity: 0.46 }) : ''}
    ${box(x + 1.25, y + 1.25, CHIP.w - 2.5, CHIP.h - 2.5, { rx: 5, fill: 'none', stroke: isAuto ? '#000000' : ring, sw: isAuto ? 1.5 : 1.25, opacity: isAuto ? 0.8 : 0.85 })}
    ${box(x + 1.5, y + 1.5, CHIP.w - 3, 1, { fill: '#ffffff', opacity: 0.06 })}
    ${auto != null ? box(x + 78, y + 50 - auto * 0.5 - 2, 9, 2, { fill: '#ff8a00' }) : ''}
    ${fx ? box(x + 3, y + 24, 9, 2, { fill: '#ff8a00' }) + box(x + 78, y + 24, 9, 2, { fill: '#ff8a00' }) : ''}
    ${T(x + 45, y + 20, title, { size: titleSize, ls: 1.68, fill: isAuto ? '#0b2a13' : titleColor })}
    ${T(x + 45, y + 41, value, { size: valueSize, ls: 0.19, fill: isAuto ? '#04140a' : valueColor, tabular: true })}
  </g>`;
}

function eqChips(deck) {
  const cx = COL[deck], d = DECK[deck];
  return chip(cx, CHIPS_Y.hi, { title: 'HI', value: d.eq.hi + '%', ring: '#66ce77', tint: 0.12, fill: d.eq.hi })
    + chip(cx, CHIPS_Y.mid, { title: 'MID', value: d.eq.mid + '%', ring: '#66ce77', tint: 0.12, fill: d.eq.mid })
    + chip(cx, CHIPS_Y.low, { title: 'LOW', value: d.eq.low + '%', ring: '#66ce77', tint: 0.12, fill: d.eq.low });
}

function bracket(deck) {
  const cx = COL[deck];
  const top = CHIPS_Y.hi, bottom = CHIPS_Y.low + CHIP.h;
  const bx = deck === 'A' ? cx - 18 : cx + CHIP.w + 8;
  const y1 = top + 6, y2 = bottom - 6;
  const line = deck === 'A'
    ? `<path d="M${bx + 10} ${y1 + 0.5} H${bx + 0.5} V${y2 - 0.5} H${bx + 10}" fill="none" stroke="#ffffff" stroke-width="1" opacity="0.26"/>`
    : `<path d="M${bx} ${y1 + 0.5} H${bx + 9.5} V${y2 - 0.5} H${bx}" fill="none" stroke="#ffffff" stroke-width="1" opacity="0.26"/>`;
  const lx = deck === 'A' ? bx - 10 : bx;
  return line + box(lx, (top + bottom) / 2 - 10, 20, 20, { fill: '#141417' })
    + T(lx + 10, (top + bottom) / 2 + 3.5, 'EQ', { size: 10, ls: 1.4 });
}

function stipple(deck) {
  const cx = COL[deck];
  return box(cx - 6, CHIPS_Y.fx - 6, CHIP.w + 12, CHIP.h + 12, { rx: 5, fill: '#131316' })
    + box(cx - 6, CHIPS_Y.fx - 6, CHIP.w + 12, CHIP.h + 12, { rx: 5, fill: 'url(#stipple)' })
    + box(cx - 6, CHIPS_Y.fx - 6, CHIP.w + 12, CHIP.h + 12, { rx: 5, fill: 'none', stroke: '#ffffff', opacity: 0.045 });
}

const trimChips = chip(COL.A, 9, { title: DECK.A.trim.title, value: DECK.A.trim.value, ring: '#66ce77', fill: DECK.A.trim.fill, auto: DECK.A.trim.auto })
  + chip((W - CHIP.w) / 2, 9, { title: 'MASTER', value: '70%', ring: '#dbe22d', fill: 70, tint: 0.22, bg: '#1a1a14', titleColor: '#b1b545', valueColor: '#f3f6b0' })
  + chip(COL.B, 9, { title: DECK.B.trim.title, value: DECK.B.trim.value, gradient: 'lit-auto' });

function channelChips(deck) {
  const d = DECK[deck];
  return eqChips(deck) + bracket(deck) + stipple(deck)
    + chip(COL[deck], CHIPS_Y.fx, { title: 'FILTER', value: 'OFF', ring: '#66ce77', fx: true })
    + chip(COL[deck], CHIPS_Y.foot, { title: d.foot.title, value: d.foot.value, fill: d.foot.fill });
}

/* ---------- faders ---------- */
function capMarkup(x, y) {
  const grooves = [];
  for (let i = 0; i < 4; i++) {
    const lx = x + 3.5 + i * 2.5, rx = x + 57 - 3.5 - i * 2.5;
    grooves.push(`<line x1="${f(lx)}" y1="${y + 3}" x2="${f(lx)}" y2="${y + 25}" stroke="#000000" stroke-width="1" opacity="0.11"/>`);
    grooves.push(`<line x1="${f(rx)}" y1="${y + 3}" x2="${f(rx)}" y2="${y + 25}" stroke="#000000" stroke-width="1" opacity="0.11"/>`);
  }
  return box(x, y, 60, CAP, { rx: 3, fill: '#c9c9cf' })
    + box(x + 0.5, y + 0.5, 59, 1, { fill: '#f4f4f6' })
    + box(x + 0.5, y + CAP - 1, 59, 1, { fill: '#000000', opacity: 0.28 })
    + grooves.join('')
    + box(x + 4, y + 13, 52, 2, { fill: '#141416' })
    + box(x + 4, y + 15, 52, 1, { fill: '#ffffff', opacity: 0.55 });
}

function tempoFader(deck) {
  const d = DECK[deck];
  const x = deck === 'A' ? TEMPO.x : mx(TEMPO.x, TEMPO.w);
  const pos = 0.5 - d.tempo / 32;
  const travel = TEMPO.h - 8 - CAP;
  const top = SLOT + (1 - pos) * travel;
  const ticks = Array.from({ length: 17 }, (_, i) => {
    const y = SLOT + 14 + (i * travel) / 16;
    const major = i % 4 === 0, len = major ? 9 : 5;
    return box(30 - 8 - len, y, len, 1, { fill: '#ffffff', opacity: major ? 0.46 : 0.24 })
      + box(30 + 8, y, len, 1, { fill: '#ffffff', opacity: major ? 0.46 : 0.24 });
  }).join('');
  return `<g id="Tempo-${deck}">
    ${box(x, TEMPO.y, 60, TEMPO.h, { rx: 4, fill: '#0c0c0f', stroke: '#000000' })}
    ${box(x + 0.5, TEMPO.y + 1, 59, 1, { fill: '#000000' })}
    ${box(x + 0.5, TEMPO.y + TEMPO.h - 2, 59, 1, { fill: '#ffffff', opacity: 0.05 })}
    ${ticks}
    ${box(x + 25, TEMPO.y + 6, 10, TEMPO.h - 12, { rx: 2, fill: '#0a0a0c', stroke: '#2a2a2f', sw: 1 })}
    ${box(x + 29.25, TEMPO.y + 6, 1.5, TEMPO.h - 12, { fill: '#ffffff', opacity: 0.05 })}
    ${box(x + 17, TEMPO.y + TEMPO.h / 2, 26, 1.5, { fill: '#ff8a00' })}
    ${capMarkup(x, TEMPO.y + top)}
    ${T(x + 30, TEMPO.y + TEMPO.h + 17.85, 'TEMPO', { size: 11, ls: 1.54 })}
    ${T(x + (deck === 'A' ? 6.5 : 53.5), TEMPO.y + 11.35, '−', { size: 10, ls: 0.4, fill: '#9a9ba1' })}
    ${T(x + (deck === 'A' ? 6.5 : 53.5), TEMPO.y + TEMPO.h - 13 + 11.35, '+', { size: 10, ls: 0.4, fill: '#9a9ba1' })}
  </g>`;
}

function levelFader(deck) {
  const d = DECK[deck];
  const x = deck === 'A' ? LEVEL.cx - LEVEL.w / 2 : mx(LEVEL.cx - LEVEL.w / 2, LEVEL.w);
  const travel = LEVEL.h - 8 - CAP;
  const top = SLOT + (1 - d.level) * travel;
  const ticks = Array.from({ length: 11 }, (_, i) => {
    const n = 10 - i;
    const y = LEVEL.y + SLOT + 14 + (i * travel) / 10;
    const even = n % 2 === 0;
    const tickX = deck === 'A' ? x - 13 : x + LEVEL.w + 3;
    const numX = deck === 'A' ? x - 32 : x + LEVEL.w + 19;
    return box(tickX, y, 10, 1, { fill: '#ffffff', opacity: even ? 0.46 : 0.22 })
      + (even ? T(deck === 'A' ? numX + 13 : numX, y + 3.5, String(n), { size: 10, ls: 0.4, fill: '#9a9ba1', anchor: deck === 'A' ? 'end' : 'start' }) : '');
  }).join('');
  return `<g id="Level-${deck}">
    ${box(x, LEVEL.y, 60, LEVEL.h, { rx: 4, fill: '#0c0c0f', stroke: '#000000' })}
    ${box(x + 0.5, LEVEL.y + 1, 59, 1, { fill: '#000000' })}
    ${box(x + 0.5, LEVEL.y + LEVEL.h - 2, 59, 1, { fill: '#ffffff', opacity: 0.05 })}
    ${box(x + 25, LEVEL.y + 6, 10, LEVEL.h - 12, { rx: 2, fill: '#0a0a0c', stroke: '#2a2a2f', sw: 1 })}
    ${box(x + 29.25, LEVEL.y + 6, 1.5, LEVEL.h - 12, { fill: '#ffffff', opacity: 0.05 })}
    ${box(x + 28, LEVEL.y + LEVEL.h - 6 - (LEVEL.h - SLOT - top - 14), 4, LEVEL.h - SLOT - top - 14, { fill: '#ffffff', opacity: 0.16 })}
    ${capMarkup(x, LEVEL.y + top)}
    ${ticks}
    ${T(x + 30, LEVEL.y + LEVEL.h + 17.85, 'LEVEL', { size: 11, ls: 1.54 })}
  </g>`;
}

function cueKey(deck) {
  const levelX = deck === 'A' ? LEVEL.cx : W - LEVEL.cx;
  return box(levelX - 35, FOOT.y, 70, FOOT.h, { rx: 4, fill: '#ff9d2b', stroke: '#000000', sw: 1.25 })
    + T(levelX, FOOT.y + 28.65, 'CUE', { size: 19, ls: 2.28, fill: '#1a0d00' });
}

/* ---------- meter ---------- */
function meter() {
  const { x, y, w, h, barTop, barBottom, ladder } = METER;
  const span = barBottom - barTop;
  const yOf = (db) => barBottom - ((db + 30) / 36) * span;
  const cols = [['A', 522], ['L', 581], ['R', 593], ['B', 652]];
  const bar = (id, cx) => {
    const level = METER.still[id], hold = METER.hold[id];
    const rungOf = (v) => ladder.slice(0, -1).reduce((found, low, i) => (v >= low ? i : found), -1);
    const lit = rungOf(level), held = rungOf(hold);
    const rungs = ladder.slice(0, -1).map((low, i) => {
      const t = Math.round(yOf(ladder[i + 1]) - barTop), b = Math.round(yOf(low) - barTop);
      const ink = i >= METER.red ? '#c9372a' : i >= METER.amber ? '#c99a26' : '#2b9e58';
      const fill = i === held && held > lit ? '#d8d8dd' : i <= lit ? ink : '#121216';
      return box(cx - 5, barTop + t + 1, 10, b - t - 2, { fill });
    }).join('');
    const aim = Math.round(yOf(id === 'A' || id === 'B' ? -6 : -3) - barTop);
    return box(cx - 5, barTop, 10, span, { fill: '#06060a', stroke: '#1e1e22' })
      + rungs
      + box(cx - 5, barTop + aim, 10, 1, { fill: '#8e8e96', opacity: 0.7 });
  };
  const nums = [552, 622].map((cx) => [6, 0, -6, -12, -18, -24, -30].map((db) =>
    T(cx, yOf(db) + 3.5, db > 0 ? '+' + db : String(db).replace('-', '−'), { size: 10, ls: 0.2, fill: db === 0 ? '#f2f2f4' : '#9a9ba1' })
  ).join('')).join('');
  return `<g>
    ${box(x, y, w, h, { rx: 4, fill: '#0f0f12', stroke: '#000000' })}
    ${box(x + 0.5, y + 0.5, w - 1, 1, { fill: '#ffffff', opacity: 0.04 })}
    ${T(522, y + 16.85, 'CH A', { size: 10, ls: 1.2 })}
    ${T(587, y + 16.85, 'MASTER', { size: 10, ls: 1.2 })}
    ${T(652, y + 16.85, 'CH B', { size: 10, ls: 1.2 })}
    ${T(552, y + 31.15, 'dBFS', { size: 9, ls: 0.54, fill: '#9a9ba1' })}
    ${T(587, y + 31.15, 'CLIP', { size: 9, ls: 1.26, fill: '#8a4f48' })}
    ${T(622, y + 31.15, 'dBFS', { size: 9, ls: 0.54, fill: '#9a9ba1' })}
    ${cols.map(([id, cx]) => bar(id, cx)).join('')}
    ${nums}
  </g>`;
}

/* ---------- foot row ---------- */
const ICON = {
  play: 'M8 5.5v13l11-6.5z',
  pause: '<rect x="6" y="5" width="4" height="14" rx="1"/><rect x="14" y="5" width="4" height="14" rx="1"/>',
  back: 'M17 5.5v13L6 12z',
  fwd: 'M7 5.5v13L18 12z'
};

function deckRows(deck) {
  const d = DECK[deck];
  const jx = deck === 'A' ? EDGE : W - EDGE - 274;
  const rx = deck === 'A' ? EDGE : W - EDGE - 338;
  const cells = [1, 4, 16, 32].map((n, i) => {
    const on = n === d.jump;
    const cx = jx + 48 + i * 44;
    return box(cx + 1, FOOT.y, 43, FOOT.h, { fill: on ? '#2a2a2f' : '#17171b' })
      + (i ? box(cx, FOOT.y, 1, FOOT.h, { fill: '#000000' }) : '')
      + (on ? box(cx + 1, FOOT.y + FOOT.h - 3, 43, 3, { fill: d.accent }) : '')
      + T(cx + 22, FOOT.y + 27.95, String(n), { size: 17, ls: 0.5, fill: on ? '#f2f2f4' : '#9a9ba1' });
  }).join('');
  const loopMid = 180 - 88 - 12;
  const loopX = rx + 2 * ROW.key + 26;
  const loopCell = (cx, w, txt, size) => box(cx, ROW.y + 7, w, 52, { rx: 4, fill: d.loopOn ? '#dd8630' : '#191a1d', stroke: '#000000' })
    + T(cx + w / 2, ROW.y + 7 + 26 + size * 0.35, txt, { size, ls: 0.5, fill: d.loopOn ? '#1a0d00' : '#cdced4' });
  return `<g id="Foot-${deck}">
    ${box(jx, FOOT.y, 44, FOOT.h, { rx: 4, fill: '#1a1a1e', stroke: '#000000' })}
    <path d="${ICON.back}" fill="#cdced4" transform="translate(${jx + 10} ${FOOT.y + 10})"/>
    ${box(jx + 48, FOOT.y, 178, FOOT.h, { rx: 4, fill: '#08080a', stroke: '#000000' })}
    ${cells}
    ${box(jx + 230, FOOT.y, 44, FOOT.h, { rx: 4, fill: '#1a1a1e', stroke: '#000000' })}
    <path d="${ICON.fwd}" fill="#cdced4" transform="translate(${jx + 240} ${FOOT.y + 10})"/>
    ${box(rx, ROW.y, ROW.key, ROW.key, { rx: 33, fill: d.cue ? '#ff9d2b' : '#1a1a1e' })}
    ${T(rx + ROW.key / 2, ROW.y + 39.65, 'CUE', { size: 19, ls: 2.28, fill: d.cue ? '#1a0d00' : '#ffab40' })}
    ${box(rx + ROW.key + 8, ROW.y, ROW.key, ROW.key, { rx: 33, fill: d.playing ? '#57c980' : '#1a1a1e' })}
    ${box(rx + ROW.key + 8, ROW.y, ROW.key, ROW.key, { rx: 31, fill: 'none', stroke: d.playing ? '#0d2917' : '#3a3a42', sw: 2 })}
    <g transform="translate(${rx + ROW.key + 8 + 20} ${ROW.y + 20}) scale(${26 / 24})" fill="${d.playing ? '#0c2a17' : '#eaeaee'}">${d.playing ? ICON.pause : `<path d="${ICON.play}"/>`}</g>
    ${loopCell(loopX, 44, '‹', 22)}
    ${loopCell(loopX + 50, loopMid, String(d.loop), 32)}
    ${loopCell(loopX + 136, 44, '›', 22)}
  </g>`;
}

/* ---------- link, crossfader, screws ---------- */
const linkKey = `<g>
  ${box(W / 2 - 34, FOOT.y, 68, FOOT.h, { rx: 4, fill: '#1a1a1e', stroke: '#000000' })}
  <circle cx="${W / 2}" cy="${FOOT.y + 8}" r="2.5" fill="#2b2b31" stroke="#000000"/>
  ${T(W / 2, FOOT.y + 24.5, 'LINK', { size: 12, ls: 1.56 })}
  ${T(W / 2, FOOT.y + 38, 'LOWS', { size: 12, ls: 1.56 })}
</g>`;

function crossfader() {
  const cx = XF.x + 29 + 0.5 * (XF.w - 58);
  const thumbX = cx - 29;
  const grooves = [];
  for (let i = 0; i < 10; i++) {
    grooves.push(box(thumbX + 5, 418 + i * 3, 48, 1, { fill: '#000000', opacity: 0.28 }));
  }
  return `<g>
    ${T(XF.x - 6, XF.cy + 4.9, '‹A', { size: 14, ls: 1.12, anchor: 'end' })}
    ${box(XF.x, XF.cy - 22 + 1, XF.w, 9, { fill: 'url(#comb)' })}
    ${box(XF.x, XF.cy + 22 - 1 - 9, XF.w, 9, { fill: 'url(#comb)' })}
    ${box(XF.x, XF.cy - 6, XF.w, 12, { rx: 3, fill: '#0b0b0d', stroke: '#000000' })}
    ${box(thumbX, XF.cy - 19, 58, 38, { rx: 3, fill: '#24242a', stroke: '#000000' })}
    ${grooves.join('')}
    ${box(cx - 1, XF.cy - 14, 2, 28, { fill: '#ececf0' })}
    ${T(XF.x + XF.w + 6, XF.cy + 4.9, 'B›', { size: 14, ls: 1.12, anchor: 'start' })}
  </g>`;
}

function screw(x, y) {
  return `<g transform="translate(${x} ${y})">
    <circle cx="3" cy="3" r="3" fill="#2c2d32" stroke="#000000"/>
    <g transform="rotate(38 3 3)">
      <rect x="0.8" y="2.5" width="4.4" height="1" fill="#000000"/>
      <rect x="2.5" y="0.8" width="1" height="4.4" fill="#000000"/>
    </g>
  </g>`;
}

const screws = `<g>${[[7, 7], [W - 13, 7], [7, H - 13], [W - 13, H - 13]].map(([x, y]) => screw(x, y)).join('')}</g>`;

/* ---------- assemble ---------- */
const svg = `<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink"
     width="1194" height="834" viewBox="0 0 1194 834" version="1.1">
  <title>Dex · Stage two · decks</title>
  <desc>Editable vector version of mockup/stage-two-decks.html. Panel is 1174 × 476 at (10, 338); song windows are an embedded image layer from stage-two-top.png.</desc>
  <defs>${defs}</defs>
  <g clip-path="url(#screen)">
    <g id="Device">
      <rect x="0" y="0" width="1194" height="834" rx="22" fill="#030304"/>
      <rect x="0.5" y="0.5" width="1193" height="833" rx="21.5" fill="none" stroke="#ffffff" opacity="0.05"/>
      <rect x="10" y="10" width="1174" height="814" fill="#0c0c0d"/>
    </g>
    <g id="Song-Windows">
      <image x="10" y="10" width="1174" height="338" preserveAspectRatio="xMidYMin slice"
             xlink:href="data:image/png;base64,${png}"/>
    </g>
    <g id="Chassis" transform="translate(10 348)">
      <g id="Panel">${panel}</g>
      <g id="Controls" transform="translate(0 1)">
        <g id="Platters">${platters}</g>
        <g id="Faceplate">${faceplate}</g>
        <g id="Deck-Keys">${deckKeys}</g>
        <g id="Trim">${trimChips}</g>
        <g id="Tempo-Faders">${tempoFader('A')}${tempoFader('B')}</g>
        <g id="Channel-Chips">${channelChips('A')}${channelChips('B')}</g>
        <g id="Level-Faders">${levelFader('A')}${levelFader('B')}</g>
        <g id="Channel-Cue">${cueKey('A')}${cueKey('B')}</g>
        <g id="Meter">${meter()}</g>
        <g id="Link-Lows">${linkKey}</g>
        <g id="Foot-Row">${deckRows('A')}${deckRows('B')}</g>
        <g id="Crossfader">${crossfader()}</g>
        <g id="Screws">${screws}</g>
      </g>
    </g>
  </g>
</svg>
`;

fs.writeFileSync(path.join(here, 'stage-two-decks.svg'), svg);
console.log(`stage-two-decks.svg: ${(svg.length / 1024).toFixed(0)} KB`);
