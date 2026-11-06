import createStretch, { type StretchNode, type StretchScheduleOptions } from 'signalsmith-stretch'
import { jumpByBars, jumpToBarAt, moveLoopByBars, type JumpDeck, type JumpResult } from '../../shared/beat-jump'
import { dbToGain, ratioToSemitones } from '../../shared/curves'
import { type BeatGrid } from '../../shared/grid'
import { clearHotCueAt, emptyHotCues, normalizeHotCues, pressHotCue, type HotCueList } from '../../shared/hot-cue'
import { type LoopRegion, loopSeconds, moveLoopToBeat, rollReleaseSec } from '../../shared/loop'
import { faderGain } from '../../shared/mixer'
import type { PowerAnalysis } from '../../shared/power'
import type { WaveformLevels } from '../../shared/waveform-levels'
import { effectiveRate } from '../../shared/sync'
import { EqChain, type EqBand } from './eq'
import type { DeckSnapshot } from './types'
import { TransportClock } from './transport-clock'

/** How far ahead transport changes are scheduled, in seconds. */
export const LOOKAHEAD = 0.03

export interface DeckLoadMeta {
  id: string
  name: string
  grid: BeatGrid | null
  peaks: Int8Array | null
  /** Saved hot cues to restore with the track. */
  hotCues?: HotCueList
  power?: PowerAnalysis | null
}

export interface DeckOptions {
  context: BaseAudioContext
  id: 'A' | 'B'
  masterBus: AudioNode
  cueBus: AudioNode
}

/**
 * One deck: a Signalsmith Stretch worklet that owns the decoded buffer and the
 * authoritative playback position, feeding the input trim, the tone section
 * (3-band isolator plus a sweep filter) and then the channel fader into the
 * master bus. Headphone cue taps after the tone section, before the fader.
 *
 * The EQ bands are cut-only fader positions (0 … 1, see shared/mixer.ts) with
 * kills as separate latches, so releasing a kill restores the exact level.
 *
 * The stretch node handles tempo without pitch change, native buffer looping
 * and its own latency compensation, which is why transport lives on it rather
 * than on an AudioBufferSourceNode.
 */
export class Deck {
  readonly id: 'A' | 'B'
  readonly context: BaseAudioContext
  source: StretchNode
  private readonly trimGain: GainNode
  private readonly eq: EqChain
  private readonly channelGain: GainNode
  private readonly cueGain: GainNode

  trackId: string | null = null
  trackName: string | null = null
  durationSec = 0
  grid: BeatGrid | null = null
  peaks: Int8Array | null = null
  levels: WaveformLevels | null = null
  power: PowerAnalysis | null = null
  /** Changes even when the same track is loaded again. */
  loadVersion = 0
  loopRegion: LoopRegion | null = null
  hotCues: HotCueList = emptyHotCues()
  cue = false
  keyLock = true
  eqFaders: Record<EqBand, number> = { low: 1, mid: 1, high: 1 }
  eqKills: Record<EqBand, boolean> = { low: false, mid: false, high: false }
  filterKnob = 0
  /** Channel fader position, 0 … 1. */
  level = 1
  /** Input gain in dB, set once per track. */
  gainTrimDb = 0
  /** CDJ cue point in seconds. */
  cuePoint = 0
  /** True while CUE is held from the cue point (CDJ preview). */
  previewing = false
  syncLocked = false
  isMaster = false
  loading = false
  error: string | null = null

  private playing = false
  private pausedPos = 0
  private clock = new TransportClock()
  private baseRate = 1
  private trim = 0
  /** Crossfader gain for this side, multiplied with the channel fader. */
  private crossfadeGain = 0
  private rollActive = false
  private rollAnchor = 0
  private rollStartedAt = 0
  /** Last loop bounds pushed to the worklet, so we only resend them when they change. */
  private lastLoopSent: { start: number; end: number } | null = null
  /** Scheduled output time of the last transport change (seek/play/loop). */
  private transportAt = 0
  /**
   * Ignore position reports until this context time. After a seek the worklet
   * keeps reporting the pre-seek position for a few blocks; folding those into
   * the clock drags the playhead backwards and makes a rate-shifted deck run
   * visibly slow.
   */
  private ignoreReportsUntil = 0

  private constructor(options: DeckOptions, source: StretchNode) {
    this.id = options.id
    this.context = options.context
    this.source = source

    this.trimGain = options.context.createGain()
    this.eq = new EqChain(options.context)
    this.channelGain = options.context.createGain()
    this.cueGain = options.context.createGain()
    this.channelGain.gain.value = 0
    this.cueGain.gain.value = 0

    source.connect(this.trimGain)
    this.trimGain.connect(this.eq.input)
    this.eq.output.connect(this.channelGain)
    this.eq.output.connect(this.cueGain)
    this.channelGain.connect(options.masterBus)
    this.cueGain.connect(options.cueBus)

    void this.source.setUpdateInterval(0.03, (time: number) => { if (this.source === source) this.onPositionReport(time) })
  }

  /**
   * Reconcile the worklet's reported position with our clock.
   *
   * Position reports are only used to catch genuine discontinuities. They are
   * not folded into the clock continuously: the worklet reports its read head,
   * including processing lookahead, rather than the sample currently audible.
   * Blending that into the output clock injects a phase error into sync.
   *
   * Our clock advances on the AudioContext timeline, which is also what the
   * scheduler uses, so it stays correct as long as play starts and rate changes
   * go through the same schedule calls.
   */
  private onPositionReport(reported: number): void {
    const now = this.context.currentTime
    if (now < this.ignoreReportsUntil) return
    if (!this.playing) return
    const expected = this.positionAt(now)
    let delta = reported - expected
    if (this.loopRegion && this.grid) {
      const { lengthSec } = loopSeconds(this.grid, this.loopRegion)
      if (lengthSec > 0 && Math.abs(delta) > lengthSec / 2) {
        delta -= Math.sign(delta) * lengthSec
      }
    }
    // Only a real jump (worklet reset, a loop we did not schedule) re-anchors.
    if (Math.abs(delta) > 0.5) {
      this.clock.schedule(now, this.rate, reported)
    }
  }

  static async create(options: DeckOptions): Promise<Deck> {
    const source = await createStretch(options.context)
    return new Deck(options, source)
  }

  get isPlaying(): boolean {
    return this.playing
  }

  get baseRateValue(): number {
    return this.baseRate
  }

  get trimValue(): number {
    return this.trim
  }

  /** Current content speed including drift trim. */
  get rate(): number {
    return effectiveRate(this.baseRate, this.trim)
  }

  get position(): number {
    return this.positionAt(this.context.currentTime)
  }

  /** True until the queued transport change has reached the audio and settled. */
  get transportSettling(): boolean {
    return this.context.currentTime - this.transportAt < 0.2
  }

  positionAt(when = this.context.currentTime): number {
    if (!this.playing) return this.pausedPos
    let pos = this.clock.positionAt(when)
    if (this.loopRegion && this.grid) {
      const { startSec, lengthSec } = loopSeconds(this.grid, this.loopRegion)
      if (lengthSec > 0 && pos >= startSec + lengthSec) {
        pos = startSec + ((pos - startSec) % lengthSec)
      }
    }
    // A quantized CUE can lead into the start of the file. The worklet pads
    // negative input with silence; retain that phase in the sync clock too.
    return Math.min(this.durationSec, pos)
  }

  private semitones(): number {
    // Key lock keeps pitch fixed; vinyl mode moves pitch with the tempo.
    return this.keyLock ? 0 : ratioToSemitones(this.baseRate)
  }

  /**
   * Push a transport change to the worklet.
   *
   * `input` is a seek and is only sent when a seek is actually intended: the
   * stretch node advances its read position by a block when it receives an
   * input jump, so sending the predicted position on every rate/trim update
   * makes the deck run away from the timeline.
   */
  private schedule(options: { when?: number; active?: boolean; input?: number; forceLoop?: boolean } = {}): void {
    const { when, forceLoop, ...rest } = options
    if (rest.input !== undefined || forceLoop) this.transportAt = when ?? this.context.currentTime + LOOKAHEAD
    if (rest.input !== undefined) {
      this.ignoreReportsUntil = Math.max(this.ignoreReportsUntil, (when ?? this.context.currentTime + LOOKAHEAD) + 0.15)
    }
    const payload: StretchScheduleOptions = {
      output: when ?? this.context.currentTime + LOOKAHEAD,
      active: rest.active ?? this.playing,
      rate: this.rate,
      semitones: this.semitones(),
      ...(rest.input !== undefined ? { input: rest.input } : {})
    }
    this.clock.schedule(payload.output!, payload.active ? this.rate : 0, rest.input)

    const loop = this.loopRegion && this.grid ? loopSeconds(this.grid, this.loopRegion) : null
    const next = loop ? { start: loop.startSec, end: loop.endSec } : { start: 0, end: 0 }
    const changed = !this.lastLoopSent || Math.abs(this.lastLoopSent.start - next.start) > 1e-6 || Math.abs(this.lastLoopSent.end - next.end) > 1e-6
    if (forceLoop || changed) {
      payload.loopStart = next.start
      payload.loopEnd = next.end
      this.lastLoopSent = next
    }
    void this.source.schedule(payload).catch(() => undefined)
  }

  async load(buffer: AudioBuffer, meta: DeckLoadMeta, eligible = () => true): Promise<boolean> {
    // Prepare a disconnected replacement. Failures leave the current track intact.
    const source = await createStretch(this.context)
    try {
      const channels: Float32Array[] = []
      const count = Math.min(2, Math.max(1, buffer.numberOfChannels))
      for (let c = 0; c < count; c++) channels.push(Float32Array.from(buffer.getChannelData(c)))
      if (channels.length === 1) channels.push(Float32Array.from(channels[0]))
      await source.addBuffers(channels, channels.map((channel) => channel.buffer as ArrayBuffer))
      await source.setUpdateInterval(0.03, (time: number) => { if (this.source === source) this.onPositionReport(time) })
      if (!eligible() || this.playing) {
        this.releaseSource(source)
        return false
      }
    } catch (error) {
      this.releaseSource(source)
      throw error
    }
    const previous = this.source
    this.source = source
    source.connect(this.trimGain)
    this.releaseSource(previous)
    this.resetTransport()
    this.trackId = meta.id
    this.trackName = meta.name
    this.grid = meta.grid
    this.peaks = meta.peaks
    this.levels = null
    this.power = meta.power ?? null
    this.durationSec = buffer.duration
    this.hotCues = normalizeHotCues(meta.hotCues, buffer.duration)
    // Auto-cue: the first downbeat when there is a grid, else the very start.
    // The playhead waits on it, as a CDJ's does, so the first CUE press
    // previews from the cue instead of moving the cue back to 0:00.
    this.cuePoint = meta.grid ? Math.max(0, meta.grid.offsetMs / 1000) : 0
    this.pausedPos = this.cuePoint
    this.previewing = false
    this.error = null

    this.lastLoopSent = null
    this.schedule({ active: false, input: this.cuePoint, when: this.context.currentTime + 0.01, forceLoop: true })
    return true
  }

  private releaseSource(source: StretchNode): void {
    source.disconnect()
    void source.dropBuffers().catch(() => undefined).finally(() => source.port.close())
  }

  dispose(): void {
    this.loadVersion++
    this.releaseSource(this.source)
    this.trimGain.disconnect()
    this.eq.disconnect()
    this.channelGain.disconnect()
    this.cueGain.disconnect()
  }

  async unload(): Promise<void> {
    this.resetTransport()
    this.trackId = null
    this.trackName = null
    this.grid = null
    this.peaks = null
    this.levels = null
    this.power = null
    this.durationSec = 0
    await this.source.dropBuffers()
    this.lastLoopSent = null
    this.schedule({ active: false, input: 0, forceLoop: true })
  }

  private resetTransport(): void {
    this.loadVersion++
    this.playing = false
    this.pausedPos = 0
    this.clock.reset(this.context.currentTime)
    this.baseRate = 1
    this.trim = 0
    this.loopRegion = null
    this.hotCues = emptyHotCues()
    this.rollActive = false
  }

  /**
   * Start playing at an explicit rate and position.
   *
   * Used by SYNC when the follower is paused: pressing play has to land on the
   * master's beat, not wherever the deck happened to stop. Doing it as one
   * scheduled transport change avoids the rate change and seek cancelling each
   * other.
   */
  async playAt(rate: number, targetSec: number, when = this.context.currentTime + LOOKAHEAD): Promise<void> {
    if (!this.trackId || this.playing) return
    this.baseRate = Math.max(0.5, Math.min(2, rate))
    this.trim = 0
    // Explicit starts may include CUE pre-roll before 0:00. Ordinary seeks
    // still clamp to the file; the worklet supplies silence for this lead-in.
    const target = Math.min(this.durationSec, targetSec)
    this.playing = true
    this.pausedPos = target
    this.lastLoopSent = null
    this.schedule({ active: true, input: target, when, forceLoop: true })
  }

  async play(): Promise<void> {
    if (!this.trackId || this.playing) return
    let pos = this.pausedPos
    if (this.loopRegion && this.grid) {
      const { startSec, endSec } = loopSeconds(this.grid, this.loopRegion)
      if (pos < startSec || pos >= endSec) pos = startSec
    }
    const when = this.context.currentTime + LOOKAHEAD
    this.playing = true
    this.lastLoopSent = null
    this.schedule({ active: true, input: pos, when, forceLoop: true })
  }

  async pause(): Promise<void> {
    if (!this.trackId || !this.playing) return
    const when = this.context.currentTime + LOOKAHEAD
    const pos = this.positionAt(when)
    this.playing = false
    this.pausedPos = pos
    this.schedule({ active: false, input: pos, when })
  }

  async toggle(): Promise<void> {
    if (this.playing) await this.pause()
    else await this.play()
  }

  async seek(sec: number): Promise<void> {
    if (!this.trackId) return
    const target = Math.max(0, Math.min(this.durationSec, sec))
    const when = this.context.currentTime + LOOKAHEAD
    this.pausedPos = target
    this.schedule({ active: this.playing, input: target, when })
  }

  /** Beat jump by whole bars (signed). Returns the bars actually moved. */
  jumpBars(bars: number): number {
    return this.jump((deck) => jumpByBars(deck, bars))
  }

  /** Overview click: jump to the bar under `sec`, keeping the place in the bar. */
  jumpToBar(sec: number): number {
    return this.jump((deck) => jumpToBarAt(deck, sec))
  }

  /**
   * Move the playhead, and a running loop with it, in one scheduled change.
   *
   * The jump is worked out from where the deck will be when the change lands
   * (LOOKAHEAD from now), not where it is now: a playing deck moves ~30 ms in
   * between, and starting from "now" would land it that far off the beat.
   */
  private jump(plan: (deck: JumpDeck) => JumpResult): number {
    if (!this.trackId || !this.grid) return 0
    const when = this.context.currentTime + LOOKAHEAD
    const { sec, bars } = plan({
      grid: this.grid,
      positionSec: this.positionAt(when),
      durationSec: this.durationSec,
      playing: this.playing,
      loop: this.loopRegion
    })
    if (bars === 0 && Math.abs(sec - this.positionAt(when)) < 1e-6) return 0
    const loopMoves = bars !== 0 && this.loopRegion != null
    if (loopMoves && this.loopRegion) this.loopRegion = moveLoopByBars(this.loopRegion, bars)
    // A roll's release point moves with it, so letting go lands in the new place.
    if (this.rollActive) this.rollAnchor += sec - this.positionAt(when)
    this.pausedPos = sec
    this.schedule({ active: this.playing, input: sec, when, forceLoop: loopMoves })
    return bars
  }

  setTempoRate(rate: number): void {
    this.baseRate = Math.max(0.5, Math.min(2, rate))
    if (this.playing) this.schedule({ active: true })
  }

  /**
   * Tempo + phase alignment in one scheduled change. Doing these as two
   * separate calls is unsafe: each schedule cancels any change queued after it,
   * so a rate change could be dropped by the seek that follows it.
   */
  applySync(rate: number, targetSec: number, when = this.context.currentTime + LOOKAHEAD): void {
    this.baseRate = Math.max(0.5, Math.min(2, rate))
    this.trim = 0
    const target = Math.max(0, Math.min(this.durationSec, targetSec))
    this.pausedPos = target
    this.lastLoopSent = null
    this.schedule({ active: this.playing, input: target, when, forceLoop: true })
  }

  setTrim(trim: number): void {
    if (Math.abs(trim - this.trim) < 1e-6) return
    this.trim = trim
    if (this.playing) this.schedule({ active: true })
  }

  setKeyLock(on: boolean): void {
    this.keyLock = on
    this.schedule({ active: this.playing })
  }

  setEqFader(band: EqBand, position: number): void {
    this.eqFaders[band] = Math.max(0, Math.min(1, position))
    this.applyBand(band)
  }

  setEqKill(band: EqBand, on: boolean): void {
    this.eqKills[band] = on
    this.applyBand(band)
  }

  private applyBand(band: EqBand): void {
    this.eq.setBandGain(band, this.eqKills[band] ? 0 : faderGain(this.eqFaders[band]))
  }

  setLevel(position: number): void {
    this.level = Math.max(0, Math.min(1, position))
    this.applyChannelGain()
  }

  setGainTrim(db: number): void {
    this.gainTrimDb = db
    this.trimGain.gain.setTargetAtTime(dbToGain(db), this.context.currentTime, 0.015)
  }

  setFilter(knob: number): void {
    this.filterKnob = Math.max(-1, Math.min(1, knob))
    this.eq.setFilter(this.filterKnob)
  }

  setCrossfadeGain(gain: number): void {
    this.crossfadeGain = Math.max(0, gain)
    this.applyChannelGain()
  }

  private applyChannelGain(): void {
    const gain = this.crossfadeGain * faderGain(this.level)
    this.channelGain.gain.setTargetAtTime(gain, this.context.currentTime, 0.015)
  }

  /**
   * CDJ CUE, pressed. Playing: back to the cue point and stop. Paused on the
   * cue point: play for as long as it is held. Paused anywhere else: that
   * spot becomes the cue point.
   */
  async cueDown(): Promise<void> {
    if (!this.trackId) return
    if (this.playing) {
      this.previewing = false
      await this.pause()
      await this.seek(this.cuePoint)
      return
    }
    if (this.atCue) {
      this.previewing = true
      await this.play()
      return
    }
    this.cuePoint = this.pausedPos
  }

  /** Paused on the cue point, where CUE previews rather than setting a new cue. */
  get atCue(): boolean {
    return Boolean(this.trackId) && !this.playing && Math.abs(this.pausedPos - this.cuePoint) < 0.02
  }

  /** A CUE preview with a phase-aligned lead-in that preserves the cue attack. */
  async previewAt(rate: number, startSec: number, when?: number): Promise<void> {
    this.previewing = true
    await this.playAt(rate, startSec, when)
  }

  /** CUE released: a preview drops back to the cue point. */
  async cueUp(): Promise<void> {
    if (!this.previewing) return
    this.previewing = false
    await this.pause()
    await this.seek(this.cuePoint)
  }

  setCue(on: boolean): void {
    this.cue = on
    this.cueGain.gain.setTargetAtTime(on ? 1 : 0, this.context.currentTime, 0.01)
  }

  /**
   * Set or recall a hot cue at the playhead. An empty slot captures the
   * position; a filled slot seeks back to it. Play/pause is left alone, so a
   * cue works both as a jump while running and as a locate while paused.
   */
  async triggerHotCue(slot: number): Promise<boolean> {
    if (!this.trackId) return false
    const previous = this.hotCues
    const { cues, seekTo } = pressHotCue(previous, slot, this.position, this.durationSec)
    this.hotCues = cues
    if (seekTo != null) {
      await this.seek(seekTo)
      return false
    }
    return cues !== previous
  }

  clearHotCue(slot: number): void {
    this.hotCues = clearHotCueAt(this.hotCues, slot)
  }

  setGrid(grid: BeatGrid | null): void {
    this.grid = grid
    if (this.loopRegion) this.schedule({ active: this.playing, forceLoop: true })
  }

  /**
   * Start (or replace) a loop. `quantized` waits for the loop's own start
   * boundary so the seam lands on a beat; `immediate` starts from wherever the
   * playhead is (used for loop roll).
   */
  async beginLoop(region: LoopRegion, mode: 'quantized' | 'immediate' = 'quantized'): Promise<void> {
    if (!this.grid) return
    const { startSec, lengthSec } = loopSeconds(this.grid, region)
    if (lengthSec <= 0.01) return
    this.loopRegion = { ...region }

    if (!this.playing) {
      this.pausedPos = startSec
      this.schedule({ active: false, input: startSec })
      return
    }

    const now = this.context.currentTime
    const current = this.positionAt(now)
    this.rollActive = mode === 'immediate'
    this.rollAnchor = current
    this.rollStartedAt = now

    let when = now + LOOKAHEAD
    if (mode === 'quantized') {
      const untilStart = Math.max(0, (startSec - current) / Math.max(0.01, this.rate))
      when = now + Math.max(LOOKAHEAD, untilStart)
      // A boundary inside LOOKAHEAD has already passed when the command lands.
      // Advance from it instead of seeking back and losing that much phase.
      const target = startSec + (when - now - untilStart) * this.rate
      this.schedule({ active: true, input: target, when, forceLoop: true })
    } else {
      // Immediate/roll: keep the playhead where it is, just constrain it.
      this.schedule({ active: true, when, forceLoop: true })
    }
  }

  /** Change the active loop's boundaries without stopping playback. */
  updateLoop(region: LoopRegion): void {
    if (!this.grid) return
    this.loopRegion = { ...region }
    this.schedule({ active: this.playing, forceLoop: true })
  }

  /** Move an active loop and playhead together, retaining the phase within it. */
  moveLoop(startBeat: number): void {
    if (!this.grid || !this.loopRegion) return
    const previous = this.loopRegion
    const next = moveLoopToBeat(this.grid, previous, startBeat, this.durationSec)
    if (next.startBeat === previous.startBeat) return
    const when = this.context.currentTime + LOOKAHEAD
    const before = loopSeconds(this.grid, previous)
    const after = loopSeconds(this.grid, next)
    // positionAt already wraps a running loop. Retain a negative offset too:
    // a newly armed loop may still be waiting for its first beat to arrive.
    const offset = this.positionAt(when) - before.startSec
    const target = after.startSec + offset
    if (this.rollActive) this.rollAnchor += after.startSec - before.startSec
    this.loopRegion = next
    this.pausedPos = target
    this.schedule({ active: this.playing, input: target, when, forceLoop: true })
  }

  /**
   * Leave the loop. By default playback continues from the loop end at the
   * moment it would have wrapped, which keeps the mix on the grid. A roll
   * release instead jumps to where the track would have reached.
   */
  async exitLoop(immediate = false): Promise<void> {
    if (!this.loopRegion || !this.grid) return
    const { endSec } = loopSeconds(this.grid, this.loopRegion)
    const now = this.context.currentTime
    // Read the wrapped position while the loop still exists. Clearing it first
    // exposes all elapsed repetitions and schedules the exit on the wrong beat.
    const current = this.positionAt(now)
    const immediateTarget = this.positionAt(now + LOOKAHEAD)
    const wasRoll = this.rollActive
    const rollAnchor = this.rollAnchor
    const rollStartedAt = this.rollStartedAt
    if (this.playing) this.clock.schedule(now, this.rate, current)
    this.loopRegion = null
    this.rollActive = false

    if (!this.playing) {
      this.pausedPos = endSec
      this.schedule({ active: false, input: endSec })
      return
    }

    if (immediate) {
      const when = now + LOOKAHEAD
      this.schedule({ active: true, input: immediateTarget, when, forceLoop: true })
      return
    }

    const untilEnd = Math.max(0, (endSec - current) / Math.max(0.01, this.rate))
    const when = now + Math.max(LOOKAHEAD, untilEnd)
    const target = wasRoll
      ? rollReleaseSec(rollAnchor, when - rollStartedAt, this.rate)
      : endSec + (when - now - untilEnd) * this.rate
    this.lastLoopSent = null
    this.schedule({ active: true, input: Math.min(this.durationSec, target), when, forceLoop: true })
  }

  /** Release a loop roll: jump to where the track would have reached. */
  async endRoll(): Promise<void> {
    if (!this.rollActive) {
      await this.exitLoop(true)
      return
    }
    const when = this.context.currentTime + LOOKAHEAD
    const target = rollReleaseSec(this.rollAnchor, when - this.rollStartedAt, this.rate)
    this.loopRegion = null
    this.rollActive = false
    this.lastLoopSent = null
    this.schedule({ active: this.playing, input: Math.min(this.durationSec, target), when, forceLoop: true })
  }

  /** Everything but `loopBeats` and `jumpBars`, which the engine owns and merges in. */
  snapshot(): Omit<DeckSnapshot, 'loopBeats' | 'jumpBars'> {
    return {
      id: this.id,
      trackId: this.trackId,
      trackName: this.trackName,
      durationSec: this.durationSec,
      grid: this.grid,
      peaks: this.peaks,
      levels: this.levels,
      power: this.power,
      playing: this.playing,
      previewing: this.previewing,
      position: this.position,
      baseRate: this.baseRate,
      rate: this.rate,
      keyLock: this.keyLock,
      eq: { ...this.eqFaders },
      kills: { ...this.eqKills },
      filter: this.filterKnob,
      level: this.level,
      trimDb: this.gainTrimDb,
      cuePoint: this.cuePoint,
      cue: this.cue,
      loop: this.loopRegion ? { ...this.loopRegion } : null,
      hotCues: [...this.hotCues],
      syncLocked: this.syncLocked,
      isMaster: this.isMaster,
      loading: this.loading,
      error: this.error
    }
  }
}
