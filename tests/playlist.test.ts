import { describe, expect, it } from 'vitest'
import {
  addToPlaylist,
  createPlaylist,
  deletePlaylist,
  forgetTrack,
  normalizePlaylists,
  removeFromPlaylist,
  renamePlaylist,
  uniquePlaylistName,
  type Playlist
} from '../src/shared/playlist'

const two = (): Playlist[] => [
  { id: 'p1', name: 'Warm up', trackIds: ['a', 'b'] },
  { id: 'p2', name: 'Peak', trackIds: ['b', 'c'] }
]

describe('playlist names', () => {
  it('numbers a name that is already taken, ignoring case', () => {
    const lists = createPlaylist(createPlaylist([], 'x'), 'y')
    expect(lists.map((list) => list.name)).toEqual(['New playlist', 'New playlist 2'])
    expect(uniquePlaylistName('warm UP', two())).toBe('warm UP 2')
  })

  it('renames, keeps its own name free, and ignores blank names', () => {
    expect(renamePlaylist(two(), 'p1', 'Warm up')[0].name).toBe('Warm up')
    expect(renamePlaylist(two(), 'p1', 'Peak')[0].name).toBe('Peak 2')
    expect(renamePlaylist(two(), 'p1', '   ')[0].name).toBe('Warm up')
  })
})

describe('playlist tracks', () => {
  it('appends new tracks in order and skips ones already there', () => {
    const lists = two()
    const next = addToPlaylist(lists, 'p1', ['c', 'a', 'd', 'c'])
    expect(next[0].trackIds).toEqual(['a', 'b', 'c', 'd'])
    expect(lists[0].trackIds).toEqual(['a', 'b']) // the input is not mutated
    expect(addToPlaylist(lists, 'p1', ['a'])[0]).toBe(lists[0])
  })

  it('removes from one playlist, or from all when a track leaves the library', () => {
    expect(removeFromPlaylist(two(), 'p1', 'b').map((list) => list.trackIds)).toEqual([['a'], ['b', 'c']])
    expect(forgetTrack(two(), 'b').map((list) => list.trackIds)).toEqual([['a'], ['c']])
  })

  it('deletes a playlist without touching the others', () => {
    expect(deletePlaylist(two(), 'p1')).toEqual([two()[1]])
  })
})

describe('normalizePlaylists', () => {
  it('loads a library saved before playlists existed', () => {
    expect(normalizePlaylists(undefined, new Set())).toEqual([])
  })

  it('drops malformed entries, unknown tracks and duplicates', () => {
    const raw = [
      { id: 'p1', name: 'Set', trackIds: ['a', 'gone', 'a', 3, 'b'] },
      { id: 'p1', name: 'Duplicate id', trackIds: [] },
      { id: 'p2', name: '  ', trackIds: 'nope' },
      { name: 'No id' },
      null
    ]
    expect(normalizePlaylists(raw, new Set(['a', 'b']))).toEqual([
      { id: 'p1', name: 'Set', trackIds: ['a', 'b'] },
      { id: 'p2', name: 'New playlist', trackIds: [] }
    ])
  })
})
