import { create } from 'zustand'
import type { BeatGrid } from '../../shared/grid'
import { normalizeHotCues, type HotCueList } from '../../shared/hot-cue'
import {
  addToPlaylist,
  createPlaylist,
  deletePlaylist,
  forgetTrack,
  removeFromPlaylist,
  renamePlaylist,
  type Playlist
} from '../../shared/playlist'
import type { PowerAnalysis } from '../../shared/power'
import { autoTrimDb } from '../../shared/mixer'
import { readTags } from '../../shared/tags'
import { isAudioFile, type LibraryDoc, type TrackGridAlternate, type TrackMeta } from '../../shared/types'
import { engine } from '../audio/engine'
import type { AnalysisResult } from '../audio/types'
import { bridge, forgetBrowserFile, rememberBrowserSource } from '../lib/bridge'
import { LibraryWriter } from '../lib/library-writer'
import { parseLibrary } from '../../shared/library-schema'
import { stripExtension } from '../lib/format'
import { useArt } from './art'

/** Bytes for tracks that have no path on disk (drag & drop / browser fallback). */
const sessionBytes = new Map<string, ArrayBuffer>()

/** Finite optional fields keep silent/short files safe in JSON libraries. */
function powerFields(power: PowerAnalysis): Pick<TrackMeta, 'power' | 'lufs' | 'gainDb' | 'peakToLoudnessDb'> {
  return { power, lufs: power.lufs, gainDb: power.gainDb, peakToLoudnessDb: power.peakToLoudnessDb }
}

async function fingerprint(bytes: ArrayBuffer): Promise<string> {
  return Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', bytes)), (b) => b.toString(16).padStart(2, '0')).join('')
}

/**
 * The key fields a fresh analysis writes. A track with no pitched material
 * keeps confidence 0, so it counts as analysed and is not offered again.
 */
function keyFields(key: AnalysisResult['key']): Pick<TrackMeta, 'key' | 'camelot' | 'keyConfidence'> {
  return key
    ? { key: key.key, camelot: key.camelot, keyConfidence: key.confidence }
    : { key: undefined, camelot: undefined, keyConfidence: 0 }
}

/** The grid fields a fresh analysis writes. */
function gridFields(analysis: AnalysisResult): Pick<TrackMeta, 'bpm' | 'offsetMs' | 'confidence' | 'gridUncertain' | 'gridAlternates'> {
  return {
    bpm: analysis.bpm,
    offsetMs: analysis.offsetMs,
    confidence: analysis.confidence,
    gridUncertain: analysis.uncertain || undefined,
    gridAlternates: analysis.alternates.length > 0 ? analysis.alternates : undefined
  }
}

/** Analysed before key detection existed, so it has never had a key looked for. */
export const needsKey = (track: TrackMeta): boolean => !track.camelot && track.keyConfidence == null && !track.missing

function persist(tracks: TrackMeta[], playlists: Playlist[]): void {
  if (!useLibrary.getState().hydrated) return
  const doc: LibraryDoc = { version: 1, tracks, playlists }
  libraryWriter.enqueue(JSON.stringify(doc))
}

interface IngestPayload {
  name: string
  path?: string
  bytes: ArrayBuffer
}

/** What the library is working on, for the status key in the header. */
export interface LibraryStatus {
  label: string
  /** The track being worked on. */
  name?: string
  current?: number
  total?: number
}

/** A failure, for the line under the header: a short title and what happened. */
export interface LibraryError {
  title: string
  message: string
}

/** "Artist — Title" from the tags, else the file name. */
const trackLabel = (track: Pick<TrackMeta, 'artist' | 'title' | 'name'>): string =>
  track.title ? (track.artist ? `${track.artist} — ${track.title}` : track.title) : track.name

const reason = (error: unknown): string => (error instanceof Error ? error.message : String(error))

interface LibraryState {
  tracks: TrackMeta[]
  playlists: Playlist[]
  hydrated: boolean
  saveState: 'saved' | 'saving' | 'error'
  flush: () => Promise<void>
  status: LibraryStatus | null
  error: LibraryError | null
  hydrate: () => Promise<void>
  setError: (error: LibraryError | null) => void
  addFiles: (deckIndex?: 0 | 1) => Promise<void>
  addFolder: () => Promise<void>
  addDroppedFiles: (files: File[], deckIndex?: 0 | 1) => Promise<void>
  loadToDeck: (track: TrackMeta, deckIndex: 0 | 1, reservedVersion?: number) => Promise<void>
  /** `progress`: part of a run that shows its own status. */
  reanalyze: (track: TrackMeta, progress?: boolean) => Promise<void>
  /** Re-analyses every track that has no key yet (libraries from before key detection). */
  findKeys: () => Promise<void>
  /** Write an edited grid; `alternates` replaces the track's other readings when given. */
  applyGrid: (trackId: string, grid: BeatGrid, alternates?: TrackGridAlternate[]) => void
  applyHotCues: (trackId: string, cues: HotCueList) => void
  remove: (trackId: string) => void
  /** Makes an empty playlist and returns its id. */
  createPlaylist: (name?: string) => string
  renamePlaylist: (playlistId: string, name: string) => void
  deletePlaylist: (playlistId: string) => void
  addToPlaylist: (playlistId: string, trackIds: string[]) => void
  removeFromPlaylist: (playlistId: string, trackId: string) => void
}

const libraryWriter = new LibraryWriter((json) => bridge.saveLibrary(json), (saveState, error) => {
  useLibrary.setState({ saveState, ...(error ? { error: { title: "LIBRARY NOT SAVED", message: reason(error) } } : {}) })
})

// Imports share a queue: only one file is read/decoded/analyzed at a time.
let hydration: Promise<void> | null = null
let importTail: Promise<unknown> = Promise.resolve()
const queueImport = (action: () => Promise<void>): Promise<void> => {
  const next = importTail.catch(() => undefined).then(action)
  importTail = next
  return next
}

export const useLibrary = create<LibraryState>((set, get) => {
  async function resolveBytes(track: TrackMeta): Promise<ArrayBuffer | null> {
    const cached = sessionBytes.get(track.id)
    if (cached) return cached
    if (track.path) return bridge.readFile(track.path)
    return null
  }

  function markMissing(trackId: string, missing: boolean): void {
    const tracks = get().tracks.map((track) => (track.id === trackId ? { ...track, missing } : track))
    set({ tracks })
    persist(tracks, get().playlists)
  }

  /** `batch`: where these payloads sit in a longer run (a folder read one file at a time). */
  async function ingest(payloads: IngestPayload[], targetDeck?: 0 | 1, batch = { start: 0, total: payloads.length }, version?: number): Promise<void> {
    if (payloads.length === 0) return
    let added: TrackMeta | null = null
    for (let i = 0; i < payloads.length; i++) {
      const payload = payloads[i]
      const sourceHash = await fingerprint(payload.bytes)
      const known = get().tracks.find((track) => bridge.kind === 'browser' || !payload.path ? track.fingerprint === sourceHash : track.path === payload.path)
      const id = known?.id ?? (payload.path ? crypto.randomUUID() : sourceHash)
      if (known && known.fingerprint === sourceHash) {
        // Dropping an already-known track should still load it (and restore the
        // bytes when the file has no usable path, e.g. the browser fallback).
        if (!payload.path) sessionBytes.set(id, payload.bytes)
        if (known.missing && payload.path) markMissing(id, false)
        if (payload.path && payload.path !== known.path) {
          if (known.path) forgetBrowserFile(known.path)
          added = { ...known, path: payload.path, missing: false }
          const tracks = get().tracks.map((track) => track.id === id ? added! : track)
          set({ tracks })
          persist(tracks, get().playlists)
        } else added = known
        continue
      }
      const tags = readTags(payload.bytes)
      set({
        status: {
          label: 'ANALYSING',
          name: trackLabel({ ...tags, name: stripExtension(payload.name) }),
          current: batch.start + i + 1,
          total: batch.total
        }
      })
      try {
        const analysis = await engine.analyze(payload.bytes)
        const meta: TrackMeta = {
          ...known,
          id,
          fingerprint: sourceHash,
          name: stripExtension(payload.name),
          artist: tags.artist,
          title: tags.title,
          path: payload.path,
          durationSec: analysis.durationSec,
          hotCues: known?.fingerprint && known.fingerprint !== sourceHash ? undefined : normalizeHotCues(known?.hotCues, analysis.durationSec),
          ...gridFields(analysis),
          peaks: analysis.peaks,
          ...keyFields(analysis.key),
          ...powerFields(analysis.power),
          analyzedAt: new Date().toISOString()
        }
        if (!payload.path) sessionBytes.set(id, payload.bytes)
        const tracks = [...get().tracks.filter((entry) => entry.id !== id), meta]
        set({ tracks })
        persist(tracks, get().playlists)
        added = meta
      } catch (error) {
        if (payload.path && !get().tracks.some((track) => track.path === payload.path)) forgetBrowserFile(payload.path)
        set({ error: { title: "CAN'T ANALYSE", message: `${payload.name}: ${reason(error)}` } })
      }
    }
    set({ status: null })

    if (added && targetDeck !== undefined) await get().loadToDeck(added, targetDeck, version)
  }

  function savePlaylists(playlists: Playlist[]): void {
    set({ playlists })
    persist(get().tracks, playlists)
  }

  return {
    tracks: [],
    playlists: [],
    hydrated: false,
    saveState: 'saved',
    flush: () => libraryWriter.flush(),
    status: null,
    error: null,

    setError: (error) => set({ error }),

    async hydrate() {
      if (get().hydrated) return
      if (hydration) return hydration
      hydration = (async () => {
        try {
          const raw = await bridge.loadLibrary()
          const doc = raw ? parseLibrary(raw) : { tracks: [], playlists: [] }
          set({ tracks: doc.tracks, playlists: doc.playlists ?? [], hydrated: true })
        } catch (error) {
          set({ error: { title: "CAN'T READ LIBRARY", message: reason(error) }, saveState: 'error' })
          // Stay unhydrated: do not replace damaged data with a new empty library.
        }
      })().finally(() => { hydration = null })
      return hydration
    },

    async addFiles(deckIndex) {
      let version: number | undefined
      try { if (deckIndex !== undefined) version = engine.beginDeckLoad(deckIndex) }
      catch (error) { set({ error: { title: "CAN'T LOAD", message: reason(error) } }); return }
      await queueImport(async () => {
        try {
          await get().hydrate()
          if (!get().hydrated) return
          const refs = await bridge.pickFiles()
          for (let i = 0; i < refs.length; i++) {
            const bytes = await bridge.readFile(refs[i].path)
            if (bytes) await ingest([{ ...refs[i], bytes }], i === refs.length - 1 ? deckIndex : undefined, { start: i, total: refs.length }, version)
          }
        } catch (error) { set({ status: null, error: { title: "CAN'T ADD", message: reason(error) } }) }
      })
    },

    async addFolder() {
      await queueImport(async () => {
        try {
          await get().hydrate()
          if (!get().hydrated) return
          const refs = await bridge.pickFolder()
          for (let i = 0; i < refs.length; i++) {
            const bytes = await bridge.readFile(refs[i].path)
            if (bytes) await ingest([{ ...refs[i], bytes }], undefined, { start: i, total: refs.length })
          }
        } catch (error) { set({ status: null, error: { title: "CAN'T ADD", message: reason(error) } }) }
      })
    },

    async addDroppedFiles(files, deckIndex) {
      let version: number | undefined
      try { if (deckIndex !== undefined) version = engine.beginDeckLoad(deckIndex) }
      catch (error) { set({ error: { title: "CAN'T LOAD", message: reason(error) } }); return }
      await queueImport(async () => {
        try {
          await get().hydrate()
          if (!get().hydrated) return
          const audio = files.filter((file) => isAudioFile(file.name))
          for (let i = 0; i < audio.length; i++) {
            const file = audio[i]
            const path = bridge.kind === 'browser' ? rememberBrowserSource(file) : await bridge.getPathForFile(file) || undefined
            const bytes = await file.arrayBuffer()
            await ingest([{ name: file.name, path, bytes }], i === audio.length - 1 ? deckIndex : undefined, { start: i, total: audio.length }, version)
          }
        } catch (error) { set({ status: null, error: { title: "CAN'T ADD", message: reason(error) } }) }
      })
    },

    async loadToDeck(track, deckIndex, reservedVersion) {
      let version: number | undefined
      try {
        version = reservedVersion ?? engine.beginDeckLoad(deckIndex)
        const bytes = await resolveBytes(track)
        if (!engine.isDeckLoadCurrent(deckIndex, version)) return
        if (!bytes) {
          markMissing(track.id, true)
          throw new Error('The file is missing. Add it again to play it.')
        }
        const sourceHash = await fingerprint(bytes)
        if (!engine.isDeckLoadCurrent(deckIndex, version)) return
        if (track.fingerprint && track.fingerprint !== sourceHash) {
          // A file changed in place: never apply the previous song's grid or key.
          const analysis = await engine.analyze(bytes)
          if (!engine.isDeckLoadCurrent(deckIndex, version)) return
          track = { ...track, fingerprint: sourceHash, durationSec: analysis.durationSec, ...gridFields(analysis), peaks: analysis.peaks, ...keyFields(analysis.key), ...powerFields(analysis.power), hotCues: undefined, analyzedAt: new Date().toISOString() }
          const tracks = get().tracks.map((entry) => entry.id === track.id ? track : entry)
          set({ tracks })
          persist(tracks, get().playlists)
        }
        const tags = readTags(bytes)
        if ((tags.artist && !track.artist) || (tags.title && !track.title)) {
          const tracks = get().tracks.map((entry) =>
            entry.id === track.id ? { ...entry, artist: entry.artist ?? tags.artist, title: entry.title ?? tags.title } : entry
          )
          set({ tracks })
          persist(tracks, get().playlists)
        }
        const loaded = await engine.loadIntoDeck(deckIndex, {
          id: track.id,
          name: track.name,
          bytes,
          grid: { bpm: track.bpm, offsetMs: track.offsetMs, confidence: track.confidence },
          peaks: Int8Array.from(track.peaks),
          hotCues: normalizeHotCues(track.hotCues, track.durationSec),
          power: track.power,
          trimDb: autoTrimDb(track.gainDb ?? 0),
          onPower: (power) => {
            const tracks = get().tracks.map((entry) => entry.id === track.id && entry.power === track.power ? { ...entry, ...powerFields(power) } : entry)
            set({ tracks })
            persist(tracks, get().playlists)
          }
        }, version)
        if (loaded) {
          if (!track.fingerprint) {
            const tracks = get().tracks.map((entry) => entry.id === track.id ? { ...entry, fingerprint: sourceHash } : entry)
            set({ tracks })
            persist(tracks, get().playlists)
          }
          useArt.getState().show(track.id, tags.picture ?? null)
          if (track.missing) markMissing(track.id, false)
        }
      } catch (error) {
        if (version !== undefined && !engine.isDeckLoadCurrent(deckIndex, version)) return
        set({ error: { title: "CAN'T LOAD", message: `"${trackLabel(track)}": ${reason(error)}` } })
      }
    },

    async reanalyze(track, progress = false) {
      try {
        const bytes = await resolveBytes(track)
        if (!bytes) {
          set({ error: { title: "CAN'T ANALYSE", message: `"${trackLabel(track)}" isn't on disk any more. Add the file again to analyse it.` } })
          return
        }
        if (!progress) set({ status: { label: 'ANALYSING', name: trackLabel(track) } })
        const sourceHash = await fingerprint(bytes)
        const analysis = await engine.analyze(bytes)
        if (!progress) set({ status: null })
        const tracks = get().tracks.map((entry) =>
          entry.id === track.id
            ? {
                ...entry,
                ...gridFields(analysis),
                fingerprint: sourceHash,
                durationSec: analysis.durationSec,
                peaks: analysis.peaks,
                ...keyFields(analysis.key),
                ...powerFields(analysis.power),
                analyzedAt: new Date().toISOString()
              }
            : entry
        )
        set({ tracks })
        persist(tracks, get().playlists)
        for (const index of [0, 1] as const) {
          const deck = engine.getDeck(index)
          if (deck?.trackId === track.id) {
            deck.power = analysis.power
            deck.setGrid({ bpm: analysis.bpm, offsetMs: analysis.offsetMs, confidence: analysis.confidence })
          }
        }
        engine.commit()
      } catch (error) {
        set({ status: progress ? get().status : null, error: { title: "CAN'T ANALYSE", message: `"${trackLabel(track)}": ${reason(error)}` } })
      }
    },

    async findKeys() {
      const pending = get().tracks.filter(needsKey)
      for (let i = 0; i < pending.length; i++) {
        // Re-read it: an earlier pass may have changed or removed the entry.
        const current = get().tracks.find((entry) => entry.id === pending[i].id)
        if (!current) continue
        set({ status: { label: 'FINDING KEYS', name: trackLabel(current), current: i + 1, total: pending.length } })
        await get().reanalyze(current, true)
      }
      set({ status: null })
    },

    applyGrid(trackId, grid, alternates) {
      const tracks = get().tracks.map((track) =>
        track.id === trackId
          ? {
              ...track,
              bpm: grid.bpm,
              offsetMs: grid.offsetMs,
              confidence: grid.confidence,
              // A person has looked at the grid now, so it is no longer flagged.
              gridUncertain: undefined,
              gridAlternates: alternates ?? track.gridAlternates
            }
          : track
      )
      set({ tracks })
      persist(tracks, get().playlists)
    },

    applyHotCues(trackId, cues) {
      const hotCues = normalizeHotCues(cues)
      const tracks = get().tracks.map((track) => (track.id === trackId ? { ...track, hotCues } : track))
      set({ tracks })
      persist(tracks, get().playlists)
    },

    remove(trackId) {
      const removed = get().tracks.find((track) => track.id === trackId)
      if (removed?.path) forgetBrowserFile(removed.path)
      sessionBytes.delete(trackId)
      const tracks = get().tracks.filter((track) => track.id !== trackId)
      const playlists = forgetTrack(get().playlists, trackId)
      set({ tracks, playlists })
      persist(tracks, playlists)
    },

    createPlaylist(name) {
      const id = `pl-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 7)}`
      savePlaylists(createPlaylist(get().playlists, id, name))
      return id
    },

    renamePlaylist(playlistId, name) {
      savePlaylists(renamePlaylist(get().playlists, playlistId, name))
    },

    deletePlaylist(playlistId) {
      savePlaylists(deletePlaylist(get().playlists, playlistId))
    },

    addToPlaylist(playlistId, trackIds) {
      savePlaylists(addToPlaylist(get().playlists, playlistId, trackIds))
    },

    removeFromPlaylist(playlistId, trackId) {
      savePlaylists(removeFromPlaylist(get().playlists, playlistId, trackId))
    }
  }
})
