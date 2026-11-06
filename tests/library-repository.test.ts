import { afterEach, describe, expect, it, vi } from 'vitest'
import { promises as fs } from 'node:fs'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { LibraryRepository } from '../src/main/services/library-repository'
import { LibraryWriter } from '../src/renderer/lib/library-writer'
import { parseLibrary } from '../src/shared/library-schema'

const dirs: string[] = []
afterEach(async () => { vi.restoreAllMocks(); await Promise.all(dirs.splice(0).map((dir) => fs.rm(dir, { recursive: true, force: true }))) })
const json = (name: string): string => JSON.stringify({ version: 1, tracks: [], playlists: [{ id: 'p', name, trackIds: [] }] })
async function repository() {
  const dir = await fs.mkdtemp(path.join(tmpdir(), 'dex-library-test-'))
  dirs.push(dir)
  const repo = new LibraryRepository(path.join(dir, 'library.json'))
  await repo.load()
  return repo
}
describe('durable library repository', () => {
  it('serializes concurrent writes and retains the preceding good revision', async () => {
    const repo = await repository()
    await Promise.all([repo.save(json('one')), repo.save(json('two')), repo.save(json('three'))])
    expect(await repo.load()).toBe(json('three'))
    expect(await fs.readFile(`${repo.target}.bak`, 'utf8')).toBe(json('two'))
    expect((await fs.readdir(path.dirname(repo.target))).filter((v) => v.endsWith('.tmp'))).toEqual([])
  })
  it('preserves the primary when replacement fails and can retry', async () => {
    const repo = await repository()
    await repo.save(json('good'))
    const rename = fs.rename.bind(fs)
    vi.spyOn(fs, 'rename').mockImplementation(async (from, to) => {
      if (to === repo.target) throw new Error('Injected replacement failure')
      return rename(from, to)
    })
    await expect(repo.save(json('failed'))).rejects.toThrow('Injected')
    expect(await fs.readFile(repo.target, 'utf8')).toBe(json('good'))
    vi.restoreAllMocks()
    await repo.save(json('retry'))
    expect(await repo.load()).toBe(json('retry'))
  })
  it('recovers backup and preserves damaged bytes', async () => {
    const repo = await repository()
    await repo.save(json('previous'))
    await repo.save(json('new'))
    await fs.writeFile(repo.target, 'damaged')
    const recovered = new LibraryRepository(repo.target)
    expect(await recovered.load()).toBe(json('previous'))
    const preserved = (await fs.readdir(path.dirname(repo.target))).find((v) => v.includes('.damaged-'))!
    expect(await fs.readFile(path.join(path.dirname(repo.target), preserved), 'utf8')).toBe('damaged')
  })
  it('blocks saving when neither primary nor backup can be recovered', async () => {
    const repo = await repository()
    await fs.writeFile(repo.target, '{broken')
    const broken = new LibraryRepository(repo.target)
    await expect(broken.load()).rejects.toThrow('preserved')
    await expect(broken.save(json('empty'))).rejects.toThrow('valid library')
    expect(await fs.readFile(repo.target, 'utf8')).toBe('{broken')
  })
  it('migrates four-slot hot cues from existing libraries', () => {
    const track = { id: 'legacy', name: 'Legacy', bpm: 124, offsetMs: 0, confidence: 1, durationSec: 60, analyzedAt: '', peaks: [], hotCues: [0, 10, null, 30] }
    const parsed = parseLibrary(JSON.stringify({ version: 1, tracks: [track] }))
    expect(parsed.tracks[0].hotCues).toEqual([0, 10, null, 30, null, null, null, null])
  })
  it('rejects invalid metadata instead of allowing it into the app', () => {
    for (const tracks of [[{}], [{ id: 'x', bpm: 'NaN' }]]) expect(() => parseLibrary(JSON.stringify({ version: 1, tracks }))).toThrow()
  })
})

describe('renderer save queue', () => {
  it('coalesces intermediate revisions and flushes the latest before close', async () => {
    let release!: () => void
    const gate = new Promise<void>((resolve) => { release = resolve })
    const writes: string[] = []
    const writer = new LibraryWriter(async (value) => { writes.push(value); if (value === 'one') await gate }, () => undefined)
    writer.enqueue('one'); await Promise.resolve(); writer.enqueue('two'); writer.enqueue('three')
    release()
    await writer.flush()
    expect(writes).toEqual(['one', 'three'])
  })
  it('flushes a new mutation made by a save-status subscriber', async () => {
    const writes: string[] = []
    let updated = false
    const writer = new LibraryWriter(async (value) => { writes.push(value) }, (state) => {
      if (state === 'saved' && !updated) { updated = true; writer.enqueue('newest') }
    })
    writer.enqueue('initial')
    await writer.flush()
    expect(writes).toEqual(['initial', 'newest'])
  })
  it('keeps failed work for retry and reports unsaved state', async () => {
    const save = vi.fn().mockRejectedValueOnce(new Error('disk full')).mockResolvedValue(undefined)
    const states: string[] = []
    const writer = new LibraryWriter(save, (state) => states.push(state))
    writer.enqueue('new')
    await expect(writer.flush()).rejects.toThrow('disk full')
    await writer.flush()
    expect(save.mock.calls.map(([value]) => value)).toEqual(['new', 'new'])
    expect(states).toEqual(['saving', 'error', 'saving', 'saved'])
  })
})
