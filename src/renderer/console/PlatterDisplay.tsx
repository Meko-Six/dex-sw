import { memo } from 'react'

const TICKS = 40
// The wedge covers precisely two neighboring fixed tick positions.
const GAP = 'M50 50 L42.154 -49.692 A100 100 0 0 1 73.345 -47.237 Z'

const Marks = memo(function Marks({ mask }: { mask: string }) {
  return <g className="platter-ticks" mask={`url(#${mask})`}>
    {Array.from({ length: TICKS }, (_, i) => <path key={i} d="M50 7V11 M50 13V16 M50 18V21" transform={`rotate(${i * (360 / TICKS)} 50 50)`} />)}
  </g>
})

/** Fixed radial marks with a two-mark gap that follows the track position. */
export function PlatterDisplay({ side, angle }: { side: string; angle: number }) {
  const mask = `platter-gap-${side}`
  const gapAngle = Math.floor(angle / (360 / TICKS)) * (360 / TICKS)
  return (
    <div className="platter-display" aria-hidden="true">
      <svg viewBox="0 0 100 100">
        <defs>
          <mask id={mask} maskUnits="userSpaceOnUse" x="0" y="0" width="100" height="100">
            <rect width="100" height="100" fill="white" />
            <path className="platter-gap" d={GAP} fill="black" style={{ transform: `rotate(${gapAngle}deg)` }} />
          </mask>
        </defs>
        <circle className="platter-screen-edge" cx="50" cy="50" r="48" />
        <Marks mask={mask} />
        <circle className="platter-accent-ring" cx="50" cy="50" r="24" />
        <circle className="platter-inner-ring" cx="50" cy="50" r="19" />
        <circle className="platter-hub" cx="50" cy="50" r="15" />
      </svg>
    </div>
  )
}
