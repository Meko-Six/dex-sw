import type { CSSProperties } from 'react'

/**
 * The console's coordinates, copied from the mockup (mockup/xdj-mixer-alt.html)
 * so the app lands on the same pixels. x runs across the 1194 pt canvas (the
 * mockup's 10 pt bezel included, hence the −10), y down from the drawing's
 * chassis line, raised by LIFT.
 */

export const STAGE_W = 1174
export const STAGE_H = 814
/**
 * Elastic height: a window taller than the stage's shape gives its spare
 * height to the zoom lanes, up to a 4:3 screen (the 13" iPads); taller still
 * letterboxes. Widths never change, so the 1174 × 814 base stays exact.
 */
export const MAX_STRETCH = (STAGE_W * 3) / 4 - STAGE_H

export const LIFT = 48

export function at(x: number, y: number, w: number, h: number): CSSProperties {
  return { left: x - 10, top: y - LIFT, width: w, height: h }
}

export const TEMPO_COL_H = 326.5
/** The platter sits 8 pt under the TRIM row's keys (62 + 44) and 8 pt above the beat jump row. */
export const PLATTER = { y: 114, size: 262 }
export const ROW_Y = 446
export const KEY = 66
/**
 * Beat jump: a row of its own under the platter, level with the mixer's
 * CUE · KILL row (ROW.kill), as wide as the TRIM row's keys (pill wide):
 * square ◀ and ▶ at its ends, the length selector between them.
 */
export const JUMP = { y: 384, h: 44, key: 44, gap: 6, pill: 64 }
/** The keys that jump each deck back and forward: one pair per hand, like 1 and 2 for play. */
export const JUMP_KEYS: Record<'A' | 'B', readonly [back: string, forward: string]> = { A: ['q', 'w'], B: ['o', 'p'] }

export const DECK_X = {
  A: { pills: [78, 148, 218, 288], tempo: 46, platter: 215, row: 22 },
  B: { pills: [842, 912, 982, 1052], tempo: 1148, platter: 979, row: 832 }
} as const

export type Column = 'level' | 'high' | 'mid' | 'low'
export type Band = 'high' | 'mid' | 'low'

export const BAND_NAME: Record<Column, string> = { high: 'HI', mid: 'MID', low: 'LOW', level: 'LEVEL' }
export const BANDS: Band[] = ['high', 'mid', 'low']
const COLS: Record<Column, [number, number]> = { level: [372, 44], high: [422, 44], mid: [472, 44], low: [522, 52] }
/** Deck B's columns mirror deck A's across the centre. */
export const colX = (side: 'A' | 'B', col: Column): [number, number] => {
  const [x, w] = COLS[col]
  return [side === 'A' ? x : 1194 - x - w, w]
}
export const ROW = { top: [62, 44], val: [110, 36], fader: [150, 228], kill: [384, 44], xf: [455, 48] } as const
/** Height of a mixer fader cap. */
export const CAP = 24

export const accentOf = (side: 'A' | 'B'): string => (side === 'B' ? 'var(--b)' : 'var(--a)')

/** A style object that also carries CSS custom properties. */
export const vars = (style: Record<string, string | number | undefined>): CSSProperties => style as CSSProperties
