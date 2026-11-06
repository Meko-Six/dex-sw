import { afterEach, describe, expect, it, vi } from 'vitest'
import { InputTap } from '../src/renderer/audio/tap'
import { OutputRouter } from '../src/renderer/audio/routing'
import { MixEngine } from '../src/renderer/audio/engine'
import { Deck } from '../src/renderer/audio/deck'

vi.mock('signalsmith-stretch', () => ({ default: vi.fn() }))
const deferred = <T>() => { let resolve!: (value: T) => void; const promise = new Promise<T>((done) => { resolve = done }); return { promise, resolve } }
class Node {
  outputs = new Set<Node>()
  gain = { value: 0, setTargetAtTime: vi.fn() }
  threshold = {}; knee = {}; ratio = {}; attack = {}; release = {}
  fftSize = 1024
  connect(target: Node) { this.outputs.add(target); return target }
  disconnect(target?: Node) { if (target) this.outputs.delete(target); else this.outputs.clear() }
  getFloatTimeDomainData() {}
}
const fakeContext = () => ({
  state: 'running', currentTime: 0, sampleRate: 48000,
  createGain: () => new Node(), createDynamicsCompressor: () => new Node(), createAnalyser: () => new Node(),
  createChannelMerger: () => new Node(), createChannelSplitter: () => new Node(),
  destination: Object.assign(new Node(), { maxChannelCount: 4 }), close: vi.fn().mockResolvedValue(undefined)
})
afterEach(() => { vi.unstubAllGlobals(); vi.restoreAllMocks() })
describe('audio lifetime', () => {
  it('keeps output graph connections bounded across mode switches', () => {
    const context = fakeContext()
    const router = new OutputRouter(context as unknown as AudioContext)
    const master = router.masterOut as unknown as Node
    const count = master.outputs.size
    for (let i = 0; i < 100; i++) router.setMode(i % 2 ? 'split' : 'multichannel')
    expect(master.outputs.size).toBe(count)
    router.dispose()
    expect(master.outputs.size).toBe(0)
  })
  it('stops a late stream without creating an audio context after cancellation', async () => {
    const media = deferred<MediaStream>(), stop = vi.fn(), context = vi.fn()
    vi.stubGlobal('navigator', { mediaDevices: { getUserMedia: () => media.promise } })
    vi.stubGlobal('AudioContext', context)
    const tap = new InputTap()
    const pending = tap.start()
    await tap.stop()
    media.resolve({ getTracks: () => [{ stop }] } as unknown as MediaStream)
    await pending
    expect(stop).toHaveBeenCalledOnce()
    expect(context).not.toHaveBeenCalled()
    expect(tap.getSnapshot().status).toBe('idle')
  })
  it('shares readiness, cleans a failed initialization and permits retry', async () => {
    const contexts: ReturnType<typeof fakeContext>[] = []
    vi.stubGlobal('AudioContext', function () { const ctx = fakeContext(); contexts.push(ctx); return ctx })
    vi.stubGlobal('window', { setInterval, clearInterval, setTimeout, clearTimeout, localStorage: { getItem: () => null } })
    const a = deferred<Deck>(), b = deferred<Deck>()
    const create = vi.spyOn(Deck, 'create').mockImplementationOnce(() => a.promise).mockImplementationOnce(() => b.promise)
    const engine = new MixEngine()
    let ready = false
    const first = engine.init(), second = engine.init().then(() => { ready = true })
    await Promise.resolve()
    expect(ready).toBe(false)
    const dispose = vi.fn()
    a.resolve({ dispose } as unknown as Deck)
    // Fail only after the concurrent callers have joined the same initialization.
    b.resolve(Promise.reject(new Error('worklet failed')) as unknown as Deck)
    await expect(first).rejects.toThrow('worklet failed')
    await expect(second).rejects.toThrow('worklet failed')
    expect(dispose).toHaveBeenCalledOnce()
    expect(contexts[0].close).toHaveBeenCalledOnce()
    create.mockRejectedValue(new Error('retry reached worklet'))
    await expect(engine.init()).rejects.toThrow('retry reached')
    expect(contexts).toHaveLength(2)
    await engine.dispose()
    await engine.dispose()
  })
})
