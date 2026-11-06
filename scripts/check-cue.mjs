// With empty decks in a running dev app:
// node scripts/check-cue.mjs (npm run dev -- --remoteDebuggingPort 9222)
// Real Chromium input tests pointer capture, synthetic clicks and touch cancel.
import { fileURLToPath } from 'node:url'

const root = fileURLToPath(new URL('../', import.meta.url)).replace(/\/$/, '')
const targets = await (await fetch('http://127.0.0.1:9222/json')).json()
const page = targets.find(t => t.type === 'page' && t.url.includes('5173'))
if (!page) throw new Error('Open the Dex dev app with debugging on :9222')
const ws = new WebSocket(page.webSocketDebuggerUrl)
await new Promise(resolve => ws.addEventListener('open', resolve))
let id = 0
const call = (method, params = {}) => new Promise((resolve, reject) => {
  const request = ++id
  const receive = event => {
    const response = JSON.parse(event.data)
    if (response.id !== request) return
    ws.removeEventListener('message', receive)
    if (response.error) reject(new Error(JSON.stringify(response.error)))
    else resolve(response.result)
  }
  ws.addEventListener('message', receive)
  ws.send(JSON.stringify({id: request, method, params}))
})
const evaluate = async expression => {
  const result = await call('Runtime.evaluate', {expression, awaitPromise: true, returnByValue: true, userGesture: true})
  if (result.exceptionDetails) throw new Error(JSON.stringify(result.exceptionDetails))
  return result.result.value
}
const wait = ms => new Promise(resolve => setTimeout(resolve, ms))
const assert = (condition, label) => { if (!condition) throw new Error(label) }
const mouse = (type, point, buttons = 0) => call('Input.dispatchMouseEvent', {
  type, x: point.x, y: point.y, buttons,
  button: buttons || type !== 'mouseMoved' ? 'left' : 'none',
  ...(type === 'mouseMoved' ? {} : {clickCount: 1})
})
const touch = (type, point) => call('Input.dispatchTouchEvent', {
  type, touchPoints: point ? [{id: 1, x: point.x, y: point.y}] : []
})
const state = () => evaluate(`(() => {
  const a = window.__engine.getDeck(0), b = window.__engine.getDeck(1);
  const when = a.context.currentTime + 0.04;
  let phase = a.positionAt(when) * a.grid.bpm / 60 - b.positionAt(when) * b.grid.bpm / 60;
  phase -= Math.round(phase);
  return {playing: b.isPlaying, previewing: b.previewing, position: b.position,
    cue: b.cuePoint, phaseMs: Math.abs(phase) * 60000 / a.grid.bpm,
    schedules: window.__cueSchedules.length,
    playLabel: document.querySelector('.bay.b .big.play').getAttribute('aria-label')};
})()`)
const reset = () => evaluate('(async () => { await window.__engine.cueDown(1); await window.__engine.cueUp(1); })()')
const results = []
let savedSync
try {
  const occupied = await evaluate('window.__engine?.getSnapshot().decks.some(d => d.trackId)')
  assert(!occupied, 'Use an empty test window; existing tracks will not be replaced')
  // Start with a fresh singleton after any module hot reloads.
  await call('Page.reload')
  await wait(900)
  savedSync = await evaluate('localStorage.getItem("dex.sync")')
  await evaluate(`(async () => {
    const engine = window.__engine;
    await engine.init(); await engine.resume();
    const {renderClicks} = await import(${JSON.stringify('/@fs/' + root + '/src/shared/synth.ts')});
    for (const [index, bpm] of [[0, 120], [1, 128]]) {
      const samples = renderClicks(bpm, 60, 48000);
      const bytes = new ArrayBuffer(44 + samples.length * 4), view = new DataView(bytes);
      const tag = (at, text) => [...text].forEach((c,i) => view.setUint8(at+i, c.charCodeAt(0)));
      tag(0,'RIFF'); view.setUint32(4, bytes.byteLength-8, true); tag(8,'WAVE');
      tag(12,'fmt '); view.setUint32(16,16,true); view.setUint16(20,3,true); view.setUint16(22,1,true);
      view.setUint32(24,48000,true); view.setUint32(28,192000,true); view.setUint16(32,4,true);
      view.setUint16(34,32,true); tag(36,'data'); view.setUint32(40,samples.length*4,true);
      new Float32Array(bytes,44).set(samples);
      await engine.loadIntoDeck(index, {id:'cue-test-'+index, name:'CUE test', bytes,
        grid:{bpm, offsetMs:0, confidence:1}});
    }
    engine.sync(0); engine.sync(1); engine.setMasterVolume(0);
    window.__cueSchedules = [];
    const source = engine.getDeck(1).source, schedule = source.schedule.bind(source);
    source.schedule = options => { window.__cueSchedules.push(options); return schedule(options); };
    window.__cuePointerEvents = [];
    for (const type of ['pointerdown','pointermove','pointerup','pointercancel','gotpointercapture','lostpointercapture']) {
      document.addEventListener(type, e => window.__cuePointerEvents.push({type, id:e.pointerId, buttons:e.buttons, button:e.button, target:e.target.className, x:e.clientX, y:e.clientY}), true);
    }
    await engine.play(0);
  })()`)
  const points = await evaluate(`(() => {
    const point = selector => { const r = document.querySelector(selector).getBoundingClientRect(); return {x:r.x+r.width/2, y:r.y+r.height/2}; };
    return {cue:point('.bay.b .big.cue'), play:point('.bay.b .big.play')};
  })()`)
  for (const delay of [85, 15, 110]) {
    await mouse('mousePressed', points.cue, 1); await wait(delay)
    const held = await state()
    assert(held.playing && held.previewing && held.phaseMs < 2, 'CUE tap must preview on the master beat: ' + JSON.stringify(held))
    assert(held.playLabel === 'Deck B play', 'PLAY must offer continuation during a preview')
    await mouse('mouseReleased', points.cue); await wait(60)
    const released = await state()
    assert(!released.playing && !released.previewing && Math.abs(released.position-released.cue) < 1e-6, 'CUE release must return to cue')
    await wait(137)
  }
  results.push('Repeated CUE taps snap to the beat and return to cue')

  await mouse('mousePressed', points.cue, 1); await wait(90)
  const before = await state()
  await mouse('mouseMoved', points.play, 1)
  const latched = await state()
  assert(latched.playing && !latched.previewing && before.schedules === latched.schedules, 'Slide must latch without rescheduling audio: ' + JSON.stringify({before, latched, points, events:await evaluate('window.__cuePointerEvents.slice(-12)')}))
  await mouse('mouseReleased', points.play); await wait(90)
  assert((await state()).playing, 'Synthetic click after sliding must not pause playback')
  results.push('Mouse CUE-to-PLAY slide continues uninterrupted after release')
  await reset(); await wait(60)

  await mouse('mousePressed', points.cue, 1); await wait(90)
  await evaluate('document.querySelector(".bay.b .big.play").click()')
  await mouse('mouseReleased', points.cue); await wait(60)
  assert((await state()).playing && !(await state()).previewing, 'PLAY during held CUE must latch')
  results.push('Pressing PLAY while holding CUE keeps playback running')
  await reset(); await wait(60)

  await call('Emulation.setTouchEmulationEnabled', {enabled: true})
  await touch('touchStart', points.cue); await wait(90)
  await touch('touchCancel'); await wait(60)
  assert(!(await state()).playing, 'Cancelled touch must stop a preview')
  results.push('Touch cancellation returns to cue')
  await touch('touchStart', points.cue); await wait(90)
  const touchBefore = await state()
  await touch('touchMove', points.play)
  const touchAfter = await state()
  assert(touchAfter.playing && !touchAfter.previewing && touchBefore.schedules === touchAfter.schedules, 'Touch slide must latch without rescheduling')
  await touch('touchEnd'); await wait(90)
  assert((await state()).playing, 'Touch release after sliding must keep playing')
  results.push('Touch CUE-to-PLAY slide continues uninterrupted after release')
  await reset(); await wait(60)
  await touch('touchStart', points.cue); await wait(90)
  const twoBefore = await state()
  const finger = (id, p) => ({id, x:p.x, y:p.y})
  await call('Input.dispatchTouchEvent', {type:'touchStart', touchPoints:[finger(1, points.cue), finger(2, points.play)]})
  assert((await state()).playing && !(await state()).previewing, 'A second finger on PLAY must immediately latch CUE')
  await call('Input.dispatchTouchEvent', {type:'touchEnd', touchPoints:[finger(1, points.cue)]})
  await touch('touchEnd'); await wait(90)
  const twoAfter = await state()
  assert(twoAfter.playing && !twoAfter.previewing && twoBefore.schedules === twoAfter.schedules, 'Releasing both fingers must keep uninterrupted playback')
  results.push('Two-finger CUE hold plus PLAY press latches without stopping on release')
  await call('Emulation.setTouchEmulationEnabled', {enabled:false})
  await evaluate('window.__engine.stopAll()')
  for (const [width, height] of [[1174, 814], [880, 610]]) {
    await call('Emulation.setDeviceMetricsOverride', {width, height, deviceScaleFactor:1, mobile:false})
    await wait(80)
    for (const [index, side, bpm] of [[0,'a',120], [1,'b',128]]) {
      await evaluate(`window.__engine.seek(${index}, 10.123)`)
      const p = await evaluate(`(() => {
        const r = document.querySelector('.bay.${side} .platter').getBoundingClientRect();
        const x = r.x+r.width/2, y = r.y+r.height/2, radius = r.width*0.38;
        return {top:{x,y:y-radius}, right:{x:x+radius,y}};
      })()`)
      await mouse('mousePressed', p.top, 1)
      await mouse('mouseMoved', p.right, 1)
      await mouse('mouseReleased', p.right)
      const forward = await evaluate(`window.__engine.getDeck(${index}).position`)
      assert(Math.abs(forward - 10.123 - 30/bpm) < 0.001, 'Quarter-turn must move half a beat at every window size')
      await mouse('mousePressed', p.right, 1)
      await mouse('mouseMoved', p.top, 1)
      await mouse('mouseReleased', p.top)
      const back = await evaluate(`window.__engine.getDeck(${index}).position`)
      assert(Math.abs(back-10.123) < 0.001, 'Reverse quarter-turn must return by half a beat')
    }
  }
  results.push('Platter quarter-turns move half a beat in both directions at 120/128 BPM and two window sizes')
  await evaluate('window.__engine.seek(1, 10.123)')
  const circle = await evaluate(`(() => {
    const r=document.querySelector('.bay.b .platter').getBoundingClientRect();
    const x=r.x+r.width/2,y=r.y+r.height/2,rad=r.width*.38;
    return Array.from({length:9}, (_,i) => ({x:x+rad*Math.cos(-Math.PI/2+i*Math.PI/4),y:y+rad*Math.sin(-Math.PI/2+i*Math.PI/4)}));
  })()`)
  await mouse('mousePressed', circle[0], 1)
  await mouse('mouseMoved', circle[2], 1); await wait(50)
  await mouse('mouseMoved', circle[0], 1)
  await mouse('mouseReleased', circle[0])
  assert(Math.abs(await evaluate('window.__engine.getDeck(1).position')-10.123) < 0.001, 'Reversing within one drag must return to the starting position')
  await mouse('mousePressed', circle[0], 1)
  for (const point of circle.slice(1)) await mouse('mouseMoved', point, 1)
  await mouse('mouseReleased', circle[8])
  assert(Math.abs(await evaluate('window.__engine.getDeck(1).position')-10.123-120/128) < 0.001, 'A full turn must retain all movement across throttled pointer events')
  results.push('Platter reversal and a full circular turn retain exact movement')
  await evaluate('window.__engine.seek(1, 10.123)')
  await call('Emulation.setTouchEmulationEnabled', {enabled:true})
  await touch('touchStart', circle[0]); await touch('touchMove', circle[2]); await touch('touchEnd')
  assert(Math.abs(await evaluate('window.__engine.getDeck(1).position')-10.123-30/128) < 0.001, 'A touch quarter-turn must move half a beat')
  await call('Emulation.setTouchEmulationEnabled', {enabled:false})
  results.push('Touch platter quarter-turn moves half a beat')
  // A playing SYNC deck must retain the fine manual position rather than
  // immediately rounding the jog to a whole beat.
  await evaluate('(async () => { await window.__engine.play(0); await window.__engine.play(1); })()')
  const jog = await evaluate(`(() => {
    const r=document.querySelector('.bay.b .platter').getBoundingClientRect();
    const x=r.x+r.width/2,y=r.y+r.height/2,rad=r.width*.38;
    window.__jogStart=null;
    document.querySelector('.bay.b .platter').addEventListener('pointerdown', () => window.__jogStart=window.__engine.getDeck(1).position, {once:true, capture:true});
    return {top:{x,y:y-rad},right:{x:x+rad,y}};
  })()`)
  await mouse('mousePressed', jog.top, 1)
  await mouse('mouseMoved', jog.right, 1)
  await mouse('mouseReleased', jog.right)
  const fine = await evaluate(`(() => {
    const command=window.__cueSchedules.filter(s => s.active && s.input !== undefined).at(-1);
    return {delta:command.input-window.__jogStart, sync:window.__engine.getDeck(1).syncLocked};
  })()`)
  assert(fine.sync && Math.abs(fine.delta-30/128) < 0.015, 'Playing platter jog must preserve half-beat movement with SYNC armed')
  results.push('Playing platter retains fractional-beat movement with SYNC armed')
  const displayState = () => evaluate(`(() => {
    const root=document.querySelector('.bay.b .platter-display');
    return {gap:root.querySelector('.platter-gap').style.transform,
      ticks:[...root.querySelectorAll('.platter-ticks path')].map(p=>p.getAttribute('transform'))};
  })()`)
  const lit = await displayState(); await wait(160)
  const rotating = await displayState()
  assert(lit.ticks.length === 40 && JSON.stringify(lit.ticks) === JSON.stringify(rotating.ticks), 'Radial lines must remain fixed')
  assert(lit.gap !== rotating.gap, 'The missing-line gap must move with playback')
  await evaluate('window.__engine.pause(1)'); await wait(90)
  const pausedDisplay = await displayState(); await wait(160)
  assert(pausedDisplay.gap === (await displayState()).gap, 'The missing-line gap must stop when paused')
  results.push('Center display keeps radial lines fixed, moves its gap during playback and freezes on pause')
  console.log(JSON.stringify({ok:true, results}, null, 2))
} finally {
  await mouse('mouseReleased', {x:0, y:0}).catch(() => {})
  await call('Emulation.setTouchEmulationEnabled', {enabled: false}).catch(() => {})
  await call('Emulation.clearDeviceMetricsOverride').catch(() => {})
  if (savedSync !== undefined) await evaluate(`(async () => {
    await window.__engine.stopAll();
    await window.__engine.getDeck(0).unload(); await window.__engine.getDeck(1).unload();
    if (${JSON.stringify(savedSync)} === null) localStorage.removeItem('dex.sync');
    else localStorage.setItem('dex.sync', ${JSON.stringify(savedSync)});
    window.__engine.setMasterVolume(0.85); window.__engine.commit();
  })()`).catch(() => {})
  if (savedSync !== undefined) await call('Page.reload').catch(() => {})
  ws.close()
}
