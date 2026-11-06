import { build } from 'esbuild'
import fs from 'node:fs/promises'
import path from 'node:path'
const root = path.resolve('.')
const worker = (await fs.readdir(path.join(root, 'out/renderer/assets'))).find((name) => /^analysis\.worker-.*\.js$/.test(name))
if (!worker) throw new Error('Run npm run build before the runtime checks.')
await build({ stdin: { contents: `
      export {engine, MixEngine} from './src/renderer/audio/engine';
      export {useLibrary} from './src/renderer/state/library';
      export {WaveformRenderer, drawWaveform2D} from './src/renderer/ui/waveform-gl';
      export {buildWaveformLevels} from './src/shared/waveform-levels';
      import {createRoot} from 'react-dom/client';
      import {createElement} from 'react';
      import {WaveCanvas} from './src/renderer/console/WaveCanvas';
      import {Library} from './src/renderer/console/Sheets';
      import {useConsole} from './src/renderer/console/state';
      export {useConsole};
      import {useDeckPosition,useEngineSnapshot} from './src/renderer/hooks';
      export function mountWave(container, props) { const root=createRoot(container);root.render(createElement(WaveCanvas,props));return root }
      export function mountLibrary(container,snapshot) {const root=createRoot(container);root.render(createElement(Library,{snapshot}));return root}
      export function mountLive(container,index,overview) {
        function Live(){const deck=useEngineSnapshot().decks[index],position=useDeckPosition(index);return createElement(WaveCanvas,{deck,startSec:overview?0:position-2,spanSec:overview?deck.durationSec:8,playSec:position,amp:1,oneSided:overview,paint:{peak:[1,1,1,1],rms:[1,1,1,1],peakPlayed:[1,1,1,1],rmsPlayed:[1,1,1,1],line:[0,0,0,0]}})}
        const root=createRoot(container);root.render(createElement(Live));return root;
      }
    `, resolveDir: root, loader: 'ts' }, bundle: true, format: 'esm', platform: 'browser', target: 'esnext', jsx: 'automatic', define: { 'import.meta.env.DEV': 'false', 'process.env.NODE_ENV': '"production"' }, plugins: [{ name: 'built-worker-url', setup(build) { build.onLoad({ filter: /audio\/engine\.ts$/ }, async ({ path: file }) => ({ contents: (await fs.readFile(file, 'utf8')).replace("new URL('./analysis.worker.ts', import.meta.url)", `new URL('./assets/${worker}', import.meta.url)`), loader: 'ts' })) } }], outfile: path.join(root, 'out/renderer/runtime-test.js') })
