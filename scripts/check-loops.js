// node scripts/live-eval.mjs scripts/check-loops.js
// Each source beat has a different pitch. Identifying the recorded pitches
// proves the audio content repeats, which an identical click train cannot do.
const liveEngine = window.__engine
const { MixEngine } = await import('/audio/engine.ts')
window.__engine = liveEngine
const { FFT } = await import('/@fs/' + projectRoot + '/src/shared/fft.ts')
const engine = new MixEngine()
const savedSync=localStorage.getItem('dex.sync')
await engine.init(); await engine.resume(); engine.setMasterVolume(0)
const deck = engine.getDeck(0), context = deck.context, sr = context.sampleRate
const wait = ms => new Promise(resolve => setTimeout(resolve, ms))
const buffer = context.createBuffer(2, sr * 40, sr)
for (let c = 0; c < 2; c++) {
  const data = buffer.getChannelData(c)
  for (let beat = 0; beat < 80; beat++) {
    const at = Math.round(beat * 0.5 * sr), frequency = 440 + beat * 64
    for (let i = 0; i < sr * 0.14; i++) {
      const t = i / sr
      data[at+i] = Math.sin(2*Math.PI*frequency*t) * Math.exp(-t*18) * 0.7
    }
  }
}
const url = URL.createObjectURL(new Blob([`
class LoopRecorder extends AudioWorkletProcessor {
  process(inputs) {
    const data=new Float32Array(inputs[0]?.[0] || 128);
    this.port.postMessage({time:currentTime,data},[data.buffer]); return true;
  }
} registerProcessor('loop-recorder',LoopRecorder);
`], {type:'text/javascript'}))
await context.audioWorklet.addModule(url); URL.revokeObjectURL(url)
const recorder = new AudioWorkletNode(context,'loop-recorder')
const sink=context.createGain(); sink.gain.value=0
deck.source.connect(recorder); recorder.connect(sink); sink.connect(context.destination)
let chunks=[]
recorder.port.onmessage=e=>chunks.push(e.data)
const commands=[], schedule=deck.source.schedule.bind(deck.source)
deck.source.schedule = options => { commands.push(options); return schedule(options) }
const identify = from => {
  const selected=chunks.filter(c=>c.time>=from)
  if (!selected.length) return []
  const samples=new Float32Array(selected.length*128)
  selected.forEach((c,i)=>samples.set(c.data,i*128))
  const fft=new FFT(4096), events=[]
  let last=-sr
  for(let i=0;i<samples.length-5000;i++) {
    if (Math.abs(samples[i])<0.12 || i-last<sr*0.3) continue
    last=i
    const re=new Float64Array(4096),im=new Float64Array(4096)
    for(let j=0;j<4096;j++) re[j]=samples[i+Math.round(sr*0.01)+j]*(0.5-0.5*Math.cos(2*Math.PI*j/4095))
    fft.transform(re,im)
    let best=1,power=0
    for(let k=1;k<2048;k++) {
      const p=re[k]*re[k]+im[k]*im[k]
      if(p>power){power=p;best=k}
    }
    events.push({time:selected[0].time+i/sr,beat:Math.round((best*sr/4096-440)/64)})
  }
  return events
}
try {
  await deck.load(buffer,{id:'loop-content-test',name:'Distinct beat pitches',grid:{bpm:120,offsetMs:0,confidence:1},peaks:null})
  await engine.seek(0,4.23); await engine.play(0); await wait(180)
  engine.setLoopSize(0,4); await engine.toggleLoop(0)
  const region={...deck.loopRegion}
  const command=commands.at(-1)
  await wait(4700)
  const events=identify(command.output+0.15)
  const valid = (events, region, min=4) => events.length>=min && events.every((event,i)=>event.beat>=region.startBeat && event.beat<region.startBeat+region.lengthBeats &&
    (i===0 || event.beat===region.startBeat+((events[i-1].beat-region.startBeat+1)%region.lengthBeats)))
  const results=[{label:'loop while playing',pass:valid(events,region,7),region,command,position:deck.position,events}]
  engine.moveLoop(0,region.startBeat+3)
  let movedFrom=context.currentTime+0.35;await wait(3500)
  let movedEvents=identify(movedFrom)
  results.push({label:'move playing loop forward three beats',pass:valid(movedEvents,deck.loopRegion,5),region:{...deck.loopRegion},events:movedEvents})
  engine.moveLoop(0,deck.loopRegion.startBeat-2)
  movedFrom=context.currentTime+0.35;await wait(3500)
  movedEvents=identify(movedFrom)
  results.push({label:'move playing loop backward two beats',pass:valid(movedEvents,deck.loopRegion,5),region:{...deck.loopRegion},events:movedEvents})
  const other=engine.getDeck(1)
  await other.load(buffer,{id:'loop-master',name:'Master',grid:{bpm:120,offsetMs:0,confidence:1},peaks:null})
  await engine.play(1); engine.setMaster(1); engine.sync(0); engine.setTempoRate(1,1.08)
  let from=context.currentTime+0.3; await wait(4300)
  let current=identify(from)
  results.push({label:'synced loop after tempo change',pass:valid(current,deck.loopRegion),region:{...deck.loopRegion},events:current})
  engine.stepLoopSize(0,-1); from=context.currentTime+0.4; await wait(2800)
  current=identify(from)
  results.push({label:'halve running loop',pass:valid(current,deck.loopRegion),region:{...deck.loopRegion},events:current})
  engine.stepLoopSize(0,1); engine.stepLoopSize(0,1); from=context.currentTime+0.5; await wait(4900)
  current=identify(from)
  results.push({label:'extend running loop',pass:valid(current,deck.loopRegion),region:{...deck.loopRegion},events:current})
  await engine.stopAll(); await engine.exitLoop(0); await engine.seek(0,0)
  engine.setLoopSize(0,1); await engine.toggleLoop(0)
  await engine.play(1); await engine.cueDown(0); engine.continueCue(0); await engine.cueUp(0)
  from=context.currentTime+0.6; await wait(2900)
  current=identify(from)
  results.push({label:'loop armed while paused, then synced CUE-to-PLAY',pass:valid(current,deck.loopRegion),region:{...deck.loopRegion},events:current})
  await engine.stopAll(); await engine.exitLoop(0); await engine.seek(0,4.01)
  await engine.play(0); engine.setLoopSize(0,8); await engine.toggleLoop(0)
  const expected=deck.positionAt(context.currentTime+0.03)+1
  const pendingStart=deck.loopRegion.startBeat
  engine.moveLoop(0,pendingStart+2)
  const pendingCommand=commands.at(-1)
  results.push({label:'move a loop before its quantized entry lands',pass:Math.abs(pendingCommand.input-expected)<0.005 && deck.loopRegion.startBeat===pendingStart+2,
    expectedInput:expected,input:pendingCommand.input,region:{...deck.loopRegion}})
  return {ok:results.every(r=>r.pass),results}
} finally {
  await engine.stopAll(); clearInterval(engine.syncTimer); engine.worker?.terminate()
  recorder.disconnect(); await context.close()
  if(savedSync===null)localStorage.removeItem('dex.sync');else localStorage.setItem('dex.sync',savedSync)
}
