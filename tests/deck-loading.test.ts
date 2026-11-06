import { afterEach, describe, expect, it, vi } from 'vitest'
import { MixEngine } from '../src/renderer/audio/engine'
import type { DeckLoadMeta } from '../src/renderer/audio/deck'
vi.mock('signalsmith-stretch', () => ({ default: vi.fn() }))
function deferred<T>() { let resolve!: (value: T) => void; const promise = new Promise<T>((done) => { resolve = done }); return { promise, resolve } }
function setup() {
  const engine = new MixEngine()
  const base = engine.getSnapshot().decks[0]
  const deck = {
    trackId: 'original', isPlaying: false, loading: false, error: null as string | null, loadVersion: 0,
    snapshot: () => ({ ...base, trackId: deck.trackId, playing: deck.isPlaying, loading: deck.loading, error: deck.error }),
    setGainTrim: vi.fn(),
    load: vi.fn(async (_buffer: AudioBuffer, meta: DeckLoadMeta, eligible: () => boolean) => {
      if (!eligible() || deck.isPlaying) return false
      deck.trackId = meta.id; deck.loadVersion++; return true
    })
  }
  // Fake only devices/DSP; execute the real request, readiness and commit path.
  Object.assign(engine, { deckList: [deck, null], ready: true })
  const internals = engine as unknown as {
    decode: (bytes: ArrayBuffer) => Promise<AudioBuffer>; buildLevels: () => void
    applyCrossfader: () => void; claimMaster: () => void; follow: () => void
  }
  vi.spyOn(internals, 'buildLevels').mockImplementation(() => undefined)
  vi.spyOn(internals, 'applyCrossfader').mockImplementation(() => undefined)
  vi.spyOn(internals, 'claimMaster').mockImplementation(() => undefined)
  vi.spyOn(internals, 'follow').mockImplementation(() => undefined)
  return { engine, deck, internals }
}
const buffer = { duration: 10 } as AudioBuffer
const request = (id: string, trimDb = 0) => ({ id, name: id, bytes: new ArrayBuffer(4), trimDb })
afterEach(() => vi.restoreAllMocks())
describe('deck load commands', () => {
  it('keeps the last selection and its trim when an earlier decode finishes late', async () => {
    const { engine, deck, internals } = setup()
    const firstDecode = deferred<AudioBuffer>()
    const decode = vi.spyOn(internals, 'decode').mockReturnValueOnce(firstDecode.promise).mockResolvedValue(buffer)
    const older = engine.loadIntoDeck(0, request('older', -10))
    await vi.waitFor(() => expect(decode).toHaveBeenCalledOnce())
    const newer = engine.loadIntoDeck(0, request('newer', -3))
    firstDecode.resolve(buffer)
    expect(await older).toBe(false)
    expect(await newer).toBe(true)
    expect(deck.trackId).toBe('newer')
    expect(deck.load).toHaveBeenCalledOnce()
    expect(deck.setGainTrim).toHaveBeenCalledExactlyOnceWith(-3)
    expect(deck.loading).toBe(false)
  })
  it('keeps playback which starts while a replacement is decoding', async () => {
    const { engine, deck, internals } = setup()
    const decode = deferred<AudioBuffer>()
    const spy = vi.spyOn(internals, 'decode').mockReturnValue(decode.promise)
    const pending = engine.loadIntoDeck(0, request('replacement'))
    await vi.waitFor(() => expect(spy).toHaveBeenCalledOnce())
    deck.isPlaying = true; decode.resolve(buffer)
    await expect(pending).rejects.toThrow('started playing')
    expect(deck.trackId).toBe('original')
    expect(deck.isPlaying).toBe(true)
    expect(deck.load).not.toHaveBeenCalled()
    expect(deck.loading).toBe(false)
  })
  it('rejects a playing deck before decoding and guards a late file read token', async () => {
    const { engine, deck, internals } = setup()
    const decode = vi.spyOn(internals, 'decode').mockResolvedValue(buffer)
    deck.isPlaying = true
    await expect(engine.loadIntoDeck(0, request('blocked'))).rejects.toThrow('Pause')
    expect(decode).not.toHaveBeenCalled()
    deck.isPlaying = false
    const old = engine.beginDeckLoad(0)
    await engine.loadIntoDeck(0, request('newer'))
    expect(await engine.loadIntoDeck(0, request('old-read'), old)).toBe(false)
    expect(deck.trackId).toBe('newer')
  })
  it('preserves current metadata and clears loading on decode failure', async () => {
    const { engine, deck, internals } = setup()
    vi.spyOn(internals, 'decode').mockRejectedValue(new Error('bad audio'))
    await expect(engine.loadIntoDeck(0, request('broken'))).rejects.toThrow('bad audio')
    expect(deck.trackId).toBe('original')
    expect(deck.load).not.toHaveBeenCalled()
    expect(deck.loading).toBe(false)
    expect(deck.error).toBe('bad audio')
  })
})
