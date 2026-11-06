/**
 * Pixel diff between the mockup and the app (or any two pages that draw the
 * 1174 × 814 console stage).
 *
 *   npm run diff:mockup     (scripts/mockup-diff.json: the mockup against the
 *                            app's ?demo=mockup, renderer on port 5299)
 *   electron scripts/pixel-diff.mjs spec.json
 *
 * spec.json:
 *   {
 *     "out": "path/to/dir",
 *     "pairs": [{
 *       "name": "home",
 *       "a": { "url": "http://localhost:8765/xdj-mixer-alt.html", "window": [1300, 1000], "setup": "toggleLib()" },
 *       "b": { "url": "http://localhost:5299/?demo=mockup", "window": [1174, 814], "setup": "", "css": "" },
 *       "mask": [[x, y, w, h], …],     // stage-px regions to ignore
 *       "only": [[x, y, w, h], …],     // if set, compare only inside these
 *       "aa": 40,                      // anti-aliasing tolerance, see below
 *       "budget": 500                  // pass with up to this many differing px
 *     }],
 *     "css": "…"                       // injected into every page, e.g. to stop animations
 *   }
 *
 * Each page is loaded in an offscreen window, `setup` runs in it, and after
 * the transitions settle the `.ipad` content box (inside any bezel) is
 * captured. For every pair it writes a.png, b.png and diff.png (identical
 * pixels dimmed, differing ones magenta), a.json and b.json (every element's
 * box under the stage; compare them with scripts/geometry-diff.py), and
 * prints the differing pixel count with the boxes of the clusters that differ
 * (rounding noise of up to NOISE levels per channel is counted separately).
 *
 * Instead of a page, a "b" side can be an image another program draws, e.g.
 * the native console (scripts/native-diff.json):
 *   "b": { "render": "swift run … --scale {scale} --out {out}" }
 * runs the command at side a's capture density and diffs the PNG it writes.
 * Two renderers never anti-alias glyph edges alike, so such a pair can set
 * "aa": a pixel then differs only if no pixel within 1 px of it in the other
 * image is within that many levels. Wrong colours, missing parts and shifts
 * of 2 px or more still show; edge rasterisation does not.
 */
import { app, BrowserWindow } from 'electron'
import { execSync } from 'node:child_process'
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { join, resolve } from 'node:path'
import { pathToFileURL } from 'node:url'

const specPath = process.argv.find((arg) => arg.endsWith('.json'))
if (!specPath) {
  console.error('usage: electron scripts/pixel-diff.mjs spec.json')
  process.exit(2)
}
const spec = JSON.parse(readFileSync(specPath, 'utf8'))
const outDir = resolve(spec.out)
mkdirSync(outDir, { recursive: true })

app.commandLine.appendSwitch('autoplay-policy', 'no-user-gesture-required')

/** [path, x, y, w, h, text] for every element under .ipad, in stage px. */
const GEOMETRY = `(() => {
  const root = document.querySelector('.ipad')
  const r0 = root.getBoundingClientRect()
  const s = r0.width / root.offsetWidth
  const ox = r0.left + root.clientLeft * s
  const oy = r0.top + root.clientTop * s
  const out = []
  const walk = (el, path) => {
    Array.from(el.children).forEach((c, i) => {
      if (c.closest('.hots, svg, .wave-canvas')) return
      const cls = typeof c.className === 'string' && c.className.trim() ? '.' + c.className.trim().split(/\\s+/).sort().join('.') : ''
      const p = path + '>' + c.tagName.toLowerCase() + cls
      const r = c.getBoundingClientRect()
      const txt = c.children.length === 0 ? (c.textContent || '').trim().slice(0, 24) : ''
      out.push([p, +((r.left - ox) / s).toFixed(2), +((r.top - oy) / s).toFixed(2), +(r.width / s).toFixed(2), +(r.height / s).toFixed(2), txt])
      walk(c, p)
    })
  }
  walk(root, '')
  return JSON.stringify(out)
})()`

/**
 * Gradients blended through translucent layers can round a channel one level
 * differently from one page to the next; differences this small are counted
 * apart, so they cannot hide a real one.
 */
const NOISE = 2

const sleep = (ms) => new Promise((done) => setTimeout(done, ms))

async function capture(target) {
  const [width, height] = target.window ?? [1300, 1000]
  const win = new BrowserWindow({
    show: false,
    width,
    height,
    useContentSize: true,
    paintWhenInitiallyHidden: true,
    webPreferences: { offscreen: true, backgroundThrottling: false }
  })
  // A second window's first load is sometimes aborted (ERR_FAILED) for no
  // reason Chromium reports; loading again succeeds.
  // A bare path is a file in the repository, e.g. mockup/xdj-mixer-alt.html.
  const url = /^[a-z]+:/.test(target.url) ? target.url : pathToFileURL(resolve(target.url)).href
  for (let attempt = 0; ; attempt++) {
    try {
      await win.loadURL(url)
      break
    } catch (error) {
      if (attempt >= 3) throw error
      await sleep(300)
    }
  }
  if (spec.css) await win.webContents.insertCSS(spec.css)
  if (target.css) await win.webContents.insertCSS(target.css)
  await win.webContents.executeJavaScript('document.fonts.ready.then(() => true)')
  await sleep(target.wait ?? 600)
  if (target.setup) {
    await win.webContents.executeJavaScript(`(async () => { ${target.setup} })()`)
    await sleep(target.settle ?? 700)
  }
  const rect = await win.webContents.executeJavaScript(`(() => {
    const el = document.querySelector('.ipad')
    if (!el) return null
    const r = el.getBoundingClientRect()
    const s = r.width / el.offsetWidth
    return { x: r.left + el.clientLeft * s, y: r.top + el.clientTop * s, width: el.clientWidth * s, height: el.clientHeight * s }
  })()`)
  if (!rect) throw new Error(`No .ipad on ${target.url}`)
  const box = { x: Math.round(rect.x), y: Math.round(rect.y), width: Math.round(rect.width), height: Math.round(rect.height) }
  const image = await win.webContents.capturePage(box)
  // Every element's box relative to the stage, for finding sub-pixel shifts
  // the image alone cannot explain.
  const geometry = await win.webContents.executeJavaScript(GEOMETRY)
  win.destroy()
  // Offscreen windows capture at the screen's own density, whatever the
  // switch says; masks and cluster boxes are converted with this.
  return { image, density: image.getSize().width / rect.width, geometry }
}

/** The closest match to pixel i of `pa` among the 3 × 3 neighbourhood in `pb`, either way round. */
function nearest(pa, pb, i, x, y, width, height) {
  const near = (from, to) => {
    let best = 255
    for (let dy = -1; dy <= 1; dy++) {
      for (let dx = -1; dx <= 1; dx++) {
        const nx = x + dx
        const ny = y + dy
        if (nx < 0 || ny < 0 || nx >= width || ny >= height) continue
        const j = (ny * width + nx) * 4
        best = Math.min(best, Math.max(Math.abs(from[i] - to[j]), Math.abs(from[i + 1] - to[j + 1]), Math.abs(from[i + 2] - to[j + 2])))
      }
    }
    return best
  }
  return Math.max(near(pa, pb), near(pb, pa))
}

/** Runs a target's `render` command at `density` and loads the PNG it writes. */
async function render(target, density, dir) {
  const { nativeImage } = await import('electron')
  const out = join(dir, 'b.png')
  execSync(target.render.replaceAll('{scale}', String(density)).replaceAll('{out}', JSON.stringify(out)), { stdio: ['ignore', 'ignore', 'inherit'] })
  return { image: nativeImage.createFromPath(out), geometry: '[]' }
}

/** Connected clusters of differing pixels, on a coarse grid so a line of text is one box. */
function clusters(mask, width, height, cell = 8) {
  const cw = Math.ceil(width / cell)
  const ch = Math.ceil(height / cell)
  const hit = new Uint8Array(cw * ch)
  for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) if (mask[y * width + x]) hit[Math.floor(y / cell) * cw + Math.floor(x / cell)] = 1
  const seen = new Uint8Array(cw * ch)
  const boxes = []
  for (let i = 0; i < hit.length; i++) {
    if (!hit[i] || seen[i]) continue
    let x0 = Infinity, y0 = Infinity, x1 = -1, y1 = -1, n = 0
    const stack = [i]
    seen[i] = 1
    while (stack.length) {
      const j = stack.pop()
      const cx = j % cw
      const cy = Math.floor(j / cw)
      x0 = Math.min(x0, cx); y0 = Math.min(y0, cy); x1 = Math.max(x1, cx); y1 = Math.max(y1, cy); n++
      for (const [dx, dy] of [[1, 0], [-1, 0], [0, 1], [0, -1]]) {
        const nx = cx + dx
        const ny = cy + dy
        if (nx < 0 || ny < 0 || nx >= cw || ny >= ch) continue
        const k = ny * cw + nx
        if (hit[k] && !seen[k]) { seen[k] = 1; stack.push(k) }
      }
    }
    boxes.push({ x: x0 * cell, y: y0 * cell, w: (x1 - x0 + 1) * cell, h: (y1 - y0 + 1) * cell, cells: n })
  }
  return boxes.sort((a, b) => a.y - b.y || a.x - b.x)
}

async function run() {
  let failed = false
  for (const pair of spec.pairs) {
    // One at a time: python's http.server answers one request at a time.
    const { image: a, density, geometry: ga } = await capture(pair.a)
    const dir = join(outDir, pair.name)
    mkdirSync(dir, { recursive: true })
    const { image: b, geometry: gb } = pair.b.render ? await render(pair.b, density, dir) : await capture(pair.b)
    const scale = density
    writeFileSync(join(dir, 'a.png'), a.toPNG())
    writeFileSync(join(dir, 'b.png'), b.toPNG())
    writeFileSync(join(dir, 'a.json'), ga)
    writeFileSync(join(dir, 'b.json'), gb)
    const sa = a.getSize()
    const sb = b.getSize()
    if (sa.width !== sb.width || sa.height !== sb.height) {
      console.log(`${pair.name}: size differs, a ${sa.width}×${sa.height} vs b ${sb.width}×${sb.height}`)
      failed = true
      continue
    }
    const { width, height } = sa
    const pa = a.toBitmap()
    const pb = b.toBitmap()
    const out = Buffer.alloc(pa.length)
    const diff = new Uint8Array(width * height)
    const inside = (boxes) => (x, y) =>
      boxes.some(([mx, my, mw, mh]) => x >= mx * scale && x < (mx + mw) * scale && y >= my * scale && y < (my + mh) * scale)
    const inMask = inside(pair.mask ?? [])
    const inOnly = pair.only ? inside(pair.only) : () => true
    const masked = (x, y) => inMask(x, y) || !inOnly(x, y)
    let count = 0
    let noise = 0
    for (let y = 0; y < height; y++) {
      for (let x = 0; x < width; x++) {
        const i = (y * width + x) * 4
        let delta = Math.max(Math.abs(pa[i] - pb[i]), Math.abs(pa[i + 1] - pb[i + 1]), Math.abs(pa[i + 2] - pb[i + 2]))
        if (pair.aa && delta > NOISE) delta = nearest(pa, pb, i, x, y, width, height) <= pair.aa ? 0 : delta
        if (delta > 0 && delta <= NOISE && !masked(x, y)) noise++
        if (delta > NOISE && !masked(x, y)) {
          diff[y * width + x] = 1
          count++
          out[i] = 255; out[i + 1] = 0; out[i + 2] = 255; out[i + 3] = 255
        } else {
          // BGRA, dimmed to a third so the differences stand out.
          out[i] = pa[i] / 3; out[i + 1] = pa[i + 1] / 3; out[i + 2] = pa[i + 2] / 3; out[i + 3] = 255
        }
      }
    }
    const { nativeImage } = await import('electron')
    writeFileSync(join(dir, 'diff.png'), nativeImage.createFromBitmap(out, { width, height }).toPNG())
    const boxes = clusters(diff, width, height, 8 * scale).map((box) => ({
      x: box.x / scale, y: box.y / scale, w: box.w / scale, h: box.h / scale
    }))
    console.log(`${pair.name}: ${count} px differ${count ? ` in ${boxes.length} clusters` : ''}${noise ? ` (and ${noise} px by ${NOISE} levels or less)` : ''}`)
    for (const box of boxes.slice(0, 40)) console.log(`  [${box.x}, ${box.y}, ${box.w}, ${box.h}]`)
    if (boxes.length > 40) console.log(`  … ${boxes.length - 40} more`)
    if (pair.budget != null) console.log(`  ${count <= pair.budget ? 'within' : 'OVER'} budget of ${pair.budget}`)
    if (count > (pair.budget ?? 0)) failed = true
  }
  app.exit(failed ? 1 : 0)
}

// Captures run one window at a time; closing one must not quit the app.
app.on('window-all-closed', () => {})
app.whenReady().then(run).catch((error) => {
  console.error(error)
  app.exit(2)
})
