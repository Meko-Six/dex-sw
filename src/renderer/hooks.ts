import { useSyncExternalStore } from 'react'
import { engine } from './audio/engine'
import type { EngineSnapshot } from './audio/types'

export function useEngineSnapshot(): EngineSnapshot {
  return useSyncExternalStore(engine.subscribe, engine.getSnapshot, engine.getSnapshot)
}

/** A single presentation timer. Audio and sync retain their independent clocks. */
const visualListeners = new Set<() => void>()
let positions: [number, number] = [0, 0]
let meter = -60
let ticks = 0
let timer: number | undefined
let unsubscribeEngine: (() => void) | undefined
function sample(): void {
  if (document.hidden) return
  positions = [engine.getDeck(0)?.position ?? 0, engine.getDeck(1)?.position ?? 0]
  if (++ticks % 2 === 0) meter = engine.readMeterDb()
  for (const listener of visualListeners) listener()
}
function visibility(): void {
  window.clearInterval(timer)
  timer = undefined
  if (!document.hidden) { sample(); timer = window.setInterval(sample, 33) }
}
function subscribeVisual(listener: () => void): () => void {
  visualListeners.add(listener)
  if (visualListeners.size === 1) {
    document.addEventListener('visibilitychange', visibility)
    unsubscribeEngine = engine.subscribe(sample)
    visibility()
  }
  return () => {
    visualListeners.delete(listener)
    if (!visualListeners.size) {
      window.clearInterval(timer)
      timer = undefined
      document.removeEventListener('visibilitychange', visibility)
      unsubscribeEngine?.()
    }
  }
}

export function useDeckPosition(index: 0 | 1): number {
  return useSyncExternalStore(subscribeVisual, () => positions[index], () => 0)
}

export function useMeterDb(): number {
  return useSyncExternalStore(subscribeVisual, () => meter, () => -60)
}
