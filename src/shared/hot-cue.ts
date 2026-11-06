/**
 * Hot cues: eight recallable positions per track.
 *
 * A deck holds a working copy; the library entry is the durable copy, saved
 * whenever a cue changes and restored when the track is loaded. These helpers
 * keep the set/recall and validation rules testable without an audio context:
 * an empty slot captures the playhead, a filled slot recalls it.
 */

export const HOT_CUE_COUNT = 8

/**
 * One colour per slot, shared by the pads and the waveform markers so a pad
 * and its marker read as the same cue. Dark text sits on all of them.
 */
export const HOT_CUE_COLOURS = [
  '#38a8ff',
  '#35d06b',
  '#ffb020',
  '#ff5d8f',
  '#b06cff',
  '#22d3ee',
  '#ff8a1f',
  '#d9e86a'
] as const

export type HotCueList = Array<number | null>

export interface HotCuePress {
  cues: HotCueList
  /** Where to seek when the slot already held a cue; null when it was just set. */
  seekTo: number | null
}

const clamp = (value: number, min: number, max: number): number => Math.min(max, Math.max(min, value))

export function emptyHotCues(): HotCueList {
  return Array.from({ length: HOT_CUE_COUNT }, () => null)
}

/** Press a hot-cue pad: set it on the first press, recall it after that. */
export function pressHotCue(
  cues: HotCueList,
  slot: number,
  positionSec: number,
  durationSec: number
): HotCuePress {
  if (!Number.isInteger(slot) || slot < 0 || slot >= cues.length) return { cues, seekTo: null }
  const limit = Math.max(0, durationSec)
  const existing = cues[slot]
  if (existing != null) return { cues, seekTo: clamp(existing, 0, limit) }
  const next = cues.slice()
  next[slot] = clamp(positionSec, 0, limit)
  return { cues: next, seekTo: null }
}

export function clearHotCueAt(cues: HotCueList, slot: number): HotCueList {
  if (!Number.isInteger(slot) || slot < 0 || slot >= cues.length || cues[slot] == null) return cues
  const next = cues.slice()
  next[slot] = null
  return next
}

/**
 * Coerce a stored value into HOT_CUE_COUNT valid cues. Older libraries may have
 * none, or the four slots saved before the count went to eight; those fill
 * slots 1–4 and the rest start empty.
 * Non-finite entries and anything past the track are dropped or clamped.
 */
export function normalizeHotCues(value: unknown, durationSec = Infinity): HotCueList {
  const cues = emptyHotCues()
  if (!Array.isArray(value)) return cues
  const limit = Number.isFinite(durationSec) ? Math.max(0, durationSec) : Infinity
  for (let slot = 0; slot < HOT_CUE_COUNT; slot++) {
    const cue = value[slot]
    if (typeof cue === 'number' && Number.isFinite(cue)) cues[slot] = clamp(cue, 0, limit)
  }
  return cues
}
