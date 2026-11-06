/** Types shared between the main process, preload bridge and renderer. */

import type { HotCueList } from './hot-cue'
import type { Playlist } from './playlist'
import type { PowerAnalysis } from './power'

export interface TrackMeta {
  id: string
  name: string
  /** Absolute path on disk (absent for files loaded through the browser fallback). */
  path?: string
  durationSec: number
  bpm: number
  offsetMs: number
  confidence: number
  /** The analysis could not tell this tempo from a related one; cleared once a person edits the grid. */
  gridUncertain?: boolean
  /** Other readings of the tempo, each with its own downbeat, strongest first (see GridAlternate). */
  gridAlternates?: TrackGridAlternate[]
  /** Interleaved min/max int8 pairs for the waveform. */
  peaks: number[]
  fingerprint?: string
  analyzedAt: string
  missing?: boolean
  /** From the file's tags when it has them; the track windows fall back to the file name. */
  artist?: string
  title?: string

  // --- v2 additions (optional: libraries written before these existed still load) ---
  /** Musical key, e.g. "F# minor". */
  key?: string
  /** Camelot wheel code, e.g. "11A", for harmonic mixing. */
  camelot?: string
  /** 0…1 confidence from the chroma/profile correlation. */
  keyConfidence?: number
  /** Versioned musical-intensity curve and its loudness measurements. */
  power?: PowerAnalysis
  /** Integrated loudness (LUFS, BS.1770). */
  lufs?: number
  /** Gain in dB that levels this track to the crate target. */
  gainDb?: number
  /** Peak minus loudness: low values mean a heavily limited master. */
  peakToLoudnessDb?: number
  /** Eight hot-cue positions in seconds, saved with the track. */
  hotCues?: HotCueList
  /** Provenance from the import manifest. */
  source?: 'local' | 'youtube' | 'lossless' | 'manual' | 'none'
  sourceUrl?: string
  isrc?: string
  spotifyId?: string
  qualityGrade?: 'A' | 'B' | 'C'
}

export interface TrackGridAlternate {
  bpm: number
  offsetMs: number
  /** This tempo over the chosen one, e.g. "2/3". */
  relation: string
}

export interface LibraryDoc {
  version: 1
  tracks: TrackMeta[]
  /** Optional: libraries saved before playlists existed still load. */
  playlists?: Playlist[]
}

export interface FileRef {
  name: string
  path: string
}

export interface FilePayload extends FileRef {
  bytes: ArrayBuffer
}

export interface DexBridge {
  pickFiles(): Promise<FileRef[]>
  pickFolder(): Promise<FileRef[]>
  readFile(path: string): Promise<ArrayBuffer | null>
  /** Electron only; empty string in the browser fallback. */
  getPathForFile(file: unknown): Promise<string>
  /** Last-resort decode path for formats Chromium refuses; null when unavailable. */
  transcodeToWav(bytes: ArrayBuffer, name: string): Promise<ArrayBuffer | null>
  loadLibrary(): Promise<string | null>
  saveLibrary(json: string): Promise<void>
  onBeforeClose?(flush: () => Promise<void>): () => void
  platform: string
  version: string
}

export const AUDIO_EXTENSIONS = ['mp3', 'flac', 'wav', 'aiff', 'aif', 'm4a', 'aac', 'ogg', 'opus'] as const

export function isAudioFile(name: string): boolean {
  const ext = name.split('.').pop()?.toLowerCase() ?? ''
  return (AUDIO_EXTENSIONS as readonly string[]).includes(ext)
}
