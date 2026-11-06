import { useCallback, useRef, useState, type PointerEvent as ReactPointerEvent } from 'react'
import { linkedLow } from '../../shared/mixer'
import { engine } from '../audio/engine'
import { CAP } from './layout'

/**
 * Chassis drags, as in the mockup: every pointer drives its own control, so a
 * fader ride and a kill tap (or two faders) work at once. Movement is
 * relative — the control moves by the finger's travel, never to the finger —
 * and moving the finger 60 pt across the control slows it to ¼, 120 pt to ⅒.
 * A double tap resets. Kill pads mute on touch-down: a tap latches, a hold of
 * 300 ms or more is momentary, and touching a latched kill releases it.
 *
 * Controls are found by their data attributes, like the mockup's markup:
 * data-param (and data-deck, data-axis="x" for horizontal) on sliders,
 * data-kill="A-low" on kill pads.
 */

export type Param = 'xfade' | 'trimpos' | 'filter' | 'level' | 'high' | 'mid' | 'low' | 'tempo' | 'master' | 'cuemix'
type Side = 'A' | 'B'

/** Tempo fader travel: ±16 %. Down is faster, as on a CDJ. */
export const TEMPO_RANGE = 0.16
export const tempoToFader = (rate: number): number => 0.5 - (rate - 1) / (2 * TEMPO_RANGE)
const faderToTempo = (value: number): number => 1 + (0.5 - value) * 2 * TEMPO_RANGE

const HOLD_MS = 300
const DOUBLE_TAP_MS = 320
const RESET: Partial<Record<Param, number>> = { xfade: 0.5, filter: 0.5, trimpos: 0.5, tempo: 0.5 }
/** Cap size per control, the part of the box the travel cannot use. */
const TEMPO_CAP = 34

const indexOf = (side: Side): 0 | 1 => (side === 'B' ? 1 : 0)
/** The master fader's top: 120 %, a little headroom over unity. */
export const MASTER_MAX = 1.2

export function getP(side: Side | undefined, param: Param): number {
  const snapshot = engine.getSnapshot()
  if (param === 'xfade') return snapshot.crossfader
  if (param === 'master') return snapshot.masterVolume / MASTER_MAX
  if (param === 'cuemix') return snapshot.cueMix
  const deck = snapshot.decks[indexOf(side ?? 'A')]
  switch (param) {
    case 'trimpos':
      return (deck.trimDb + 12) / 24
    case 'filter':
      return (deck.filter + 1) / 2
    case 'level':
      return deck.level
    case 'tempo':
      return tempoToFader(deck.baseRate)
    default:
      return deck.eq[param]
  }
}

export function setP(side: Side | undefined, param: Param, value: number): void {
  const c = Math.max(0, Math.min(1, value))
  const index = indexOf(side ?? 'A')
  switch (param) {
    case 'xfade':
      engine.setCrossfader(c)
      return
    case 'master':
      engine.setMasterVolume(c * MASTER_MAX)
      return
    case 'cuemix':
      engine.setCueMix(c)
      return
    case 'trimpos': {
      const t = Math.round((c * 24 - 12) * 10) / 10
      engine.setGainTrim(index, Math.abs(t) < 0.25 ? 0 : t)
      return
    }
    case 'filter':
      engine.setFilter(index, c * 2 - 1)
      return
    case 'level':
      engine.setLevel(index, c)
      return
    case 'tempo':
      engine.setTempoRate(index, faderToTempo(c))
      return
    default:
      engine.setEqFader(index, param, c)
  }
}

interface Drag {
  el: HTMLElement
  side: Side | undefined
  param: Param
  horiz: boolean
  scale: number
  travel: number
  last: number
  cross0: number
  moved: boolean
  acc: number
  speed: number
}

interface KillTouch {
  side: Side
  band: 'high' | 'mid' | 'low'
  wasOn: boolean
  t0: number
}

export interface MixDrags {
  onPointerDown: (event: ReactPointerEvent<HTMLElement>) => void
  onPointerMove: (event: ReactPointerEvent<HTMLElement>) => void
  onPointerUp: (event: ReactPointerEvent<HTMLElement>) => void
  /** The drag on this control once it has moved, for the FINE readouts. */
  active: (side: Side | undefined, param: Param) => { speed: number } | null
  /** Kill pads under a finger right now. */
  held: (side: Side, band: string) => boolean
  /** True for a moment after a drag, so the click that ends it opens nothing. */
  swallowClick: () => boolean
}

/** `linked` is LINK LOWS: a LOW drag moves the other deck's LOW the opposite way. */
export function useMixDrags(linked: { current: boolean }): MixDrags {
  const drags = useRef(new Map<number, Drag>())
  const kills = useRef(new Map<number, KillTouch>())
  const lastTap = useRef<{ el: HTMLElement | null; t: number }>({ el: null, t: 0 })
  const swallowUntil = useRef(0)
  const [, repaint] = useState(0)
  const bump = useCallback(() => repaint((n) => n + 1), [])

  const killDown = (event: ReactPointerEvent<HTMLElement>, el: HTMLElement): void => {
    const [side, band] = el.dataset.kill!.split('-') as [Side, 'high' | 'mid' | 'low']
    const deck = engine.getSnapshot().decks[indexOf(side)]
    kills.current.set(event.pointerId, { side, band, wasOn: deck.kills[band], t0: performance.now() })
    engine.setEqKill(indexOf(side), band, true)
    try {
      el.setPointerCapture(event.pointerId)
    } catch {
      // A pointer that is already gone cannot be captured.
    }
    bump()
  }

  const killUp = (event: ReactPointerEvent<HTMLElement>): boolean => {
    const touch = kills.current.get(event.pointerId)
    if (!touch) return false
    kills.current.delete(event.pointerId)
    const held = performance.now() - touch.t0 >= HOLD_MS
    engine.setEqKill(indexOf(touch.side), touch.band, touch.wasOn ? false : !held)
    bump()
    return true
  }

  const onPointerDown = (event: ReactPointerEvent<HTMLElement>): void => {
    if (event.button > 0) return
    const target = event.target as HTMLElement
    const kill = target.closest<HTMLElement>('[data-kill]')
    if (kill) {
      killDown(event, kill)
      return
    }
    const el = target.closest<HTMLElement>('[data-param]')
    if (!el) return
    const horiz = el.dataset.axis === 'x'
    const rect = el.getBoundingClientRect()
    const scale = (horiz ? rect.width / el.offsetWidth : rect.height / el.offsetHeight) || 1
    const param = el.dataset.param as Param
    // The cap's own size is travel it cannot use; the volume faders' caps overhang the ends instead.
    const thumb = el.classList.contains('fader-h')
      ? 0
      : horiz
        ? parseFloat(getComputedStyle(el).getPropertyValue('--tw')) || 40
        : param === 'tempo'
          ? TEMPO_CAP
          : CAP
    const travel = ((horiz ? el.offsetWidth : el.offsetHeight - 2) - thumb) * scale
    drags.current.set(event.pointerId, {
      el,
      side: el.dataset.deck as Side | undefined,
      param,
      horiz,
      scale,
      travel,
      last: horiz ? event.clientX : event.clientY,
      cross0: horiz ? event.clientY : event.clientX,
      moved: false,
      acc: 0,
      speed: 1
    })
    try {
      el.setPointerCapture(event.pointerId)
    } catch {
      // A pointer that is already gone cannot be captured.
    }
  }

  const onPointerMove = (event: ReactPointerEvent<HTMLElement>): void => {
    const d = drags.current.get(event.pointerId)
    if (!d) return
    const now = d.horiz ? event.clientX : event.clientY
    // Up and right raise the value (for tempo, up is slower, as on a CDJ).
    const delta = d.horiz ? now - d.last : d.last - now
    d.last = now
    const cross = Math.abs((d.horiz ? event.clientY : event.clientX) - d.cross0) / d.scale
    const speed = cross >= 120 ? 0.1 : cross >= 60 ? 0.25 : 1
    const speedChanged = speed !== d.speed
    d.speed = speed
    d.acc += Math.abs(delta)
    if (!d.moved) {
      if (d.acc < 3 * d.scale) return
      d.moved = true
      bump()
    } else if (speedChanged) bump()
    const before = getP(d.side, d.param)
    setP(d.side, d.param, before + (delta / d.travel) * d.speed)
    if (d.param === 'low' && linked.current && d.side) {
      const other: Side = d.side === 'A' ? 'B' : 'A'
      const after = getP(d.side, 'low')
      setP(other, 'low', linkedLow(getP(other, 'low'), after - before))
    }
  }

  const onPointerUp = (event: ReactPointerEvent<HTMLElement>): void => {
    if (killUp(event)) return
    const d = drags.current.get(event.pointerId)
    if (!d) return
    drags.current.delete(event.pointerId)
    try {
      if (d.el.hasPointerCapture(event.pointerId)) d.el.releasePointerCapture(event.pointerId)
    } catch {
      // Already released.
    }
    if (d.moved) {
      swallowUntil.current = performance.now() + 400
      bump()
    } else if (event.type === 'pointerup') {
      const t = performance.now()
      if (lastTap.current.el === d.el && t - lastTap.current.t < DOUBLE_TAP_MS) {
        setP(d.side, d.param, RESET[d.param] ?? 1)
        lastTap.current = { el: null, t: 0 }
      } else {
        lastTap.current = { el: d.el, t }
      }
    }
  }

  const active = (side: Side | undefined, param: Param): { speed: number } | null => {
    for (const d of drags.current.values()) if (d.side === side && d.param === param && d.moved) return { speed: d.speed }
    return null
  }

  const held = (side: Side, band: string): boolean => {
    for (const touch of kills.current.values()) if (touch.side === side && touch.band === band) return true
    return false
  }

  return {
    onPointerDown,
    onPointerMove,
    onPointerUp,
    active,
    held,
    swallowClick: () => performance.now() < swallowUntil.current
  }
}

