import { useEffect, useRef, type PointerEvent as ReactPointerEvent } from 'react'
import { powerAt } from '../../shared/power'
import { camelotColour } from '../../shared/camelot'
import { HOT_CUE_COLOURS } from '../../shared/hot-cue'
import { loopSeconds } from '../../shared/loop'
import type { TrackMeta } from '../../shared/types'
import { engine } from '../audio/engine'
import type { DeckSnapshot, EngineSnapshot } from '../audio/types'
import { useDeckPosition } from '../hooks'
import { useArt } from '../state/art'
import { useLibrary } from '../state/library'
import { bpmParts, clock, remain, splitName, tempo } from './format'
import { accentOf, vars } from './layout'
import { clampSpan, SPAN_DEFAULT_SEC, SPAN_MAX_SEC, SPAN_MIN_SEC, useConsole, type Side } from './state'
import { DEMO_ART, DemoWave, isDemo } from './demo'
import { flatPaint, WaveCanvas } from './WaveCanvas'
import { rgba } from '../ui/waveform-gl'

const SIDES: Side[] = ['A', 'B']
const indexOf = (side: Side): 0 | 1 => (side === 'B' ? 1 : 0)

/** The track a deck holds, from the library. */
export function useDeckTrack(deck: DeckSnapshot): TrackMeta | undefined {
  return useLibrary((state) => (deck.trackId ? state.tracks.find((track) => track.id === deck.trackId) : undefined))
}

/** "Artist — Title" from the tags, or the file name split the same way. */
export function trackNames(track: TrackMeta | undefined, fallback: string | null): { artist: string; title: string } {
  if (track?.title) return { artist: track.artist ?? '', title: track.title }
  return splitName(track?.name ?? fallback ?? '')
}

function deckState(deck: DeckSnapshot): string {
  if (deck.loading) return 'loading'
  if (!deck.trackId) return 'empty'
  return deck.playing ? 'playing' : 'cued'
}

// ---- header ---------------------------------------------------------------

/**
 * Wordmark, what the library is working on, sync and master chips, VOLUME,
 * sample rate, split cue, TAP and the shortcuts key.
 */
export function Head({ snapshot }: { snapshot: EngineSnapshot }) {
  const energyEnabled = useConsole((state) => state.energyEnabled)
  const toggleEnergy = useConsole((state) => state.toggleEnergy)
  const volOpen = useConsole((state) => state.volOpen)
  const toggleVol = useConsole((state) => state.toggleVol)
  const sheet = useConsole((state) => state.sheet)
  const setSheet = useConsole((state) => state.setSheet)
  const status = useLibrary((state) => state.status)
  const saveState = useLibrary((state) => state.saveState)
  const flush = useLibrary((state) => state.flush)
  const split = snapshot.outputMode === 'split'
  const loaded = snapshot.decks.some((deck) => deck.trackId)
  const count = status?.current != null && status.total ? ` ${status.current} / ${status.total}` : ''
  return (
    <div className="head">
      <span className="brand">
        <i></i>DEX
      </span>
      {status && (
        <span className="head-status">
          <i></i>
          {`${status.label}${count}`}
          {status.name && <b>{status.name}</b>}
          {count && <em style={vars({ '--p': `${Math.round((1000 * status.current!) / status.total!) / 10}%` })}></em>}
        </span>
      )}
      <span className="head-chips">
        {saveState === 'saving' && <span className="chip">SAVING</span>}
        {saveState === 'error' && <button className="chip" onClick={() => void flush().catch(() => undefined)} title="Retry saving the library">NOT SAVED · RETRY</button>}
        {snapshot.decks.map(
          (deck) =>
            deck.syncLocked && (
              <span key={deck.id} className="chip live">
                {`SYNC ${deck.id}`}
              </span>
            )
        )}
        {loaded && <span className="chip master">{`MASTER ${snapshot.decks[snapshot.masterDeck].id}`}</span>}
      </span>
      <button className={`btn head-btn bands-btn ${energyEnabled ? '' : 'on'}`} aria-pressed={!energyEnabled} onClick={() => { if (energyEnabled) toggleEnergy() }} title="Frequency bands: blue bass, orange mids, white highs. Equal brightness throughout the track.">3BAND</button>
      <button className={`btn head-btn energy-btn ${energyEnabled ? 'on' : ''}`} aria-pressed={energyEnabled} onClick={toggleEnergy} title="Estimated musical intensity: blue → cyan → amber → red. Same scale for both decks. Toggle intensity or three frequency bands.">
        <i aria-hidden="true" />ENERGY
      </button>
      <button className={`btn vol-btn ${volOpen ? 'on' : ''}`} onClick={() => toggleVol()}>
        VOLUME
      </button>
      <span className="chip">{`${(snapshot.sampleRate / 1000).toFixed(1)} kHz`}</span>
      <button
        className={`btn head-btn ${split ? '' : 'on'}`}
        onClick={() => engine.setOutputMode(split ? 'multichannel' : 'split')}
        title="Split cue: master left, cue right. 4-channel: master 1/2, cue 3/4."
      >
        {split ? 'SPLIT CUE' : '4-CH CUE'}
      </button>
      <button className={`btn head-btn ${sheet === 'tap' ? 'on' : ''}`} onClick={() => setSheet(sheet === 'tap' ? null : 'tap')} title="Read the tempo of an external input">
        TAP
      </button>
      <button className="mini" onClick={() => setSheet(sheet === 'shortcuts' ? null : 'shortcuts')} title="Shortcuts">
        ?
      </button>
    </div>
  )
}

/** A failure, on one line under the header, red like a lit KILL. */
export function Alert({ title, message, onDismiss }: { title: string; message: string; onDismiss?: () => void }) {
  return (
    <div className="alert" role="alert">
      <b>{title}</b>
      <span>{message}</span>
      {onDismiss && (
        <button className="mini" onClick={onDismiss} title="Dismiss">
          ✕
        </button>
      )}
    </div>
  )
}

// ---- the screen: two zoom lanes under one playhead --------------------------

/** Shared neutral fallback while the worker builds frequency envelopes. */
const WAVE_PAINT = flatPaint(rgba('#7ea7e6'))

export function Screen({ snapshot }: { snapshot: EngineSnapshot }) {
  const spanSec = useConsole((state) => state.spanSec)
  const setSpan = useConsole((state) => state.setSpan)
  const openGrid = useConsole((state) => state.openGrid)
  const zoom = SPAN_MAX_SEC / spanSec
  return (
    <div className="screen">
      <div className="grid-stack">
        {SIDES.map((side) => (
          <button
            key={side}
            className="gridkey"
            data-side={side}
            style={vars({ '--accent': accentOf(side) })}
            onClick={() => snapshot.decks[indexOf(side)].trackId && openGrid(side)}
            title={`Beat grid for deck ${side}`}
          >
            GRID<span className="letter">{side}</span>
          </button>
        ))}
      </div>
      <div className="screen-zoom">
        {SIDES.map((side) => (
          <Lane key={side} side={side} deck={snapshot.decks[indexOf(side)]} spanSec={spanSec} />
        ))}
        <span className="zw-head" aria-hidden="true"></span>
      </div>
      <div className="zoom-stack">
        <span role="button" title="Zoom in" onClick={() => setSpan(spanSec / 2)} aria-disabled={spanSec <= SPAN_MIN_SEC}>
          +
        </span>
        <span className="read">{`×${zoom >= 1 ? Math.round(zoom) : zoom.toFixed(1)}`}</span>
        <span role="button" title="Zoom out" onClick={() => setSpan(spanSec * 2)} aria-disabled={spanSec >= SPAN_MAX_SEC}>
          −
        </span>
      </div>
    </div>
  )
}

interface LaneProps {
  side: Side
  deck: DeckSnapshot
  spanSec: number
}

/**
 * One zoom lane. The playhead is fixed at the middle and the audio scrolls
 * under it; drag to scrub, scroll to zoom, double-click for the default zoom.
 */
function Lane({ side, deck, spanSec }: LaneProps) {
  const energyEnabled = useConsole((state) => state.energyEnabled)
  const index = indexOf(side)
  const position = useDeckPosition(index)
  const setSpan = useConsole((state) => state.setSpan)
  const ref = useRef<HTMLDivElement | null>(null)
  const drag = useRef<{ pointerId: number; startX: number; start: number; width: number; moved: boolean } | null>(null)
  const loopDrag = useRef<{
    pointerId: number; startX: number; startBeat: number; width: number; span: number;
    bpm: number; trackId: string; length: number; moved: boolean; lastBeat: number
  } | null>(null)
  const lastSeek = useRef(0)
  const startSec = position - spanSec / 2
  const grid = deck.grid
  const cueLeft = deck.trackId ? ((deck.cuePoint - startSec) / spanSec) * 100 : null
  const dropping = useConsole((state) => state.drop?.side === side) && !deck.playing

  // Wheel zoom needs a non-passive listener to stop the page scrolling.
  useEffect(() => {
    const element = ref.current
    if (!element) return
    const onWheel = (event: WheelEvent): void => {
      event.preventDefault()
      if (loopDrag.current) return
      const { spanSec: span, setSpan: set } = useConsole.getState()
      set(clampSpan(span * (event.deltaY > 0 ? 1.3 : 0.77)))
    }
    element.addEventListener('wheel', onWheel, { passive: false })
    return () => element.removeEventListener('wheel', onWheel)
  }, [])

  const seekBy = (event: ReactPointerEvent<HTMLDivElement>, throttle: boolean): void => {
    const d = drag.current
    if (!d) return
    const now = performance.now()
    if (throttle && now - lastSeek.current < 40) return
    lastSeek.current = now
    const target = d.start - ((event.clientX - d.startX) / d.width) * spanSec
    void engine.seek(index, Math.max(0, Math.min(deck.durationSec, target)))
  }

  const moveLoop = (event: ReactPointerEvent<HTMLDivElement>): void => {
    const d = loopDrag.current
    if (!d || d.pointerId !== event.pointerId || d.trackId !== deck.trackId || d.length !== deck.loop?.lengthBeats) return
    if (!d.moved && Math.abs(event.clientX - d.startX) < 3) return
    d.moved = true
    const beat = d.startBeat + Math.round((event.clientX - d.startX) / d.width * d.span * d.bpm / 60)
    if (beat === d.lastBeat) return
    d.lastBeat = beat
    engine.moveLoop(index, beat)
  }

  const endLoopDrag = (): void => {
    loopDrag.current = null
    ref.current?.classList.remove('moving-loop')
  }

  const beginLoopDrag = (event: ReactPointerEvent<HTMLDivElement>): void => {
    event.stopPropagation()
    const element = ref.current
    if (event.button !== 0 || !element || !deck.trackId || !grid || !deck.loop || loopDrag.current || drag.current) return
    const width = element.getBoundingClientRect().width
    if (width < 3) return
    loopDrag.current = {
      pointerId: event.pointerId, startX: event.clientX, startBeat: deck.loop.startBeat,
      width, span: spanSec, bpm: grid.bpm, trackId: deck.trackId, length: deck.loop.lengthBeats,
      moved: false, lastBeat: deck.loop.startBeat
    }
    // Capture on the stable lane: the loop itself can leave the old viewport
    // for a frame while the playhead catches up with the scheduled move.
    try {
      element.setPointerCapture(event.pointerId)
    } catch {
      endLoopDrag()
      return
    }
    element.classList.add('moving-loop')
    engine.focusDeck(index)
  }

  return (
    <div
      ref={ref}
      className={`zw ${dropping ? 'drop' : ''}`}
      data-deck={side}
      data-side={side}
      style={vars({ '--accent': accentOf(side) })}
      onPointerDown={(event) => {
        if (!deck.trackId || event.button !== 0 || loopDrag.current || drag.current) return
        const rect = event.currentTarget.getBoundingClientRect()
        if (rect.width < 3) return
        drag.current = { pointerId: event.pointerId, startX: event.clientX, start: position, width: rect.width, moved: false }
        event.currentTarget.classList.add('scrubbing')
        try {
          event.currentTarget.setPointerCapture(event.pointerId)
        } catch {
          // A pointer that is already gone cannot be captured.
        }
      }}
      onPointerMove={(event) => {
        if (loopDrag.current?.pointerId === event.pointerId) {
          moveLoop(event)
          return
        }
        const d = drag.current
        if (!d || d.pointerId !== event.pointerId) return
        if (!d.moved && Math.abs(event.clientX - d.startX) < 3) return
        d.moved = true
        seekBy(event, true)
      }}
      onPointerUp={(event) => {
        if (loopDrag.current?.pointerId === event.pointerId) {
          moveLoop(event)
          endLoopDrag()
          return
        }
        const d = drag.current
        if (!d || d.pointerId !== event.pointerId) return
        if (d.moved) seekBy(event, false)
        drag.current = null
        event.currentTarget.classList.remove('scrubbing')
      }}
      onPointerCancel={(event) => {
        if (loopDrag.current?.pointerId === event.pointerId) endLoopDrag()
        drag.current = null
        event.currentTarget.classList.remove('scrubbing')
      }}
      onLostPointerCapture={(event) => {
        if (loopDrag.current?.pointerId === event.pointerId) endLoopDrag()
      }}
      onDoubleClick={() => setSpan(SPAN_DEFAULT_SEC)}
    >
      {!deck.trackId ? null : isDemo ? (
        <DemoWave lane side={side} />
      ) : (
        <WaveCanvas
          deck={deck}
          startSec={startSec}
          spanSec={spanSec}
          playSec={position}
          amp={0.96}
          paint={WAVE_PAINT}
        />
      )}
      {deck.trackId && grid && deck.loop && <LaneLoop grid={grid} loop={deck.loop} startSec={startSec} spanSec={spanSec} durationSec={deck.durationSec} onPointerDown={beginLoopDrag} onStep={(delta) => engine.moveLoop(index, deck.loop!.startBeat + delta)} />}
      {deck.trackId && grid && <LaneGrid grid={grid} startSec={startSec} spanSec={spanSec} durationSec={deck.durationSec} />}
      <span className="zw-label">
        DECK <b style={{ color: accentOf(side) }}>{side}</b>
        {` · ${grid ? grid.bpm.toFixed(1) : '—'} BPM · ${deckState(deck).toUpperCase()}`}
        {energyEnabled && deck.trackId && <em className="energy-reading" title="Estimated musical intensity, 0–100. Input trim and EQ do not affect this analysis.">{deck.power ? ` · ENERGY ${Math.round(powerAt(deck.power, position) * 100)}` : ' · ENERGY —'}</em>}
      </span>
      {!deck.trackId && !deck.loading && <span className="zw-empty">NO TRACK</span>}
      {cueLeft != null && cueLeft >= -2 && cueLeft <= 102 && <span className="zw-cue" style={{ left: `${cueLeft}%` }}></span>}
    </div>
  )
}

/** Highlight the actual selected audio region, clipped to this zoom window. */
function LaneLoop({ grid, loop, startSec, spanSec, durationSec, onPointerDown, onStep }: {
  grid: NonNullable<DeckSnapshot['grid']>
  loop: NonNullable<DeckSnapshot['loop']>
  startSec: number
  spanSec: number
  durationSec: number
  onPointerDown: (event: ReactPointerEvent<HTMLDivElement>) => void
  onStep: (delta: number) => void
}) {
  const region = loopSeconds(grid, loop)
  const endSec = startSec + spanSec
  const left = Math.max(startSec, region.startSec)
  const right = Math.min(endSec, region.endSec)
  if (right <= left) return null
  return (
    <div
      className={`zw-loop ${region.startSec >= startSec ? 'edge-start' : ''} ${region.endSec <= endSec ? 'edge-end' : ''}`}
      style={{ left: `${100 * (left - startSec) / spanSec}%`, width: `${100 * (right - left) / spanSec}%` }}
      data-start-sec={region.startSec}
      data-end-sec={region.endSec}
      role="slider"
      tabIndex={0}
      title="Drag to move the loop in whole beats"
      aria-label={`${loop.lengthBeats}-beat loop position`}
      aria-valuenow={loop.startBeat}
      aria-valuemin={Math.ceil(-grid.offsetMs / 1000 * grid.bpm / 60)}
      aria-valuemax={Math.floor((durationSec - grid.offsetMs / 1000) * grid.bpm / 60 - loop.lengthBeats)}
      aria-valuetext={`Loop starts at ${region.startSec.toFixed(2)} seconds`}
      onPointerDown={onPointerDown}
      onDoubleClick={(event) => event.stopPropagation()}
      onKeyDown={(event) => {
        if (event.key !== 'ArrowLeft' && event.key !== 'ArrowRight') return
        event.preventDefault()
        event.stopPropagation()
        onStep(event.key === 'ArrowRight' ? 1 : -1)
      }}
    >
      <b>{`LOOP · ${loop.lengthBeats} ${loop.lengthBeats === 1 ? 'BEAT' : 'BEATS'}`}</b>
    </div>
  )
}

interface LaneGridProps {
  grid: NonNullable<DeckSnapshot['grid']>
  startSec: number
  spanSec: number
  durationSec: number
}

/**
 * The beat grid along a lane's edges, Pioneer style: a tick at the top and
 * bottom on every beat in view, a longer red one on each bar's downbeat. The
 * grid's offset is folded at the bar, so beat 0 is a downbeat.
 */
function LaneGrid({ grid, startSec, spanSec, durationSec }: LaneGridProps) {
  const period = 60 / grid.bpm
  const offset = grid.offsetMs / 1000
  const first = Math.ceil((Math.max(0, startSec) - offset) / period)
  const last = Math.floor((Math.min(durationSec, startSec + spanSec) - offset) / period)
  const ticks = []
  for (let k = first; k <= last; k++) {
    const left = ((offset + k * period - startSec) / spanSec) * 100
    ticks.push(<i key={k} className={((k % 4) + 4) % 4 === 0 ? 'bar' : ''} style={{ left: `${left.toFixed(3)}%` }}></i>)
  }
  return <div className="zw-grid">{ticks}</div>
}

// ---- track windows -------------------------------------------------------------

const ART_LABEL: Record<string, string> = { '': 'LOAD', armed: 'LOAD', blocked: 'PLAYING', loaded: 'LOADED' }

/** Placeholder cover for a track with no art: two colours from the track id. */
function placeholderArt(seed: string): string {
  let hash = 0
  for (let i = 0; i < seed.length; i++) hash = (hash * 31 + seed.charCodeAt(i)) >>> 0
  const hue = hash % 360
  return `linear-gradient(135deg, hsl(${hue} 50% 32%) 0 55%, hsl(${(hue + 150) % 360} 55% 52%) 55% 100%)`
}

export function Info({ snapshot }: { snapshot: EngineSnapshot }) {
  return (
    <div className="info">
      {SIDES.map((side) => (
        <TrackWindow key={side} side={side} deck={snapshot.decks[indexOf(side)]} />
      ))}
    </div>
  )
}

interface TrackWindowProps {
  side: Side
  deck: DeckSnapshot
}

/**
 * The CDJ-style track window: title bar, album art (the load target), REMAIN,
 * TEMPO, KEY and the BPM box over a one-sided overview with hot cue flags.
 */
function TrackWindow({ side, deck }: TrackWindowProps) {
  const index = indexOf(side)
  const position = useDeckPosition(index)
  const track = useDeckTrack(deck)
  const artUrl = useArt((state) => (deck.trackId ? state.urls[deck.trackId] : null))
  const libOpen = useConsole((state) => state.libOpen)
  const selectedId = useConsole((state) => state.selectedId)
  const toggleLib = useConsole((state) => state.toggleLib)
  const selected = useLibrary((state) => (selectedId ? state.tracks.find((entry) => entry.id === selectedId) : undefined))
  const loadToDeck = useLibrary((state) => state.loadToDeck)
  const drop = useConsole((state) => (state.drop?.side === side ? state.drop : null))

  const { artist, title } = trackNames(track, deck.trackName)
  const length = deck.durationSec
  // The demo works the played share out from whole elapsed seconds, as the mockup does.
  const played = length > 0 ? Math.min(1, Math.max(0, (isDemo ? Math.floor(position) : position) / length)) : 0
  const pct = (seconds: number): string => `${((100 * seconds) / length).toFixed(2)}%`
  const left = remain(length - position)
  const { sign, digits } = tempo(deck.baseRate)
  const keyLabel = deck.keyLock ? 'KEY LOCK' : ''
  const role = deck.isMaster ? 'master' : deck.syncLocked ? 'sync' : ''
  const [bpmWhole, bpmTenth] = deck.grid ? bpmParts(deck.grid.bpm * deck.rate) : ['—', '']
  const camelot = track?.camelot ?? null
  const cuePoint = deck.trackId && deck.cuePoint > 0.05 ? deck.cuePoint : null
  const loop = deck.grid && deck.loop ? loopSeconds(deck.grid, deck.loop) : null
  const seeking = useRef<number | null>(null)
  const seekAt = (event: ReactPointerEvent<HTMLDivElement>): void => {
    const rect = event.currentTarget.getBoundingClientRect()
    if (rect.width <= 0) return
    // To the bar under the pointer, keeping the place in the bar (see shared/beat-jump.ts).
    void engine.jumpToBar(index, Math.max(0, Math.min(1, (event.clientX - rect.left) / rect.width)) * length)
  }

  const artState = !libOpen || !selected ? '' : selected.id === deck.trackId ? 'loaded' : deck.playing ? 'blocked' : 'armed'
  const tapArt = (): void => {
    // A load into a stopped deck is the end of the job: close the library.
    if (libOpen && selected) {
      if (deck.playing || artState === 'loaded') return
      void loadToDeck(selected, index)
      toggleLib(false)
    } else toggleLib()
  }

  const step = length > 240 ? 60 : 15
  const ticks = length > 0 ? Array.from({ length: Math.floor(length / step) }, (_, i) => ((100 * (i + 1) * step) / length).toFixed(2)) : []
  const cues = length > 0 ? deck.hotCues.map((seconds, slot) => (seconds == null ? null : { seconds, slot })).filter((cue) => cue !== null) : []

  // A file or library row held over the deck: load here, or say why not.
  const dropCover = drop ? (
    deck.playing ? (
      <div className="zdrop blocked">
        <b>{`DECK ${side} IS PLAYING`}</b>
        <span>{`Pause it to load here, or drop on deck ${side === 'A' ? 'B' : 'A'}`}</span>
      </div>
    ) : (
      <div className="zdrop">
        <b>{`DROP TO LOAD ON ${side}`}</b>
        <span>{drop.label}</span>
      </div>
    )
  ) : null

  // An empty deck keeps its window; the readouts go dark and say how to load.
  if (!deck.trackId) {
    return (
      <div className="zcard empty" data-deck={side} data-side={side} style={vars({ '--accent': accentOf(side) })} onPointerDown={() => engine.focusDeck(index)}>
        <div className="ztitle">
          <span className="zdeck">{side}</span>
          <span className="note">♪</span>
          <span className="zname" onClick={() => toggleLib()}>
            {deck.loading ? 'Loading…' : 'No track loaded'}
          </span>
          <span className="zartist"></span>
        </div>
        <button className={`zart ${artState}`} onClick={tapArt} title={`Open the library to load deck ${side}`} style={vars({ '--art': '#151517' })}>
          <i>♪</i>
          <b>{ART_LABEL[artState]}</b>
        </button>
        <div className="zbody">
          <div className="zreads">
            <div className="zrem">
              <span className="zlbl">REMAIN</span>
              <span className="zsub">
                {'-:-- '}
                <span>/ -:--</span>
              </span>
            </div>
            <div className="zremain">
              <b>
                --:--<i>.---</i>
              </b>
            </div>
            <div className="ztempo">
              <span className="zlbl">TEMPO</span>
              <b>
                + 0.00<i>%</i>
              </b>
            </div>
            <div className="zkey">
              <span className="zkeychip off">KEY</span>
              <span className="cam" style={vars({ '--cam': 'var(--dim)' })}>
                —
              </span>
            </div>
            <div className="zbpm">
              <b>
                ---<i>.-</i>
              </b>
              <span></span>
            </div>
          </div>
          <div className="zfull">
            <div className="zflags" style={{ position: 'relative' }}></div>
            <div className="zwave">
              <span className="zempty">TAP THE ART TO LOAD, OR DROP A FILE HERE</span>
            </div>
            <div className="zbar"></div>
            <div className="zticks"></div>
          </div>
        </div>
        {dropCover}
      </div>
    )
  }

  return (
    <div className="zcard" data-deck={side} data-side={side} style={vars({ '--accent': accentOf(side) })} onPointerDown={() => engine.focusDeck(index)}>
      <div className="ztitle">
        <span className="zdeck">{side}</span>
        <span className="note">♪</span>
        <span className="zname" onClick={() => toggleLib()}>
          {deck.loading ? 'Loading…' : deck.trackId ? title : 'No track loaded'}
        </span>
        <span className="zartist">{deck.trackId ? artist : ''}</span>
      </div>
      <button
        className={`zart ${artState}`}
        onClick={tapArt}
        title={`Load a track onto deck ${side}`}
        style={vars({ '--art': artUrl ? `center / cover no-repeat url("${artUrl}")` : (isDemo && DEMO_ART[deck.trackId ?? '']) || placeholderArt(deck.trackId ?? side) })}
      >
        {!artUrl && <i>♪</i>}
        <b>{ART_LABEL[artState]}</b>
      </button>
      <div className="zbody">
        <div className="zreads">
          <div className="zrem">
            <span className="zlbl">REMAIN</span>
            <span className="zsub">
              {`${clock(position)} `}
              <span>{`/ ${clock(length)}`}</span>
            </span>
          </div>
          <div className="zremain">
            <b>
              {left.whole}
              <i>{`.${left.ms}`}</i>
            </b>
          </div>
          <div className="ztempo">
            <span className="zlbl">TEMPO</span>
            <b>
              {`${sign} ${digits}`}
              <i>%</i>
            </b>
          </div>
          <div className="zkey">
            <span className={`zkeychip ${keyLabel ? '' : 'off'}`}>{keyLabel || 'KEY'}</span>
            <span className="cam" style={vars({ '--cam': camelot ? (camelotColour(camelot) ?? 'var(--dim)') : 'var(--dim)' })}>
              {camelot ?? '—'}
            </span>
          </div>
          <div className={`zbpm ${role}`}>
            <b>
              {bpmWhole}
              {bpmTenth && <i>{`.${bpmTenth}`}</i>}
            </b>
            <span>{role === 'master' ? 'MASTER' : role === 'sync' ? 'SYNC' : ''}</span>
          </div>
        </div>
        <div
          className="zfull"
          onPointerDown={(event) => {
            if (!deck.trackId || length <= 0) return
            seeking.current = event.pointerId
            event.currentTarget.setPointerCapture(event.pointerId)
            seekAt(event)
          }}
          onPointerMove={(event) => {
            if (seeking.current === event.pointerId) seekAt(event)
          }}
          onPointerUp={() => (seeking.current = null)}
          onPointerCancel={() => (seeking.current = null)}
        >
          <div className="zflags" style={{ position: 'relative' }}>
            {cues.map((cue) => (
              <span key={cue.slot} className="zflag" style={vars({ left: pct(cue.seconds), '--hc': HOT_CUE_COLOURS[cue.slot] })}>
                <b>{cue.slot + 1}</b>
              </span>
            ))}
            {cuePoint != null && <span className="zflag mem" style={{ left: pct(cuePoint) }}></span>}
          </div>
          <div className="zwave">
            {isDemo ? (
              <DemoWave side={side} played={played} />
            ) : (
              <WaveCanvas deck={deck} startSec={0} spanSec={length} playSec={position} amp={0.96} oneSided paint={WAVE_PAINT} />
            )}
            {loop && <span className="zloop" style={{ left: pct(loop.startSec), width: pct(loop.lengthSec) }}></span>}
          </div>
          <div className="zbar">
            <i style={{ left: `${(played * 100).toFixed(2)}%` }}></i>
          </div>
          <div className="zticks">
            {ticks.map((left) => (
              <i key={left} style={{ left: `${left}%` }}></i>
            ))}
          </div>
          {cues.map((cue) => (
            <span key={cue.slot} className="zline" style={vars({ left: pct(cue.seconds), '--hc': HOT_CUE_COLOURS[cue.slot] })}></span>
          ))}
          {cuePoint != null && <span className="zline" style={vars({ left: pct(cuePoint), '--hc': 'var(--red)' })}></span>}
          {length > 0 && <span className="zhead" style={{ left: `${(played * 100).toFixed(2)}%` }}></span>}
        </div>
      </div>
      {dropCover}
    </div>
  )
}

