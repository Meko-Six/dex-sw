import { validPower, type PowerAnalysis } from '../../shared/power'
import { crossfadeGains } from '../../shared/curves'
import { DEFAULT_JUMP_BARS, JUMP_LENGTHS_BARS } from '../../shared/beat-jump'
import type { BeatDetection } from '../../shared/detector'
import {
  type BeatGrid,
  beatPhase,
  doubleGrid as doubleGridValue,
  halveGrid as halveGridValue,
  nudgeGrid as nudgeGridValue,
  secToBeat,
  setGridBpm
} from '../../shared/grid'
import { emptyHotCues, type HotCueList } from '../../shared/hot-cue'
import { createLoop, doubleLoop, halfLoop, type LoopRegion, MAX_LOOP_BEATS, MIN_LOOP_BEATS, resizeLoop, stepLoopBeats } from '../../shared/loop'
import {
  phaseCorrectionBeats,
  alignedPositionSec,
  cueLeadInSec,
  phaseErrorBeats,
  SyncController,
  tempoRateFor
} from '../../shared/sync'
import { bridge } from '../lib/bridge'
import { Deck, LOOKAHEAD } from './deck'
import { DeckLoads } from './deck-loads'
import { WorkQueue } from './work-queue'
import { OutputRouter } from './routing'
import { TRIM_RANGE_DB } from '../../shared/mixer'
import type { WaveformLevels } from '../../shared/waveform-levels'
import type { AnalysisResult, DeckSnapshot, EngineSnapshot } from './types'

export interface LoadRequest {
  id: string
  name: string
  bytes: ArrayBuffer
  grid?: BeatGrid | null
  peaks?: Int8Array | null
  hotCues?: HotCueList
  power?: PowerAnalysis | null
  onPower?: (power: PowerAnalysis) => void
  trimDb?: number
}

interface AnalysisWorkerResult {
  bpm: number
  offsetMs: number
  confidence: number
  uncertain: boolean
  alternates: AnalysisResult['alternates']
  peaks: number[]
  power: PowerAnalysis
  key: AnalysisResult['key']
}

/** Where each deck's SYNC is kept between sessions. */
const SYNC_KEY = 'dex.sync'

const emptyDeck = (id: 'A' | 'B'): DeckSnapshot => ({
  id,
  trackId: null,
  trackName: null,
  durationSec: 0,
  grid: null,
  peaks: null,
  levels: null,
  power: null,
  playing: false,
  previewing: false,
  position: 0,
  baseRate: 1,
  rate: 1,
  keyLock: true,
  eq: { low: 1, mid: 1, high: 1 },
  kills: { low: false, mid: false, high: false },
  filter: 0,
  level: 1,
  trimDb: 0,
  cuePoint: 0,
  cue: false,
  loop: null,
  loopBeats: 8,
  jumpBars: DEFAULT_JUMP_BARS,
  hotCues: emptyHotCues(),
  syncLocked: false,
  isMaster: false,
  loading: false,
  error: null
})

/**
 * The mixer. Owns the single AudioContext, both decks, output routing, the
 * analysis worker and the sync/drift loop. React talks to this class and reads
 * immutable snapshots via useSyncExternalStore.
 */
export class MixEngine {
  private jobs = new WorkQueue()
  private loads = new DeckLoads()
  private disposed = false
  private ctx: AudioContext | null = null
  private router: OutputRouter | null = null
  private worker: Worker | null = null
  private workerDeadline: number | undefined
  private initPromise: Promise<void> | null = null
  private deckList: [Deck | null, Deck | null] = [null, null]
  private syncTimer: number | null = null
  private listeners = new Set<() => void>()
  private analysisQueue = new Map<
    number,
    { resolve: (value: AnalysisWorkerResult) => void; reject: (error: Error) => void }
  >()
  private analysisId = 0
  private levelsQueue = new Map<number, (result: { levels?: WaveformLevels; power?: PowerAnalysis; error?: string }) => void>()

  private crossfaderValue = 0.5
  private cueMixValue = 0.85
  private masterVolumeValue = 0.85
  private masterDeckIndex: 0 | 1 = 0
  private focusedDeckIndex: 0 | 1 = 0
  private ready = false
  private controllers: [SyncController, SyncController] = [new SyncController(), new SyncController()]
  private lastLoopBeats: [number, number] = [8, 8]
  private jumpLengths: [number, number] = [DEFAULT_JUMP_BARS, DEFAULT_JUMP_BARS]
  private snapshot: EngineSnapshot = {
    ready: false,
    decks: [emptyDeck('A'), emptyDeck('B')],
    crossfader: 0.5,
    cueMix: 0.85,
    masterVolume: 0.85,
    outputMode: 'split',
    sampleRate: 0,
    masterDeck: 0,
    focusedDeck: 0
  }

  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener)
    return () => {
      this.listeners.delete(listener)
    }
  }

  getSnapshot = (): EngineSnapshot => this.snapshot

  getDeck(index: 0 | 1): Deck | null {
    return this.deckList[index]
  }

  async init(): Promise<void> {
    if (this.disposed) throw new Error('Audio engine has been disposed')
    if (this.initPromise) return this.initPromise
    if (this.ready) return
    this.initPromise = (async () => {
      const context = new AudioContext({ latencyHint: 'interactive' })
      this.ctx = context
      const router = new OutputRouter(context)
      this.router = router
      const results = await Promise.allSettled([
        Deck.create({ context, id: 'A', masterBus: router.masterIn, cueBus: router.cueIn }),
        Deck.create({ context, id: 'B', masterBus: router.masterIn, cueBus: router.cueIn })
      ])
      const created = results.flatMap((result) => result.status === 'fulfilled' ? [result.value] : [])
      const failure = results.find((result) => result.status === 'rejected')
      if (failure || this.disposed) {
        for (const deck of created) deck.dispose()
        throw failure?.reason ?? new Error('Audio engine has been disposed')
      }
      const [a, b] = created
      this.deckList = [a, b]
      a.isMaster = true
      this.restoreSync()
      this.applyCrossfader()
      router.setCueMix(this.cueMixValue)
      router.setMasterVolume(this.masterVolumeValue)
      this.ready = true
      this.startSyncLoop()
      this.emit()
    })().catch(async (error) => {
      this.ready = false
      for (const deck of this.deckList) deck?.dispose()
      this.deckList = [null, null]
      this.router?.dispose()
      this.router = null
      const context = this.ctx
      this.ctx = null
      if (context && context.state !== 'closed') await context.close().catch(() => undefined)
      this.emit()
      throw error
    }).finally(() => { this.initPromise = null })
    return this.initPromise
  }

  async resume(): Promise<void> {
    if (this.ctx && this.ctx.state === 'suspended') {
      await this.ctx.resume()
    }
  }

  private deckSnapshot(index: 0 | 1): DeckSnapshot {
    const deck = this.deckList[index]
    const base = deck ? deck.snapshot() : emptyDeck(index === 0 ? 'A' : 'B')
    return { ...base, loopBeats: this.lastLoopBeats[index], jumpBars: this.jumpLengths[index] }
  }

  private emit(): void {
    this.snapshot = {
      ready: this.ready,
      decks: [this.deckSnapshot(0), this.deckSnapshot(1)],
      crossfader: this.crossfaderValue,
      cueMix: this.cueMixValue,
      masterVolume: this.masterVolumeValue,
      outputMode: this.router?.currentMode ?? 'split',
      sampleRate: this.ctx?.sampleRate ?? 0,
      masterDeck: this.masterDeckIndex,
      focusedDeck: this.focusedDeckIndex
    }
    for (const listener of this.listeners) listener()
  }

  private requireContext(): AudioContext {
    if (!this.ctx) throw new Error('Audio engine is not ready')
    return this.ctx
  }

  private requireDeck(index: 0 | 1): Deck {
    const deck = this.deckList[index]
    if (!deck) throw new Error('Deck is not ready')
    return deck
  }

  private startSyncLoop(): void {
    if (this.syncTimer !== null) return
    this.syncTimer = window.setInterval(() => {
      let transportChanged = false
      for (const index of [0, 1] as const) {
        const deck = this.deckList[index]
        if (!deck?.isPlaying || !deck.trackId || deck.durationSec <= 0) continue
        if (deck.position >= deck.durationSec - 0.03) {
          void deck.pause()
          transportChanged = true
        }
      }
      if (transportChanged) {
        this.claimMaster()
        this.emit()
      }

      for (const index of [0, 1] as const) {
        const follower = this.deckList[index]
        const master = this.deckList[index === 0 ? 1 : 0]
        if (index === this.masterDeckIndex || !follower?.syncLocked || !follower.isPlaying || !master?.isPlaying) continue
        if (!follower.grid || !master.grid) continue
        // Never fight a transport change that has not landed yet: schedules
        // cancel later pending changes, so a trim tick too soon after a seek
        // would silently undo the seek.
        if (follower.transportSettling || master.transportSettling) continue
        const error = phaseErrorBeats(master.position, master.grid, follower.position, follower.grid)
        const next = this.controllers[index].update(error)
        if (Math.abs(next - follower.trimValue) > 1e-5) follower.setTrim(next)
      }
    }, 250)
  }

  // ---- decoding and analysis -------------------------------------------------

  private async decode(bytes: ArrayBuffer): Promise<AudioBuffer> {
    const context = this.requireContext()
    try {
      return await context.decodeAudioData(bytes.slice(0))
    } catch (error) {
      if (this.disposed) throw error
      const wav = await bridge.transcodeToWav(bytes, 'track')
      if (!wav) throw error
      return await context.decodeAudioData(wav)
    }
  }

  private ensureWorker(): Worker {
    if (this.disposed) throw new Error('Audio engine disposed')
    if (this.worker) return this.worker
    const worker = new Worker(new URL('./analysis.worker.ts', import.meta.url), { type: 'module' })
    worker.onmessage = (event: MessageEvent) => {
      const data = event.data as {
        id: number
        detection?: Pick<BeatDetection, 'bpm' | 'offsetMs' | 'confidence' | 'uncertain' | 'alternates'>
        peaks?: number[]
        power?: PowerAnalysis
        key?: AnalysisResult['key']
        error?: string
      }
      window.clearTimeout(this.workerDeadline)
      const levelsDone = this.levelsQueue.get(data.id)
      if (levelsDone) {
        this.levelsQueue.delete(data.id)
        levelsDone(event.data)
        return
      }
      const pending = this.analysisQueue.get(data.id)
      if (!pending) return
      this.analysisQueue.delete(data.id)
      if (data.error || !data.detection || !data.peaks || !data.power) {
        pending.reject(new Error(data.error ?? 'Analysis failed'))
        return
      }
      pending.resolve({
        bpm: data.detection.bpm,
        offsetMs: data.detection.offsetMs,
        confidence: data.detection.confidence,
        uncertain: data.detection.uncertain,
        alternates: data.detection.alternates.map(({ bpm, offsetMs, relation }) => ({ bpm, offsetMs, relation })),
        peaks: data.peaks,
        power: data.power,
        key: data.key ?? null
      })
    }
    worker.onerror = (event) => this.failWorker(new Error(event.message || 'Analysis worker crashed'))
    this.worker = worker
    return worker
  }

  private failWorker(error: Error): void {
    window.clearTimeout(this.workerDeadline)
    for (const pending of this.analysisQueue.values()) pending.reject(error)
    this.analysisQueue.clear()
    for (const done of this.levelsQueue.values()) done({ error: error.message })
    this.levelsQueue.clear()
    this.worker?.terminate()
    this.worker = null
  }

  private armWorker(): void {
    window.clearTimeout(this.workerDeadline)
    this.workerDeadline = window.setTimeout(() => this.failWorker(new Error('Analysis timed out. Try the track again.')), 120000)
  }

  private runAnalysis(channels: Float32Array[], sampleRate: number): Promise<AnalysisWorkerResult> {
    return new Promise((resolve, reject) => {
      const worker = this.ensureWorker()
      const id = ++this.analysisId
      this.analysisQueue.set(id, { resolve, reject })
      const transfer = channels.map((channel) => channel.buffer as ArrayBuffer)
      this.armWorker()
      try { worker.postMessage({ id, channels, sampleRate }, transfer) }
      catch (error) { window.clearTimeout(this.workerDeadline); this.analysisQueue.delete(id); reject(error) }
    })
  }

  /**
   * The screen's fine waveform for a freshly loaded deck. Until it arrives the
   * lanes draw from the library's coarse peaks; it is dropped if another
   * track went onto the deck in the meantime.
   */
  private buildLevels(index: 0 | 1, buffer: AudioBuffer, request: LoadRequest): void {
    const version = this.requireDeck(index).loadVersion
    const needsPower = !validPower(request.power, buffer.duration)
    const originalPower = this.requireDeck(index).power
    void this.jobs.run(() => new Promise<void>((resolve) => {
      const channels: Float32Array[] = []
      for (let c = 0; c < Math.min(2, buffer.numberOfChannels); c++) channels.push(Float32Array.from(buffer.getChannelData(c)))
      const worker = this.ensureWorker()
      const id = ++this.analysisId
      this.levelsQueue.set(id, ({ levels, power, error }) => {
        resolve()
        const deck = this.deckList[index]
        if (!deck || deck.trackId !== request.id || deck.loadVersion !== version) return
        if (levels) deck.levels = levels
        if (power && deck.power === originalPower) {
          deck.power = power
          request.onPower?.(power)
        }
        if (error) console.warn('Waveform/energy analysis failed:', error)
        this.emit()
      })
      this.armWorker()
      try { worker.postMessage(
        { id, channels, sampleRate: buffer.sampleRate, kind: 'levels', grid: request.grid, power: needsPower },
        channels.map((channel) => channel.buffer as ArrayBuffer)
      ) } catch (error) { this.failWorker(error instanceof Error ? error : new Error(String(error))) }
    }), { key: `levels:${index}`, bytes: buffer.length * Math.min(2, buffer.numberOfChannels) * 4, priority: 1 }).catch((error) => {
      if (error.name !== 'AbortError') console.warn('Waveform job:', error)
    })
  }

  /** Decode + analyse without loading a deck (library ingestion). */
  async analyze(bytes: ArrayBuffer): Promise<AnalysisResult> {
    await this.init()
    return this.jobs.run(async () => {
      const buffer = await this.decode(bytes)
      const channels: Float32Array[] = []
      const count = Math.min(2, Math.max(1, buffer.numberOfChannels))
      for (let c = 0; c < count; c++) channels.push(Float32Array.from(buffer.getChannelData(c)))
      if (channels.length === 1) channels.push(Float32Array.from(channels[0]))
      const result = await this.runAnalysis(channels, buffer.sampleRate)
      return { durationSec: buffer.duration, ...result }
    }, { bytes: bytes.byteLength })
  }

  /** Reserve before reading the file, so selection order includes slow disk reads. */
  beginDeckLoad(index: 0 | 1): number {
    if (this.deckList[index]?.isPlaying) throw new Error('Pause the deck before loading another track.')
    this.jobs.cancel(`levels:${index}`)
    this.jobs.cancel(`decode:${index}`)
    const version = this.loads.request(index)
    const deck = this.deckList[index]
    if (deck?.loading) { deck.loading = false; this.emit() }
    return version
  }

  isDeckLoadCurrent(index: 0 | 1, version: number): boolean { return this.loads.current(index, version) }

  async loadIntoDeck(index: 0 | 1, request: LoadRequest, version = this.beginDeckLoad(index)): Promise<boolean> {
    await this.init()
    if (!this.loads.current(index, version)) return false
    const deck = this.requireDeck(index)
    if (deck.isPlaying) throw new Error('Pause the deck before loading another track.')
    deck.loading = true
    deck.error = null
    this.emit()
    try {
      const buffer = await this.jobs.run(() => this.decode(request.bytes), { key: `decode:${index}`, bytes: request.bytes.byteLength, priority: 2 })
      if (!this.loads.current(index, version)) return false
      let loaded = false
      await this.loads.commit(index, version, async () => {
        if (deck.isPlaying) throw new Error('The deck started playing. Pause it before loading another track.')
        loaded = await deck.load(buffer, {
          id: request.id,
          name: request.name,
          grid: request.grid ?? null,
          peaks: request.peaks ?? null,
          hotCues: request.hotCues,
          power: validPower(request.power, buffer.duration) ? request.power : null
        }, () => this.loads.current(index, version))
        if (!loaded) {
          if (this.loads.current(index, version) && deck.isPlaying) throw new Error('The deck started playing. Its current track was kept.')
          return
        }
        deck.setGainTrim(Math.max(-TRIM_RANGE_DB, Math.min(TRIM_RANGE_DB, request.trimDb ?? 0)))
        this.focusDeck(index)
        this.claimMaster()
        this.follow(0)
        this.follow(1)
        this.buildLevels(index, buffer, request)
        this.applyCrossfader()
      })
      return loaded && this.loads.current(index, version)
    } catch (error) {
      if (!this.loads.current(index, version)) return false
      deck.error = error instanceof Error ? error.message : String(error)
      throw error
    } finally {
      if (this.loads.current(index, version)) {
        deck.loading = false
        this.emit()
      }
    }
  }

  async dispose(): Promise<void> {
    if (this.disposed) return
    this.disposed = true
    this.loads.invalidate()
    this.jobs.dispose()
    if (this.syncTimer !== null) window.clearInterval(this.syncTimer)
    this.syncTimer = null
    await this.initPromise?.catch(() => undefined)
    for (const deck of this.deckList) deck?.dispose()
    this.deckList = [null, null]
    this.router?.dispose()
    this.router = null
    window.clearTimeout(this.workerDeadline)
    this.worker?.terminate()
    this.worker = null
    const error = new Error('Audio engine disposed')
    for (const job of this.analysisQueue.values()) job.reject(error)
    this.analysisQueue.clear()
    for (const done of this.levelsQueue.values()) done({ error: error.message })
    this.levelsQueue.clear()
    const context = this.ctx
    this.ctx = null
    if (context && context.state !== 'closed') await context.close()
    this.ready = false
    this.emit()
    this.listeners.clear()
  }

  // ---- transport -------------------------------------------------------------

  async togglePlay(index: 0 | 1): Promise<void> {
    const deck = this.requireDeck(index)
    this.focusDeck(index)

    // PLAY while CUE is held from the cue point: keep playing, as on a CDJ.
    if (this.continueCue(index)) return

    const start = this.syncedStart(index)
    if (start) await deck.playAt(start.rate, start.sec, start.when)
    else await deck.toggle()
    this.claimMaster()
    this.emit()
  }

  /**
   * How a paused deck has to start beside a playing one (which becomes
   * master). It lands on the master's closest beat within the track (normally
   * at most half a beat either side of where it is parked), so a start never
   * depends on hitting the key in time. With SYNC it also takes the master's
   * tempo; without, it keeps its own. Null when nothing is playing to snap to.
   * CUE uses a lead-in instead, preserving the attack at the saved cue point.
   */
  private syncedStart(index: 0 | 1, fromCue = false): { rate: number; sec: number; when: number } | null {
    const deck = this.requireDeck(index)
    const other = index === 0 ? 1 : 0
    const master = this.deckList[other]
    if (deck.isPlaying || !master?.isPlaying || !master.grid || !deck.grid) return null
    this.setMasterIndex(other)
    this.controllers[index].reset()
    const when = this.requireContext().currentTime + LOOKAHEAD
    const masterPosition = master.positionAt(when)
    const correction = phaseErrorBeats(masterPosition, master.grid, deck.position, deck.grid)
    const rate = deck.syncLocked ? tempoRateFor(master.grid.bpm * master.rate, deck.grid.bpm) : deck.baseRateValue
    const sec = fromCue
      ? cueLeadInSec(deck.cuePoint, masterPosition, master.grid, deck.grid)
      : alignedPositionSec(deck.position, correction, deck.grid, deck.durationSec)
    return { rate, sec, when }
  }

  async play(index: 0 | 1): Promise<void> {
    const deck = this.requireDeck(index)
    if (this.continueCue(index)) return
    const start = this.syncedStart(index)
    if (start) await deck.playAt(start.rate, start.sec, start.when)
    else await deck.play()
    this.claimMaster()
    this.emit()
  }

  async pause(index: 0 | 1): Promise<void> {
    const deck = this.requireDeck(index)
    await deck.pause()
    this.claimMaster()
    this.emit()
  }

  /** Latch an existing CUE preview without restarting or rescheduling audio. */
  continueCue(index: 0 | 1): boolean {
    const deck = this.requireDeck(index)
    if (!deck.previewing || !deck.isPlaying) return false
    deck.previewing = false
    this.emit()
    return true
  }

  async seek(index: 0 | 1, sec: number): Promise<void> {
    const deck = this.requireDeck(index)
    const master = this.deckList[index === 0 ? 1 : 0]
    if (deck.syncLocked && deck.isPlaying && master?.isPlaying && deck.grid && master.grid) {
      const when = this.requireContext().currentTime + LOOKAHEAD
      const position = Math.max(0, Math.min(deck.durationSec, sec))
      // A seek on the master keeps its partner's beat, without changing who
      // leads the tempo. A follower also refreshes its tempo match.
      const rate = index === this.masterDeckIndex ? deck.baseRateValue : tempoRateFor(master.grid.bpm * master.rate, deck.grid.bpm)
      const correction = phaseErrorBeats(master.positionAt(when), master.grid, position, deck.grid)
      deck.applySync(rate, alignedPositionSec(position, correction, deck.grid, deck.durationSec), when)
      this.controllers[index].reset()
    } else {
      await deck.seek(sec)
    }
    this.emit()
  }

  async stopAll(): Promise<void> {
    await Promise.all(this.deckList.map((deck) => deck?.pause()))
    this.emit()
  }

  /** Manual platter movement retains its exact fractional-beat position. */
  async scrub(index: 0 | 1, sec: number): Promise<void> {
    await this.requireDeck(index).seek(sec)
    this.controllers[index].reset()
    this.emit()
  }

  // ---- tempo and sync ---------------------------------------------------------

  setTempoRate(index: 0 | 1, rate: number): void {
    const deck = this.requireDeck(index)
    // Moving a follower's tempo takes it off SYNC; moving the master's carries its followers along.
    if (deck.syncLocked && index !== this.masterDeckIndex) this.unsyncDeck(index)
    deck.setTempoRate(rate)
    this.follow(index === 0 ? 1 : 0)
    this.emit()
  }

  nudgeTempo(index: 0 | 1, delta: number): void {
    const deck = this.requireDeck(index)
    this.setTempoRate(index, deck.baseRateValue + delta)
  }

  resetTempo(index: 0 | 1): void {
    this.setTempoRate(index, 1)
  }

  /** Match a deck's tempo to an external BPM (from the input tap). */
  matchTempoToBpm(index: 0 | 1, bpm: number): void {
    const deck = this.requireDeck(index)
    if (!deck.grid || bpm <= 0) return
    this.setTempoRate(index, tempoRateFor(bpm, deck.grid.bpm))
  }

  setKeyLock(index: 0 | 1, on: boolean): void {
    this.requireDeck(index).setKeyLock(on)
    this.emit()
  }

  // ---- beat grid editing ------------------------------------------------------

  setDeckGrid(index: 0 | 1, grid: BeatGrid): void {
    this.requireDeck(index).setGrid(grid)
    this.emit()
  }

  nudgeGrid(index: 0 | 1, deltaMs: number): void {
    const deck = this.requireDeck(index)
    if (!deck.grid) return
    deck.setGrid(nudgeGridValue(deck.grid, deltaMs))
    this.emit()
  }

  setGridBpm(index: 0 | 1, bpm: number): void {
    const deck = this.requireDeck(index)
    if (!deck.grid) return
    deck.setGrid(setGridBpm(deck.grid, bpm))
    this.emit()
  }

  halveGrid(index: 0 | 1): void {
    const deck = this.requireDeck(index)
    if (!deck.grid) return
    deck.setGrid(halveGridValue(deck.grid))
    this.emit()
  }

  doubleGrid(index: 0 | 1): void {
    const deck = this.requireDeck(index)
    if (!deck.grid) return
    deck.setGrid(doubleGridValue(deck.grid))
    this.emit()
  }

  /** Public re-render trigger for state changed directly on a deck. */
  commit(): void {
    this.emit()
  }

  setMaster(index: 0 | 1): void {
    this.setMasterIndex(index)
    this.requireDeck(index).setTrim(0)
    this.follow(index === 0 ? 1 : 0)
    this.emit()
  }

  private setMasterIndex(index: 0 | 1): void {
    this.masterDeckIndex = index
    this.deckList.forEach((deck, i) => {
      if (deck) deck.isMaster = i === index
    })
  }

  /** The deck playing on its own leads: MASTER moves to it, as on a CDJ. */
  private claimMaster(): void {
    const playing = ([0, 1] as const).filter((i) => this.deckList[i]?.isPlaying)
    if (playing.length === 1) this.setMasterIndex(playing[0])
  }

  /**
   * SYNC on. It is a setting of the deck, not of the track: it can be armed on
   * an empty deck, survives loads and restarts, and both decks can have it.
   * The deck playing leads; pressed on a stopped deck beside a loaded one, it
   * follows that one.
   */
  sync(index: 0 | 1): void {
    const deck = this.requireDeck(index)
    const other = index === 0 ? 1 : 0
    deck.syncLocked = true
    this.saveSync()
    const leader = this.deckList[other]
    if (index === this.masterDeckIndex && leader?.trackId && (leader.isPlaying || !deck.isPlaying)) this.setMasterIndex(other)
    this.follow(index, true)
    this.emit()
  }

  /**
   * A synced deck that is not master takes the master's tempo. With
   * `snapPhase`, a follower already playing beside a playing master also jumps
   * forward onto its beat (SYNC pressed mid-mix); otherwise the drift trim
   * keeps the phase.
   */
  private follow(index: 0 | 1, snapPhase = false): void {
    const deck = this.deckList[index]
    const master = this.deckList[index === 0 ? 1 : 0]
    if (!deck?.syncLocked || index === this.masterDeckIndex || !deck.grid || !master?.grid || !master.trackId) return
    const rate = tempoRateFor(master.grid.bpm * master.rate, deck.grid.bpm)
    this.controllers[index].reset()
    if (snapPhase && deck.isPlaying && master.isPlaying) {
      const when = this.requireContext().currentTime + LOOKAHEAD
      const position = deck.positionAt(when)
      const correction = phaseCorrectionBeats(beatPhase(master.grid, master.positionAt(when)), beatPhase(deck.grid, position))
      deck.applySync(rate, alignedPositionSec(position, correction, deck.grid, deck.durationSec), when)
    } else {
      deck.setTempoRate(rate)
      deck.setTrim(0)
    }
  }

  unsync(index: 0 | 1): void {
    this.unsyncDeck(index)
    this.emit()
  }

  private unsyncDeck(index: 0 | 1): void {
    const deck = this.deckList[index]
    if (!deck) return
    deck.syncLocked = false
    deck.setTrim(0)
    this.controllers[index].reset()
    this.saveSync()
  }

  /** SYNC per deck is kept between sessions, so the next load obeys it. */
  private saveSync(): void {
    try {
      localStorage.setItem(SYNC_KEY, JSON.stringify(this.deckList.map((deck) => Boolean(deck?.syncLocked))))
    } catch {
      // No storage (private window, blocked): SYNC lasts the session.
    }
  }

  private restoreSync(): void {
    // SYNC starts on: a new DJ gets matched tempo and beats without knowing the key.
    let saved: unknown = [true, true]
    try {
      saved = JSON.parse(localStorage.getItem(SYNC_KEY) ?? '[true,true]')
    } catch {
      // Unreadable: keep the default.
    }
    if (Array.isArray(saved)) this.deckList.forEach((deck, i) => deck && (deck.syncLocked = saved[i] === true))
  }

  // ---- mixing -----------------------------------------------------------------

  setCrossfader(value: number): void {
    this.crossfaderValue = Math.max(0, Math.min(1, value))
    this.applyCrossfader()
    this.emit()
  }

  private applyCrossfader(): void {
    const [a, b] = crossfadeGains(this.crossfaderValue)
    this.deckList[0]?.setCrossfadeGain(a)
    this.deckList[1]?.setCrossfadeGain(b)
  }

  setCue(index: 0 | 1, on: boolean): void {
    this.requireDeck(index).setCue(on)
    this.emit()
  }

  /** Returns true when the press captured a new cue (so the library can save it). */
  async triggerHotCue(index: 0 | 1, slot: number): Promise<boolean> {
    const deck = this.requireDeck(index)
    const target = deck.hotCues[slot]
    if (deck.trackId && target != null) {
      await this.seek(index, target)
      return false
    }
    const captured = await deck.triggerHotCue(slot)
    this.emit()
    return captured
  }

  clearHotCue(index: 0 | 1, slot: number): void {
    this.requireDeck(index).clearHotCue(slot)
    this.emit()
  }

  setCueMix(value: number): void {
    this.cueMixValue = Math.max(0, Math.min(1, value))
    this.router?.setCueMix(this.cueMixValue)
    this.emit()
  }

  setMasterVolume(value: number): void {
    this.masterVolumeValue = Math.max(0, Math.min(1.2, value))
    this.router?.setMasterVolume(this.masterVolumeValue)
    this.emit()
  }

  /** Cut-only EQ fader, 0 (foot) … 1 (unity). */
  setEqFader(index: 0 | 1, band: 'low' | 'mid' | 'high', position: number): void {
    this.requireDeck(index).setEqFader(band, position)
    this.emit()
  }

  setEqKill(index: 0 | 1, band: 'low' | 'mid' | 'high', on: boolean): void {
    this.requireDeck(index).setEqKill(band, on)
    this.emit()
  }

  /** Channel fader, 0 … 1. */
  setLevel(index: 0 | 1, position: number): void {
    this.requireDeck(index).setLevel(position)
    this.emit()
  }

  setGainTrim(index: 0 | 1, db: number): void {
    this.requireDeck(index).setGainTrim(Math.max(-TRIM_RANGE_DB, Math.min(TRIM_RANGE_DB, db)))
    this.emit()
  }

  async cueDown(index: 0 | 1): Promise<void> {
    this.focusDeck(index)
    const deck = this.requireDeck(index)
    // Keep the cue attack: lead into it on the master's beat instead of
    // seeking past it, which can skip the very first kick of a loaded track.
    const start = deck.atCue ? this.syncedStart(index, true) : null
    if (start) await deck.previewAt(start.rate, start.sec, start.when)
    else await deck.cueDown()
    this.claimMaster()
    this.emit()
  }

  async cueUp(index: 0 | 1): Promise<void> {
    await this.requireDeck(index).cueUp()
    this.emit()
  }

  setFilter(index: 0 | 1, knob: number): void {
    this.requireDeck(index).setFilter(knob)
    this.emit()
  }

  setOutputMode(mode: 'split' | 'multichannel'): void {
    this.router?.setMode(mode)
    this.emit()
  }

  focusDeck(index: 0 | 1): void {
    if (this.focusedDeckIndex === index) return
    this.focusedDeckIndex = index
    this.emit()
  }

  readMeterDb(): number {
    return this.router?.readLevelDb() ?? -60
  }

  // ---- loops ------------------------------------------------------------------

  async setLoopBars(index: 0 | 1, bars: number, immediate = false): Promise<void> {
    const deck = this.requireDeck(index)
    if (!deck.grid) return
    const lengthBeats = Math.max(1, Math.round(bars * 4))
    this.lastLoopBeats[index] = lengthBeats
    const region: LoopRegion = immediate
      ? { startBeat: Math.floor(secToBeat(deck.grid, deck.position)), lengthBeats }
      : createLoop(deck.grid, deck.position, lengthBeats, 'beat')
    await deck.beginLoop(region, immediate ? 'immediate' : 'quantized')
    this.emit()
  }

  async exitLoop(index: 0 | 1, immediate = false): Promise<void> {
    await this.requireDeck(index).exitLoop(immediate)
    this.emit()
  }

  /** Drag the selected loop along the track in whole-beat steps. */
  moveLoop(index: 0 | 1, startBeat: number): void {
    const deck = this.requireDeck(index)
    const before = deck.loopRegion?.startBeat
    deck.moveLoop(startBeat)
    if (deck.loopRegion?.startBeat !== before) this.emit()
  }

  halveLoop(index: 0 | 1): void {
    const deck = this.requireDeck(index)
    if (!deck.loopRegion || !deck.grid) return
    const next = resizeLoop(deck.loopRegion, halfLoop(deck.loopRegion).lengthBeats, secToBeat(deck.grid, deck.position))
    deck.updateLoop(next)
    this.lastLoopBeats[index] = next.lengthBeats
    this.emit()
  }

  doubleLoop(index: 0 | 1): void {
    const deck = this.requireDeck(index)
    if (!deck.loopRegion) return
    const next = doubleLoop(deck.loopRegion)
    deck.updateLoop(next)
    this.lastLoopBeats[index] = next.lengthBeats
    this.emit()
  }

  /**
   * Loop stepper: set the size the next loop or roll uses. A running loop
   * takes the new length straight away: growing keeps its start, shrinking
   * keeps the part the playhead is in.
   */
  setLoopSize(index: 0 | 1, beats: number): void {
    const lengthBeats = Math.min(MAX_LOOP_BEATS, Math.max(MIN_LOOP_BEATS, Math.round(beats)))
    this.lastLoopBeats[index] = lengthBeats
    const deck = this.deckList[index]
    if (deck?.loopRegion && deck.grid) deck.updateLoop(resizeLoop(deck.loopRegion, lengthBeats, secToBeat(deck.grid, deck.position)))
    this.emit()
  }

  /**
   * Loop stepper arrows. Steps from the engine's own size, not a rendered
   * copy, so taps faster than a re-render still each take a step.
   */
  stepLoopSize(index: 0 | 1, direction: -1 | 1): void {
    this.setLoopSize(index, stepLoopBeats(this.lastLoopBeats[index], direction))
  }

  /** Loop stepper readout: start a quantised loop at the stepper size, or leave the running one. */
  async toggleLoop(index: 0 | 1): Promise<void> {
    const deck = this.requireDeck(index)
    if (deck.loopRegion) {
      await this.exitLoop(index)
      return
    }
    await this.setLoopBars(index, this.lastLoopBeats[index] / 4)
  }

  async startRoll(index: 0 | 1): Promise<void> {
    const deck = this.requireDeck(index)
    if (!deck.grid) return
    const lengthBeats = this.lastLoopBeats[index]
    const region: LoopRegion = {
      startBeat: Math.floor(secToBeat(deck.grid, deck.position)),
      lengthBeats
    }
    await deck.beginLoop(region, 'immediate')
    this.emit()
  }

  async endRoll(index: 0 | 1): Promise<void> {
    await this.requireDeck(index).endRoll()
    this.emit()
  }

  // ---- beat jump --------------------------------------------------------------

  /** The jump selector: how many bars one press of ◀ or ▶ moves. */
  setJumpBars(index: 0 | 1, bars: number): void {
    if (!(JUMP_LENGTHS_BARS as readonly number[]).includes(bars)) return
    this.jumpLengths[index] = bars
    this.emit()
  }

  /** ◀ / ▶: one jump of the selected length. A running loop moves with it. */
  beatJump(index: 0 | 1, direction: -1 | 1): void {
    const deck = this.deckList[index]
    if (!deck) return
    this.focusDeck(index)
    deck.jumpBars(direction * this.jumpLengths[index])
    this.emit()
  }

  /** Overview click: jump to the bar under `sec`, in phase. Without a grid it is a plain seek. */
  async jumpToBar(index: 0 | 1, sec: number): Promise<void> {
    const deck = this.requireDeck(index)
    if (!deck.grid) {
      await this.seek(index, sec)
      return
    }
    deck.jumpToBar(sec)
    this.emit()
  }
}

export const engine = new MixEngine()

// Dev-only handle so the renderer can be inspected/measured from the browser
// console (and by the headless verification pass). Stripped from production builds.
if (import.meta.env.DEV && typeof window !== 'undefined') {
  ;(window as unknown as { __engine?: MixEngine }).__engine = engine
}
