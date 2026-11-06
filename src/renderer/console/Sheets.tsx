import { useEffect, useMemo, useRef, useState, type PointerEvent as ReactPointerEvent } from 'react'
import { camelotColour, camelotRank, compatibleKeys, parseCamelot } from '../../shared/camelot'
import {
  barSeconds,
  doubleGrid,
  halveGrid,
  normalizeOffset,
  nudgeGrid,
  setGridBpm,
  setGridOffset,
  type BeatGrid
} from '../../shared/grid'
import type { TrackGridAlternate, TrackMeta } from '../../shared/types'
import { decodePeak, pickLevel } from '../../shared/waveform-levels'
import { engine } from '../audio/engine'
import type { EngineSnapshot } from '../audio/types'
import { useDeckPosition } from '../hooks'
import { useLibrary } from '../state/library'
import { clock } from './format'
import { displayName, setDraggedTrack, TRACK_DRAG_TYPE } from './drop'
import { InfoButton } from './Help'
import { DEMO_LIB_SCREENS, demoScreen, DemoGridPeaks, isDemo } from './demo'
import { accentOf, vars } from './layout'
import { useConsole, type Side } from './state'
import { useMixDrags } from './useMixDrags'
import { useLevels } from './WaveCanvas'

// ---- volume ----------------------------------------------------------------------

/** Master, and the headphone blend from the cued deck to the master. */
export function VolumePop({ snapshot }: { snapshot: EngineSnapshot }) {
  const volOpen = useConsole((state) => state.volOpen)
  const toggleVol = useConsole((state) => state.toggleVol)
  const drags = useMixDrags(useRef(false))
  const fader = (param: 'master' | 'cuemix', value: number, label: string) => (
    <div
      className="fader-h"
      data-param={param}
      data-axis="x"
      role="slider"
      aria-label={label}
      style={vars({ '--pos': `${Math.round(value * 100)}%` })}
      onPointerDown={drags.onPointerDown}
      onPointerMove={drags.onPointerMove}
      onPointerUp={drags.onPointerUp}
      onPointerCancel={drags.onPointerUp}
    >
      <span className="fr"></span>
      <span className="zero"></span>
      <span className="thumb"></span>
    </div>
  )
  return (
    <section className={`volpop ${volOpen ? 'open' : ''}`} aria-label="Volume">
      <h3>
        {'Volume '}
        <InfoButton topic="volume" />
        <button className="btn ghost done" onClick={() => toggleVol(false)}>
          Done
        </button>
      </h3>
      <div className="vrow">
        <span className="tiny">master</span>
        {fader('master', snapshot.masterVolume / 1.2, 'Master volume')}
        <span className="val">{`${Math.round(snapshot.masterVolume * 100)}%`}</span>
      </div>
      <div className="vrow">
        <span className="tiny">cue mix</span>
        {fader('cuemix', snapshot.cueMix, 'Cue mix')}
        <span className="val">{`${Math.round(snapshot.cueMix * 100)}%`}</span>
      </div>
    </section>
  )
}

// ---- library -----------------------------------------------------------------------

type SortColumn = 'name' | 'key' | 'bpm' | 'dur' | 'grid'
const COLUMNS: Array<[SortColumn, string]> = [
  ['name', 'track'],
  ['key', 'key'],
  ['bpm', 'bpm'],
  ['dur', 'time'],
  ['grid', 'grid']
]

const SORT_VALUE: Record<SortColumn, (track: TrackMeta) => number | string> = {
  name: (track) => displayName(track).toLowerCase(),
  key: (track) => camelotRank(track.camelot),
  bpm: (track) => track.bpm,
  dur: (track) => Math.floor(track.durationSec),
  grid: (track) => Math.round(track.confidence * 100)
}

function CamelotBadge({ code, selected }: { code: string | undefined; selected?: boolean }) {
  return (
    <span className={`cam ${selected ? 'sel' : ''}`} style={vars({ '--cam': (code && camelotColour(code)) || 'var(--dim)' })}>
      {code ?? '—'}
    </span>
  )
}

/**
 * The crate, under the track windows and the CUE · PLAY · loop · crossfader
 * row: playlists on the left, the tracks beside them. Tap a row, then a
 * deck's album art to load it; rows also drag onto a deck or a playlist.
 */
export function Library({ snapshot }: { snapshot: EngineSnapshot }) {
  const libOpen = useConsole((state) => state.libOpen)
  const toggleLib = useConsole((state) => state.toggleLib)
  const selectedId = useConsole((state) => state.selectedId)
  const select = useConsole((state) => state.select)
  const tracks = useLibrary((state) => state.tracks)
  const playlists = useLibrary((state) => state.playlists)
  const addFiles = useLibrary((state) => state.addFiles)
  const addFolder = useLibrary((state) => state.addFolder)
  const reanalyze = useLibrary((state) => state.reanalyze)
  const remove = useLibrary((state) => state.remove)
  const findKeys = useLibrary((state) => state.findKeys)
  const busy = useLibrary((state) => state.status != null)
  const createPlaylist = useLibrary((state) => state.createPlaylist)
  const addToPlaylist = useLibrary((state) => state.addToPlaylist)
  const removeFromPlaylist = useLibrary((state) => state.removeFromPlaylist)
  const renamePlaylist = useLibrary((state) => state.renamePlaylist)
  const deletePlaylist = useLibrary((state) => state.deletePlaylist)
  const [query, setQuery] = useState('')
  const [view, setView] = useState(DEMO_LIB_SCREENS.includes(demoScreen) ? 'warm' : 'all')
  const [sort, setSort] = useState<{ column: SortColumn; dir: 1 | -1 } | null>(null)
  const [keyFilter, setKeyFilter] = useState('')
  const [compatible, setCompatible] = useState(true)
  const [menuFor, setMenuFor] = useState<string | null>(null)
  const [editing, setEditing] = useState<string | null>(demoScreen === 'rename' ? 'warm' : null)
  /** The playlist whose ⋯ menu is open, and whether its delete is waiting for the second tap. */
  const [listMenu, setListMenuState] = useState<string | null>(demoScreen === 'playlistmenu' || demoScreen === 'delete' ? 'warm' : null)
  const [confirmDelete, setConfirmDelete] = useState(demoScreen === 'delete')
  const setListMenu = (id: string | null): void => {
    setListMenuState(id)
    setConfirmDelete(false)
  }
  const searchRef = useRef<HTMLInputElement | null>(null)
  const listRef = useRef<HTMLDivElement | null>(null)
  const [viewport, setViewport] = useState({ top: 0, height: 400 })
  useEffect(() => {
    const list = listRef.current
    if (!list || !libOpen) return
    const update = (): void => setViewport({ top: list.scrollTop, height: list.clientHeight })
    const observer = new ResizeObserver(update)
    observer.observe(list)
    update()
    return () => observer.disconnect()
  }, [libOpen])
  useEffect(() => {
    if (listRef.current) listRef.current.scrollTop = 0
    setViewport((value) => ({ ...value, top: 0 }))
  }, [view, query, keyFilter, sort])


  const playlist = view === 'all' ? null : (playlists.find((entry) => entry.id === view) ?? null)
  const byId = useMemo(() => new Map(tracks.map((track) => [track.id, track])), [tracks])

  // A deleted playlist drops the view back to the whole library.
  useEffect(() => {
    if (view !== 'all' && !playlist) setView('all')
  }, [view, playlist])

  useEffect(() => {
    if (!libOpen) {
      searchRef.current?.blur()
      setMenuFor(null)
      setListMenu(null)
    }
  }, [libOpen])

  // The + and ⋯ menus close on any tap outside them.
  useEffect(() => {
    if (!menuFor && !listMenu) return
    const onPointerDown = (event: PointerEvent): void => {
      if (!(event.target as Element).closest?.('.lib-actions')) {
        setMenuFor(null)
        setListMenu(null)
      }
    }
    document.addEventListener('pointerdown', onPointerDown)
    return () => document.removeEventListener('pointerdown', onPointerDown)
  }, [menuFor, listMenu])

  const keys = keyFilter ? (compatible ? compatibleKeys(keyFilter) : [keyFilter]) : null
  const rows = useMemo(() => {
    const needle = query.trim().toLowerCase()
    const base = playlist
      ? playlist.trackIds.map((id) => byId.get(id)).filter((track): track is TrackMeta => track != null)
      : [...tracks].sort((a, b) => displayName(a).localeCompare(displayName(b)))
    const list = base.filter((track) => {
      if (keys && !keys.includes(track.camelot ?? '')) return false
      if (!needle) return true
      if (parseCamelot(needle.toUpperCase())) return track.camelot === needle.toUpperCase()
      return `${displayName(track)} ${track.key ?? ''} ${track.camelot ?? ''} ${track.bpm.toFixed(1)}`.toLowerCase().includes(needle)
    })
    if (!sort) return list
    const value = SORT_VALUE[sort.column]
    return [...list].sort((a, b) => {
      const x = value(a)
      const y = value(b)
      return (x < y ? -1 : x > y ? 1 : 0) * sort.dir || displayName(a).localeCompare(displayName(b))
    })
  }, [tracks, byId, playlist, query, keys?.join(), sort])

  const virtual = rows.length > 200
  const firstRow = virtual ? Math.max(0, Math.floor(viewport.top / 49) - 8) : 0
  const visibleRows = libOpen ? (virtual ? rows.slice(firstRow, firstRow + Math.ceil(viewport.height / 49) + 16) : rows) : []
  const total = playlist ? playlist.trackIds.length : tracks.length
  const loadedOn = (trackId: string): string =>
    snapshot.decks
      .filter((deck) => deck.trackId === trackId)
      .map((deck) => deck.id)
      .join(' + ')
  const missingKeys = tracks.filter((track) => !track.camelot && track.keyConfidence == null && !track.missing).length
  const pickKey = (code: string): void => setKeyFilter((current) => (current === code ? '' : code))
  const sortBy = (column: SortColumn): void =>
    setSort((current) => (current?.column === column ? { column, dir: current.dir === 1 ? -1 : 1 } : { column, dir: 1 }))
  const openPlaylist = (id: string): void => {
    if (id !== view) setListMenu(null)
    setView(id)
    setSort(null)
  }

  return (
    <section className={`library ${libOpen ? 'open' : ''}`} aria-hidden={!libOpen} inert={!libOpen}>
      <div className="lib-head">
        <h2>{playlist ? playlist.name : 'Library'}</h2>
        <span className="lib-count">
          {`${total} ${total === 1 ? 'track' : 'tracks'}${rows.length !== total ? ` · ${rows.length} shown` : ''}`}
        </span>
        <input
          ref={searchRef}
          className="search"
          placeholder="Search tracks, keys (4A), BPM"
          value={query}
          onChange={(event) => setQuery(event.target.value)}
          spellCheck={false}
        />
        {missingKeys > 0 && (
          <button className="btn" onClick={() => void findKeys()} disabled={busy} title="Analyse the key of every track that does not have one yet">
            {`Find keys (${missingKeys})`}
          </button>
        )}
        <button className="btn accent" onClick={() => void addFiles()}>
          Add files
        </button>
        <button className="btn" onClick={() => void addFolder()}>
          Add folder
        </button>
        <InfoButton topic="library" />
        <button className="btn ghost done" onClick={() => toggleLib(false)}>
          Done
        </button>
      </div>
      <div className="lib-body">
        <nav className="lib-side">
          <span className="lib-side-label">COLLECTION</span>
          <button className={`lib-side-item ${playlist ? '' : 'on'}`} onClick={() => openPlaylist('all')}>
            <i>♫</i>
            <span>All tracks</span>
            <em>{tracks.length}</em>
          </button>
          <div className="lib-side-head">
            <span className="lib-side-label">PLAYLISTS</span>
            <span className="lib-actions">
              <button
                onClick={() => {
                  const id = createPlaylist()
                  openPlaylist(id)
                  setEditing(id)
                }}
                title="New playlist"
              >
                +
              </button>
            </span>
          </div>
          {playlists.length === 0 && <p className="lib-side-empty">No playlists yet. Tap + to make one.</p>}
          {playlists.map((entry) => {
            const on = view === entry.id
            const renaming = editing === entry.id
            const menuOpen = on && listMenu === entry.id
            const count = entry.trackIds.length
            return (
              <div
                key={entry.id}
                className={`lib-side-item ${on ? 'on' : ''}`}
                role="button"
                onClick={() => !renaming && openPlaylist(entry.id)}
                onDoubleClick={() => setEditing(entry.id)}
                onContextMenu={(event) => {
                  event.preventDefault()
                  openPlaylist(entry.id)
                  setListMenu(entry.id)
                }}
                onDragOver={(event) => {
                  if (event.dataTransfer.types.includes(TRACK_DRAG_TYPE)) event.preventDefault()
                }}
                onDrop={(event) => {
                  const trackId = event.dataTransfer.getData(TRACK_DRAG_TYPE)
                  if (!trackId) return
                  event.preventDefault()
                  addToPlaylist(entry.id, [trackId])
                }}
              >
                <i>≡</i>
                {renaming ? (
                  <input
                    className="lib-side-input"
                    defaultValue={entry.name}
                    autoFocus={!isDemo}
                    onFocus={(event) => event.currentTarget.select()}
                    onBlur={(event) => {
                      renamePlaylist(entry.id, event.currentTarget.value)
                      setEditing(null)
                    }}
                    onKeyDown={(event) => {
                      if (event.key === 'Enter') event.currentTarget.blur()
                      if (event.key === 'Escape') {
                        event.stopPropagation()
                        event.currentTarget.value = entry.name
                        event.currentTarget.blur()
                      }
                    }}
                  />
                ) : (
                  <span>{entry.name}</span>
                )}
                <em>{count}</em>
                {on && !renaming && (
                  <span className="lib-actions">
                    <button
                      className={menuOpen ? 'on' : ''}
                      onClick={(event) => {
                        event.stopPropagation()
                        setListMenu(menuOpen ? null : entry.id)
                      }}
                      title="Rename or delete"
                    >
                      ⋯
                    </button>
                    {menuOpen && (
                      // Delete asks twice; the tracks stay in the library.
                      <div className="lib-menu" onClick={(event) => event.stopPropagation()}>
                        <b>{entry.name.toUpperCase()}</b>
                        <button
                          onClick={() => {
                            setListMenu(null)
                            setEditing(entry.id)
                          }}
                        >
                          <i>✎</i>Rename
                        </button>
                        <button
                          className={`danger ${confirmDelete ? 'confirm' : ''}`}
                          onClick={() => {
                            if (!confirmDelete) return setConfirmDelete(true)
                            setListMenu(null)
                            deletePlaylist(entry.id)
                          }}
                        >
                          <i>✕</i>
                          {confirmDelete ? 'Tap again to delete' : 'Delete playlist'}
                        </button>
                        {confirmDelete && <small>{`Its ${count} ${count === 1 ? 'track stays' : 'tracks stay'} in the library.`}</small>}
                      </div>
                    )}
                  </span>
                )}
              </div>
            )
          })}
        </nav>
        <div className="lib-main">
          <div className="lib-filter">
            {keys ? (
              <>
                <span>Key</span>
                {keys.map((code) => (
                  <span key={code} className="lib-key" onClick={() => pickKey(code)}>
                    <CamelotBadge code={code} selected={code === keyFilter} />
                  </span>
                ))}
                <div className="seg">
                  <button className={compatible ? '' : 'on'} onClick={() => setCompatible(false)}>
                    {`${keyFilter} only`}
                  </button>
                  <button className={compatible ? 'on' : ''} onClick={() => setCompatible(true)}>
                    + compatible
                  </button>
                </div>
                <button className="btn ghost clear" onClick={() => setKeyFilter('')}>
                  Clear
                </button>
              </>
            ) : (
              <span>All keys</span>
            )}
          </div>
          <div className="lib-cols">
            {COLUMNS.map(([column, label]) => (
              <button
                key={column}
                className={sort?.column === column ? `on${sort.dir < 0 ? ' desc' : ''}` : ''}
                onClick={() => sortBy(column)}
              >
                {label}
              </button>
            ))}
            <span></span>
          </div>
          <div className="lib-list" style={virtual ? { overflowAnchor: 'none' } : undefined} ref={listRef} onScroll={(event) => setViewport({ top: event.currentTarget.scrollTop, height: event.currentTarget.clientHeight })}>
            {rows.length === 0 && (
              <p className="lib-empty">
                {tracks.length === 0
                  ? 'No tracks yet. Add files or a folder, or drop audio onto a deck.'
                  : query || keyFilter
                    ? 'Nothing matches that search or key.'
                    : 'This playlist is empty. Drag tracks onto it, or use + on a track.'}
              </p>
            )}
            <div style={virtual ? { height: rows.length * 49, position: 'relative', flexShrink: 0 } : { display: 'contents' }}>
            {visibleRows.map((track, rowIndex) => {
              const on = loadedOn(track.id)
              return (
                <div
                  key={track.id}
                  className={`lib-row ${selectedId === track.id ? 'selected' : ''}`}
                  style={virtual ? { position: 'absolute', top: (firstRow + rowIndex) * 49, left: 0, right: 0, height: 46 } : undefined}
                  onClick={() => {
                    select(track.id)
                    setMenuFor(null)
                  }}
                  draggable={!track.missing}
                  onDragStart={(event) => {
                    event.dataTransfer.setData(TRACK_DRAG_TYPE, track.id)
                    event.dataTransfer.effectAllowed = 'copy'
                    setDraggedTrack(track.id)
                    select(track.id)
                  }}
                >
                  <div style={{ minWidth: 0 }}>
                    <div className="lib-name" title={track.path ?? track.name}>
                      {displayName(track)}
                    </div>
                    <div className="lib-sub">
                      <span>{track.missing ? 'file missing' : (track.key ?? '')}</span>
                      {on && <span className="on">{`on ${on}`}</span>}
                    </div>
                  </div>
                  <span
                    className="lib-key"
                    onClick={(event) => {
                      event.stopPropagation()
                      if (track.camelot) pickKey(track.camelot)
                    }}
                    title={track.camelot ? `Show ${track.camelot} and its harmonic matches` : 'No key found'}
                  >
                    <CamelotBadge code={track.camelot} selected={keyFilter !== '' && keyFilter === track.camelot} />
                  </span>
                  <span className="lib-bpm">{track.bpm.toFixed(1)}</span>
                  <span className="lib-dur">{clock(track.durationSec)}</span>
                  <span
                    className={`lib-grid${track.gridUncertain ? ' unsure' : ''}`}
                    title={
                      track.gridUncertain
                        ? `Tempo uncertain: it may be ${(track.gridAlternates ?? []).map((alternate) => alternate.bpm.toFixed(2)).join(' or ')}. Open the beat grid to choose.`
                        : undefined
                    }
                  >
                    {Math.round(track.confidence * 100)}%{track.gridUncertain ? '?' : ''}
                  </span>
                  <div className="lib-actions">
                    <button
                      className={menuFor === track.id ? 'on' : ''}
                      onClick={(event) => {
                        event.stopPropagation()
                        setMenuFor((current) => (current === track.id ? null : track.id))
                      }}
                      title="Add to a playlist"
                    >
                      +
                    </button>
                    <button
                      onClick={(event) => {
                        event.stopPropagation()
                        void reanalyze(track)
                      }}
                      title="Re-analyse"
                    >
                      ↻
                    </button>
                    {playlist ? (
                      <button
                        onClick={(event) => {
                          event.stopPropagation()
                          removeFromPlaylist(playlist.id, track.id)
                        }}
                        title={`Take out of ${playlist.name}`}
                      >
                        −
                      </button>
                    ) : (
                      <button
                        onClick={(event) => {
                          event.stopPropagation()
                          remove(track.id)
                        }}
                        title="Remove from the library"
                      >
                        ✕
                      </button>
                    )}
                    {menuFor === track.id && (
                      <div className="lib-menu" onClick={(event) => event.stopPropagation()}>
                        <b>ADD TO PLAYLIST</b>
                        {playlists.map((entry) => {
                          const member = entry.trackIds.includes(track.id)
                          return (
                            <button
                              key={entry.id}
                              onClick={() => (member ? removeFromPlaylist(entry.id, track.id) : addToPlaylist(entry.id, [track.id]))}
                            >
                              <i>{member ? '✓' : ''}</i>
                              {entry.name}
                            </button>
                          )
                        })}
                        <button
                          onClick={() => {
                            const id = createPlaylist()
                            addToPlaylist(id, [track.id])
                            openPlaylist(id)
                            setMenuFor(null)
                          }}
                        >
                          <i>+</i>New playlist
                        </button>
                      </div>
                    )}
                  </div>
                </div>
              )
            })}
            </div>
          </div>
        </div>
      </div>
    </section>
  )
}

// ---- beat grid sheet -----------------------------------------------------------------

/** The sheet's window: eight seconds round the playhead, as 132 bars. */
const WINDOW_SEC = 8
const BARS = 132

/**
 * Beat grid editing for one deck. Drag the waveform to pull the grid onto
 * the beat, or arm SET DOWNBEAT and tap the first beat of a bar; every edit
 * is written to the library entry.
 */
export function GridSheet({ snapshot }: { snapshot: EngineSnapshot }) {
  const gridOpen = useConsole((state) => state.gridOpen)
  const closeGrid = useConsole((state) => state.closeGrid)
  return (
    <section
      className={`gridsheet ${gridOpen ? 'open' : ''}`}
      onClick={(event) => {
        if (!(event.target as Element).closest('.gsheet')) closeGrid()
      }}
    >
      {gridOpen && <GridEditor key={gridOpen} side={gridOpen} snapshot={snapshot} />}
    </section>
  )
}

/** "2/3" → "3/2", "2" → "1/2". */
function invertRelation(relation: string): string {
  const [n, d = '1'] = relation.split('/')
  return d === '1' ? `1/${n}` : n === '1' ? d : `${d}/${n}`
}

/** A tempo over another as the simplest ratio of small numbers, e.g. "4/3". */
function relationOver(bpm: number, base: number): string {
  const ratio = bpm / base
  for (let d = 1; d <= 8; d++) {
    const n = Math.round(ratio * d)
    if (n > 0 && Math.abs(n / d - ratio) < 0.005 * ratio) return d === 1 ? String(n) : `${n}/${d}`
  }
  return ratio.toFixed(2)
}

function GridEditor({ side, snapshot }: { side: Side; snapshot: EngineSnapshot }) {
  const index = side === 'B' ? 1 : 0
  const deck = snapshot.decks[index]
  const closeGrid = useConsole((state) => state.closeGrid)
  const applyGrid = useLibrary((state) => state.applyGrid)
  const track = useLibrary((state) => state.tracks.find((entry) => entry.id === deck.trackId))
  const position = useDeckPosition(index)
  const levels = useLevels(deck)
  const [anchor] = useState(() => (isDemo ? 24 : deck.position))
  const [armed, setArmed] = useState(false)
  const [taps, setTaps] = useState<number[]>([])
  const [dragOffset, setDragOffset] = useState<number | null>(null)
  const drag = useRef<{ pointerId: number; startX: number; offsetMs: number; left: number; width: number; moved: boolean } | null>(null)
  const grid = deck.grid
  const start = anchor - WINDOW_SEC / 2
  const shown = grid && dragOffset !== null ? { ...grid, offsetMs: dragOffset } : grid

  const apply = (next: BeatGrid, alternates?: TrackGridAlternate[]): void => {
    engine.setDeckGrid(index, next)
    if (deck.trackId) applyGrid(deck.trackId, next, alternates)
  }
  /** Take another reading; the one it replaces joins the list, so it is one click back. */
  const applyAlternate = (alternate: TrackGridAlternate): void => {
    if (!grid || !track?.gridAlternates) return
    const previous = { bpm: grid.bpm, offsetMs: grid.offsetMs, relation: invertRelation(alternate.relation) }
    apply(
      { bpm: alternate.bpm, offsetMs: alternate.offsetMs, confidence: grid.confidence },
      track.gridAlternates.map((entry) => (entry === alternate ? previous : { ...entry, relation: relationOver(entry.bpm, alternate.bpm) }))
    )
  }
  /** Fold at the bar rather than the beat, so the downbeat keeps its phase. */
  const commitOffset = (offsetMs: number): void => {
    if (grid) apply(setGridOffset(grid, normalizeOffset(offsetMs, barSeconds(grid) * 1000)))
  }

  const peaks = useMemo(() => {
    if (!levels) return null
    const samplesPerBar = (WINDOW_SEC / BARS) * levels.sampleRate
    const level = pickLevel(levels, samplesPerBar / 4)
    return Array.from({ length: BARS }, (_, bar) => {
      const s0 = (start + (bar / BARS) * WINDOW_SEC) * levels.sampleRate
      const b0 = Math.max(0, Math.floor(s0 / level.binSize))
      const b1 = Math.min(level.count, Math.ceil((s0 + samplesPerBar) / level.binSize))
      let peak = 0
      for (let b = b0; b < b1; b++) peak = Math.max(peak, -decodePeak(level.data[b * 4]), decodePeak(level.data[b * 4 + 1]))
      return Math.max(6, Math.min(100, peak * 100))
    })
  }, [levels, start])

  const lines = []
  if (shown) {
    const period = 60 / shown.bpm
    const offset = shown.offsetMs / 1000
    const first = Math.floor((start - offset) / period) - 1
    const last = Math.ceil((start + WINDOW_SEC - offset) / period) + 1
    for (let beat = first; beat <= last; beat++) {
      const pct = ((offset + beat * period - start) / WINDOW_SEC) * 100
      if (pct < -0.5 || pct > 100.5) continue
      const downbeat = ((beat % 4) + 4) % 4 === 0
      lines.push(
        <span key={beat} className={`gbeat${downbeat ? ' bar' : ''}`} style={{ left: `${pct.toFixed(2)}%` }}>
          {downbeat && <b>{Math.floor(beat / 4) + 1}</b>}
        </span>
      )
    }
  }

  const tapTempo = (): void => {
    const now = performance.now()
    const recent = [...taps.filter((time) => now - time < 2600), now].slice(-8)
    setTaps(recent)
    if (recent.length >= 3) {
      const intervals = recent.slice(1).map((time, i) => time - recent[i])
      const average = intervals.reduce((sum, value) => sum + value, 0) / intervals.length
      if (average > 150) apply({ bpm: Math.min(200, Math.max(60, 60000 / average)), offsetMs: grid?.offsetMs ?? 0, confidence: 0.5 })
    }
  }

  const onPointerDown = (event: ReactPointerEvent<HTMLDivElement>): void => {
    if (!grid) return
    const rect = event.currentTarget.getBoundingClientRect()
    drag.current = { pointerId: event.pointerId, startX: event.clientX, offsetMs: grid.offsetMs, left: rect.left, width: rect.width, moved: false }
    try {
      event.currentTarget.setPointerCapture(event.pointerId)
    } catch {
      // A pointer that is already gone cannot be captured.
    }
  }
  const onPointerMove = (event: ReactPointerEvent<HTMLDivElement>): void => {
    const d = drag.current
    if (!d || d.pointerId !== event.pointerId || armed) return
    const dx = event.clientX - d.startX
    if (!d.moved && Math.abs(dx) < 3) return
    d.moved = true
    setDragOffset(d.offsetMs + (dx / Math.max(1, d.width)) * WINDOW_SEC * 1000)
  }
  const onPointerUp = (event: ReactPointerEvent<HTMLDivElement>): void => {
    const d = drag.current
    if (!d || d.pointerId !== event.pointerId) return
    drag.current = null
    if (armed && !d.moved) {
      const x = Math.min(1, Math.max(0, (event.clientX - d.left) / Math.max(1, d.width)))
      commitOffset((start + x * WINDOW_SEC) * 1000)
      setArmed(false)
    } else if (d.moved && dragOffset !== null) commitOffset(dragOffset)
    setDragOffset(null)
  }

  const tapLabel = taps.length > 0 ? `${taps.length} ${taps.length === 1 ? 'tap' : 'taps'}` : '3 taps'
  const nowLeft = isDemo ? 50 : ((position - start) / WINDOW_SEC) * 100

  return (
    <div className="gsheet" style={vars({ '--accent': accentOf(side) })}>
      <div className="gsheet-head">
        <h2>
          Beat grid <span>{`· deck ${side}`}</span>
        </h2>
        <InfoButton topic="grid" />
        <button className="btn ghost done" onClick={closeGrid}>
          Close
        </button>
      </div>
      <div className="gstats">
        <div className="gstat">
          <b>{grid ? grid.bpm.toFixed(1) : '—'}</b>
          <span>BPM</span>
        </div>
        <div className="gstat">
          <b className={track?.gridUncertain ? 'unsure' : grid && grid.confidence >= 0.6 ? 'ok' : ''}>
            {grid ? `${Math.round(grid.confidence * 100)}%${track?.gridUncertain ? '?' : ''}` : '—'}
          </b>
          <span>confidence</span>
        </div>
        <div className="gstat">
          <b>{shown ? `${shown.offsetMs >= 0 ? '+' : ''}${shown.offsetMs.toFixed(1)}` : '—'}</b>
          <span>offset ms</span>
        </div>
      </div>
      <div className="gview">
        <div className="gview-head">
          <span className="gview-title">grid · 4/4 · 8 s</span>
          <span className="gview-hint">{armed ? 'Tap the first beat of a bar' : 'Drag to shift the grid'}</span>
          <button className={`garm ${armed ? 'on' : ''}`} onClick={() => setArmed(!armed)} disabled={!grid}>
            {armed ? 'TAP THE FIRST BEAT' : 'SET DOWNBEAT'}
          </button>
        </div>
        <div
          className={`gwave ${armed ? 'arming' : ''}`}
          onPointerDown={onPointerDown}
          onPointerMove={onPointerMove}
          onPointerUp={onPointerUp}
          onPointerCancel={() => {
            drag.current = null
            setDragOffset(null)
          }}
        >
          <div className="gpeaks">
            {isDemo ? <DemoGridPeaks side={side} /> : peaks?.map((height, bar) => <i key={bar} style={{ height: `${height.toFixed(1)}%` }}></i>)}
          </div>
          <div className="glines">{lines}</div>
          {nowLeft >= 0 && nowLeft <= 100 && <span className="gnow" style={{ left: `${nowLeft}%` }}></span>}
        </div>
      </div>
      <div className="gactions">
        <button className="gact tall" onClick={tapTempo} disabled={!deck.trackId}>
          TAP<small>{tapLabel}</small>
        </button>
        <button className="gact" onClick={() => grid && apply(setGridBpm(grid, grid.bpm - 0.1))} disabled={!grid}>
          −0.1<small>BPM</small>
        </button>
        <button className="gact" onClick={() => grid && apply(setGridBpm(grid, grid.bpm + 0.1))} disabled={!grid}>
          +0.1<small>BPM</small>
        </button>
        <button className="gact" onClick={() => grid && apply(nudgeGrid(grid, -1))} disabled={!grid}>
          ◀ 1 ms<small>earlier</small>
        </button>
        <button className="gact" onClick={() => grid && apply(nudgeGrid(grid, 1))} disabled={!grid}>
          1 ms ▶<small>later</small>
        </button>
        <button className="gact" onClick={() => grid && apply(halveGrid(grid))} disabled={!grid}>
          ÷2<small>half</small>
        </button>
        <button className="gact" onClick={() => grid && apply(doubleGrid(grid))} disabled={!grid}>
          ×2<small>double</small>
        </button>
      </div>
      {grid && track?.gridAlternates && track.gridAlternates.length > 0 && (
        <div className={`galts${track.gridUncertain ? ' unsure' : ''}`}>
          <span>{track.gridUncertain ? 'Not sure of this tempo · it may be' : 'Other readings'}</span>
          {track.gridAlternates.map((alternate) => (
            <button
              key={alternate.bpm}
              className="gact galt"
              onClick={() => applyAlternate(alternate)}
              title={`Use ${alternate.bpm.toFixed(2)} BPM, with its own downbeat`}
            >
              {alternate.bpm.toFixed(2)}
              <small>{`${alternate.relation}×`}</small>
            </button>
          ))}
        </div>
      )}
    </div>
  )
}
