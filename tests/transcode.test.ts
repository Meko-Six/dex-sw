import { afterEach, describe, expect, it, vi } from 'vitest'
import { EventEmitter } from 'node:events'
import { PassThrough } from 'node:stream'
import { promises as fs } from 'node:fs'
import path from 'node:path'
import { spawn } from 'node:child_process'
import { transcodeToWav } from '../src/main/services/transcode'
vi.mock('node:child_process', () => ({ spawn: vi.fn() }))
afterEach(() => { vi.useRealTimers(); vi.resetAllMocks() })
function child() {
  const value = Object.assign(new EventEmitter(), { stderr: new PassThrough(), kill: vi.fn() })
  value.kill.mockImplementation(() => { queueMicrotask(() => value.emit('close', null)); return true })
  return value
}
describe('bounded fallback decoder', () => {
  it('drains noisy stderr, bounds ffmpeg, and removes temporary input/output', async () => {
    const process = child()
    let directory = ''
    vi.mocked(spawn).mockImplementation((_command, args) => {
      const output = args!.at(-1) as string
      directory = path.dirname(output)
      void fs.writeFile(output, new Uint8Array(100)).then(() => {
        // Much larger than a typical pipe buffer, without retaining the output.
        for (let i = 0; i < 100; i++) process.stderr.write(new Uint8Array(65536))
        process.emit('close', 0)
      })
      return process as unknown as ReturnType<typeof spawn>
    })
    const result = await transcodeToWav(new ArrayBuffer(4), 'track.mp3')
    expect(result?.byteLength).toBe(100)
    expect(spawn).toHaveBeenCalledWith('ffmpeg', expect.arrayContaining(['-nostdin', '-protocol_whitelist', 'file,pipe', '-fs', '-t']), expect.objectContaining({ stdio: ['ignore', 'ignore', 'pipe'] }))
    await expect(fs.stat(directory)).rejects.toMatchObject({ code: 'ENOENT' })
  })
  it('kills overdue children, limits concurrency, and still cleans up', async () => {
    const process = child()
    let directory = ''
    vi.mocked(spawn).mockImplementation((_command, args) => { directory = path.dirname(args!.at(-1) as string); return process as unknown as ReturnType<typeof spawn> })
    vi.useFakeTimers({ toFake: ['setTimeout', 'clearTimeout'] })
    const pending = transcodeToWav(new ArrayBuffer(4), 'track.mp3')
    await vi.waitFor(() => expect(spawn).toHaveBeenCalledOnce())
    await expect(transcodeToWav(new ArrayBuffer(4), 'second.mp3')).rejects.toThrow('busy')
    await vi.advanceTimersByTimeAsync(120000)
    expect(await pending).toBeNull()
    expect(process.kill).toHaveBeenCalledWith('SIGKILL')
    await expect(fs.stat(directory)).rejects.toMatchObject({ code: 'ENOENT' })
  })
  it('rejects malformed payloads before spawning a process', async () => {
    await expect(transcodeToWav('bytes', 'name')).rejects.toThrow('Invalid')
    expect(spawn).not.toHaveBeenCalled()
  })
})
