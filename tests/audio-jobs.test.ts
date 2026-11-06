import { describe, expect, it } from 'vitest'
import { WorkQueue } from '../src/renderer/audio/work-queue'
import { DeckLoads } from '../src/renderer/audio/deck-loads'
const deferred = () => { let resolve!: () => void; const promise = new Promise<void>((done) => { resolve = done }); return { promise, resolve } }
describe('bounded audio work', () => {
  it('drops stale queued jobs and prioritizes visible deck loads', async () => {
    const queue = new WorkQueue(100)
    const gate = deferred(), order: string[] = []
    const active = queue.run(() => gate.promise, { bytes: 1 })
    const stale = queue.run(async () => order.push('stale'), { key: 'deck', bytes: 50 })
    const cancelled = expect(stale).rejects.toMatchObject({ name: 'AbortError' })
    const background = queue.run(async () => order.push('background'), { bytes: 10 })
    const latest = queue.run(async () => order.push('latest'), { key: 'deck', priority: 2, bytes: 50 })
    expect(queue.queuedBytes).toBe(60)
    gate.resolve()
    await Promise.all([active, cancelled, background, latest])
    expect(order).toEqual(['latest', 'background'])
    expect(queue.queuedBytes).toBe(0)
  })
  it('rejects over-budget admissions and disposal clears queued ownership', async () => {
    const queue = new WorkQueue(100), gate = deferred()
    const active = queue.run(() => gate.promise, { bytes: 1 })
    const pending = queue.run(async () => undefined, { bytes: 90 })
    const cancelled = expect(pending).rejects.toMatchObject({ name: 'AbortError' })
    await expect(queue.run(async () => undefined, { bytes: 11 })).rejects.toThrow('budget')
    queue.dispose(); gate.resolve()
    await Promise.all([active, cancelled])
    expect(queue.queuedBytes).toBe(0)
  })
})
describe('deck selection ordering', () => {
  it('discards an old selection and serializes commits on the same deck', async () => {
    const loads = new DeckLoads(), gate = deferred(), order: string[] = []
    const old = loads.request(0), latest = loads.request(0)
    expect(await loads.commit(0, old, async () => { order.push('old') })).toBe(false)
    const first = loads.commit(0, latest, async () => { order.push('start'); await gate.promise; order.push('finish') })
    const newer = loads.request(0)
    const second = loads.commit(0, newer, async () => { order.push('new') })
    await Promise.resolve(); expect(order).not.toContain('new')
    gate.resolve(); await Promise.all([first, second])
    // A queued selection can be superseded even before its commit starts.
    expect(order.at(-1)).toBe('new')
    expect(order).not.toContain('old')
  })
})
