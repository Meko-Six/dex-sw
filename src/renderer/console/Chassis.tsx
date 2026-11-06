import { useRef, type PointerEvent as ReactPointerEvent } from 'react'
import { JUMP_LENGTHS_BARS } from '../../shared/beat-jump'
import { filterSetting } from '../../shared/curves'
import { autoTrimDb, faderDb, formatDb, lowSumDb } from '../../shared/mixer'
import { platterBeatDelta, PLATTER_BEATS_PER_TURN } from '../../shared/platter'
import { engine } from '../audio/engine'
import type { DeckSnapshot, EngineSnapshot } from '../audio/types'
import { useDeckPosition, useMeterDb } from '../hooks'
import { useLibrary } from '../state/library'
import { useDeckTrack } from './Band'
import { cueTime, tempoText } from './format'
import { InfoButton } from './Help'
import { PlatterDisplay } from './PlatterDisplay'
import {
  accentOf,
  at,
  BAND_NAME,
  BANDS,
  CAP,
  colX,
  DECK_X,
  JUMP,
  JUMP_KEYS,
  KEY,
  PLATTER,
  ROW,
  ROW_Y,
  TEMPO_COL_H,
  vars,
  type Band,
  type Column
} from './layout'
import { useConsole, type Side } from './state'
import { tempoToFader, useMixDrags, type MixDrags } from './useMixDrags'

const indexOf = (side: Side): 0 | 1 => (side === 'B' ? 1 : 0)

const ICON_PLAY = (
  <svg viewBox="0 0 24 24">
    <path d="M8 5.5v13l11-6.5z" />
  </svg>
)
const ICON_BACK = (
  <svg viewBox="0 0 24 24">
    <path d="M17 5.5v13L6 12z" />
  </svg>
)
const ICON_FORWARD = (
  <svg viewBox="0 0 24 24">
    <path d="M7 5.5v13L18 12z" />
  </svg>
)
const ICON_PAUSE = (
  <svg viewBox="0 0 24 24">
    <rect x="6" y="5" width="4" height="14" rx="1" />
    <rect x="14" y="5" width="4" height="14" rx="1" />
  </svg>
)

/** "0.0", "+1.4", "−3.0" for TRIM. */
const fmtTrim = (db: number): string => (Math.abs(db) < 0.05 ? '0.0' : `${db > 0 ? '+' : '−'}${Math.abs(db).toFixed(1)}`)

function filterLabel(knob: number): string {
  const setting = filterSetting(knob)
  if (Math.abs(knob) < 0.04 || setting.frequency >= 20000) return 'FILTER'
  const hz = setting.frequency >= 1000 ? `${(setting.frequency / 1000).toFixed(1)}k` : String(Math.round(setting.frequency))
  return `${setting.type === 'lowpass' ? 'LP' : 'HP'} ${hz}`
}

/**
 * The chassis: deck A's bay, the mixer, deck B's bay. Every control sits at
 * the mockup's coordinates; slider drags and kill pads are handled here for
 * the whole chassis, as in the mockup, so several can be held at once.
 */
export function Chassis({ snapshot }: { snapshot: EngineSnapshot }) {
  const link = useConsole((state) => state.link)
  const mixPop = useConsole((state) => state.mixPop)
  const setMixPop = useConsole((state) => state.setMixPop)
  const linked = useRef(link)
  linked.current = link
  const drags = useMixDrags(linked)

  return (
    <main
      className="chassis"
      onPointerDown={drags.onPointerDown}
      onPointerMove={drags.onPointerMove}
      onPointerUp={drags.onPointerUp}
      onPointerCancel={drags.onPointerUp}
      onClick={(event) => {
        // A tap outside an open mixer popover closes it.
        if (mixPop && !(event.target as Element).closest('.mixpop, .trimchip, .bandval')) setMixPop(null)
      }}
    >
      <Bay side="A" snapshot={snapshot} drags={drags} />
      <Mixer snapshot={snapshot} drags={drags} />
      <Bay side="B" snapshot={snapshot} drags={drags} />
    </main>
  )
}

// ---- deck bay ----------------------------------------------------------------------

interface BayProps {
  side: Side
  snapshot: EngineSnapshot
  drags: MixDrags
}

/**
 * One deck: SYNC · MASTER · KEY · HOT CUE on the TRIM row, the tempo fader on
 * the outside edge, the platter, and CUE · PLAY · loop along the bottom.
 */
function Bay({ side, snapshot, drags }: BayProps) {
  const index = indexOf(side)
  const deck = snapshot.decks[index]
  const x = DECK_X[side]
  const cueOpen = useConsole((state) => state.cueOpen[side])
  const toggleHotCues = useConsole((state) => state.toggleHotCues)
  const tempoActive = drags.active(side, 'tempo')
  const empty = !deck.trackId
  const cuePointer = useRef<number | null>(null)
  const playButton = useRef<HTMLButtonElement>(null)
  const continuedOnPress = useRef(false)
  const latchCueAt = (event: ReactPointerEvent<HTMLButtonElement>): void => {
    if (cuePointer.current !== event.pointerId) return
    const bounds = playButton.current?.getBoundingClientRect()
    if (bounds && event.clientX >= bounds.left && event.clientX <= bounds.right && event.clientY >= bounds.top && event.clientY <= bounds.bottom) {
      engine.continueCue(index)
    }
  }
  const releaseCue = (event: ReactPointerEvent<HTMLButtonElement>): void => {
    if (cuePointer.current !== event.pointerId) return
    cuePointer.current = null
    void engine.cueUp(index)
  }
  const pill = (i: number, cls: string, label: string, onClick: () => void, disabled = false) => (
    <button className={`pill at ${cls}`} style={at(x.pills[i], ROW.top[0], 64, ROW.top[1])} onClick={onClick} disabled={disabled}>
      {label}
    </button>
  )

  return (
    <section
      className={`bay ${side === 'A' ? 'a' : 'b'} ${deck.playing ? 'playing' : ''}`}
      data-side={side}
      onPointerDown={() => engine.focusDeck(index)}
    >
      {pill(0, deck.syncLocked ? 'on' : '', 'SYNC', () => (deck.syncLocked ? engine.unsync(index) : engine.sync(index)))}
      {pill(1, deck.isMaster && !empty ? 'on' : '', 'MASTER', () => engine.setMaster(index), empty)}
      {pill(2, deck.keyLock ? 'blue on' : 'blue', 'KEY', () => engine.setKeyLock(index, !deck.keyLock))}
      {pill(3, cueOpen ? 'on' : '', 'HOT CUE', () => toggleHotCues(side), empty)}
      <div className="col at" style={at(x.tempo - 24, 66, 48, TEMPO_COL_H)}>
        <span className="eq-name">TEMPO</span>
        <div
          className={`fader-v accent ${tempoActive ? 'dragging' : ''}`}
          data-param="tempo"
          data-deck={side}
          role="slider"
          aria-label={`Deck ${side} tempo`}
          style={vars({ '--pos': `${(tempoToFader(deck.baseRate) * 100).toFixed(4)}%`, '--lvl': tempoToFader(deck.baseRate).toFixed(4) })}
        >
          <span className="fr"></span>
          <span className="zero"></span>
          <span className="thumb"></span>
        </div>
        <span className="eq-val mono">{tempoText(deck.baseRate)}</span>
      </div>
      <div className="face-platter at" style={at(x.platter - PLATTER.size / 2, PLATTER.y, PLATTER.size, PLATTER.size)}>
        <Platter index={index} deck={deck} />
      </div>
      <BeatJump side={side} deck={deck} />
      <button
        className="big lg cue at keep"
        style={at(x.row, ROW_Y, KEY, KEY)}
        onPointerDown={(event) => {
          if (event.button !== 0 || cuePointer.current !== null) return
          cuePointer.current = event.pointerId
          try {
            event.currentTarget.setPointerCapture(event.pointerId)
          } catch {
            // A pointer that is already gone cannot be captured.
          }
          void engine.cueDown(index)
        }}
        onPointerMove={latchCueAt}
        onPointerUp={(event) => {
          latchCueAt(event)
          releaseCue(event)
        }}
        onPointerCancel={releaseCue}
        onLostPointerCapture={releaseCue}
        aria-label={`Deck ${side} cue`}
        title="Tap or hold CUE to preview on the playing deck's beat; slide onto PLAY to keep playing"
        disabled={empty}
      >
        CUE
      </button>
      <button
        ref={playButton}
        className="big lg play at keep"
        style={at(x.row + KEY + 8, ROW_Y, KEY, KEY)}
        onPointerDown={(event) => {
          if (event.button === 0) continuedOnPress.current = engine.continueCue(index)
        }}
        onPointerCancel={() => (continuedOnPress.current = false)}
        onClick={(event) => {
          // A second finger can latch on press while the first holds CUE.
          // Its ensuing click must not turn that continuation into a pause.
          if (continuedOnPress.current && event.detail > 0) {
            continuedOnPress.current = false
            return
          }
          continuedOnPress.current = false
          void engine.togglePlay(index)
        }}
        disabled={empty}
        aria-label={`Deck ${side} ${deck.previewing || !deck.playing ? 'play' : 'pause'}`}
        title={deck.previewing ? 'Keep the CUE preview playing' : deck.playing ? 'Pause' : 'Play'}
      >
        {deck.playing && !deck.previewing ? ICON_PAUSE : ICON_PLAY}
      </button>
      <div className="at keep" style={{ ...at(x.row + 2 * KEY + 26, ROW_Y + 7, 340 - 2 * KEY - 26, 52), display: 'flex' }}>
        <LoopStepper index={index} deck={deck} />
      </div>
      {cueOpen && <HotCuePop side={side} deck={deck} />}
    </section>
  )
}

/** The record: circular scrubbing at two beats per full turn. */
function Platter({ index, deck }: { index: 0 | 1; deck: DeckSnapshot }) {
  const position = useDeckPosition(index)
  const drag = useRef<{
    pointerId: number; trackId: string; start: number; secondsPerBeat: number;
    cx: number; cy: number; deadZone: number; angle: number | null; beats: number; appliedBeats: number
  } | null>(null)
  const lastSeek = useRef(0)
  const secondsPerBeat = 60 / (deck.grid?.bpm ?? 120)
  const angle = (((position / secondsPerBeat * 360 / PLATTER_BEATS_PER_TURN) % 360) + 360) % 360
  const scrub = (event: ReactPointerEvent<HTMLDivElement>, throttle: boolean): void => {
    const state = drag.current
    if (!state || state.pointerId !== event.pointerId || state.trackId !== deck.trackId || deck.durationSec <= 0) return
    const dx = event.clientX - state.cx, dy = event.clientY - state.cy
    if (Math.hypot(dx, dy) < state.deadZone) {
      state.angle = null
    } else {
      const nextAngle = Math.atan2(dy, dx)
      if (state.angle !== null) state.beats += platterBeatDelta(state.angle, nextAngle)
      state.angle = nextAngle
    }
    const now = performance.now()
    const target = Math.max(0, Math.min(deck.durationSec, state.start + state.beats * state.secondsPerBeat))
    state.beats = (target - state.start) / state.secondsPerBeat
    if (Math.abs(state.beats - state.appliedBeats) < 1e-6 || (throttle && now - lastSeek.current < 40)) return
    lastSeek.current = now
    state.appliedBeats = state.beats
    void engine.scrub(index, target)
  }
  return (
    <div
      className="platter"
      title="Drag around the platter: 90° moves half a beat"
      onPointerDown={(event) => {
        if (!deck.trackId || event.button !== 0 || drag.current) return
        const rect = event.currentTarget.getBoundingClientRect()
        const cx = rect.left + rect.width / 2, cy = rect.top + rect.height / 2
        const dx = event.clientX - cx, dy = event.clientY - cy
        const deadZone = rect.width * 0.08
        event.currentTarget.setPointerCapture(event.pointerId)
        drag.current = {
          pointerId: event.pointerId, trackId: deck.trackId,
          start: engine.getDeck(index)?.position ?? position, secondsPerBeat,
          cx, cy, deadZone, angle: Math.hypot(dx, dy) < deadZone ? null : Math.atan2(dy, dx), beats: 0, appliedBeats: 0
        }
        lastSeek.current = 0
      }}
      onPointerMove={(event) => scrub(event, true)}
      onPointerUp={(event) => {
        if (drag.current?.pointerId !== event.pointerId) return
        scrub(event, false)
        drag.current = null
      }}
      onPointerCancel={(event) => {
        if (drag.current?.pointerId === event.pointerId) drag.current = null
      }}
      onLostPointerCapture={(event) => {
        if (drag.current?.pointerId === event.pointerId) drag.current = null
      }}
    >
      <PlatterDisplay side={deck.id} angle={angle} />
    </div>
  )
}

/**
 * Beat jump, CDJ style: ◀ and ▶ jump whole bars of the deck's grid, one jump
 * per press, keeping the place in the bar; the selector between them picks
 * how many. A paused deck lands on a bar line; a running loop moves along.
 */
function BeatJump({ side, deck }: { side: Side; deck: DeckSnapshot }) {
  const index = indexOf(side)
  const cols = DECK_X[side].pills
  const right = cols[3] + JUMP.pill
  const off = !deck.trackId || !deck.grid
  const bars = deck.jumpBars
  const unit = bars === 1 ? 'bar' : 'bars'
  const [backKey, forwardKey] = JUMP_KEYS[side].map((key) => key.toUpperCase())
  return (
    <>
      <button
        className="jstep at"
        style={at(cols[0], JUMP.y, JUMP.key, JUMP.h)}
        onClick={() => engine.beatJump(index, -1)}
        disabled={off}
        title={`Jump back ${bars} ${unit} (${backKey})`}
      >
        {ICON_BACK}
      </button>
      <div className="jlen at" style={at(cols[0] + JUMP.key + JUMP.gap, JUMP.y, right - cols[0] - 2 * (JUMP.key + JUMP.gap), JUMP.h)}>
        {JUMP_LENGTHS_BARS.map((length) => (
          <button
            key={length}
            className={length === bars ? 'on' : ''}
            onClick={() => engine.setJumpBars(index, length)}
            disabled={off}
            title={`Jump ${length} ${length === 1 ? 'bar' : 'bars'} a press`}
          >
            {length}
          </button>
        ))}
      </div>
      <button
        className="jstep at"
        style={at(right - JUMP.key, JUMP.y, JUMP.key, JUMP.h)}
        onClick={() => engine.beatJump(index, 1)}
        disabled={off}
        title={`Jump forward ${bars} ${unit} (${forwardKey})`}
      >
        {ICON_FORWARD}
      </button>
    </>
  )
}

/** ‹ halves, › doubles (a running loop follows); the readout starts or leaves the loop. */
function LoopStepper({ index, deck }: { index: 0 | 1; deck: DeckSnapshot }) {
  const on = deck.loop != null
  const beats = deck.loop?.lengthBeats ?? deck.loopBeats
  if (!deck.trackId) {
    return (
      <div className="loopbar">
        <button className="lstep" disabled>
          ‹
        </button>
        <button className="lsize" disabled>
          <b>{beats}</b>
        </button>
        <button className="lstep" disabled>
          ›
        </button>
      </div>
    )
  }
  return (
    <div className={`loopbar ${on ? 'on' : ''}`}>
      <button className="lstep" onClick={() => engine.stepLoopSize(index, -1)} disabled={beats <= 1} title="Halve the loop size">
        ‹
      </button>
      <button className={`lsize ${on ? 'on' : ''}`} onClick={() => void engine.toggleLoop(index)} title={on ? 'Leave the loop' : 'Start a loop at this size'} aria-pressed={on} aria-label={`Deck ${deck.id}, ${beats}-beat loop`}>
        <b>{beats}</b>
      </button>
      <button className="lstep" onClick={() => engine.stepLoopSize(index, 1)} disabled={beats >= 64} title="Double the loop size">
        ›
      </button>
    </div>
  )
}

/**
 * Hot cues: a 4 × 2 bank over the platter, opened by HOT CUE. An empty pad
 * captures the playhead, a set pad jumps; DELETE turns set pads into erasers
 * until it is pressed again or nothing is left.
 */
function HotCuePop({ side, deck }: { side: Side; deck: DeckSnapshot }) {
  const index = indexOf(side)
  const deleting = useConsole((state) => state.cueDelete[side])
  const setCueDelete = useConsole((state) => state.setCueDelete)
  const toggleHotCues = useConsole((state) => state.toggleHotCues)
  const applyHotCues = useLibrary((state) => state.applyHotCues)
  const anySet = deck.hotCues.some((seconds) => seconds != null)

  /** Mirror the deck's working cues into the library entry that loaded it. */
  const save = (trackId: string | null): void => {
    if (trackId) applyHotCues(trackId, engine.getSnapshot().decks[index].hotCues)
  }
  const press = (slot: number): void => {
    const set = deck.hotCues[slot] != null
    if (set && deleting) {
      engine.clearHotCue(index, slot)
      save(deck.trackId)
      if (!engine.getSnapshot().decks[index].hotCues.some((seconds) => seconds != null)) setCueDelete(side, false)
      return
    }
    if (!deck.trackId) return
    const trackId = deck.trackId
    void engine.triggerHotCue(index, slot).then((captured) => {
      // A recall does not change the saved cues; only a capture does.
      if (captured && engine.getSnapshot().decks[index].trackId === trackId) save(trackId)
    })
  }

  return (
    <div
      className={`mixpop cuepop at ${deleting ? 'deleting' : ''}`}
      data-side={side}
      style={{ ...at(DECK_X[side].platter - 150, 132, 300, 236), ...vars({ '--accent': accentOf(side) }) }}
    >
      <h4>
        {`Hot cues ${side}`}
        <button className={`cuebank-del ${deleting ? 'on' : ''}`} onClick={() => setCueDelete(side, !deleting)} disabled={!anySet}>
          {deleting ? 'KEEP' : 'DELETE'}
        </button>
        <button className="btn ghost done" onClick={() => toggleHotCues(side)}>
          Done
        </button>
      </h4>
      <div className="cuebank-grid">
        {deck.hotCues.map((seconds, slot) =>
          seconds != null ? (
            <button key={slot} className="hc set" onClick={() => press(slot)}>
              <b>{slot + 1}</b>
              <small>{cueTime(seconds)}</small>
            </button>
          ) : (
            <button key={slot} className="hc" onClick={() => press(slot)} disabled={deleting}>
              <b>{slot + 1}</b>
              <small>set</small>
            </button>
          )
        )}
      </div>
    </div>
  )
}

// ---- mixer -----------------------------------------------------------------------------

const FADER_IDS: Column[] = ['level', ...BANDS]
const TICKS = [1, 0.8, 0.6, 0.4, 0.2, 0]

interface MixerProps {
  snapshot: EngineSnapshot
  drags: MixDrags
}

/**
 * Per channel, outside in: LEVEL · HI · MID · LOW, so the two LOW faders sit
 * side by side across the centre. Every band fader is cut-only on one law;
 * kills are separate latching pads. Between the LOWs: LOW Σ, the master
 * meter, the low-sum meter and LINK LOWS. The crossfader runs underneath.
 */
function Mixer({ snapshot, drags }: MixerProps) {
  const link = useConsole((state) => state.link)
  const toggleLink = useConsole((state) => state.toggleLink)
  const mixPop = useConsole((state) => state.mixPop)
  const meterDb = useMeterDb()
  const [a, b] = snapshot.decks
  const sum = lowSumDb(
    { low: a.eq.low, lowKill: a.kills.low, level: a.level, trimDb: a.trimDb },
    { low: b.eq.low, lowKill: b.kills.low, level: b.level, trimDb: b.trimDb },
    snapshot.crossfader
  )
  const sumBar = sum === Number.NEGATIVE_INFINITY ? 0 : Math.max(0, Math.min(100, ((sum + 24) / 30) * 100))
  const meterBar = Math.max(0, Math.min(100, ((meterDb + 48) / 48) * 100))
  const xfActive = drags.active(undefined, 'xfade')

  return (
    <section className="mixer">
      <Channel side="A" deck={a} drags={drags} />
      <button className="bandval sumval at" style={at(574, ROW.val[0], 46, ROW.val[1])}>
        <b>LOW Σ</b>
        <span className={sum >= 3 ? 'over' : sum > 1 ? 'warn' : ''}>{formatDb(sum)}</span>
      </button>
      <div className="meter-v at" title="Master peak" style={at(578, ROW.fader[0], 7, ROW.fader[1])}>
        <i style={vars({ '--h': `${meterBar}%` })}></i>
      </div>
      <div className="meter-v at" style={at(589, ROW.fader[0], 27, ROW.fader[1])}>
        <i style={vars({ '--h': `${sumBar}%` })}></i>
        <span className="u" style={{ bottom: '80%' }}></span>
      </div>
      <button className={`linkbtn at ${link ? 'on' : ''}`} onClick={toggleLink} style={at(575, ROW.kill[0], 44, ROW.kill[1])}>
        LINK
        <br />
        LOWS
      </button>
      <Channel side="B" deck={b} drags={drags} />
      <span className="xside at keep" style={{ ...at(452, ROW.xf[0] + 12, 14, 24), lineHeight: '24px' }}>
        A
      </span>
      <div
        className={`fx xf mixctl keep ${xfActive ? 'dragging' : ''}`}
        data-param="xfade"
        data-axis="x"
        role="slider"
        aria-label="Crossfader"
        style={{ ...at(472, ROW.xf[0], 250, ROW.xf[1]), ...vars({ '--pos': snapshot.crossfader.toFixed(4) }) }}
      >
        <span className="fr"></span>
        <span className="zero"></span>
        <span className="thumb"></span>
      </div>
      <span className="xside at keep" style={{ ...at(728, ROW.xf[0] + 12, 14, 24), lineHeight: '24px' }}>
        B
      </span>
      {mixPop?.kind === 'trim' && <TrimPop side={mixPop.side} snapshot={snapshot} drags={drags} />}
      {mixPop?.kind === 'band' && <BandPop band={mixPop.band} snapshot={snapshot} drags={drags} />}
    </section>
  )
}

interface ChannelProps {
  side: Side
  deck: DeckSnapshot
  drags: MixDrags
}

function Channel({ side, deck, drags }: ChannelProps) {
  const link = useConsole((state) => state.link)
  const setMixPop = useConsole((state) => state.setMixPop)
  const track = useDeckTrack(deck)
  const [lx, lw] = colX(side, 'level')
  const trimX = side === 'A' ? 372 : 762
  const filterX = side === 'A' ? 440 : 620
  const auto = track?.gainDb != null && Math.abs(track.gainDb) >= 0.05 && Math.abs(deck.trimDb - autoTrimDb(track.gainDb)) < 0.05
  const filterActive = drags.active(side, 'filter')

  return (
    <div className={`chan ${side === 'B' ? 'b' : 'a'}`} data-side={side} style={vars({ '--accent': accentOf(side) })}>
      <button
        className={`trimchip at ${auto ? 'auto' : ''}`}
        onClick={() => setMixPop({ kind: 'trim', side })}
        style={at(trimX, ROW.top[0], 60, ROW.top[1])}
      >
        <b>{auto ? 'AUTO' : 'TRIM'}</b>
        <span>{fmtTrim(deck.trimDb)}</span>
      </button>
      <div
        className={`fx mixctl ${filterActive ? 'dragging' : ''}`}
        data-param="filter"
        data-deck={side}
        data-axis="x"
        role="slider"
        aria-label={`Deck ${side} filter`}
        style={{ ...at(filterX, ROW.top[0], 134, ROW.top[1]), ...vars({ '--pos': ((deck.filter + 1) / 2).toFixed(4) }) }}
      >
        <span className="fr"></span>
        <span className="zero"></span>
        <span className="flabel">{filterLabel(deck.filter)}</span>
        <span className="thumb"></span>
      </div>
      {FADER_IDS.map((col) => {
        const [x, w] = colX(side, col)
        const position = col === 'level' ? deck.level : deck.eq[col]
        const killed = col !== 'level' && deck.kills[col]
        const db = faderDb(position)
        const drag = drags.active(side, col)
        const name = drag && drag.speed < 1 ? (drag.speed > 0.2 ? 'FINE ¼' : 'FINE ⅒') : BAND_NAME[col]
        const valClass = [killed ? 'killed' : '', !killed && db < -0.05 ? 'cut' : '', drag ? 'live' : '', drag && drag.speed < 1 ? 'fine' : '']
        const inner = ROW.fader[1] - 2
        return [
          <button
            key={`val-${col}`}
            className={`bandval at ${valClass.filter(Boolean).join(' ')}`}
            onClick={() => {
              if (col !== 'level' && !drags.swallowClick()) setMixPop({ kind: 'band', band: col })
            }}
            style={at(x - 3, ROW.val[0], w + 6, ROW.val[1])}
          >
            <b>{name}</b>
            <span>{killed ? 'KILL' : formatDb(db)}</span>
          </button>,
          <div
            key={`fader-${col}`}
            className={[
              'cf mixctl',
              col === 'level' ? 'lvl' : col,
              killed ? 'killed' : '',
              col === 'low' && link ? 'linked' : '',
              drag ? 'dragging' : ''
            ]
              .filter(Boolean)
              .join(' ')}
            role="slider"
            data-deck={side}
            data-param={col}
            aria-label={`Deck ${side} ${BAND_NAME[col]}`}
            style={{ ...at(x, ROW.fader[0], w, ROW.fader[1]), ...vars({ '--pos': position.toFixed(4) }) }}
          >
            {TICKS.map((p) => (
              <i key={p} className={`tick ${p === 1 ? 'unity' : ''}`} style={{ top: `${(inner - CAP / 2 - p * (inner - CAP)).toFixed(1)}px` }}></i>
            ))}
            <span className="fr"></span>
            <span className="thumb"></span>
          </div>
        ]
      })}
      {BANDS.map((band) => {
        const [x, w] = colX(side, band)
        return <KillPad key={band} side={side} band={band} deck={deck} drags={drags} className="at" style={at(x, ROW.kill[0], w, ROW.kill[1])} />
      })}
      <button className={`chan-btn at ${deck.cue ? 'on' : ''}`} onClick={() => engine.setCue(indexOf(side), !deck.cue)} style={at(lx, ROW.kill[0], lw, ROW.kill[1])}>
        CUE
      </button>
    </div>
  )
}

interface KillPadProps {
  side: Side
  band: Band
  deck: DeckSnapshot
  drags: MixDrags
  className?: string
  style: React.CSSProperties
}

function KillPad({ side, band, deck, drags, className = '', style }: KillPadProps) {
  const on = deck.kills[band]
  return (
    <button
      className={['kill-pad mixctl', className, on ? 'on' : '', drags.held(side, band) ? 'held' : ''].filter(Boolean).join(' ')}
      data-kill={`${side}-${band}`}
      aria-label={`Kill deck ${side} ${BAND_NAME[band]}`}
      aria-pressed={on}
      style={style}
    >
      {BAND_NAME[band]}
      <br />
      KILL
    </button>
  )
}

function TrimPop({ side, snapshot, drags }: { side: Side; snapshot: EngineSnapshot; drags: MixDrags }) {
  const setMixPop = useConsole((state) => state.setMixPop)
  const deck = snapshot.decks[indexOf(side)]
  const active = drags.active(side, 'trimpos')
  return (
    <div className="mixpop at" data-side={side} style={{ ...at(side === 'A' ? 372 : 522, 110, 300, 124), ...vars({ '--accent': accentOf(side) }) }}>
      <h4>
        {`Trim ${side}`}
        <InfoButton topic="trim" />
        <button className="btn ghost done" onClick={() => setMixPop(null)}>
          Done
        </button>
      </h4>
      <div className="row">
        <div
          className={`fx mixctl ${active ? 'dragging' : ''}`}
          data-param="trimpos"
          data-deck={side}
          data-axis="x"
          role="slider"
          aria-label={`Deck ${side} trim`}
          style={vars({ position: 'relative', flex: 1, height: '44px', '--pos': ((deck.trimDb + 12) / 24).toFixed(4) })}
        >
          <span className="fr"></span>
          <span className="zero"></span>
          <span className="thumb"></span>
        </div>
        <span className="val">{`${fmtTrim(deck.trimDb)} dB`}</span>
        <button className="btn" onClick={() => engine.setGainTrim(indexOf(side), 0)}>
          RESET
        </button>
      </div>
    </div>
  )
}

function BandPop({ band, snapshot, drags }: { band: Band; snapshot: EngineSnapshot; drags: MixDrags }) {
  const setMixPop = useConsole((state) => state.setMixPop)
  const link = useConsole((state) => state.link)
  const toggleLink = useConsole((state) => state.toggleLink)
  const row = (side: Side) => {
    const deck = snapshot.decks[indexOf(side)]
    const killed = deck.kills[band]
    const drag = drags.active(side, band)
    return (
      <div className="row" style={vars({ '--accent': accentOf(side) })}>
        <span className="letter who">{side}</span>
        <div
          className={`fx band mixctl ${killed ? 'killed' : ''} ${drag ? 'dragging' : ''}`}
          data-param={band}
          data-deck={side}
          data-axis="x"
          role="slider"
          aria-label={`Deck ${side} ${BAND_NAME[band]}`}
          style={vars({ position: 'relative', flex: 1, height: '52px', '--pos': deck.eq[band].toFixed(4) })}
        >
          <span className="fr"></span>
          <span className="thumb"></span>
        </div>
        <span className={`val ${killed ? 'killed' : ''}`}>{killed ? 'KILL' : `${drag && drag.speed < 1 ? '· ' : ''}${formatDb(faderDb(deck.eq[band]))}`}</span>
        <KillPad side={side} band={band} deck={deck} drags={drags} style={{ width: '52px', height: '52px' }} />
      </div>
    )
  }
  return (
    <div className="mixpop at" style={at(352, 62, 490, band === 'low' ? 252 : 196)}>
      <h4>
        {`${BAND_NAME[band]} · both decks`}
        <InfoButton topic="band" />
        <button className="btn ghost done" onClick={() => setMixPop(null)}>
          Done
        </button>
      </h4>
      {row('A')}
      {row('B')}
      {band === 'low' && (
        <div className="row">
          <button className={`linkbtn ${link ? 'on' : ''}`} onClick={toggleLink} style={{ minWidth: '120px', minHeight: '44px' }}>
            LINK LOWS
          </button>
        </div>
      )}
    </div>
  )
}
