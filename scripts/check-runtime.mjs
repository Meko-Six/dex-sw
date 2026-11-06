// Production Electron/IPC/worklet integration, isolated from the user's profile.
// npm run build && npm run check:runtime (needs a GUI session or xvfb-run on Linux).
import { app, BrowserWindow, dialog, ipcMain } from 'electron'
import fs from 'node:fs/promises'
import path from 'node:path'
import { pathToFileURL } from 'node:url'
import assert from 'node:assert/strict'
const root = path.resolve('.')
const out = path.join(root, 'out/runtime-check')
await fs.mkdir(out, { recursive: true })
const profile = await fs.mkdtemp(path.join(out, 'profile-'))
app.setPath('userData', profile)
app.commandLine.appendSwitch('autoplay-policy', 'no-user-gesture-required')
const report = { checks: [], errors: [] }
const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms))
const check = (ok, message) => { assert.ok(ok, message); report.checks.push(message); console.log(message) }
async function run() {
  const watchdog = setTimeout(() => { console.error('Runtime check timed out'); app.exit(1) }, 180000)
  watchdog.unref()
  let win
  try {
    const fixture = path.join(root, 'fixtures/house-124.wav')
    const folder = path.join(out, 'audio')
    await fs.mkdir(folder, { recursive: true })
    await fs.copyFile(fixture, path.join(folder, 'one.wav'))
    await fs.copyFile(path.join(root, 'fixtures/techno-128.wav'), path.join(folder, 'two.wav'))
    let chosenFile = fixture
    dialog.showOpenDialog = async (_window, options) => ({ canceled: false, filePaths: options.properties.includes('openDirectory') ? [folder] : [chosenFile] })
    await import(pathToFileURL(path.join(root, 'out/main/index.js')).href)
    for (let i = 0; i < 100 && !BrowserWindow.getAllWindows().length; i++) await wait(20)
    win = BrowserWindow.getAllWindows()[0]
    assert.ok(win, 'Application window exists')
    win.webContents.on('console-message', (details) => { if (details.level === 'error') report.errors.push(details.message) })
    for (let i = 0; i < 100; i++) {
      if (!win.webContents.isLoading() && await win.webContents.executeJavaScript('!!window.dex && !!document.querySelector(".head")')) break
      await wait(50)
    }
    const evaluate = (expression) => win.webContents.executeJavaScript(expression, true)
    check(win.webContents.getLastWebPreferences().sandbox === true, 'Production renderer is sandboxed')
    check(await evaluate(`typeof window.require === 'undefined' && typeof window.dex.readFile === 'function'`), 'Isolated preload bridge works without renderer Node access')
    const blocked = await evaluate(`window.dex.readFile(${JSON.stringify(path.join(root, 'package.json'))}).then(()=>false,()=>true)`)
    check(blocked, 'Unapproved file read is rejected')
    const listener = ipcMain._invokeHandlers.get('fs:readFile')
    await assert.rejects(Promise.resolve().then(() => listener({ sender: win.webContents, senderFrame: { url: 'https://untrusted.invalid' } }, fixture)), /Untrusted/)
    check(true, 'Foreign frame is rejected at the IPC handler')
    check(await evaluate(`(()=>{try{eval('1+1');return false}catch{return true}})()`), 'Production CSP blocks JavaScript eval')
    await evaluate(`(async()=>{window.testModule = await import('./runtime-test.js'); await window.testModule.engine.init(); await window.testModule.engine.resume(); window.testModule.engine.setMasterVolume(0); await window.testModule.useLibrary.getState().hydrate()})()`)
    const imported = await evaluate(`(async()=>{ const {useLibrary:l,engine:e}=window.testModule;await l.getState().addFiles();return {tracks:l.getState().tracks.length,deck:e.getDeck(0).trackId,error:l.getState().error}})()`)
    check(imported.tracks === 1 && imported.deck === null && !imported.error, 'Adding files imports without replacing a deck')
    const loaded = await evaluate(`(async()=>{ const {useLibrary:l,engine:e}=window.testModule;await l.getState().loadToDeck(l.getState().tracks[0],0); await e.play(0);return {id:e.getDeck(0).trackId,playing:e.getDeck(0).isPlaying,error:l.getState().error}})()`)
    check(loaded.playing && loaded.id && !loaded.error, 'Real worklet loads transferred PCM and starts playback under CSP')
    await wait(500)
    const retained = await evaluate(`(async()=>{ const {useLibrary:l,engine:e}=window.testModule;const id=e.getDeck(0).trackId;const start=e.getDeck(0).position;await l.getState().addFolder();await l.getState().loadToDeck(l.getState().tracks[1],0);return {same:e.getDeck(0).trackId===id,playing:e.getDeck(0).isPlaying,advanced:e.getDeck(0).position>start,tracks:l.getState().tracks.length,rejected:l.getState().error?.message}})()`)
    check(retained.same && retained.playing && retained.advanced && retained.tracks === 3 && retained.rejected?.includes('Pause'), 'Folder import and explicit replacement leave a playing deck untouched')
    const levels = await evaluate(`(async()=>{ const e=window.testModule.engine;await e.pause(0);for(let i=0;i<100&&!e.getDeck(0).levels;i++)await new Promise(r=>setTimeout(r,30));return !!e.getDeck(0).levels})()`)
    check(levels, 'Analysis worker builds three-band waveforms under production CSP')
    const render = await evaluate(`(async()=>{ const {WaveformRenderer:R,buildWaveformLevels:build}=window.testModule;const samples=new Float32Array(48000);for(let i=0;i<samples.length;i++)samples[i]=Math.sin(i/20)*.8;const levels=build([samples],48000);const canvas=document.createElement('canvas');canvas.width=256;canvas.height=64;const r=R.create(canvas);const paint={peak:[1,1,1,1],rms:[1,1,1,1],peakPlayed:[1,1,1,1],rmsPlayed:[1,1,1,1],line:[0,0,0,0]};r.setLevels(levels);const before=r.textures.size;r.draw({startCol:0,samplesPerPixel:188,playSample:0,amp:1,paint,threeBand:true});const after=r.textures.size;const gl=canvas.getContext('webgl2'),pixels=new Uint8Array(256*64*4);gl.readPixels(0,0,256,64,gl.RGBA,gl.UNSIGNED_BYTE,pixels);const visible=pixels.some(v=>v>0);r.dispose();window.testWave={levels,paint};return {before,after,visible,error:gl.getError()}})()`)
    check(render.before === 0 && render.after === 1 && render.visible && render.error === 0, 'Waveforms lazily upload only the selected GPU level and draw correctly')
    const fallback = await evaluate(`(async()=>{
      const host=document.createElement('div');host.style.cssText='width:256px;height:64px;position:fixed;top:0;left:0';document.body.appendChild(host);
      const original=WebGL2RenderingContext.prototype.getShaderParameter;
      WebGL2RenderingContext.prototype.getShaderParameter=()=>false;
      const root=window.testModule.mountWave(host,{deck:{levels:window.testWave.levels,durationSec:1,power:null},startSec:0,spanSec:1,playSec:0,amp:1,paint:window.testWave.paint});
      await new Promise(r=>setTimeout(r,300));WebGL2RenderingContext.prototype.getShaderParameter=original;
      const canvas=host.querySelector('canvas');const ctx=canvas?.getContext('2d');const visible=ctx?.getImageData(0,0,canvas.width,canvas.height).data.some(v=>v>0);root.unmount();host.remove();return !!visible;
    })()`)
    check(fallback, 'Shader initialization failure replaces the canvas and draws the 2D fallback')
    await evaluate(`window.testModule.useLibrary.getState().flush()`)
    const saved = JSON.parse(await fs.readFile(path.join(profile, 'library.json'), 'utf8'))
    check(saved.tracks.length === 3 && saved.tracks.every(t => t.fingerprint), 'Library saves atomically with source fingerprints')
    const transport = await evaluate(`(async()=>{
      const {engine:e,useLibrary:l}=window.testModule;
      await l.getState().loadToDeck(l.getState().tracks[2],1);
      await e.play(0);await new Promise(r=>setTimeout(r,250));
      await e.cueDown(1);await new Promise(r=>setTimeout(r,250));
      const a=e.getDeck(0),b=e.getDeck(1);
      const beat=d=>(d.position-d.grid.offsetMs/1000)*d.grid.bpm/60;
      const delta=beat(a)-beat(b),phase=Math.abs(delta-Math.round(delta));
      await e.play(1);await e.cueUp(1);
      const latched=b.isPlaying;
      await e.setLoopBars(0,1,true);
      const loop=a.loopRegion, start=a.grid.offsetMs/1000+loop.startBeat*60/a.grid.bpm, length=loop.lengthBeats*60/a.grid.bpm;
      await new Promise(r=>setTimeout(r,Math.ceil((length+1)*1000)));
      const audible=a.source.inputTime, visual=a.position;
      await e.pause(0);await e.pause(1);
      return {phase,latched,start,length,audible,visual,loop:!!loop};
    })()`)
    report.transport = transport
    check(transport.phase < 0.05 && transport.latched, 'Synced CUE retains beat alignment and PLAY latches held playback')
    check(transport.loop && transport.visual >= transport.start - .05 && transport.visual < transport.start + transport.length + .05 && transport.audible >= transport.start - .2 && transport.audible < transport.start + transport.length + .2, 'Native worklet and visual clock both wrap within the active loop')
    if (process.argv.includes('--long')) {
      const songs = ['8556621_Solace_Original_Mix.mp3', '7585933_Dark_Rooms_Original_Mix.mp3'].map(name=>path.join(root,'accuracy/audio/Techno',name))
      for(const file of songs) await fs.access(file)
      const memorySamples=[]
      const sample=()=>memorySamples.push({at:Date.now(),processes:app.getAppMetrics().map(({type,memory})=>({type,...memory}))})
      sample();const memoryTimer=setInterval(sample,100)
      try {
        chosenFile=songs[0]
        const burst=await evaluate(`(async()=>{
          const {engine:e}=window.testModule;const [ref]=await window.dex.pickFiles();const bytes=await window.dex.readFile(ref.path);
          const request={name:ref.name,bytes,grid:{bpm:126,offsetMs:0,confidence:1}};
          const old=e.loadIntoDeck(0,{...request,id:'long-old'});await new Promise(r=>setTimeout(r,20));
          const results=await Promise.all([old,...[1,2,3].map(i=>e.loadIntoDeck(0,{...request,id:'long-'+i}))]);
          return {results,id:e.getDeck(0).trackId,duration:e.getDeck(0).durationSec,queuedBytes:e.jobs.queuedBytes};
        })()`)
        check(burst.id==='long-3' && burst.results.at(-1) && burst.results.slice(0,-1).every(v=>!v), 'Rapid long-track loads retain the latest selection and discard older work')
        chosenFile=songs[1]
        await evaluate(`(async()=>{const {engine:e}=window.testModule;const [ref]=await window.dex.pickFiles();const bytes=await window.dex.readFile(ref.path);await e.loadIntoDeck(1,{id:'long-b',name:ref.name,bytes,grid:{bpm:124,offsetMs:0,confidence:1}});for(let i=0;i<1000&&[0,1].some(i=>!e.getDeck(i).levels);i++)await new Promise(r=>setTimeout(r,30));})()`)
        const performanceResult=await evaluate(`(async()=>{
          const m=window.testModule,e=m.engine;const instances=[];const roots=[];const hosts=[];
          const original=m.WaveformRenderer.create;m.WaveformRenderer.create=function(canvas){const r=original.call(this,canvas);if(r)instances.push(r);return r};
          for(let index=0;index<2;index++)for(const overview of [false,true]){const host=document.createElement('div');host.style.cssText='position:fixed;left:0;top:'+(hosts.length*80)+'px;width:1100px;height:70px;background:black';document.body.appendChild(host);hosts.push(host);roots.push(m.mountLive(host,index,overview))}
          await e.play(0);await e.play(1);const frames=[];const start=performance.now();let previous=start;
          await new Promise(resolve=>{function tick(now){frames.push(now-previous);previous=now;if(now-start<5000)requestAnimationFrame(tick);else resolve()}requestAnimationFrame(tick)});
          const gpuBytes=instances.reduce((sum,r)=>sum+[...r.textures.keys()].reduce((n,l)=>n+Math.ceil(l.count/4096)*4096*4*(l.bands?2:1),0),0);
          const textureCounts=instances.map(r=>r.textures.size);const duration=[0,1].map(i=>e.getDeck(i).durationSec);const queuedBytes=e.jobs.queuedBytes;
          await e.pause(0);await e.pause(1);roots.forEach(r=>r.unmount());hosts.forEach(h=>h.remove());m.WaveformRenderer.create=original;
          frames.sort((a,b)=>a-b);return {duration,gpuBytes,textureCounts,queuedBytes,frameMedianMs:frames[Math.floor(frames.length*.5)],frameP95Ms:frames[Math.floor(frames.length*.95)],frames:frames.length};
        })()`)
        check(performanceResult.textureCounts.length===4 && performanceResult.textureCounts.every(n=>n>=1&&n<=2) && performanceResult.queuedBytes===0, 'Two real tracks render four live waveforms with bounded texture caches and an empty job queue')
        report.longTrackProfile={burst,...performanceResult,memorySamples}
        console.log('Long-track profile:',JSON.stringify({...performanceResult,memorySamples:memorySamples.length}))
      } finally { clearInterval(memoryTimer) }
    }
    report.memoryKiB = app.getAppMetrics().map(({type,memory})=>({type,...memory}))
    const listRendering=await evaluate(`(async()=>{
      const m=window.testModule,l=m.useLibrary,c=m.useConsole;const tracks=l.getState().tracks,open=c.getState().libOpen;
      const many=Array.from({length:1000},(_,i)=>({...tracks[0],id:'virtual-'+i,name:'Virtual '+String(i).padStart(4,'0')}));l.setState({tracks:many});c.setState({libOpen:true});
      const host=document.createElement('div');host.style.cssText='position:fixed;inset:0;width:1174px;height:814px;z-index:999';document.body.appendChild(host);
      const root=m.mountLibrary(host,m.engine.getSnapshot());await new Promise(r=>setTimeout(r,150));
      const sheet=host.querySelector('.library');sheet.style.cssText='position:absolute;inset:0;height:500px;display:flex';await new Promise(r=>setTimeout(r,100));
      const list=host.querySelector('.lib-list'),firstCount=host.querySelectorAll('.lib-row').length;
      list.scrollTop=490*49;list.dispatchEvent(new Event('scroll'));await new Promise(r=>setTimeout(r,100));
      const scrollTop=list.scrollTop,targetVisible=[...host.querySelectorAll('.lib-name')].some(node=>node.textContent==='Virtual 0490'),scrolledCount=host.querySelectorAll('.lib-row').length;
      c.setState({libOpen:false});await new Promise(r=>setTimeout(r,50));const closedCount=host.querySelectorAll('.lib-row').length;
      root.unmount();host.remove();l.setState({tracks});c.setState({libOpen:open});return {firstCount,targetVisible,scrolledCount,closedCount,scrollTop};
    })()`)
    report.listRendering=listRendering
    check(listRendering.firstCount>0&&listRendering.firstCount<100&&listRendering.scrolledCount<100&&listRendering.targetVisible&&Math.abs(listRendering.scrollTop-24010)<1&&listRendering.closedCount===0, 'Large libraries render only visible rows and release them when closed: '+JSON.stringify(listRendering))
    const shot = await win.webContents.capturePage()
    await fs.writeFile(path.join(out, 'production.png'), shot.toPNG())
    // Dispose the test engine; the application close handler flushes its own library writer.
    await evaluate(`window.testModule.engine.dispose()`)
    win.close()
    for (let i = 0; i < 100 && !win.isDestroyed(); i++) await wait(20)
    check(win.isDestroyed(), 'Deliberate close waits for renderer and main-process persistence')
    await fs.writeFile(path.join(out, 'report.json'), JSON.stringify(report, null, 2))
    if (report.longTrackProfile) await fs.writeFile(path.join(out, 'resource-profile.json'), JSON.stringify(report, null, 2))
    app.exit(0)
  } catch (error) {
    report.failure = String(error.stack ?? error)
    console.error(error)
    await fs.writeFile(path.join(out, 'report.json'), JSON.stringify(report, null, 2))
    app.exit(1)
  } finally { await fs.rm(path.join(root, 'out/renderer/runtime-test.js'), { force: true }).catch(() => undefined) }
}
app.whenReady().then(run)
