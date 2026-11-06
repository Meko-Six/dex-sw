import { create } from 'zustand'
import type { TagPicture } from '../../shared/tags'
import { engine } from '../audio/engine'

interface ArtState {
  /** Object URLs of the covers of tracks loaded this session, by track id. */
  urls: Record<string, string | null>
  show: (trackId: string, picture: TagPicture | null) => void
}

/**
 * Cover art for the track windows. Covers are read from the file when it
 * loads onto a deck and kept only while a deck holds the track.
 */
export const useArt = create<ArtState>((set, get) => ({
  urls: {},
  show(trackId, picture) {
    const onDecks = new Set(engine.getSnapshot().decks.map((deck) => deck.trackId))
    onDecks.add(trackId)
    const urls: Record<string, string | null> = {}
    for (const [id, url] of Object.entries(get().urls)) {
      if (onDecks.has(id) && id !== trackId) urls[id] = url
      else if (url) URL.revokeObjectURL(url)
    }
    urls[trackId] = picture ? URL.createObjectURL(new Blob([picture.data.slice()], { type: picture.mime })) : null
    set({ urls })
  }
}))
