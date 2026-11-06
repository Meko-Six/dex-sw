import { normalizeHotCues } from './hot-cue'
import { normalizePlaylists } from './playlist'
import { validPower } from './power'
import type { LibraryDoc, TrackMeta } from './types'

export const MAX_LIBRARY_BYTES = 64 * 1024 * 1024
const object = (v: unknown): v is Record<string, unknown> => !!v && typeof v === 'object' && !Array.isArray(v)
const text = (v: unknown, max = 4096): v is string => typeof v === 'string' && v.length <= max
const finite = (v: unknown, min: number, max: number): v is number => typeof v === 'number' && Number.isFinite(v) && v >= min && v <= max

/** Validate persisted inputs before they can reach formatting, DSP or file access. */
export function parseLibrary(json: string): LibraryDoc {
  if (json.length > MAX_LIBRARY_BYTES) throw new Error('The library exceeds the supported size.')
  const doc: unknown = JSON.parse(json)
  if (!object(doc) || doc.version !== 1 || !Array.isArray(doc.tracks) || doc.tracks.length > 100000) throw new Error('Unsupported or damaged library format.')
  const seen = new Set<string>()
  const tracks = doc.tracks.map((v): TrackMeta => {
    if (!object(v) || !text(v.id, 256) || !v.id || seen.has(v.id) || !text(v.name) ||
      !finite(v.durationSec, 0, 86400) || !finite(v.bpm, 1, 1000) || !finite(v.offsetMs, -86400000, 86400000) ||
      !finite(v.confidence, 0, 1) || !text(v.analyzedAt, 128) || !Array.isArray(v.peaks) || v.peaks.length > 2000000 ||
      !v.peaks.every((n) => finite(n, -128, 127) && Number.isInteger(n))) throw new Error('The library contains invalid track metadata. The original has been preserved.')
    seen.add(v.id)
    for (const key of ['path', 'artist', 'title', 'key', 'camelot', 'sourceUrl', 'isrc', 'spotifyId', 'fingerprint']) {
      if (v[key] !== undefined && !text(v[key])) throw new Error(`Invalid track ${key}.`)
    }
    for (const key of ['lufs', 'gainDb', 'peakToLoudnessDb']) {
      if (v[key] !== undefined && !finite(v[key], -300, 300)) throw new Error(`Invalid track ${key}.`)
    }
    if (v.keyConfidence !== undefined && !finite(v.keyConfidence, 0, 1)) throw new Error('Invalid key confidence.')
    for (const key of ['missing', 'gridUncertain']) if (v[key] !== undefined && typeof v[key] !== 'boolean') throw new Error(`Invalid ${key}.`)
    if (v.hotCues !== undefined && (!Array.isArray(v.hotCues) || (v.hotCues.length !== 4 && v.hotCues.length !== 8) || !v.hotCues.every((n) => n === null || finite(n, 0, v.durationSec as number)))) throw new Error('Invalid hot cues.')
    if (v.gridAlternates !== undefined && (!Array.isArray(v.gridAlternates) || v.gridAlternates.length > 32 || !v.gridAlternates.every((a) => object(a) && finite(a.bpm, 1, 1000) && finite(a.offsetMs, -86400000, 86400000) && text(a.relation, 32)))) throw new Error('Invalid alternate grid.')
    if (v.hotCues !== undefined) v = { ...v, hotCues: normalizeHotCues(v.hotCues as TrackMeta['hotCues'], v.durationSec as number) }
    if (v.power !== undefined && !validPower(v.power as TrackMeta['power'], v.durationSec)) {
      // An obsolete optional analysis cache is safe to rebuild from the audio.
      const copy = { ...v }
      delete copy.power
      return copy as unknown as TrackMeta
    }
    return v as unknown as TrackMeta
  })
  return { version: 1, tracks, playlists: normalizePlaylists(doc.playlists, seen) }
}
