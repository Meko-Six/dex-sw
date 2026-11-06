import { useEffect, useMemo, useRef, useState } from 'react'
import { useConsole } from './state'
import { levelsFromPeaks, snapView } from '../../shared/waveform-levels'
import type { DeckSnapshot } from '../audio/types'
import { useWaveformLayer, type RGBA, type WaveformPaint } from '../ui/waveform-gl'

/** The deck's level pyramid, or the library's coarse peaks until it is built. */
export function useLevels(deck: DeckSnapshot) {
  return useMemo(
    () => deck.levels ?? (deck.peaks && deck.durationSec > 0 ? levelsFromPeaks(deck.peaks, deck.durationSec) : null),
    [deck.levels, deck.peaks, deck.durationSec]
  )
}

/** A neutral fallback until the decoded three-band envelopes arrive. */
export function flatPaint(color: RGBA): WaveformPaint {
  return { peak: color, rms: color, peakPlayed: color, rmsPlayed: color, line: [0, 0, 0, 0] }
}

interface WaveCanvasProps {
  deck: DeckSnapshot
  /** Track time at the left edge and across the canvas, in seconds. */
  startSec: number
  spanSec: number
  /** Current playhead time; all columns use the same brightness. */
  playSec: number
  amp: number
  oneSided?: boolean
  paint: WaveformPaint
}

/**
 * A waveform canvas filling its box, drawn one device pixel per column. The
 * stage is scaled to the window, so the canvas is sized from its on-screen
 * box rather than its layout size.
 */
export function WaveCanvas({ deck, startSec, spanSec, playSec, amp, oneSided, paint }: WaveCanvasProps) {
  const { canvasKey, canvasRef, draw } = useWaveformLayer()
  const [size, setSize] = useState({ width: 1, height: 1 })
  const levels = useLevels(deck)
  const energyEnabled = useConsole((state) => state.energyEnabled)
  const frame = useRef(0)

  useEffect(() => {
    const canvas = canvasRef.current
    if (!canvas) return
    const resize = (): void => {
      const rect = canvas.getBoundingClientRect()
      const dpr = window.devicePixelRatio || 1
      const width = Math.max(1, Math.round(rect.width * dpr))
      const height = Math.max(1, Math.round(rect.height * dpr))
      setSize((previous) => previous.width === width && previous.height === height ? previous : { width, height })
    }
    const observer = new ResizeObserver(resize)
    observer.observe(canvas)
    // Stage scaling changes the bounding box without changing CSS layout size.
    const stage = canvas.closest('.ipad')
    const transform = new MutationObserver(resize)
    if (stage) transform.observe(stage, { attributes: true, attributeFilter: ['style'] })
    window.addEventListener('resize', resize)
    resize()
    return () => { observer.disconnect(); transform.disconnect(); window.removeEventListener('resize', resize) }
  }, [canvasKey, canvasRef])

  useEffect(() => {
    cancelAnimationFrame(frame.current)
    frame.current = requestAnimationFrame(() => {
      const canvas = canvasRef.current
      if (!canvas) return
      const { width, height } = size
      if (canvas.width !== width) canvas.width = width
      if (canvas.height !== height) canvas.height = height
      if (!levels || deck.durationSec <= 0) {
        draw(null, { startCol: 0, samplesPerPixel: 1, playSample: 0, amp, oneSided, paint })
        return
      }
      const snap = snapView(startSec, Math.max(0.001, spanSec), width, levels.sampleRate)
      draw(levels, {
        startCol: snap.startCol,
        samplesPerPixel: snap.samplesPerPixel,
        playSample: playSec * levels.sampleRate,
        amp,
        oneSided,
        paint,
        power: energyEnabled ? deck.power : null,
        threeBand: !energyEnabled || !deck.power
      })
    })
    return () => cancelAnimationFrame(frame.current)
  })

  return <canvas key={canvasKey} ref={canvasRef} className="wave-canvas" aria-hidden="true" />
}
