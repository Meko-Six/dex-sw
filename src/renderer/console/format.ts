/** Readouts in the formats the mockup prints. */

const pad = (value: number, width: number): string => String(value).padStart(width, '0')

/** "5:11": the elapsed and total times under REMAIN. */
export function clock(seconds: number): string {
  const total = Math.max(0, Math.floor(Number.isFinite(seconds) ? seconds : 0))
  return `${Math.floor(total / 60)}:${pad(total % 60, 2)}`
}

/** "01:12" and "418": the remaining time, split where the digits change size. */
export function remain(seconds: number): { whole: string; ms: string } {
  const value = Math.max(0, Number.isFinite(seconds) ? seconds : 0)
  const millis = Math.floor(value * 1000)
  const secs = Math.floor(millis / 1000)
  return { whole: `${pad(Math.floor(secs / 60), 2)}:${pad(secs % 60, 2)}`, ms: pad(millis % 1000, 3) }
}

/** "0:32.0": a hot cue's time on its pad. */
export function cueTime(seconds: number): string {
  const tenths = Math.max(0, Math.floor(seconds * 10))
  const secs = Math.floor(tenths / 10)
  return `${Math.floor(secs / 60)}:${pad(secs % 60, 2)}.${tenths % 10}`
}

/** Tempo as a signed percentage to two places: sign ("+" or "−") and digits. */
export function tempo(rate: number): { sign: string; digits: string } {
  const pct = Math.round((rate - 1) * 10000) / 100
  return { sign: pct < 0 ? '−' : '+', digits: Math.abs(pct).toFixed(2) }
}

/** "+2.31%" under the tempo fader. */
export function tempoText(rate: number): string {
  const { sign, digits } = tempo(rate)
  return `${sign}${digits}%`
}

/** "133.0" split into "133" and "0". */
export function bpmParts(bpm: number): [string, string] {
  const [whole, tenth] = bpm.toFixed(1).split('.')
  return [whole, tenth]
}

/** "Artist — Title" from tags, or the file name's own "Artist - Title". */
export function splitName(name: string): { artist: string; title: string } {
  const match = /^(.+?)\s+[-–—]\s+(.+)$/.exec(name)
  return match ? { artist: match[1], title: match[2] } : { artist: '', title: name }
}
