import { useEffect } from 'react'
import type { TrackMeta } from '../../shared/types'
import { engine } from '../audio/engine'
import { useLibrary } from '../state/library'
import { useConsole, type Side } from './state'

/** Drag data type for a library row dropped on a deck or a playlist. */
export const TRACK_DRAG_TYPE = 'application/x-dex-track'

/** "Artist — Title", from the tags when there are some. */
export function displayName(track: TrackMeta): string {
  if (track.title) return track.artist ? `${track.artist} — ${track.title}` : track.title
  const match = /^(.+?)\s+[-–—]\s+(.+)$/.exec(track.name)
  return match ? `${match[1]} — ${match[2]}` : track.name
}

/** The library row being dragged: a drag's data can only be read on the drop. */
let draggedTrackId: string | null = null
export const setDraggedTrack = (trackId: string | null): void => {
  draggedTrackId = trackId
}

/** The deck under a drag: its track window, its zoom lane or its bay. */
function sideAt(event: DragEvent): Side | null {
  const side = (event.target as Element | null)?.closest?.('.zcard, .zw, .bay')?.getAttribute('data-side')
  return side === 'A' || side === 'B' ? side : null
}

function carried(event: DragEvent): 'track' | 'files' | null {
  const types = Array.from(event.dataTransfer?.types ?? [])
  if (types.includes(TRACK_DRAG_TYPE)) return 'track'
  if (types.includes('Files')) return 'files'
  return null
}

/** What the drop would bring, for the overlay's second line. */
function dropLabel(event: DragEvent, kind: 'track' | 'files'): string {
  if (kind === 'track') {
    const track = useLibrary.getState().tracks.find((entry) => entry.id === draggedTrackId)
    return track ? `${displayName(track)} · from the library` : 'From the library'
  }
  const count = Array.from(event.dataTransfer?.items ?? []).filter((item) => item.kind === 'file').length
  return count > 1 ? `${count} files · analysed, the last one loaded` : 'Audio file · analysed, then loaded'
}

/**
 * Files and library rows dropped on a deck: its track window, lane or bay.
 * While one is held over a deck its window says what will happen; a playing
 * deck refuses. A file dropped anywhere else is ignored rather than opened.
 */
export function useDeckDrop(): void {
  useEffect(() => {
    const { setDrop } = useConsole.getState()
    const onDragOver = (event: DragEvent): void => {
      const kind = carried(event)
      if (!kind) return
      const side = sideAt(event)
      if (!side) {
        // Playlists take rows themselves; a stray file must not open as a page.
        if (kind === 'files') {
          event.preventDefault()
          if (event.dataTransfer) event.dataTransfer.dropEffect = 'none'
        }
        setDrop(null)
        return
      }
      event.preventDefault()
      const playing = engine.getSnapshot().decks[side === 'B' ? 1 : 0].playing
      if (event.dataTransfer) event.dataTransfer.dropEffect = playing ? 'none' : 'copy'
      setDrop({ side, label: dropLabel(event, kind) })
    }
    const onDragLeave = (event: DragEvent): void => {
      // Leaving the window, not just moving between elements.
      if (event.relatedTarget == null) setDrop(null)
    }
    const onDrop = (event: DragEvent): void => {
      const kind = carried(event)
      setDrop(null)
      if (!kind) return
      const side = sideAt(event)
      if (!side) {
        if (kind === 'files') event.preventDefault()
        return
      }
      event.preventDefault()
      const index = side === 'B' ? 1 : 0
      if (engine.getSnapshot().decks[index].playing) return
      const library = useLibrary.getState()
      if (kind === 'track') {
        const track = library.tracks.find((entry) => entry.id === event.dataTransfer?.getData(TRACK_DRAG_TYPE))
        if (track) void library.loadToDeck(track, index)
      } else {
        const files = Array.from(event.dataTransfer?.files ?? [])
        if (files.length > 0) void library.addDroppedFiles(files, index)
      }
    }
    const onDragEnd = (): void => {
      setDraggedTrack(null)
      setDrop(null)
    }
    window.addEventListener('dragover', onDragOver)
    window.addEventListener('dragleave', onDragLeave)
    window.addEventListener('drop', onDrop)
    window.addEventListener('dragend', onDragEnd)
    return () => {
      window.removeEventListener('dragover', onDragOver)
      window.removeEventListener('dragleave', onDragLeave)
      window.removeEventListener('drop', onDrop)
      window.removeEventListener('dragend', onDragEnd)
    }
  }, [])
}
