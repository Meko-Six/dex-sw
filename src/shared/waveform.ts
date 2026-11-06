/**
 * Geometry for a scrolling waveform with a fixed playhead at 50 %.
 *
 * The playhead is the centre of the view, so the visible window is always
 * `span` long and centred on the deck's current position. Near the start or
 * end of a track the window extends past the audio; the caller draws only the
 * real part, which leaves the pre-roll/post-roll margins empty instead of
 * moving the line off centre.
 */

export const MIN_WAVEFORM_SPAN = 0.015

const clamp = (value: number, min: number, max: number): number => Math.min(max, Math.max(min, value))

export interface WaveformView {
  /** Playback position as a fraction of the track, clamped to the track. */
  centerFraction: number
  /** Visible length as a fraction of the track. */
  span: number
  /** Visible window in seconds. These may sit outside [0, duration]. */
  startSec: number
  endSec: number
  spanSec: number
}

export function waveformView(positionSec: number, durationSec: number, spanFraction: number): WaveformView {
  const duration = Math.max(0.001, durationSec)
  const span = clamp(spanFraction, MIN_WAVEFORM_SPAN, 1)
  const centerFraction = clamp(positionSec / duration, 0, 1)
  const spanSec = span * duration
  const centerSec = centerFraction * duration
  return {
    centerFraction,
    span,
    startSec: centerSec - spanSec / 2,
    endSec: centerSec + spanSec / 2,
    spanSec
  }
}

/** Time under a pointer at `xFraction` of the waveform, relative to the fixed line. */
export function seekToFraction(
  positionSec: number,
  durationSec: number,
  spanFraction: number,
  xFraction: number
): number {
  const duration = Math.max(0.001, durationSec)
  const span = clamp(spanFraction, MIN_WAVEFORM_SPAN, 1)
  const x = clamp(xFraction, 0, 1)
  const center = clamp(positionSec / duration, 0, 1)
  return clamp((center + (x - 0.5) * span) * duration, 0, duration)
}

/**
 * Drag-to-scrub: moving the waveform right pulls earlier audio under the fixed
 * line. `dragFraction` is the pointer travel as a fraction of the waveform
 * width, so a rightward drag is positive.
 */
export function seekByDrag(
  positionSec: number,
  durationSec: number,
  spanFraction: number,
  dragFraction: number
): number {
  const duration = Math.max(0.001, durationSec)
  const span = clamp(spanFraction, MIN_WAVEFORM_SPAN, 1)
  return clamp(positionSec - dragFraction * span * duration, 0, duration)
}

/** Wheel zoom factor > 1 zooms out; the window stays centred on the line. */
export function zoomSpan(spanFraction: number, factor: number): number {
  return clamp(spanFraction * factor, MIN_WAVEFORM_SPAN, 1)
}

/**
 * X position of a track time in the visible window, or null when it is off
 * screen. Markers use this so they cannot be drawn outside the canvas.
 */
export function timeToX(seconds: number, startSec: number, spanSec: number, width: number): number | null {
  if (spanSec <= 0 || width <= 0) return null
  const x = ((seconds - startSec) / spanSec) * width
  return x < 0 || x > width ? null : x
}
