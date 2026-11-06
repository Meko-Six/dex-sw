// node scripts/live-eval.mjs scripts/check-cue-start.js
// Check the exact scheduled cue input at several points in the master's beat.
// An isolated mixer leaves the user's loaded decks alone.
const liveEngine = window.__engine
const { MixEngine } = await import('/audio/engine.ts')
window.__engine = liveEngine
const engine = new MixEngine()
await engine.init(); await engine.resume()
engine.setMasterVolume(0)
const a = engine.getDeck(0), b = engine.getDeck(1)
const period = 60 / 124
const wait = ms => new Promise(resolve => setTimeout(resolve, ms))
const savedSync = localStorage.getItem('dex.sync')
const results = []
const recorderUrl = URL.createObjectURL(new Blob([`
  class CueAttackRecorder extends AudioWorkletProcessor {
    process(inputs) {
      const data = new Float32Array(inputs[0]?.[0] || 128);
      this.port.postMessage({time:currentTime, data}, [data.buffer]);
      return true;
    }
  }
  registerProcessor('cue-attack-recorder', CueAttackRecorder);
`], {type:'text/javascript'}))
await a.context.audioWorklet.addModule(recorderUrl)
URL.revokeObjectURL(recorderUrl)
const recorder = new AudioWorkletNode(a.context, 'cue-attack-recorder')
const sink = a.context.createGain(); sink.gain.value = 0
b.source.connect(recorder); recorder.connect(sink); sink.connect(a.context.destination)
let chunks = []
recorder.port.onmessage = e => chunks.push(e.data)
try {
  const bytes = await (await fetch('/@fs/' + projectRoot + '/fixtures/house-124.wav')).arrayBuffer()
  for (const index of [0, 1]) await engine.loadIntoDeck(index, {
    id: 'cue-origin-' + index, name: 'Cue origin check', bytes,
    grid: {bpm:124, offsetMs:0, confidence:1}
  })
  engine.sync(0); engine.sync(1)
  const schedules = [], schedule = b.source.schedule.bind(b.source)
  b.source.schedule = options => { schedules.push(options); return schedule(options) }
  for (const cue of [0, 8 * period]) {
    await engine.seek(1, cue); b.cuePoint = cue
    for (const phase of [0.05, 0.25, 0.5, 0.75, 0.9]) {
      await a.playAt(1, (4 + phase) * period)
      await wait(45)
      chunks = []
      await engine.cueDown(1)
      const command = schedules.filter(s => s.active && s.input !== undefined).at(-1)
      let error = (a.positionAt(command.output) - command.input) / period
      error -= Math.round(error)
      const cueOutput = command.output + (cue - command.input) / command.rate
      await wait(Math.max(0, cueOutput - a.context.currentTime) * 1000 + 100)
      let firstAttackMs = null
      if (cue === 0) {
        // Before the file starts, the lead-in must be silent. The first
        // audible attack must be the cue's own kick, not the following kick.
        const first = chunks.flatMap(chunk => {
          const index = chunk.data.findIndex((v, i) => chunk.time + i / a.context.sampleRate >= command.output && Math.abs(v) > 0.12)
          return index < 0 ? [] : [chunk.time + index / a.context.sampleRate]
        })[0]
        firstAttackMs = Number.isFinite(first) ? (first - cueOutput) * 1000 : null
      }
      results.push({cue, phase, input: command.input, advanceBeats: (command.input - cue) / period,
        firstAttackMs,
        phaseErrorMs: Math.abs(error) * period * 1000,
        pass: command.input <= cue + 1e-8 && Math.abs(error) * period < 0.002 &&
          // Identify the cue's own kick: allow the stretch node's startup
          // transient (up to ~30 ms), but never accept the next beat (~484 ms).
          (cue !== 0 || (firstAttackMs !== null && firstAttackMs > -15 && firstAttackMs < 40))})
      await engine.cueUp(1); await engine.pause(0); await wait(60)
    }
  }
  return {ok:results.every(r => r.pass), results}
} finally {
  await engine.stopAll(); clearInterval(engine.syncTimer)
  recorder.disconnect()
  engine.worker?.terminate(); await a.context.close()
  if (savedSync === null) localStorage.removeItem('dex.sync')
  else localStorage.setItem('dex.sync', savedSync)
}
