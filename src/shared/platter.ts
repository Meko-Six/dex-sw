/** Jog calibration: a quarter-turn moves half a beat. */
export const PLATTER_BEATS_PER_TURN = 2

/** Signed angular step in beats, including crossing the ±π seam. */
export function platterBeatDelta(fromRadians: number, toRadians: number): number {
  let delta = (toRadians - fromRadians) % (2 * Math.PI)
  if (delta > Math.PI) delta -= 2 * Math.PI
  if (delta < -Math.PI) delta += 2 * Math.PI
  return delta * PLATTER_BEATS_PER_TURN / (2 * Math.PI)
}
