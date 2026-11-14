// Builds the native app's stage artwork from the stage-two mockup.
//
// The mockup (stage-two-decks.html) embeds the user's drawing, stage-two-decks FA.svg,
// as static SVG under its live controls. This takes that static art, leaves out what the
// app draws live (the platter displays' marks and the meter rungs), and prints it to two
// vector PDFs the app draws as they are:
//
//   chassis-base.pdf     the fascia and screws, always shown
//   chassis-platters.pdf the two platters, which the app also draws on top while one is scrubbed
//   chassis-art.pdf      everything else, hidden with the controls while the library is up
//
// Both cover the chassis only: the drawing's x 10 … 1184, y 348 … 824.
//
//   npx electron mockup/build-stage-art.mjs

import { app, BrowserWindow } from 'electron';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const out = path.join(here, '..', 'native', 'Sources', 'DexConsole', 'Art');
const html = fs.readFileSync(path.join(here, 'stage-two-decks.html'), 'utf8');

const svgStart = html.indexOf('<svg id="stage"');
const svg = html.slice(svgStart, html.indexOf('</svg>', svgStart) + 6);
const defs = svg.slice(svg.indexOf('<defs>'), svg.indexOf('</defs>') + 7);
const art = svg.slice(svg.indexOf('<g id="art">') + 12, svg.indexOf('<g id="dyn">'));

const base = art.slice(art.indexOf('<!-- Fascia and screws -->'), art.indexOf('<!-- Platters -->'));
let platters = art.slice(art.indexOf('<!-- Platters -->'), art.indexOf('<!-- Mixer faceplate -->'));
let rest = art.slice(art.indexOf('<!-- Mixer faceplate -->'));
rest = rest.slice(0, rest.lastIndexOf('</g>'));

// The platter displays' marks: the app turns them with the track.
const centres = [[234, 545], [960, 545]];
platters = platters.replace(/<line\b[^>]*>/g, (tag) => {
  const n = (k) => +(tag.match(new RegExp(`\\s${k}="([-\\d.]+)"`)) || [])[1];
  const [x, y] = [n('x1'), n('y1')];
  return centres.some(([cx, cy]) => Math.hypot(x - cx, y - cy) < 50) ? '' : tag;
});
// The meter's rungs and aim marks: the app lights them. The wells stay.
const meterX = ['548.46', '586.46', '600.46', '637.75'];
rest = rest.replace(/<rect\b[^>]*>/g, (tag) => {
  const cls = (tag.match(/class="(st\d+)"/) || [])[1];
  const x = (tag.match(/\sx="([-\d.]+)"/) || [])[1];
  return meterX.includes(x) && ['st141', 'st134', 'st142', 'st139', 'st42'].includes(cls) ? '' : tag;
});

const page = (body) => `<!doctype html><html><head><meta charset="utf-8"><style>
  @page { size: 1174px 476px; margin: 0; }
  html, body { margin: 0; padding: 0; background: transparent; }
  svg { display: block; }
</style></head><body>
<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink"
  width="1174" height="476" viewBox="10 348 1174 476">${defs}${body}</svg>
</body></html>`;

async function print(win, name, body) {
  const file = path.join(os.tmpdir(), `dex-${name}.html`);
  fs.writeFileSync(file, page(body));
  await win.loadFile(file);
  await win.webContents.executeJavaScript('document.fonts.ready.then(() => true)');
  const pdf = await win.webContents.printToPDF({ printBackground: true, preferCSSPageSize: true, margins: { marginType: 'none' } });
  fs.writeFileSync(path.join(out, `${name}.pdf`), pdf);
  console.log(`${name}.pdf  ${pdf.length} bytes`);
}

app.whenReady().then(async () => {
  fs.mkdirSync(out, { recursive: true });
  const win = new BrowserWindow({ show: false, width: 1174, height: 476 });
  try {
    await print(win, 'chassis-base', base);
    await print(win, 'chassis-platters', platters);
    await print(win, 'chassis-art', rest);
  } catch (error) {
    console.error(error);
    process.exitCode = 1;
  }
  app.quit();
});
