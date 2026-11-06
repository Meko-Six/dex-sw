/**
 * Audacity label files, for hand-marked downbeats (scripts/accuracy-labels.ts).
 */

/** The bench's hit window (DEFAULT_DOWNBEAT_TOLERANCE_MS in scripts/accuracy.ts). */
const TOLERANCE_MS = 15
/**
 * Marks closer than this are one mark placed twice: even at 200 BPM kicks are
 * 300 ms apart.
 */
const SAME_MARK_SEC = 0.1
/** The tag is a whole BPM, so the played tempo can be half a BPM either side. */
const TAG_SLACK_BPM = 0.5

/**
 * Start times from an Audacity label export: one label per line as
 * "start<TAB>end<TAB>text". Lines starting with a backslash carry a spectral
 * label's frequency range and are skipped; a decimal comma (some locales) is
 * read as a point. Of two labels on the same spot, a point label (⌘B with no
 * selection) wins over a region, which is usually a stray selection.
 */
export function parseLabels(text: string): number[] {
  const labels: Array<{ start: number; point: boolean }> = []
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim()
    if (!line || line.startsWith('\\')) continue
    const [start, end] = line.split('\t').map((field) => Number.parseFloat(field.replace(',', '.')))
    if (Number.isFinite(start) && start >= 0) labels.push({ start, point: !Number.isFinite(end) || Math.abs(end - start) < 1e-4 })
  }
  labels.sort((a, b) => a.start - b.start)
  const kept: typeof labels = []
  for (const label of labels) {
    const last = kept[kept.length - 1]
    if (last && label.start - last.start < SAME_MARK_SEC) {
      if (label.point && !last.point) kept[kept.length - 1] = label
    } else kept.push(label)
  }
  return kept.map((label) => label.start)
}

/**
 * The tag is a whole BPM, so the played tempo can be half a BPM either side.
 * Over this many beats that is still under a quarter of a beat, so the count
 * between the first two marks is certain from the tag alone.
 */
export const SAFE_FIRST_GAP_BEATS = 64

export interface MarkFit {
  /** The tempo the marks give, to a fraction of a BPM. */
  bpm: number
  /** Beats from the first mark to each mark. */
  counts: number[]
  /** How far each mark sits from the fitted grid, in ms. */
  residualsMs: number[]
  /** The first gap is long enough that the tag alone may miscount it. */
  firstGapUnsure: boolean
}

/** Least-squares line through (count, time): seconds per beat and the time of beat 0. */
function fitLine(counts: number[], times: number[]): { beat: number; start: number } {
  const n = counts.length
  const mc = counts.reduce((sum, value) => sum + value, 0) / n
  const mt = times.reduce((sum, value) => sum + value, 0) / n
  let num = 0
  let den = 0
  for (let i = 0; i < n; i++) {
    num += (counts[i] - mc) * (times[i] - mt)
    den += (counts[i] - mc) ** 2
  }
  const beat = num / den
  return { beat, start: mt - beat * mc }
}

/**
 * Fits a constant-tempo grid to the marks, counting beats outwards from the
 * first: the tag counts the first gap, that gap refines the tempo, the
 * refined tempo counts the next gap, and so on. A mark off the kick then
 * shows as a residual rather than being absorbed into a slightly different
 * tempo. Null with fewer than two marks.
 */
export function fitMarks(times: number[], tagBpm: number): MarkFit | null {
  if (times.length < 2) return null
  const counts = [0]
  let beat = 60 / tagBpm
  for (let i = 1; i < times.length; i++) {
    counts.push(Math.max(1, Math.round((times[i] - times[0]) / beat)))
    beat = fitLine(counts, times.slice(0, i + 1)).beat
  }
  const line = fitLine(counts, times)
  return {
    bpm: 60 / line.beat,
    counts,
    residualsMs: times.map((time, i) => (time - (line.start + line.beat * counts[i])) * 1000),
    firstGapUnsure: counts[1] > SAFE_FIRST_GAP_BEATS
  }
}

/** The bench's hit window, for flagging marks that sit off the fitted grid. */
export const MARK_TOLERANCE_MS = TOLERANCE_MS

/** A steady grid through some of the marks. */
export interface GridFit {
  bpm: number
  /** Beats from the first mark to each mark. */
  counts: number[]
  residualsMs: number[]
}

/**
 * The steady grid within half a BPM of the tag that puts every mark on a beat,
 * trying every whole number of beats across the marks and refitting each by
 * least squares. Of several, the one nearest the tag: tracks are produced at a
 * set tempo, and the tag is that tempo rounded. Null when none fits.
 */
export function gridNearTag(times: number[], tagBpm: number): GridFit | null {
  if (times.length < 2) return null
  const span = times[times.length - 1] - times[0]
  let best: GridFit | null = null
  const lo = Math.ceil((span * (tagBpm - TAG_SLACK_BPM)) / 60)
  const hi = Math.floor((span * (tagBpm + TAG_SLACK_BPM)) / 60)
  for (let beats = Math.max(1, lo); beats <= hi; beats++) {
    const rough = span / beats
    const counts = times.map((time) => Math.round((time - times[0]) / rough))
    if (counts.some((count, i) => i > 0 && count <= counts[i - 1])) continue
    const line = fitLine(counts, times)
    const residualsMs = times.map((time, i) => (time - (line.start + line.beat * counts[i])) * 1000)
    if (residualsMs.some((ms) => Math.abs(ms) > TOLERANCE_MS)) continue
    const bpm = 60 / line.beat
    if (!best || Math.abs(bpm - tagBpm) < Math.abs(best.bpm - tagBpm)) best = { bpm, counts, residualsMs }
  }
  return best
}

/**
 * Whether the marks sit on a steady grid near the tag, or all but one do. When
 * leaving one mark out lands nearer the tag than fitting them all, that mark
 * is the odd one: on the wrong sound, or dropped where no kick is (a label at
 * 0.000 left by mistake). Ties go to keeping every mark.
 */
export function checkMarks(times: number[], tagBpm: number): { fit: GridFit; odd: { index: number; offMs: number } | null } | null {
  const all = gridNearTag(times, tagBpm)
  let best: { fit: GridFit; odd: { index: number; offMs: number } | null } | null = all ? { fit: all, odd: null } : null
  if (times.length >= 4) {
    for (let i = 0; i < times.length; i++) {
      const rest = times.filter((_, j) => j !== i)
      const fit = gridNearTag(rest, tagBpm)
      if (!fit || (best && Math.abs(fit.bpm - tagBpm) >= Math.abs(best.fit.bpm - tagBpm) - 0.01)) continue
      const beat = 60 / fit.bpm
      const start = rest[0] - fit.residualsMs[0] / 1000
      const offMs = (times[i] - (start + Math.round((times[i] - start) / beat) * beat)) * 1000
      best = { fit, odd: { index: i, offMs } }
    }
  }
  return best
}
