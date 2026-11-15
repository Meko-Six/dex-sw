/* The beat grid sheet for stage-two-decks.html, brought over from the
   xdj-mixer-alt mockup: drag the waveform onto the lines, step a beat, zoom,
   SET DOWNBEAT, TAP, ±0.1 BPM, ±1 ms, ÷2 ×2 and the other tempos, with the
   (i) instructions. The waveform is drawn in shades of the deck's colour and
   the lines are white. Everything lives on window.GridSheet, so none of it
   meets the stage's own names.

   Open it with GridSheet.open('A' | 'B'). GridSheet.alternates(mode) gives
   deck A's track other tempo readings: 'alts', 'unsure' (also flags the
   tempo as uncertain) or null. */
(() => {
  const DECKS = {
    A: { bpm: 133.0, confidence: 95, offset: 489.9, colour: [0x27, 0x6f, 0xff], seed: 7 },
    B: { bpm: 130.0, confidence: 88, offset: 247.3, colour: [0xff, 0x8a, 0x1f], seed: 21 }
  };
  /* The audio under the waveform: tied to the deck's original grid, so moving
     the grid visibly pulls the lines off the transients. */
  const AUDIO = { A: { bpm: 133.0, offsetMs: 489.9 }, B: { bpm: 130.0, offsetMs: 247.3 } };
  const TRACK_MS = 384000;
  const PLAYHEAD_MS = 24000;
  const ZOOMS = [8000, 4000, 2000, 1000, 500, 250];

  const edit = {};
  for (const key of ['A', 'B']) edit[key] = { bpm: DECKS[key].bpm, confidence: DECKS[key].confidence, offset: DECKS[key].offset, taps: [] };
  const windowAt = { A: { startMs: 0 }, B: { startMs: 0 } };
  let open = null, zoom = 2, armed = false, drag = null, help = false, altsMode = null;

  /* Other tempos, each with its own downbeat. */
  const ALTS = [
    { bpm: 88.667, offset: 120.4, relation: '2/3' },
    { bpm: 177.333, offset: 489.9, relation: '4/3' },
    { bpm: 99.75, offset: 312.8, relation: '3/4' }
  ];

  const spanMs = () => ZOOMS[zoom];
  const $ = (id) => document.getElementById(id);
  function centre(key, centreMs) {
    windowAt[key].startMs = Math.max(0, Math.min(TRACK_MS - spanMs(), centreMs - spanMs() / 2));
  }

  /* ---------- the signal and its columns ---------- */
  const noise = (ms) => { const x = Math.sin(Math.floor(ms * 8) * 12.9898) * 43758.5453; return (x - Math.floor(x)) * 2 - 1; };
  /* A kick with a hard attack on every beat, harder on the downbeat, a hat on the offbeat. */
  function signal(audio, ms) {
    const period = 60000 / audio.bpm;
    const beat = Math.floor((ms - audio.offsetMs) / period);
    const since = ms - (audio.offsetMs + beat * period);
    const downbeat = ((beat % 4) + 4) % 4 === 0;
    const pitch = 58 + 190 * Math.exp(-since / 14);
    const kick = (downbeat ? 1 : 0.84) * Math.exp(-since / 95) * Math.sin(2 * Math.PI * pitch * since / 1000);
    const off = since - period / 2;
    const hat = off >= 0 ? 0.3 * Math.exp(-off / 20) * noise(ms) : 0;
    return kick + hat + 0.05 * noise(ms);
  }

  /* The app's waveform crossovers (DexWaveform.c): a second-order section. */
  function biquad(rate, hz, high) {
    const w = 2 * Math.PI * Math.min(hz, rate * 0.45) / rate;
    const c = Math.cos(w), alpha = Math.sin(w) / Math.SQRT2, a0 = 1 + alpha;
    const b0 = (high ? 1 + c : 1 - c) / 2 / a0;
    const f = { b0, b1: (high ? -(1 + c) : 1 - c) / a0, b2: b0, a1: -2 * c / a0, a2: (1 - alpha) / a0, z1: 0, z2: 0 };
    return (x) => { const y = f.b0 * x + f.z1; f.z1 = f.b1 * x - f.a1 * y + f.z2; f.z2 = f.b2 * x - f.a2 * y; return y; };
  }

  /* Per column: the signal's lowest and highest, and its MID (220 Hz to 3.5 kHz)
     and HIGH (above 3.5 kHz) envelopes, which rise at once and fall over 4 ms,
     so every layer keeps the hit's exact start. As GridWaveBuilder in the app. */
  function readColumns(audio, startMs, span, count) {
    const rate = 44100;
    const hp220 = biquad(rate, 220, 1), lp3500 = biquad(rate, 3500, 0), hp3500 = biquad(rate, 3500, 1);
    const fall = Math.exp(-1 / (rate * 0.004));
    const lo = new Float32Array(count), hi = new Float32Array(count), mid = new Float32Array(count), top = new Float32Array(count);
    const first = Math.floor((startMs - 60) * rate / 1000), last = Math.ceil((startMs + span) * rate / 1000);
    let midEnv = 0, highEnv = 0;
    for (let n = first; n < last; n++) {
      const ms = n * 1000 / rate, x = ms < 0 ? 0 : signal(audio, ms);
      midEnv = Math.max(Math.abs(lp3500(hp220(x))), midEnv * fall);
      highEnv = Math.max(Math.abs(hp3500(x)), highEnv * fall);
      const column = Math.floor((ms - startMs) / span * count);
      if (column < 0 || column >= count) continue;
      lo[column] = Math.min(lo[column], x); hi[column] = Math.max(hi[column], x);
      mid[column] = Math.max(mid[column], midEnv); top[column] = Math.max(top[column], highEnv);
    }
    return { lo, hi, mid, top };
  }

  /* ---------- painting ---------- */
  /* One column per screen pixel, drawn at twice the stage's size, in shades of
     the deck's colour: the whole signal outermost and darkest, its real lowest
     to highest; MID inside it in the deck colour; HIGH palest in the middle. */
  function paintWave(key) {
    const canvas = $('gcanvas');
    if (!canvas) return;
    const box = canvas.parentElement;
    const columns = box.clientWidth * 2, height = box.clientHeight * 2;
    if (canvas.width !== columns) canvas.width = columns;
    if (canvas.height !== height) canvas.height = height;
    const context = canvas.getContext('2d');
    context.clearRect(0, 0, columns, height);
    const { lo, hi, mid, top } = readColumns(AUDIO[key], windowAt[key].startMs, spanMs(), columns);
    const middle = height / 2, reach = middle - 12;
    const deck = DECKS[key].colour;
    const shade = (to, t) => 'rgb(' + deck.map((v, i) => Math.round(v + (to[i] - v) * t)).join(',') + ')';
    context.fillStyle = shade([6, 6, 7], 0.45);
    context.beginPath();
    context.moveTo(0, middle - hi[0] * reach);
    for (let c = 1; c < columns; c++) context.lineTo(c, middle - hi[c] * reach);
    for (let c = columns - 1; c >= 0; c--) context.lineTo(c, middle - lo[c] * reach);
    context.closePath();
    context.fill();
    const layer = (values, gain, fill) => {
      context.fillStyle = fill;
      context.beginPath();
      context.moveTo(0, middle);
      for (let c = 0; c < columns; c++) context.lineTo(c, middle - Math.min(1, values[c] * gain) * reach);
      for (let c = columns - 1; c >= 0; c--) context.lineTo(c, middle + Math.min(1, values[c] * gain) * reach);
      context.closePath();
      context.fill();
    };
    layer(mid, 1.2, shade(deck, 0));
    layer(top, 0.9, shade([255, 255, 255], 0.72));
  }

  /* The whole track under the wave: where the window is, and a way to move it. */
  function paintStrip(key) {
    const canvas = $('gstrip');
    if (!canvas) return;
    const box = canvas.parentElement;
    const columns = box.clientWidth, height = box.clientHeight;
    if (canvas.width !== columns) { canvas.width = columns; canvas.height = height; }
    const context = canvas.getContext('2d');
    context.clearRect(0, 0, columns, height);
    context.fillStyle = '#6a6e71';
    let seed = DECKS[key].seed;
    for (let column = 0; column < columns; column += 2) {
      seed = (seed * 9301 + 49297) % 233280;
      const section = 0.45 + 0.4 * Math.abs(Math.sin(column / columns * 9 + DECKS[key].seed));
      const level = Math.max(2, section * (0.75 + 0.25 * seed / 233280) * (height - 6));
      context.fillRect(column, (height - level) / 2, 1, level);
    }
    const spot = $('gspot');
    spot.style.left = (windowAt[key].startMs / TRACK_MS * 100).toFixed(3) + '%';
    spot.style.width = 'max(8px, ' + (spanMs() / TRACK_MS * 100).toFixed(3) + '%)';
  }

  function lines(key) {
    const g = edit[key];
    const period = 60000 / g.bpm;
    const startMs = windowAt[key].startMs, span = spanMs();
    const first = Math.floor((startMs - g.offset) / period) - 1;
    const last = Math.ceil((startMs + span - g.offset) / period) + 1;
    let out = '';
    for (let beat = first; beat <= last; beat++) {
      const pct = ((g.offset + beat * period - startMs) / span) * 100;
      if (pct < -0.5 || pct > 100.5) continue;
      const downbeat = ((beat % 4) + 4) % 4 === 0;
      out += '<span class="gbeat' + (downbeat ? ' down' : '') + '" style="left:' + pct.toFixed(2) + '%">' +
        (downbeat ? '<b>' + (Math.floor(beat / 4) + 1) + '</b>' : '') + '</span>';
    }
    // The playhead belongs to the audio, so it moves with the waveform.
    const now = ((PLAYHEAD_MS - startMs) / span) * 100;
    if (now >= 0 && now <= 100) out += '<span class="gnow" style="left:' + now.toFixed(2) + '%"></span>';
    return out;
  }

  /* ---------- the sheet ---------- */
  const unsure = () => open === 'A' && altsMode === 'unsure';
  const altsShown = () => (open === 'A' && altsMode ? ALTS : []);
  const icon = (kind, action, title) =>
    `<button class="gicon ${kind}" onclick="event.stopPropagation(); ${action}" title="${title}" aria-label="${title}"><img src="../icons/${kind}.svg" alt=""></button>`;

  function sheetHtml() {
    const key = open, g = edit[key];
    const tapLabel = g.taps.length > 0 ? g.taps.length + (g.taps.length === 1 ? ' tap' : ' taps') : '3 taps';
    const alts = altsShown();
    const altsHtml = alts.length === 0 ? '' : `
      <div class="galts${unsure() ? ' unsure' : ''}" data-ctl="grid.alternates">
        <span>${unsure() ? 'Not sure of this tempo · it may be' : 'Other readings'}</span>
        ${alts.map((alt, n) => `<button class="gact galt" onclick="GridSheet.useAlt(${n})" title="Use ${alt.bpm.toFixed(2)} BPM, with its own downbeat">${alt.bpm.toFixed(2)}<small>${alt.relation}×</small></button>`).join('')}
      </div>`;
    const span = spanMs();
    return `
      <div class="gsheet gridwide" style="--accent:var(--${key.toLowerCase()})">
        <div class="gsheet-head">
          <h2>Beat grid <span>· deck ${key}</span></h2>
          ${icon('info', 'GridSheet.help(true)', 'How the beat grid works')}
          ${icon('close', 'GridSheet.close()', 'Close')}
        </div>
        <div class="gstats" data-ctl="grid.readouts">
          <div class="gstat"><b id="gbpm">${g.bpm.toFixed(1)}</b><span>BPM</span></div>
          <div class="gstat"><b class="${unsure() ? 'unsure' : 'ok'}" id="gconf">${Math.round(g.confidence)}%${unsure() ? '?' : ''}</b><span>confidence</span></div>
          <div class="gstat"><b id="goff">${(g.offset >= 0 ? '+' : '') + g.offset.toFixed(1)}</b><span>offset ms</span></div>
        </div>
        <div class="gview">
          <div class="gview-head">
            <span class="gview-title">grid · 4/4</span>
            <span class="gview-hint">${armed ? 'Tap the first beat of a bar' : 'Drag the waveform onto the lines'}</span>
            <span class="gkeys" data-ctl="grid.beatstep">
              <button class="gkey" onclick="GridSheet.step(-1)" title="Centre the line before">◀ BEAT</button>
              <button class="gkey" onclick="GridSheet.step(1)" title="Centre the line after">BEAT ▶</button>
            </span>
            <span class="gkeys" data-ctl="grid.zoom">
              <button class="gkey sq" onclick="GridSheet.zoom(-1)" title="Zoom out" ${zoom === 0 ? 'disabled' : ''}>−</button>
              <b class="gzoom">${span >= 1000 ? span / 1000 + ' S' : span + ' MS'}</b>
              <button class="gkey sq" onclick="GridSheet.zoom(1)" title="Zoom in" ${zoom === ZOOMS.length - 1 ? 'disabled' : ''}>+</button>
            </span>
            <button class="garm ${armed ? 'on' : ''}" data-ctl="grid.setdownbeat" onclick="GridSheet.arm()">${armed ? 'TAP THE FIRST BEAT' : 'SET DOWNBEAT'}</button>
          </div>
          <div class="gwave ${armed ? 'arming' : ''}" id="gwave" data-ctl="grid.wave">
            <canvas id="gcanvas"></canvas>
            <div class="glines" id="glines">${lines(key)}</div>
          </div>
          <div class="gstripbox" id="gstripbox" data-ctl="grid.overview">
            <canvas id="gstrip"></canvas>
            <span class="gspot" id="gspot"></span>
          </div>
        </div>
        <div class="gactions">
          <button class="gact tall" data-ctl="grid.tap" onclick="GridSheet.tap()">TAP<small>${tapLabel}</small></button>
          <button class="gact" data-ctl="grid.bpmdown" onclick="GridSheet.nudgeBpm(-0.1)">−0.1<small>BPM</small></button>
          <button class="gact" data-ctl="grid.bpmup" onclick="GridSheet.nudgeBpm(0.1)">+0.1<small>BPM</small></button>
          <button class="gact" data-ctl="grid.nudgeback" onclick="GridSheet.nudgeOffset(-1)">◀ 1 ms<small>earlier</small></button>
          <button class="gact" data-ctl="grid.nudgefwd" onclick="GridSheet.nudgeOffset(1)">1 ms ▶<small>later</small></button>
          <button class="gact" data-ctl="grid.halve" onclick="GridSheet.scale(0.5)">÷2<small>half</small></button>
          <button class="gact" data-ctl="grid.double" onclick="GridSheet.scale(2)">×2<small>double</small></button>
        </div>${altsHtml}
      </div>`;
  }

  const HELP_ROWS = [
    ['Drag', 'Drag the waveform until the beat sits on a line. The lines stay still.'],
    ['− +', 'Zoom in until you can see the attack of the beat.'],
    ['◀ Beat ▶', 'Step to the line before or after. The strip below the wave moves along the track.'],
    ['Set downbeat', 'Arm it, then tap the first beat of a bar.'],
    ['Tap', 'Tap along with the beat. Three taps set the tempo.'],
    ['±0.1 · 1 ms', 'Trim the tempo, or slide the grid earlier or later.'],
    ['÷2 · ×2', 'Fix a half-time or double-time reading.'],
    ['Other tempos', 'Swap in a tempo the analysis turned down. It brings its own downbeat.']
  ];
  function helpHtml() {
    return `
      <div class="gsheet narrow ghelp" onclick="event.stopPropagation()">
        <div class="gsheet-head"><h2>How the beat grid works</h2>${icon('close', 'GridSheet.help(false)', 'Close')}</div>
        <div class="ghelp-rows">${HELP_ROWS.map(([term, text]) => `<div class="ghelp-row"><b>${term}</b><span>${text}</span></div>`).join('')}</div>
        <p class="ghelp-foot">Every edit saves to the library straight away. There is no Apply step.</p>
      </div>`;
  }

  function layers() {
    let sheet = $('gridLayer'), helpLayer = $('gridHelpLayer');
    if (!sheet) {
      const host = $('ipad');
      sheet = document.createElement('section');
      sheet.className = 'grid-layer'; sheet.id = 'gridLayer';
      helpLayer = document.createElement('section');
      helpLayer.className = 'ghelp-layer'; helpLayer.id = 'gridHelpLayer';
      helpLayer.addEventListener('click', () => GridSheet.help(false));
      host.append(sheet, helpLayer);
    }
    return { sheet, helpLayer };
  }

  function render() {
    const { sheet, helpLayer } = layers();
    sheet.innerHTML = open ? sheetHtml() : '';
    sheet.classList.toggle('open', Boolean(open));
    helpLayer.innerHTML = help ? helpHtml() : '';
    helpLayer.classList.toggle('open', help);
    document.dispatchEvent(new CustomEvent('gridsheet', { detail: { open } }));
    if (!open) return;
    paintWave(open);
    paintStrip(open);
    const wave = $('gwave'), strip = $('gstripbox');
    wave.addEventListener('pointerdown', startDrag);
    wave.addEventListener('pointermove', moveDrag);
    wave.addEventListener('pointerup', endDrag);
    wave.addEventListener('pointercancel', endDrag);
    // A drag whose capture is taken away still ends, so it can't stick to the next tap.
    wave.addEventListener('lostpointercapture', endDrag);
    strip.addEventListener('pointerdown', moveStrip);
    strip.addEventListener('pointermove', moveStrip);
  }

  /* During a drag only the readouts, lines and waveform change, so the pointer capture survives. */
  function refresh() {
    if (!open || !$('gbpm')) return;
    const g = edit[open];
    $('gbpm').textContent = g.bpm.toFixed(1);
    $('gconf').textContent = Math.round(g.confidence) + '%' + (unsure() ? '?' : '');
    $('goff').textContent = (g.offset >= 0 ? '+' : '') + g.offset.toFixed(1);
    $('glines').innerHTML = lines(open);
    paintWave(open);
    paintStrip(open);
  }

  function commit() { render(); }

  /* ---------- gestures ---------- */
  function startDrag(event) {
    drag = {
      key: open, pointerId: event.pointerId, startX: event.clientX,
      startOffset: edit[open].offset, startMs: windowAt[open].startMs,
      rect: event.currentTarget.getBoundingClientRect(), moved: false, armed
    };
    try { event.currentTarget.setPointerCapture(event.pointerId); } catch { /* synthetic pointer */ }
  }
  function moveDrag(event) {
    if (!drag || event.pointerId !== drag.pointerId) return;
    const dx = event.clientX - drag.startX;
    if (Math.abs(dx) < 3) return;
    drag.moved = true;
    if (drag.armed) return;
    // The waveform follows the finger and the lines stay where they are.
    const msPerPixel = spanMs() / drag.rect.width;
    edit[drag.key].offset = drag.startOffset - dx * msPerPixel;
    windowAt[drag.key].startMs = drag.startMs - dx * msPerPixel;
    refresh();
  }
  function endDrag(event) {
    if (!drag || event.pointerId !== drag.pointerId) return;
    const done = drag;
    drag = null;
    if (done.armed && !done.moved) {
      const rect = event.currentTarget.getBoundingClientRect();
      const x = Math.min(1, Math.max(0, (event.clientX - rect.left) / rect.width));
      const timeMs = windowAt[done.key].startMs + x * spanMs();
      edit[done.key].offset = timeMs % (4 * (60000 / edit[done.key].bpm));
      armed = false;
      commit();
      return;
    }
    if (done.moved) {
      // Fold the result into one bar: the lines look the same, the offset stays readable.
      const g = edit[done.key], barMs = 4 * (60000 / g.bpm);
      g.offset = ((g.offset % barMs) + barMs) % barMs;
      commit();
    }
  }
  function moveStrip(event) {
    if (!open || (event.type === 'pointermove' && !event.buttons)) return;
    if (event.type === 'pointerdown') { try { event.currentTarget.setPointerCapture(event.pointerId); } catch { /* synthetic pointer */ } }
    const rect = event.currentTarget.getBoundingClientRect();
    centre(open, Math.min(1, Math.max(0, (event.clientX - rect.left) / rect.width)) * TRACK_MS);
    refresh();
  }

  function relationOver(bpm, base) {
    const ratio = bpm / base;
    for (let d = 1; d <= 8; d++) {
      const n = Math.round(ratio * d);
      if (n > 0 && Math.abs(n / d - ratio) < 0.005 * ratio) return d === 1 ? String(n) : `${n}/${d}`;
    }
    return ratio.toFixed(2);
  }

  window.GridSheet = {
    open(key) {
      open = key === 'B' ? 'B' : 'A';
      armed = false; drag = null; zoom = 2;
      centre(open, PLAYHEAD_MS);
      render();
    },
    close() { open = null; armed = false; drag = null; help = false; render(); },
    isOpen: () => open,
    help(on) { help = Boolean(on); render(); },
    alternates(mode) { altsMode = mode || null; render(); },
    zoom(step) {
      const middle = windowAt[open].startMs + spanMs() / 2;
      zoom = Math.max(0, Math.min(ZOOMS.length - 1, zoom + step));
      centre(open, middle);
      render();
    },
    /* Centres the next grid line before or after the middle of the window. */
    step(direction) {
      const g = edit[open], period = 60000 / g.bpm;
      const beat = (windowAt[open].startMs + spanMs() / 2 - g.offset) / period;
      const next = direction > 0 ? Math.floor(beat + 0.001) + 1 : Math.ceil(beat - 0.001) - 1;
      centre(open, g.offset + next * period);
      refresh();
    },
    arm() { armed = !armed; render(); },
    tap() {
      const g = edit[open], now = performance.now();
      g.taps = g.taps.filter((time) => now - time < 2600);
      g.taps.push(now);
      g.taps = g.taps.slice(-8);
      if (g.taps.length >= 3) {
        const intervals = g.taps.slice(1).map((time, index) => time - g.taps[index]);
        const average = intervals.reduce((sum, value) => sum + value, 0) / intervals.length;
        if (average > 150) { g.bpm = Math.min(200, Math.max(60, 60000 / average)); g.confidence = 50; }
      }
      commit();
    },
    nudgeBpm(delta) { const g = edit[open]; g.bpm = Math.min(300, Math.max(40, g.bpm + delta)); commit(); },
    nudgeOffset(delta) { edit[open].offset += delta; windowAt[open].startMs += delta; commit(); },
    scale(factor) { const g = edit[open]; g.bpm = Math.min(300, Math.max(40, g.bpm * factor)); commit(); },
    /* Swap the grid for an alternate; the reading it replaces joins the list. */
    useAlt(n) {
      const g = edit[open], alt = ALTS[n];
      const previous = { bpm: g.bpm, offset: g.offset };
      g.bpm = alt.bpm; g.offset = alt.offset;
      ALTS[n] = previous;
      for (const entry of ALTS) entry.relation = relationOver(entry.bpm, g.bpm);
      commit();
    }
  };
})();
