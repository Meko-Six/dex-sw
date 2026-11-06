import { afterEach, describe, expect, it } from 'vitest'
import { promises as fs } from 'node:fs'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { pathToFileURL } from 'node:url'
import { externalUrl, trustedDocument, validAudioBytes } from '../src/main/services/security'
import { AudioFiles } from '../src/main/services/audio-files'
const dirs: string[] = []
afterEach(async () => { await Promise.all(dirs.splice(0).map((dir) => fs.rm(dir, { recursive: true, force: true }))) })
describe('desktop authority', () => {
  it('allows only the exact app document in development and production', () => {
    const entry = '/app/renderer/index.html'
    expect(trustedDocument(`${pathToFileURL(entry).href}#library`, entry)).toBe(true)
    for (const url of ['file:///etc/passwd', 'file:///app/renderer/other.html', 'https://untrusted.invalid/']) expect(trustedDocument(url, entry)).toBe(false)
    expect(trustedDocument('http://localhost:5173/#library', entry, 'http://localhost:5173/')).toBe(true)
    for (const url of ['http://localhost:5173.evil.invalid/', 'http://localhost:5173/other', 'http://localhost:5174/']) expect(trustedDocument(url, entry, 'http://localhost:5173/')).toBe(false)
  })
  it('rejects privileged external schemes and malformed payloads', () => {
    for (const url of ['file:///tmp/a', 'javascript:alert(1)', 'data:text/html,x', 'https://user:pass@example.com/', 'invalid']) expect(externalUrl(url)).toBe(false)
    expect(externalUrl('https://example.com/')).toBe(true)
    expect(validAudioBytes(new ArrayBuffer(4))).toBe(true)
    expect(validAudioBytes(new Uint8Array(4))).toBe(false)
    expect(validAudioBytes(new ArrayBuffer(0))).toBe(false)
  })
  it('reads approved audio only and rejects later symlink changes', async () => {
    const dir = await fs.mkdtemp(path.join(tmpdir(), 'dex-file-test-')); dirs.push(dir)
    const a = path.join(dir, 'one.wav'), b = path.join(dir, 'two.wav'), link = path.join(dir, 'link.wav')
    await fs.writeFile(a, 'audio one'); await fs.writeFile(b, 'audio two'); await fs.symlink(a, link)
    const files = new AudioFiles()
    await expect(files.read(a)).rejects.toThrow('approved')
    await files.grant(a)
    expect(Buffer.from((await files.read(a))!).toString()).toBe('audio one')
    await files.grant(link); await fs.unlink(link); await fs.symlink(b, link)
    await expect(files.read(link)).rejects.toThrow('changed')
    await expect(files.grant(path.join(dir, 'secret.txt'))).rejects.toThrow('Invalid')
  })
  it('retains authorization for a missing saved audio file without reading elsewhere', async () => {
    const files = new AudioFiles()
    await files.restore('/missing/saved.wav')
    expect(files.has('/missing/saved.wav')).toBe(true)
    expect(await files.read('/missing/saved.wav')).toBeNull()
    await expect(files.read('/missing/other.wav')).rejects.toThrow('approved')
  })
})
