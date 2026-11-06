import type { PowerAnalysis } from '../../shared/power'
import type { BeatGrid } from '../../shared/grid'
import type { HotCueList } from '../../shared/hot-cue'
import type { LoopRegion } from '../../shared/loop'
import type { TrackGridAlternate } from '../../shared/types'
import type { WaveformLevels } from '../../shared/waveform-levels'

export interface DeckSnapshot {
  id: 'A' | 'B'
  trackId: string | null
  trackName: string | null
  durationSec: number
  grid: BeatGrid | null
  peaks: Int8Array | null
  /** The screen's fine waveform, built off-thread after the track loads. */
  levels: WaveformLevels | null
  power: PowerAnalysis | null
  playing: boolean
  previewing: boolean
  position: number
  baseRate: number
  rate: number
  keyLock: boolean
  /** Cut-only EQ fader positions, 0 (foot) … 1 (unity). */
  eq: { low: number; mid: number; high: number }
  /** Kill latches; the fader keeps its position underneath. */
  kills: { low: boolean; mid: boolean; high: boolean }
  /** Channel fader position, 0 … 1 (see shared/mixer.ts for the law). */
  level: number
  /** Input trim in dB. */
  trimDb: number
  /** CDJ cue point in seconds. */
  cuePoint: number
  /** One-knob sweep filter, -1 (low-pass) … +1 (high-pass), 0 = off. */
  filter: number
  cue: boolean
  loop: LoopRegion | null
  /** Loop stepper size in beats: the length the next loop or roll will use. */
  loopBeats: number
  /** Beat jump length in bars: what one press of ◀ or ▶ moves. */
  jumpBars: number
  /** Eight cue positions in seconds; null means the slot is empty. */
  hotCues: HotCueList
  syncLocked: boolean
  isMaster: boolean
  loading: boolean
  error: string | null
}

export interface EngineSnapshot {
  ready: boolean
  decks: [DeckSnapshot, DeckSnapshot]
  crossfader: number
  cueMix: number
  masterVolume: number
  outputMode: 'split' | 'multichannel'
  sampleRate: number
  masterDeck: 0 | 1
  focusedDeck: 0 | 1
}

export interface AnalysisResult {
  durationSec: number
  power: PowerAnalysis
  bpm: number
  offsetMs: number
  confidence: number
  /** The tempo could be a related reading; the grid editor offers `alternates`. */
  uncertain: boolean
  alternates: TrackGridAlternate[]
  peaks: number[]
  /** Musical key, when the track has enough pitched material to call one. */
  key: { key: string; camelot: string; confidence: number } | null
}
