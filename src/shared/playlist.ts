/**
 * Playlists: named, ordered lists of track ids kept beside the library's
 * tracks. Every helper returns a new list and leaves its input alone, so the
 * store can hand the result straight to zustand and to disk.
 */

export interface Playlist {
  id: string
  name: string
  trackIds: string[]
}

export const DEFAULT_PLAYLIST_NAME = 'New playlist'

/** A name nobody else has: "New playlist", then "New playlist 2", and so on. */
export function uniquePlaylistName(base: string, playlists: Playlist[], exceptId?: string): string {
  const wanted = base.trim() || DEFAULT_PLAYLIST_NAME
  const taken = new Set(
    playlists.filter((playlist) => playlist.id !== exceptId).map((playlist) => playlist.name.toLowerCase())
  )
  if (!taken.has(wanted.toLowerCase())) return wanted
  for (let n = 2; ; n++) {
    const candidate = `${wanted} ${n}`
    if (!taken.has(candidate.toLowerCase())) return candidate
  }
}

export function createPlaylist(playlists: Playlist[], id: string, name = DEFAULT_PLAYLIST_NAME): Playlist[] {
  return [...playlists, { id, name: uniquePlaylistName(name, playlists), trackIds: [] }]
}

export function renamePlaylist(playlists: Playlist[], id: string, name: string): Playlist[] {
  if (!name.trim()) return playlists
  return playlists.map((playlist) =>
    playlist.id === id ? { ...playlist, name: uniquePlaylistName(name, playlists, id) } : playlist
  )
}

export function deletePlaylist(playlists: Playlist[], id: string): Playlist[] {
  return playlists.filter((playlist) => playlist.id !== id)
}

/** Appends tracks the playlist does not already hold, in the order given. */
export function addToPlaylist(playlists: Playlist[], id: string, trackIds: string[]): Playlist[] {
  return playlists.map((playlist) => {
    if (playlist.id !== id) return playlist
    const have = new Set(playlist.trackIds)
    const fresh = trackIds.filter((trackId) => {
      if (have.has(trackId)) return false
      have.add(trackId)
      return true
    })
    return fresh.length ? { ...playlist, trackIds: [...playlist.trackIds, ...fresh] } : playlist
  })
}

export function removeFromPlaylist(playlists: Playlist[], id: string, trackId: string): Playlist[] {
  return playlists.map((playlist) =>
    playlist.id === id ? { ...playlist, trackIds: playlist.trackIds.filter((entry) => entry !== trackId) } : playlist
  )
}

/** Drops a track from every playlist, for when it leaves the library. */
export function forgetTrack(playlists: Playlist[], trackId: string): Playlist[] {
  return playlists.map((playlist) =>
    playlist.trackIds.includes(trackId)
      ? { ...playlist, trackIds: playlist.trackIds.filter((entry) => entry !== trackId) }
      : playlist
  )
}

/**
 * Reads playlists from a saved library: anything malformed is skipped, ids
 * the library no longer knows are dropped, and duplicates collapse.
 */
export function normalizePlaylists(raw: unknown, knownTrackIds: Set<string>): Playlist[] {
  if (!Array.isArray(raw)) return []
  const out: Playlist[] = []
  const seenIds = new Set<string>()
  for (const entry of raw) {
    if (!entry || typeof entry !== 'object') continue
    const { id, name, trackIds } = entry as Partial<Playlist>
    if (typeof id !== 'string' || !id || seenIds.has(id) || typeof name !== 'string') continue
    seenIds.add(id)
    const ids = Array.isArray(trackIds)
      ? [...new Set(trackIds.filter((trackId): trackId is string => typeof trackId === 'string' && knownTrackIds.has(trackId)))]
      : []
    out.push({ id, name: name.trim() || DEFAULT_PLAYLIST_NAME, trackIds: ids })
  }
  return out
}
