// Run in the real Electron renderer: node scripts/live-eval.mjs scripts/check-sync.js
// Uses an isolated mixer and measures its output, rather than its position clock.
const liveEngine = window.__engine
const { MixEngine } = await import('/audio/engine.ts')
window.__engine = liveEngine
const { renderClicks } = await import('/@fs/' + projectRoot + '/src/shared/synth.ts')
const { bandFrames, locateKick } = await import('/@fs/' + projectRoot + '/src/shared/grid-refine.ts')
const engine = new MixEngine()
await engine.init()
await engine.resume()
const a = engine.getDeck(0), b = engine.getDeck(1), context = a.context
engine.setMasterVolume(0)
const wait = ms => new Promise(resolve => setTimeout(resolve, ms))
const wav = (samples, sr) => {
  const bytes = new ArrayBuffer(44 + samples.length * 4), view = new DataView(bytes)
  const tag = (at, s) => [...s].forEach((c, i) => view.setUint8(at + i, c.charCodeAt(0)))
  tag(0, 'RIFF'); view.setUint32(4, bytes.byteLength - 8, true); tag(8, 'WAVE')
  tag(12, 'fmt '); view.setUint32(16, 16, true); view.setUint16(20, 3, true)
  view.setUint16(22, 1, true); view.setUint32(24, sr, true); view.setUint32(28, sr * 4, true)
  view.setUint16(32, 4, true); view.setUint16(34, 32, true); tag(36, 'data')
  view.setUint32(40, samples.length * 4, true); new Float32Array(bytes, 44).set(samples)
  return bytes
}
const recorderSource = `class SyncRecorder extends AudioWorkletProcessor {
  process(inputs) {
    this.port.postMessage({time: currentTime, channels: inputs.map(i => new Float32Array(i[0] || 128))});
    return true;
  }
} registerProcessor('sync-recorder', SyncRecorder)`
const url = URL.createObjectURL(new Blob([recorderSource], {type: 'text/javascript'}))
await context.audioWorklet.addModule(url)
URL.revokeObjectURL(url)
const recorder = new AudioWorkletNode(context, 'sync-recorder', {numberOfInputs: 2})
const silent = context.createGain(); silent.gain.value = 0
recorder.connect(silent); silent.connect(context.destination)
a.source.connect(recorder, 0, 0); b.source.connect(recorder, 0, 1)
let chunks = []
recorder.port.onmessage = e => chunks.push(e.data)
const report = (label, start) => {
  const onsets = [[], []], sr = context.sampleRate
  for (const chunk of chunks) {
    if (chunk.time < start + 0.4) continue
    chunk.channels.forEach((data, ch) => {
      for (let i = 0; i < data.length; i++) {
        const time = chunk.time + i / sr
        if (Math.abs(data[i]) > 0.12 && time - (onsets[ch].at(-1) ?? -1) > 0.3) onsets[ch].push(time)
      }
    })
  }
  const errors = onsets[1].map(t => Math.min(...onsets[0].map(u => Math.abs(t-u))) * 1000).filter(x => x < 250)
  const sorted = [...errors].sort((a,b) => a-b)
  const phase = (deck) => (deck.position - deck.grid.offsetMs / 1000) * deck.grid.bpm / 60
  const result = {label, beats: errors.length, medianMs: sorted[Math.floor(sorted.length/2)], worstMs: Math.max(...errors), clockErrorMs: Math.abs(((phase(a) - phase(b) + 0.5) % 1 + 1) % 1 - 0.5) * 60000 / (a.grid.bpm * a.rate)}
  result.pass = errors.length >= 5 && result.worstMs < 15 && result.clockErrorMs < 2
  chunks = []
  return result
}
const savedSync = localStorage.getItem('dex.sync')
const results = []
try {
  for (const [i, bpm] of [[0, 120], [1, 128]]) await engine.loadIntoDeck(i, {
    id: 'sync-check-' + i, name: 'Sync clicks', bytes: wav(renderClicks(bpm, 90, context.sampleRate), context.sampleRate),
    grid: {bpm, offsetMs: 0, confidence: 1}
  })
  engine.sync(0); engine.sync(1)
  await engine.togglePlay(0)
  // Start near 0 with a negative nearest-phase correction: it must not clamp off-beat.
  while (a.position % 0.5 < 0.31 || a.position % 0.5 > 0.36) await wait(5)
  let start = context.currentTime
  await engine.togglePlay(1); await wait(3500)
  results.push(report('start from zero', start))
  await engine.pause(1); await engine.seek(1, 8.1); engine.unsync(1)
  engine.setTempoRate(1, 1)
  await engine.togglePlay(1); await wait(600)
  engine.sync(1); start = context.currentTime; await wait(3500)
  results.push(report('SYNC during playback', start))
  engine.setTempoRate(0, 1.08); start = context.currentTime; await wait(5000)
  results.push(report('master tempo changed', start))
  await engine.cueDown(1); await engine.cueUp(1); await wait(100)
  start = context.currentTime; await engine.cueDown(1); await wait(3500)
  results.push(report('CUE preview', start))
  start = context.currentTime; engine.continueCue(1); await engine.cueUp(1); await wait(3500)
  results.push(report('CUE latched into playback', start))
  await engine.cueDown(1)
  await engine.cueUp(1); await wait(100)
  start = context.currentTime; await engine.play(1); await wait(3500)
  results.push(report('restart after CUE', start))
  start = context.currentTime; await engine.setLoopBars(1, 1); await wait(4500)
  results.push(report('one-bar loop', start))
  start = context.currentTime; engine.beatJump(1, 1); await wait(3500)
  results.push(report('beat jump inside loop', start))
  start = context.currentTime; await engine.exitLoop(1); await wait(3500)
  results.push(report('exit loop', start))
  await engine.triggerHotCue(1, 0)
  start = context.currentTime; await engine.seek(1, 40.137); await wait(3500)
  results.push(report('seek while SYNC is on', start))
  start = context.currentTime; await engine.triggerHotCue(1, 0); await wait(3500)
  results.push(report('hot cue while SYNC is on', start))
  // Use the user's music too: fresh analysis, playback, then folded kick
  // attacks in the recorded output. No library entries are changed.
  await engine.stopAll()
  const manifest = await (await fetch('/@fs/' + projectRoot + '/accuracy/manifest.json')).json()
  const music = ['8746648_Warehouse_Trip_Original_Mix', '8757915_Traffic_Original_Mix']
  const analyzed = []
  for (const [index, id] of music.entries()) {
    const entry = manifest.tracks.find(track => track.id === id)
    const bytes = await window.dex.readFile(projectRoot + '/accuracy/' + entry.file)
    const analysis = await engine.analyze(bytes)
    const grid = {bpm: analysis.bpm, offsetMs: analysis.offsetMs, confidence: analysis.confidence}
    analyzed.push({id, ...grid})
    await engine.loadIntoDeck(index, {id, name: id, bytes, grid})
    await engine.seek(index, entry.truth.downbeatsSec[0] + 0.13)
  }
  engine.setTempoRate(0, 1)
  engine.sync(0); engine.sync(1)
  await engine.play(0); await wait(770); await engine.play(1)
  start = context.currentTime; chunks = []; await wait(12000)
  const bpm = a.grid.bpm * a.rate, period = 60 / bpm
  const windows = []
  for (const [from, to] of [[1, 5], [7, 11]]) {
    const selected = chunks.filter(c => c.time >= start + from && c.time < start + to)
    const kicks = [0, 1].map(ch => {
      const samples = new Float32Array(selected.length * 128)
      selected.forEach((c, i) => samples.set(c.channels[ch], i * 128))
      return locateKick(bandFrames(samples, context.sampleRate), bpm)
    })
    let error = (kicks[0].offsetSec - kicks[1].offsetSec) / period
    error -= Math.round(error)
    windows.push({from, to, beats: selected.length * 128 / context.sampleRate / period, alignmentMs: Math.abs(error) * period * 1000, contrast: kicks.map(k => k.contrast)})
  }
  results.push({label: 'real music: Warehouse Trip + Traffic', analyzed, windows, pass: windows.every(w => w.beats >= 5 && w.alignmentMs < 15 && w.contrast.every(c => c > 2))})
  return {ok: results.every(r => r.pass), results}
} finally {
  await engine.stopAll()
  clearInterval(engine.syncTimer)
  engine.worker?.terminate()
  recorder.disconnect()
  await context.close()
  if (savedSync === null) localStorage.removeItem('dex.sync')
  else localStorage.setItem('dex.sync', savedSync)
}
