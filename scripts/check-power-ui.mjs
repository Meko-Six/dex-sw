// Isolated integration/render check. Needs npm run dev:renderer on :5299.
// node_modules/.bin/electron scripts/check-power-ui.mjs
import { app, BrowserWindow } from 'electron'
import { mkdirSync, writeFileSync } from 'node:fs'
import { resolve } from 'node:path'

const out = resolve('out/power-ui-check')
mkdirSync(resolve(out, 'profile'), { recursive: true })
app.setPath('userData', resolve(out, 'profile'))
app.commandLine.appendSwitch('autoplay-policy', 'no-user-gesture-required')
async function run() {
  const win = new BrowserWindow({ show: true, width: 1174, height: 814, useContentSize: true, title: 'Dex — energy check', webPreferences: { backgroundThrottling: false } })
  const errors = []
  win.webContents.on('console-message', (details) => { if (['warning','error'].includes(details.level) && !details.message.includes('Electron Security Warning')) errors.push(details.message) })
  const wait = ms => new Promise(r => setTimeout(r, ms))
  const results = []
  const check = (ok, message) => { if (!ok) throw new Error(message) }
  try {
    const watchdog=setTimeout(()=>{console.error('Energy check timed out');app.exit(1)},90000);watchdog.unref();
    await win.loadURL('http://127.0.0.1:5299/')
    win.webContents.debugger.attach('1.3')
    const evaluate = async expression => {
      const r = await win.webContents.debugger.sendCommand('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true, userGesture: true })
      if (r.exceptionDetails) throw new Error(JSON.stringify(r.exceptionDetails))
      return r.result.value
    }
    await evaluate(`(async()=>{
      localStorage.clear();
      const e=window.__engine;await e.init();await e.resume();e.setMasterVolume(0);
      // Use the exact import URLs held by the UI, including Vite HMR stamps.
      const chassis=await(await fetch('/console/Chassis.tsx')).text();
      const libraryURL=chassis.match(/import\\s*\\{\\s*useLibrary\\s*\\}\\s*from\\s*["']([^"']+)/)[1];
      const stateURL=chassis.match(/import\\s*\\{\\s*useConsole\\s*\\}\\s*from\\s*["']([^"']+)/)[1];
      window.__lib=(await import(libraryURL)).useLibrary;
      window.__consoleState=(await import(stateURL)).useConsole;
      window.__engine=e;
      window.__lib.setState({tracks:[],playlists:[],error:null});
      window.__initialThreeBand=!window.__consoleState.getState().energyEnabled;
      if(!window.__consoleState.getState().energyEnabled)window.__consoleState.getState().toggleEnergy();
    })()`)
    const imported = await evaluate(`(async()=>{
      const bytes=await(await fetch('/@fs/'+${JSON.stringify(resolve('.'))}+'/fixtures/house-124.wav')).arrayBuffer();
      await window.__lib.getState().addDroppedFiles([new File([bytes],'power-import.wav')],0);
      const t=window.__lib.getState().tracks[0];window.__importId=t.id;
      return {power:!!t.power,version:t.power?.version,lufs:t.lufs,gain:t.gainDb,loaded:!!window.__engine.getSnapshot().decks[0].power,cached:window.__engine.getDeck(0).power===t.power};
    })()`)
    check(imported.power && imported.loaded && imported.cached && Number.isFinite(imported.lufs), 'Normal import must analyze and load cached energy/loudness')
    results.push({ normalImport: imported });console.log('Normal import passed')
    const reanalyzed = await evaluate(`(async()=>{
      const lib=window.__lib;const t=lib.getState().tracks[0];
      lib.setState({tracks:[{...t,power:{...t.power,version:-1}}]});
      await lib.getState().reanalyze(lib.getState().tracks[0]);
      const updated=lib.getState().tracks[0];
      return {version:updated.power.version,loaded:window.__engine.getSnapshot().decks[0].power===updated.power,saved:JSON.parse(localStorage.getItem('dex.library')).tracks[0].power.version};
    })()`)
    check(reanalyzed.version === 1 && reanalyzed.loaded && reanalyzed.saved === 1, 'Re-analysis must replace and persist curve on a loaded deck')
    results.push({ reanalysis: reanalyzed });console.log('Re-analysis passed')
    await evaluate(`(async()=>{
      const root=${JSON.stringify(resolve('.'))};
      window.__legacyIds=[];
      const tracks=[
        {id:'power-solace',name:'Solace — Original Mix',file:'accuracy/audio/Techno/8556621_Solace_Original_Mix.mp3',bpm:126},
        {id:'power-dark-rooms',name:'Dark Rooms — Original Mix',file:'accuracy/audio/Techno/7585933_Dark_Rooms_Original_Mix.mp3',bpm:124}
      ];
      for(const [i,t]of tracks.entries()){
        const bytes=await(await fetch('/@fs/'+root+'/'+t.file)).arrayBuffer();
        const filename=t.id+'.mp3';let hash=0x811c9dc5;
        for(let j=0;j<filename.length;j++){hash^=filename.charCodeAt(j);hash=Math.imul(hash,0x01000193)>>>0}
        const id=hash.toString(16).padStart(8,'0');window.__legacyIds.push(id);
        const meta={...t,id,durationSec:1,offsetMs:0,confidence:1,peaks:[],analyzedAt:''};
        window.__lib.setState({tracks:[...window.__lib.getState().tracks,meta]});
        await window.__lib.getState().addDroppedFiles([new File([bytes],filename)],i);
        if(i===0){await window.__engine.play(0);window.__backfillStart=window.__engine.getDeck(0).position;}
      }
    })()`)
    const deadline = Date.now() + 30000
    let backfill
    do {
      await wait(200)
      backfill = await evaluate(`window.__engine.getSnapshot().decks.map(d=>({id:d.trackId,power:!!d.power,levels:!!d.levels}))`)
    } while (backfill.some(d => !d.power || !d.levels) && Date.now() < deadline)
    check(backfill.every(d => d.power && d.levels), 'Legacy decks must receive energy and fine waveform after load: '+JSON.stringify({backfill,library:await evaluate('window.__lib.getState().error')}))
    const saved = await evaluate(`(()=>{const tracks=JSON.parse(localStorage.getItem('dex.library')).tracks;return tracks.filter(t=>window.__legacyIds.includes(t.id)).map(t=>({id:t.id,power:!!t.power,lufs:t.lufs}))})()`)
    check(saved.length === 2 && saved.every(t => t.power && Number.isFinite(t.lufs)), 'Backfill must persist for older library tracks')
    const stable=await evaluate(`(async()=>{
      const e=window.__engine,a=e.getDeck(0);const state={playing:a.isPlaying,advanced:a.position-window.__backfillStart,trim:a.gainTrimDb};await e.pause(0);return state;
    })()`)
    check(stable.playing && stable.advanced>0.2 && stable.trim===0, 'Background analysis must allow playback and keep old-track trim at unity')
    results.push({ legacyBackfill: { decks: backfill, saved, stable } });console.log('Legacy backfill passed')
    // Test the actual shader and the 2D fallback against the same known curve.
    const render = await evaluate(`(async()=>{
      const {WaveformRenderer,drawWaveform2D}=await import('/ui/waveform-gl.ts');
      const {buildWaveformLevels}=await import('/@fs/'+${JSON.stringify(resolve('.'))}+'/src/shared/waveform-levels.ts');
      const {energyColour,powerAt}=await import('/@fs/'+${JSON.stringify(resolve('.'))}+'/src/shared/power.ts');
      const samples=new Float32Array(8000);for(let i=0;i<samples.length;i++)samples[i]=i%2?0.8:-0.8;
      const levels=buildWaveformLevels([samples],8000);
      const power={version:1,durationSec:1,startSec:0,barSec:0.5,values:[0,1],score:50,gainDb:0};
      const paint={peak:[0,1,0,1],rms:[0,1,0,1],peakPlayed:[0,1,0,1],rmsPlayed:[0,1,0,1],line:[0,0,0,0]};
      const frame={startCol:0,samplesPerPixel:8000/128,playSample:0,amp:1,paint,power};
      const gpu=document.createElement('canvas');gpu.width=128;gpu.height=64;
      const renderer=WaveformRenderer.create(gpu);if(!renderer)throw Error('WebGL2 unavailable');renderer.setLevels(levels);renderer.draw(frame);
      const gl=gpu.getContext('webgl2');const gpuPixels=new Uint8Array(128*64*4);gl.readPixels(0,0,128,64,gl.RGBA,gl.UNSIGNED_BYTE,gpuPixels);
      const cpu=document.createElement('canvas');cpu.width=128;cpu.height=64;cpu.getContext('2d',{willReadFrequently:true});drawWaveform2D(cpu.getContext('2d'),levels,frame);
      const cpuPixels=cpu.getContext('2d').getImageData(0,0,128,64).data;
      const readings=[10,48,78,116].map(x=>{
        const expected=energyColour(powerAt(power,(x+0.5)/128)).map(v=>Math.round(v*255));
        return {x,expected,gpu:[...gpuPixels.slice((32*128+x)*4,(32*128+x)*4+3)],cpu:[...cpuPixels.slice((32*128+x)*4,(32*128+x)*4+3)]};
      });
      renderer.draw({...frame,power:null});const off=new Uint8Array(4);gl.readPixels(10,32,1,1,gl.RGBA,gl.UNSIGNED_BYTE,off);
      // Same input column, moved across the playhead: all modes keep brightness.
      renderer.draw({...frame,playSample:8000});const played=new Uint8Array(4);gl.readPixels(48,32,1,1,gl.RGBA,gl.UNSIGNED_BYTE,played);
      const before=readings.find(r=>r.x===48).gpu;
      // Independently controlled bands verify the layered geometry on both backends.
      for(const level of levels.levels)for(let i=0;i<level.count;i++)level.bands.set([180,80,20,0],i*4);
      renderer.setLevels(null);renderer.setLevels(levels);
      const bandsFrame={...frame,power:null,threeBand:true,playSample:4000};
      renderer.draw(bandsFrame);drawWaveform2D(cpu.getContext('2d'),levels,bandsFrame);
      const bandsCPU=cpu.getContext('2d').getImageData(0,0,128,64).data;
      const bandReadings=[32,43,55].map(y=>{
        const a=new Uint8Array(4),b=new Uint8Array(4);
        gl.readPixels(10,y,1,1,gl.RGBA,gl.UNSIGNED_BYTE,a);gl.readPixels(100,y,1,1,gl.RGBA,gl.UNSIGNED_BYTE,b);
        return {y,left:[...a].slice(0,3),right:[...b].slice(0,3),cpu:[...bandsCPU.slice((y*128+10)*4,(y*128+10)*4+3)]};
      });
      const error=gl.getError();renderer.dispose();
      return {readings,error,off:[...off],played:[...played].slice(0,3),before,bandReadings};
    })()`)
    check(render.error === 0 && render.off[1] > 240, 'GPU toggle-off must restore deck paint without GL errors')
    check(render.readings.every(r => ['gpu', 'cpu'].every(k => r[k].every((v, i) => Math.abs(v - r.expected[i]) <= 3))), 'GPU and 2D fallback must follow the same time-aligned palette')
    check(render.played.every((v,i)=>v===render.before[i]),'Energy colors must not change brightness at the playhead')
    const bandColors=[[255,249,226],[211,145,49],[46,115,235]];
    check(render.bandReadings.every((r,i)=>['left','right','cpu'].every(k=>r[k].every((v,c)=>Math.abs(v-bandColors[i][c])<=1))), 'Three-band layers must agree on both backends and both sides of the playhead')
    results.push({ render })
    await evaluate(`(async()=>{const e=window.__engine;await e.seek(0,95);await e.seek(1,125);e.setLoopSize(0,8);await e.toggleLoop(0)})()`)
    await wait(200)
    const visuals = await evaluate(`(()=>({canvases:[...document.querySelectorAll('.wave-canvas')].length,labels:[...document.querySelectorAll('.energy-reading')].map(e=>e.textContent),button:document.querySelector('.energy-btn').getAttribute('aria-pressed'),loops:document.querySelectorAll('.zw-loop').length}))()`)
    check(visuals.canvases >= 4 && visuals.labels.length === 2 && visuals.button === 'true' && visuals.loops === 1, 'Both waveform views need energy, with the loop overlay still present')
    writeFileSync(resolve(out, 'energy-on.png'), (await win.webContents.capturePage()).toPNG())
    const toggle = await evaluate(`(()=>{document.querySelector('.energy-btn').click();return {on:window.__consoleState.getState().energyEnabled,saved:localStorage.getItem('dex.energy'),labels:document.querySelectorAll('.energy-reading').length}})()`)
    check(!toggle.on && toggle.saved === 'off', 'ENERGY button must switch off and save preference')
    await wait(120)
    check((await evaluate("document.querySelectorAll('.energy-reading').length"))===0,'Turning ENERGY off must remove intensity readouts');
    check(await evaluate("document.querySelector('.bands-btn').getAttribute('aria-pressed')==='true' && localStorage.getItem('dex.waveform')==='3band'"),'3BAND must be selected and saved after energy is disabled');
    writeFileSync(resolve(out, 'energy-off.png'), (await win.webContents.capturePage()).toPNG())
    writeFileSync(resolve(out, 'three-band.png'), (await win.webContents.capturePage()).toPNG())
    const waveRect=await evaluate("(()=>{const r=document.querySelector('.screen-zoom').getBoundingClientRect();return {x:Math.floor(r.x),y:Math.floor(r.y),width:Math.ceil(r.width),height:Math.ceil(r.height)}})()");
    writeFileSync(resolve(out, 'three-band-waves.png'), (await win.webContents.capturePage(waveRect)).toPNG())
    results.push({ visuals, toggle })
    const playback = await evaluate(`(async()=>{
      const e=window.__engine;await e.play(0);const a=e.getDeck(0).position;
      await new Promise(r=>setTimeout(r,450));const b=e.getDeck(0).position;
      await e.pause(0);return {a,b,playing:e.getDeck(0).isPlaying};
    })()`)
    check(playback.b > playback.a + 0.2 && !playback.playing, 'Analyzed tracks must still play and pause')
    results.push({ playback })
    // The chosen display mode must survive a restart; new installs use 3BAND.
    await evaluate("localStorage.clear()")
    await win.loadURL('http://127.0.0.1:5299/')
    await wait(150)
    check(await evaluate("document.querySelector('.bands-btn').getAttribute('aria-pressed')==='true'"),'A fresh library must default to 3BAND')
    await evaluate("document.querySelector('.energy-btn').click()")
    await win.loadURL('http://127.0.0.1:5299/')
    await wait(150)
    check(await evaluate("document.querySelector('.energy-btn').getAttribute('aria-pressed')==='true'"),'Explicit ENERGY preference must survive reload')
    await evaluate("document.querySelector('.bands-btn').click()")
    await win.loadURL('http://127.0.0.1:5299/')
    await wait(150)
    check(await evaluate("document.querySelector('.bands-btn').getAttribute('aria-pressed')==='true'"),'Explicit 3BAND preference must survive reload')
    results.push({preferences:'Default 3BAND, ENERGY and 3BAND persist across reloads'})
    check(!errors.some(e => /shader|Waveform|Uncaught|Analysis failed/i.test(e)), 'Renderer emitted analysis/shader errors: ' + errors.join('\n'))
    writeFileSync(resolve(out, 'report.json'), JSON.stringify({ ok: true, results, warnings: errors }, null, 2))
    console.log(JSON.stringify({ ok: true, results, warnings: errors, out }, null, 2))
    win.destroy();app.quit()
  } catch (error) {
    console.error(error);console.error(errors);win.destroy();app.exit(1)
  }
}
app.whenReady().then(run).catch(error => { console.error(error);app.exit(1) })
