import { harmonicNeighbours } from './key'

/**
 * Camelot wheel helpers for the library: colours, wheel order and the keys
 * that mix with a given one.
 */

export interface CamelotCode {
  /** 1…12 round the wheel. */
  number: number
  /** A is the minor ring, B the major. */
  ring: 'A' | 'B'
}

/**
 * The wheel in Mixed In Key colours: the minor (A) ring is the pastel tone,
 * the major (B) ring the saturated one, stepping round the hue circle.
 */
export const CAMELOT_COLOURS: Record<number, readonly [minor: string, major: string]> = {
  1: ['#56f1da', '#00e3c2'],
  2: ['#7df2aa', '#3fe58a'],
  3: ['#aef589', '#86ec4f'],
  4: ['#e8ea8a', '#dadf3f'],
  5: ['#fdcf91', '#ffb04e'],
  6: ['#fdafa0', '#ff8b74'],
  7: ['#fda7c8', '#ff7aae'],
  8: ['#f0a9ec', '#e877e4'],
  9: ['#d2b0fb', '#b98cff'],
  10: ['#b5bbfd', '#8f99ff'],
  11: ['#9ccffd', '#6db7ff'],
  12: ['#84e6f6', '#4ad6f0']
}

/** Accepts "4A", " 4a ", "12B"; anything else is null. */
export function parseCamelot(code: string | null | undefined): CamelotCode | null {
  const match = /^(\d{1,2})([AB])$/.exec((code ?? '').trim().toUpperCase())
  if (!match) return null
  const number = Number(match[1])
  if (number < 1 || number > 12) return null
  return { number, ring: match[2] as 'A' | 'B' }
}

export function camelotColour(code: string | null | undefined): string | null {
  const parsed = parseCamelot(code)
  return parsed ? CAMELOT_COLOURS[parsed.number][parsed.ring === 'A' ? 0 : 1] : null
}

/** Sort order round the wheel: 1A, 1B, 2A … 12B, with unknown keys last. */
export function camelotRank(code: string | null | undefined): number {
  const parsed = parseCamelot(code)
  return parsed ? parsed.number * 2 + (parsed.ring === 'B' ? 1 : 0) : Number.POSITIVE_INFINITY
}

/** The key itself, one step either way on its ring, and its relative major or minor. */
export function compatibleKeys(code: string): string[] {
  const parsed = parseCamelot(code)
  if (!parsed) return [code]
  const self = `${parsed.number}${parsed.ring}`
  const neighbours = harmonicNeighbours(self)
  return neighbours ? [self, neighbours.previous, neighbours.next, neighbours.relative] : [self]
}
