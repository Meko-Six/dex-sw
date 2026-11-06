// Isolated native-input regression; requires npm run dev:renderer on :5299.
// node_modules/.bin/electron scripts/check-loop-drag.mjs
import { app, BrowserWindow } from 'electron'
import { mkdirSync, writeFileSync } from 'node:fs'
import { resolve } from 'node:path'

const out = resolve('out/loop-drag-check')
mkdirSync(resolve(out,'profile'), {recursive:true})
app.setPath('userData',resolve(out,'profile'))
app.commandLine.appendSwitch('autoplay-policy','no-user-gesture-required')
async function run() {
const win = new BrowserWindow({show:true,title:'Dex — loop drag check',width:1174,height:814,useContentSize:true,
  paintWhenInitiallyHidden:true,webPreferences:{backgroundThrottling:false}})
const wait=ms=>new Promise(r=>setTimeout(r,ms))
const check=(ok,message)=>{if(!ok)throw new Error(message)}
const results=[]
try {
  await win.loadURL('http://127.0.0.1:5299/')
  console.log('Loop-drag check: renderer loaded')
  await wait(700)
  win.webContents.debugger.attach('1.3')
  const call=async(method,params)=>{
    let timer
    try {
      return await Promise.race([win.webContents.debugger.sendCommand(method,params),new Promise((_,reject)=>{
        timer=setTimeout(()=>reject(new Error('Timed out: '+method)),12000)
      })])
    } finally {clearTimeout(timer)}
  }
  const evaluate=async expression=>{
    const r=await call('Runtime.evaluate',{expression,awaitPromise:true,returnByValue:true,userGesture:true})
    if(r.exceptionDetails)throw new Error(JSON.stringify(r.exceptionDetails))
    return r.result.value
  }
  const mouse=(type,p,buttons=0)=>call('Input.dispatchMouseEvent',{
    type,x:p.x,y:p.y,buttons,button:buttons || type!=='mouseMoved'?'left':'none',
    ...(type==='mouseMoved'?{}:{clickCount:1})
  })
  const touch=(type,p)=>call('Input.dispatchTouchEvent',{type,touchPoints:p?[{id:1,x:p.x,y:p.y}]:[]})
  await evaluate(`(async()=>{
    const e=window.__engine;await e.init();await e.resume();e.setMasterVolume(0);
    for(const [index,name,bpm] of [[0,'house-124.wav',124],[1,'techno-128.wav',128]]) {
      const bytes=await(await fetch('/@fs/'+${JSON.stringify(resolve('.'))}+'/fixtures/'+name)).arrayBuffer();
      await e.loadIntoDeck(index,{id:'drag-loop-'+index,name,bytes,grid:{bpm,offsetMs:0,confidence:1}});
      await e.seek(index,4.2);
    }
    e.sync(0);e.sync(1);e.setLoopSize(0,4);await e.toggleLoop(0);
    window.__loopConsole=(await import('/console/state.ts')).useConsole;
  })()`)
  await wait(100)
  console.log('Loop-drag check: fixture decks ready')
  const state=index=>evaluate(`(()=>{
    const d=window.__engine.getDeck(${index});
    return {loop:d.loopRegion,position:d.position,playing:d.isPlaying,duration:d.durationSec,grid:d.grid,sync:d.syncLocked};
  })()`)
  const gesture=side=>evaluate(`(()=>{
    const lane=document.querySelector('.zw[data-side="${side}"]'),loop=lane.querySelector('.zw-loop');
    const a=lane.getBoundingClientRect(),b=loop.getBoundingClientRect();
    const d=window.__engine.getDeck(${side==='A'?0:1});
    return {x:b.left+b.width/2,y:b.top+b.height/2,beatPx:a.width/window.__loopConsole.getState().spanSec*60/d.grid.bpm};
  })()`)
  const drag=async(side,beats)=>{
    const p=await gesture(side),q={x:p.x+p.beatPx*beats,y:p.y}
    await mouse('mousePressed',p,1);await mouse('mouseMoved',q,1);await mouse('mouseReleased',q);await wait(100)
  }
  let before=await state(0)
  await drag('A',0.4)
  check((await state(0)).loop.startBeat===before.loop.startBeat,'Small drag must stay on nearest beat')
  await drag('A',2.6)
  let after=await state(0)
  check(after.loop.startBeat===before.loop.startBeat+3 && after.loop.lengthBeats===4 && !after.playing,'Paused drag must move three beats without resizing or playing')
  check(Math.abs(after.position-before.position-3*60/124)<1e-6,'Paused playhead must move with the loop')
  results.push('Mouse drag snaps to beats, preserves length and moves paused playhead')
  before=after
  const p=await gesture('A')
  await mouse('mousePressed',p,1)
  await mouse('mouseMoved',{x:p.x+p.beatPx*2,y:p.y},1);await wait(70)
  await mouse('mouseMoved',{x:p.x-p.beatPx*1.6,y:p.y},1)
  await mouse('mouseReleased',{x:p.x-p.beatPx*1.6,y:p.y});await wait(100)
  check((await state(0)).loop.startBeat===before.loop.startBeat-2,'Reversing within a drag must use the original beat anchor')
  results.push('Reversing within a drag moves backward without accumulated rounding')
  await call('Emulation.setDeviceMetricsOverride',{width:880,height:610,deviceScaleFactor:1,mobile:false})
  await evaluate('window.__loopConsole.getState().setSpan(6)');await wait(100)
  before=await state(0)
  await call('Emulation.setTouchEmulationEnabled',{enabled:true})
  const t=await gesture('A'),q={x:t.x-t.beatPx*1.2,y:t.y}
  await touch('touchStart',t);await touch('touchMove',q);await touch('touchEnd');await wait(100)
  check((await state(0)).loop.startBeat===before.loop.startBeat-1,'Touch drag must keep beat calibration at a smaller viewport and different zoom')
  await call('Emulation.setTouchEmulationEnabled',{enabled:false})
  results.push('Touch drag snaps correctly at a smaller window size and different zoom')
  await evaluate('window.__engine.moveLoop(0,1000000);window.__loopConsole.getState().setSpan(48)');await wait(100)
  before=await state(0);await drag('A',5)
  after=await state(0)
  check(after.loop.startBeat===before.loop.startBeat && after.loop.lengthBeats===4,'End-of-file drag must clamp the entire loop without resizing')
  check(after.grid.offsetMs/1000+(after.loop.startBeat+4)*60/after.grid.bpm<=after.duration+1e-8,'Loop end must stay inside the file')
  await drag('A',-2)
  check((await state(0)).loop.startBeat===before.loop.startBeat-2,'Loop must move backward from the end boundary')
  results.push('Dragging respects track bounds and retains the full loop length')
  await evaluate('window.__engine.moveLoop(0,10);window.__loopConsole.getState().setSpan(12)');await wait(100)
  await evaluate(`document.querySelector('.zw[data-side="A"] .zw-loop').focus()`)
  before=await state(0)
  await call('Input.dispatchKeyEvent',{type:'keyDown',key:'ArrowRight',code:'ArrowRight',windowsVirtualKeyCode:39})
  await call('Input.dispatchKeyEvent',{type:'keyUp',key:'ArrowRight',code:'ArrowRight',windowsVirtualKeyCode:39});await wait(80)
  after=await state(0)
  check(after.loop.startBeat===before.loop.startBeat+1 && after.grid.offsetMs===before.grid.offsetMs,'Arrow adjustment must move the loop, not edit the beat grid')
  results.push('Focused loop also moves by one beat using the arrow keys')
  await evaluate('(async()=>{const e=window.__engine;await e.play(0);await e.play(1);await new Promise(r=>setTimeout(r,220));e.setLoopSize(1,4);await e.toggleLoop(1)})()')
  await wait(400);before=await state(1)
  await drag('B',3)
  after=await state(1)
  const phase=await evaluate(`(()=>{
    const a=window.__engine.getDeck(0),b=window.__engine.getDeck(1),when=a.context.currentTime+0.04;
    let error=(a.positionAt(when)-a.grid.offsetMs/1000)*a.grid.bpm/60-(b.positionAt(when)-b.grid.offsetMs/1000)*b.grid.bpm/60;
    return Math.abs(error-Math.round(error));
  })()`)
  check(after.loop.startBeat===before.loop.startBeat+3 && after.playing && after.sync && phase<0.005,'Moving a playing synced loop must preserve playback and beat phase: '+JSON.stringify({before,after,phase}))
  results.push('Playing synced loop moves immediately while retaining beat alignment')
  writeFileSync(resolve(out,'preview.png'),(await win.webContents.capturePage()).toPNG())
  console.log(JSON.stringify({ok:true,results},null,2))
} catch(error) {
  console.error(error);process.exitCode=1
} finally {
  win.destroy();app.exit(process.exitCode??0)
}
}

app.whenReady().then(run).catch(error=>{console.error(error);app.exit(1)})
