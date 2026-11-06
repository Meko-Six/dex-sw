/**
 * Run a script inside the running Dex window over the DevTools protocol, to
 * test the real app (its keys, the engine, real audio) from the command line.
 *
 *   npm run dev -- --remoteDebuggingPort 9222
 *   node scripts/live-eval.mjs some-check.js
 *
 * The script is the body of an async function: it can `await`, reach the
 * engine as `window.__engine` (dev builds only) and the file bridge as
 * `window.dex`, and whatever it returns is printed as JSON.
 */
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'

const targets = await (await fetch('http://127.0.0.1:9222/json')).json()
const page = targets.find((t) => t.type === 'page' && t.url.includes('5173'))
if (!page) throw new Error('No Dex window on :5173; open ones: ' + JSON.stringify(targets.map((t) => t.url)))
const ws = new WebSocket(page.webSocketDebuggerUrl)
await new Promise((resolve) => ws.addEventListener('open', resolve))
let id = 0
const call = (method, params) =>
  new Promise((resolve) => {
    const my = ++id
    const onMessage = (event) => {
      const msg = JSON.parse(event.data)
      if (msg.id === my) {
        ws.removeEventListener('message', onMessage)
        resolve(msg)
      }
    }
    ws.addEventListener('message', onMessage)
    ws.send(JSON.stringify({ id: my, method, params }))
  })
const projectRoot = fileURLToPath(new URL('../', import.meta.url)).replace(/\/$/, '')
const expression = `(async () => { const projectRoot = ${JSON.stringify(projectRoot)}; ${readFileSync(process.argv[2], 'utf8')} })()`
const res = await call('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true, userGesture: true })
console.log(JSON.stringify(res.result?.result?.value ?? res.result ?? res.error, null, 1))
if (res.result?.exceptionDetails || res.error || res.result?.result?.value?.ok === false) process.exitCode = 1
ws.close()
