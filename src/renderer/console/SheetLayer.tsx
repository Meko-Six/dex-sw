import { useEffect, useState, useSyncExternalStore } from 'react'
import { engine } from '../audio/engine'
import { tap, tapTempoRatio } from '../audio/tap'
import type { EngineSnapshot } from '../audio/types'
import { InfoButton } from './Help'
import { useConsole, type Side } from './state'
import { vars } from './layout'

/** The sheets over the whole console: the keyboard shortcuts and TAP tempo. */
export function SheetLayer({ snapshot }: { snapshot: EngineSnapshot }) {
  const sheet = useConsole((state) => state.sheet)
  const setSheet = useConsole((state) => state.setSheet)
  return (
    <section
      className={`sheet-layer ${sheet ? 'open' : ''}`}
      onClick={(event) => {
        if (!(event.target as Element).closest('.gsheet')) setSheet(null)
      }}
    >
      {sheet === 'shortcuts' && <Shortcuts />}
      {sheet === 'tap' && <TapSheet snapshot={snapshot} />}
    </section>
  )
}

type ShortcutGroup = [name: string, rows: Array<[keys: string[], text: string]>]

const SHORTCUT_GROUPS: ShortcutGroup[] = [
  [
    'TRANSPORT',
    [
      [['1', '2'], 'Play or pause deck A or B'],
      [['SPACE'], 'Play or pause the focused deck'],
      [['C'], 'CUE on the focused deck: set, return, hold to preview'],
      [['L'], 'Start or leave a loop at the stepper size'],
      [['⇧', 'L'], 'Halve the running loop'],
      [['Q', 'W'], 'Beat jump deck A back / forward'],
      [['O', 'P'], 'Beat jump deck B back / forward']
    ]
  ],
  [
    'SYNC · TEMPO',
    [
      [['S'], 'Sync the other deck to this one'],
      [['⇧', 'S'], 'Sync this deck to the other'],
      [['[', ']'], 'Tempo −0.1 % / +0.1 %']
    ]
  ],
  ['MIXER', [[['M'], 'Headphone CUE on the focused deck']]],
  [
    'BEAT GRID',
    [
      [['←', '→'], 'Nudge the grid 1 ms'],
      [['⇧', '← →'], 'Nudge the grid 10 ms']
    ]
  ],
  [
    'CONSOLE',
    [
      [['ESC'], 'Close the open sheet, or stop both decks'],
      [['?'], 'This list']
    ]
  ]
]

function Group({ group: [name, rows] }: { group: ShortcutGroup }) {
  return (
    <div className="keys-group">
      <h3>{name}</h3>
      {rows.map(([keys, text]) => (
        <div key={text} className="keys-row">
          <div>
            {keys.map((key) => (
              <kbd key={key}>{key}</kbd>
            ))}
          </div>
          <span>{text}</span>
        </div>
      ))}
    </div>
  )
}

function Shortcuts() {
  const setSheet = useConsole((state) => state.setSheet)
  return (
    <div className="gsheet wide">
      <div className="gsheet-head">
        <h2>
          Keyboard <span>· shortcuts</span>
        </h2>
        <button className="btn ghost done" onClick={() => setSheet(null)}>
          Close
        </button>
      </div>
      <div className="keys-cols">
        <div>
          <Group group={SHORTCUT_GROUPS[0]} />
          <Group group={SHORTCUT_GROUPS[2]} />
        </div>
        <div>
          <Group group={SHORTCUT_GROUPS[1]} />
          <Group group={SHORTCUT_GROUPS[3]} />
          <Group group={SHORTCUT_GROUPS[4]} />
        </div>
      </div>
      <p className="gnote">
        The <b>focused deck</b> is the last one you touched. Shortcuts never fire while you type in the library's search.
      </p>
    </div>
  )
}

/** −60 dB at the left of the meter, 0 dB at the right. */
const levelPercent = (db: number): number => Math.max(0, Math.min(100, ((db + 60) / 60) * 100))
const signed = (value: number, digits: number): string => `${value < 0 ? '−' : '+'}${Math.abs(value).toFixed(digits)}`

/**
 * TAP: reads the tempo of an audio input (a loopback device carrying another
 * app, an interface, a microphone) so a deck can be matched to it. Analysis
 * only: it never reaches the outputs. Closing the sheet releases the input.
 */
function TapSheet({ snapshot }: { snapshot: EngineSnapshot }) {
  const state = useSyncExternalStore(tap.subscribe, tap.getSnapshot, tap.getSnapshot)
  const setSheet = useConsole((store) => store.setSheet)
  const [deviceId, setDeviceId] = useState<string | null>(null)

  // An open microphone with no visible readout is a privacy problem, not a feature.
  useEffect(() => {
    void tap.refreshDevices()
    return () => void tap.stop()
  }, [])

  useEffect(() => {
    if (state.devices.length > 0 && !state.devices.some((device) => device.id === deviceId)) {
      setDeviceId((state.devices.find((device) => device.loopback) ?? state.devices[0]).id)
    }
  }, [state.devices, deviceId])

  const listening = state.status === 'listening' || state.status === 'starting'
  const device = state.devices.find((entry) => entry.id === (listening ? state.deviceId : deviceId)) ?? null
  const level = state.status === 'listening' ? (state.levelDb > -59 ? `${signed(Math.round(state.levelDb), 0)} dB` : '−∞ dB') : '— dB'
  const windows = `${state.windows} ${state.windows === 1 ? 'window' : 'windows'}`
  const note = state.error
    ? state.error
    : state.devices.length === 0
      ? 'No audio inputs are visible. Connect an interface or install a loopback device, then Refresh.'
      : listening
        ? `Listening · ${windows}`
        : 'Pick an input and listen.'

  const match = (side: Side) => {
    const index = side === 'B' ? 1 : 0
    const grid = snapshot.decks[index].grid
    const ratio = state.bpm ? tapTempoRatio(state.bpm, grid) : null
    const detail = !grid ? 'No track loaded' : ratio == null ? `${grid.bpm.toFixed(1)} BPM` : `${grid.bpm.toFixed(1)} → ${(grid.bpm * ratio).toFixed(1)} · ${signed((ratio - 1) * 100, 2)}%`
    return (
      <button
        className="gact"
        style={vars({ '--accent': side === 'A' ? 'var(--a)' : 'var(--b)' })}
        disabled={ratio == null}
        onClick={() => state.bpm && engine.matchTempoToBpm(index, state.bpm)}
        title={`Set deck ${side}'s tempo to the tapped BPM`}
      >
        <span className={side === 'A' ? 'letter' : 'letter b'}>{side}</span>
        <span>
          {`MATCH DECK ${side}`}
          <small>{detail}</small>
        </span>
      </button>
    )
  }

  return (
    <div className="gsheet narrow">
      <div className="gsheet-head">
        <h2>
          Tap tempo <span>· audio input</span>
        </h2>
        <span className="chip exp">EXPERIMENTAL</span>
        <InfoButton topic="tap" />
        <button className="btn ghost done" onClick={() => setSheet(null)}>
          Close
        </button>
      </div>
      <div className="tap-device">
        <div className="tap-pick">
          <span>{device?.label ?? 'No audio inputs'}</span>
          {device?.loopback && <em>LOOPBACK</em>}
          <i>▾</i>
          <select
            value={deviceId ?? ''}
            onChange={(event) => setDeviceId(event.target.value || null)}
            disabled={listening || state.devices.length === 0}
            aria-label="Audio input"
          >
            {state.devices.map((entry) => (
              <option key={entry.id} value={entry.id}>
                {entry.loopback ? `${entry.label} · loopback` : entry.label}
              </option>
            ))}
          </select>
        </div>
        <button className="btn ghost" onClick={() => void tap.refreshDevices()} disabled={listening}>
          Refresh
        </button>
        {listening ? (
          <button className="btn on" onClick={() => void tap.stop()}>
            Stop
          </button>
        ) : (
          <button className="btn" onClick={() => void tap.start(deviceId)} disabled={state.devices.length === 0}>
            Listen
          </button>
        )}
      </div>
      <div className="tap-read">
        <div className="gstat">
          <b className="big-bpm">{state.bpm ? state.bpm.toFixed(1) : '—'}</b>
          <span>{state.bpm ? `BPM · ${Math.round(state.confidence * 100)}% confidence` : 'BPM'}</span>
        </div>
        <div className="gstat tap-level">
          <div className="vrow">
            <div className="meter-h">
              <i style={{ width: `${state.status === 'listening' ? levelPercent(state.levelDb).toFixed(2) : 0}%` }}></i>
            </div>
            <span className="val">{level}</span>
          </div>
          <p>{note}</p>
        </div>
      </div>
      <div className="tap-match">
        {match('A')}
        {match('B')}
      </div>
    </div>
  )
}
