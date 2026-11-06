import { energyColour } from '../../shared/power'
import { emptyHotCues, type HotCueList } from '../../shared/hot-cue'
import type { TrackMeta } from '../../shared/types'
import { engine } from '../audio/engine'
import { tap, type TapSnapshot } from '../audio/tap'
import type { DeckSnapshot, EngineSnapshot } from '../audio/types'
import { useLibrary } from '../state/library'
import { useConsole, type Side } from './state'

/**
 * `?demo=mockup` runs the console on the mockup's demo state instead of the
 * audio engine — the same two tracks, times, mixer settings and crate — and
 * draws the mockup's synthetic waveforms, so a capture of the app can be
 * diffed pixel for pixel against the mockup (scripts/pixel-diff.mjs).
 * Nothing plays; it is a test fixture, not a mode for use.
 */
export const isDemo = typeof location !== 'undefined' && new URLSearchParams(location.search).get('demo') === 'mockup'

/**
 * `&screen=` picks one of the mockup's screens beyond the console (its Screen
 * picker): firstrun, analysing, error, drop, dropblocked, shortcuts, tap,
 * playlistmenu, rename or delete.
 */
export const demoScreen = (isDemo && new URLSearchParams(location.search).get('screen')) || 'console'
/** The screens that open the library on the Warm up playlist. */
export const DEMO_LIB_SCREENS = ['playlistmenu', 'rename', 'delete']

/** The mockup's placeholder covers. */
export const DEMO_ART: Record<string, string> = {
  'demo-0': 'linear-gradient(135deg, #2b4f7a 0 55%, #d0703a 55% 100%)',
  'demo-1': 'linear-gradient(135deg, #0f5e63 0 55%, #9ad3c4 55% 100%)'
}

const LIBRARY: Array<[name: string, bpm: number, dur: string, grid: number, key: string, camelot: string]> = [
  ['Tiesto, Mathame — Everlight (Extended Mix)', 133.0, '6:24', 95, 'A minor', '8A'],
  ['Patrick Topping — Ocean', 130.0, '6:58', 88, 'F minor', '4A'],
  ['Oneeva — Platform 9 (NCS Release)', 126.0, '4:12', 91, 'D major', '10B'],
  ['Curtis Mayfield — Move On Up', 130.0, '2:00', 84, 'G major', '9B'],
  ['Arkins, JERIDE, B.A.S.E — Banger Rangers', 132.0, '2:00', 97, 'C minor', '5A'],
  ['Fred again.. — Delilah (pull me out of this)', 124.0, '4:09', 93, 'B♭ minor', '3A'],
  ['Bicep — Glue', 129.9, '4:29', 96, 'F minor', '4A'],
  ['Peggy Gou — It Goes Like (Nanana)', 130.0, '3:35', 90, 'A♭ major', '4B'],
  ['Chris Lake — Turn Off The Lights', 126.0, '3:22', 92, 'E minor', '9A'],
  ['Overmono — So U Kno', 134.0, '4:04', 87, 'D minor', '7A'],
  ['Mochakk — Jealous', 128.0, '3:12', 94, 'E♭ minor', '2A'],
  ['Disclosure — Latch', 122.0, '4:15', 89, 'C# minor', '12A']
]

const secs = (t: string): number => t.split(':').reduce((sum, part) => sum * 60 + Number(part), 0)

const cues = (entries: Array<[number, number]>): HotCueList => {
  const list = emptyHotCues()
  for (const [slot, at] of entries) list[slot] = at
  return list
}

function deck(id: Side, overrides: Partial<DeckSnapshot>): DeckSnapshot {
  return {
    id,
    trackId: null,
    trackName: null,
    durationSec: 0,
    grid: null,
    peaks: null,
    levels: null,
    power: null,
    playing: false,
    previewing: false,
    position: 0,
    baseRate: 1,
    rate: 1,
    keyLock: false,
    eq: { low: 1, mid: 1, high: 1 },
    kills: { low: false, mid: false, high: false },
    level: 1,
    trimDb: 0,
    cuePoint: 0,
    filter: 0,
    cue: false,
    loop: null,
    loopBeats: 8,
    jumpBars: 1,
    hotCues: emptyHotCues(),
    syncLocked: false,
    isMaster: false,
    loading: false,
    error: null,
    ...overrides
  }
}

const SNAPSHOT: EngineSnapshot = {
  ready: true,
  decks: [
    deck('A', {
      trackId: 'demo-0',
      trackName: LIBRARY[0][0],
      durationSec: secs('6:24'),
      grid: { bpm: 133, offsetMs: 489.9, confidence: 0.95 },
      playing: true,
      position: secs('6:24') - 72.418,
      keyLock: true,
      cue: true,
      loop: { startBeat: 688, lengthBeats: 8 },
      loopBeats: 8,
      hotCues: cues([[0, 32.0], [1, 104.7], [3, 261.5]]),
      isMaster: true
    }),
    deck('B', {
      trackId: 'demo-1',
      trackName: LIBRARY[1][0],
      durationSec: secs('6:58'),
      grid: { bpm: 130, offsetMs: 247.3, confidence: 0.88 },
      position: 0.91,
      baseRate: 1.0231,
      rate: 1.0231,
      eq: { low: 0.06, mid: 0.6, high: 0.8 },
      cuePoint: 0.9,
      loopBeats: 16,
      hotCues: cues([[0, 31.0], [2, 135.0]]),
      syncLocked: true
    })
  ],
  crossfader: 0.5,
  cueMix: 0.5,
  masterVolume: 0.816,
  outputMode: 'split',
  sampleRate: 48000,
  masterDeck: 0,
  focusedDeck: 0
}

/** First run: both decks empty, the mixer as the mockup leaves it. */
function emptyDeck(loaded: DeckSnapshot): DeckSnapshot {
  return deck(loaded.id as Side, {
    eq: loaded.eq,
    level: loaded.level,
    filter: loaded.filter,
    cue: loaded.cue,
    keyLock: loaded.keyLock,
    loopBeats: loaded.loopBeats
  })
}

/** The TAP sheet as the mockup draws it: listening to a loopback device. */
const TAP_LISTENING: TapSnapshot = {
  status: 'listening',
  devices: [{ id: 'blackhole', label: 'BlackHole 2ch', loopback: true }],
  deviceId: 'blackhole',
  deviceLabel: 'BlackHole 2ch',
  levelDb: -14,
  bpm: 128,
  confidence: 0.86,
  error: null,
  windows: 5
}

/** Swap the engine's readouts for the demo state and fill the crate. Call before the first render. */
export function installDemo(): void {
  if (demoScreen === 'firstrun') {
    SNAPSHOT.decks = [emptyDeck(SNAPSHOT.decks[0]), emptyDeck(SNAPSHOT.decks[1])]
  }
  const target = engine as unknown as Record<string, unknown>
  target.getSnapshot = () => SNAPSHOT
  target.subscribe = () => () => {}
  target.getDeck = (index: 0 | 1) => ({ position: SNAPSHOT.decks[index].position })
  target.readMeterDb = () => -120
  // No decks behind the demo: grid edits go to the library entry only.
  target.setDeckGrid = () => {}
  const tracks: TrackMeta[] = LIBRARY.map(([name, bpm, dur, grid, key, camelot], i) => {
    const [artist, title] = name.split(' — ')
    return {
      id: `demo-${i}`,
      name,
      artist,
      title,
      durationSec: secs(dur),
      bpm,
      offsetMs: 0,
      confidence: grid / 100,
      peaks: [],
      analyzedAt: '',
      key,
      camelot,
      keyConfidence: 1
    }
  })
  useLibrary.setState({
    tracks,
    hydrated: true,
    playlists: [
      { id: 'warm', name: 'Warm up', trackIds: ['demo-5', 'demo-2', 'demo-6', 'demo-3'] },
      { id: 'peak', name: 'Peak time', trackIds: [] }
    ]
  })

  if (demoScreen === 'firstrun') useLibrary.setState({ tracks: [], playlists: [] })
  if (demoScreen === 'analysing') useLibrary.setState({ status: { label: 'ANALYSING', name: 'Bicep — Glue', current: 3, total: 12 } })
  if (demoScreen === 'error') {
    useLibrary.setState({ error: { title: "CAN'T LOAD", message: '"Bicep — Glue" isn\'t on disk any more. Add the file again to play it.' } })
  }
  if (demoScreen === 'drop') useConsole.setState({ drop: { side: 'B', label: 'Bicep — Glue.flac · analysed, then loaded' } })
  if (demoScreen === 'dropblocked') useConsole.setState({ drop: { side: 'A', label: '' } })
  if (demoScreen === 'shortcuts') useConsole.setState({ sheet: 'shortcuts' })
  if (demoScreen === 'tap') {
    const fake = tap as unknown as Record<string, unknown>
    fake.getSnapshot = () => TAP_LISTENING
    fake.subscribe = () => () => {}
    fake.refreshDevices = async () => {}
    fake.stop = async () => {}
    useConsole.setState({ sheet: 'tap' })
  }
  if (DEMO_LIB_SCREENS.includes(demoScreen)) useConsole.setState({ libOpen: true })
  if (demoScreen === 'gridunsure' || demoScreen === 'gridalts' || demoScreen === 'gridhelp') {
    // Deck A's track with the tempos the analysis turned down, its grid open; gridunsure also flags it.
    useLibrary.setState({
      tracks: tracks.map((track) =>
        track.id === 'demo-0'
          ? {
              ...track,
              gridUncertain: demoScreen === 'gridunsure' || undefined,
              gridAlternates: [
                { bpm: 88.667, offsetMs: 120.4, relation: '2/3' },
                { bpm: 177.333, offsetMs: 489.9, relation: '4/3' },
                { bpm: 99.75, offsetMs: 312.8, relation: '3/4' }
              ]
            }
          : track
      )
    })
    useConsole.setState({ gridOpen: 'A', help: demoScreen === 'gridhelp' ? 'grid' : null })
  }
}

/** The mockup's synthetic stroke waveform (waveSvg), for the demo only. */
function waveSvg(count: number, seed: number, played: number, oneSided: boolean, energy: boolean) {
  let s = seed
  const rnd = (): number => {
    s = (s * 9301 + 49297) % 233280
    return s / 233280
  }
  const cut = Math.round(count * played)
  let all = ''
  let mids = ''
  let highs = ''
  let lit = ''
  for (let i = 0; i < count; i++) {
    const phrase = 0.5 + 0.5 * Math.sin(i * 0.011 + seed * 0.13)
    const beat = 0.42 + 0.58 * Math.abs(Math.sin(i * 0.083 + seed * 0.37))
    const grain = 0.62 + 0.38 * rnd()
    const hit = rnd() > 0.985 ? 0.5 : 0
    const h = Math.max(2, Math.min(96, 6 + 78 * phrase * beat * grain + hit * 26))
    const bias = 0.46 + (rnd() - 0.5) * 0.16
    const seg = oneSided
      ? 'M' + (i + 0.5) + ' 100V' + (100 - h).toFixed(1)
      : 'M' + (i + 0.5) + ' ' + (50 - h * bias).toFixed(1) + 'V' + (50 + h * (1 - bias)).toFixed(1)
    all += seg
    const bandSegment = (height: number): string => oneSided
      ? `M${i + 0.5} 100V${(100 - height).toFixed(1)}`
      : `M${i + 0.5} ${(50 - height * bias).toFixed(1)}V${(50 + height * (1 - bias)).toFixed(1)}`
    mids += bandSegment(h * (0.28 + 0.25 * Math.abs(Math.sin(i * 0.043 + seed))))
    highs += bandSegment(h * (0.12 + 0.65 * Math.abs(Math.sin(i * 0.083 + seed * 0.37)) ** 18))
    if (i < cut) lit += seg
  }
  const id = 'wv' + seed + '-' + Math.round(played * 100)
  const gradient = `${id}-energy`
  const stops = Array.from({ length: 25 }, (_, i) => {
    const value = 0.2 + 0.65 * (0.5 + 0.5 * Math.sin(count * i / 24 * 0.011 + seed * 0.13))
    const rgb = energyColour(value).map((v) => Math.round(v * 255))
    return <stop key={i} offset={`${i / 24 * 100}%`} stopColor={`rgb(${rgb.join(',')})`} />
  })
  return (
    <svg className="wave" viewBox={`0 0 ${count} 100`} preserveAspectRatio="none" aria-hidden="true">
      <defs>
        <linearGradient id={gradient}>{stops}</linearGradient>
        <clipPath id={id}>
          <rect x="0" y="0" width={count * played} height="100" />
        </clipPath>
      </defs>
      <path className="dim" d={all} style={{ stroke: energy ? `url(#${gradient})` : '#2e73eb' }} />
      {!energy && <path d={mids} style={{ stroke: '#d39131', strokeWidth: 1 }} />}
      {!energy && <path d={highs} style={{ stroke: '#fff9e2', strokeWidth: 1 }} />}
      {energy && <path className="lit" clipPath={`url(#${id})`} d={lit} style={{ stroke: `url(#${gradient})` }} />}
    </svg>
  )
}

/** A zoom lane's or an overview's demo waveform, with the mockup's seeds. */
export function DemoWave({ side, lane, played = 0.5 }: { side: Side; lane?: boolean; played?: number }) {
  const energy = useConsole((state) => state.energyEnabled)
  const seed = side === 'A' ? 7 : 21
  if (lane) {
    return (
      <div className="zw-track" style={{ transform: 'translateX(calc(-25% + 0px))' }}>
        {waveSvg(1600, seed, 0.5, false, energy)}
      </div>
    )
  }
  return waveSvg(600, seed + 3, played, true, energy)
}

/** The mockup's synthetic peaks for the beat grid sheet (gridPeaks), tied to its 20–28 s window. */
export function DemoGridPeaks({ side }: { side: Side }) {
  const audio = side === 'A' ? { bpm: 133.0, offsetMs: 489.9, seed: 7 } : { bpm: 130.0, offsetMs: 247.3, seed: 21 }
  const period = 60000 / audio.bpm
  const half = period / 2
  let seed = audio.seed
  const bars = []
  for (let i = 0; i < 132; i++) {
    const time = 20000 + (i / 132) * 8000
    seed = (seed * 9301 + 49297) % 233280
    const noise = seed / 233280
    const nearest = Math.round((time - audio.offsetMs) / period)
    const dist = Math.abs(time - (audio.offsetMs + nearest * period))
    const offDist = Math.abs(half - dist)
    const downbeat = ((nearest % 4) + 4) % 4 === 0
    const kick = Math.exp(-Math.pow(dist / 42, 2)) * (downbeat ? 100 : 82)
    const hat = Math.exp(-Math.pow(offDist / 30, 2)) * 24
    const height = Math.max(6, Math.min(100, 12 + noise * 15 + kick + hat))
    bars.push(<i key={i} style={{ height: height.toFixed(1) + '%' }}></i>)
  }
  return <>{bars}</>
}
