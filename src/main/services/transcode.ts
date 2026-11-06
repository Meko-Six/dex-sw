import { spawn } from 'node:child_process'
import { promises as fs } from 'node:fs'
import path from 'node:path'
import { tmpdir } from 'node:os'
import { validAudioBytes } from './security'

const MAX_OUTPUT = 512 * 1024 * 1024
let active = false
const children = new Set<ReturnType<typeof spawn>>()
export function stopTranscodes(): void { for (const child of children) child.kill('SIGKILL') }

/** Fallback decoding is optional, single-flight and limited to local audio. */
export async function transcodeToWav(bytes: unknown, name: unknown): Promise<ArrayBuffer | null> {
  if (!validAudioBytes(bytes) || typeof name !== 'string' || name.length > 4096) throw new Error('Invalid audio decode request.')
  if (active) throw new Error('The fallback decoder is busy. Try again when the current track finishes loading.')
  active = true
  let dir: string | undefined
  try {
    dir = await fs.mkdtemp(path.join(tmpdir(), 'dex-'))
    const extension = /^\.[a-zA-Z0-9]{1,8}$/.test(path.extname(name)) ? path.extname(name) : '.bin'
    const input = path.join(dir, `input${extension}`)
    const output = path.join(dir, 'output.wav')
    await fs.writeFile(input, new Uint8Array(bytes))
    const ok = await new Promise<boolean>((resolve) => {
      const child = spawn('ffmpeg', [
        '-nostdin', '-hide_banner', '-loglevel', 'error', '-y',
        '-protocol_whitelist', 'file,pipe', '-i', input, '-vn', '-sn', '-dn',
        '-t', '3600', '-fs', String(MAX_OUTPUT), '-ac', '2', '-ar', '48000', '-c:a', 'pcm_s24le', output
      ], { stdio: ['ignore', 'ignore', 'pipe'] })
      children.add(child)
      let timedOut = false
      const timer = setTimeout(() => { timedOut = true; child.kill('SIGKILL') }, 120000)
      child.stderr?.on('data', () => { /* drain; never accumulate untrusted decoder output */ })
      child.once('error', () => { clearTimeout(timer); children.delete(child); resolve(false) })
      child.once('close', (code) => { clearTimeout(timer); children.delete(child); resolve(!timedOut && code === 0) })
    })
    if (!ok) return null
    const stat = await fs.stat(output)
    // Reaching a cap is truncation, never present it as the complete song.
    if (stat.size >= MAX_OUTPUT || stat.size <= 44) return null
    const buffer = await fs.readFile(output)
    return buffer.buffer.slice(buffer.byteOffset, buffer.byteOffset + buffer.byteLength) as ArrayBuffer
  } catch { return null } finally {
    if (dir) await fs.rm(dir, { recursive: true, force: true }).catch(() => undefined)
    active = false
  }
}
