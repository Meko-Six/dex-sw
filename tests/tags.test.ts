import { describe, expect, it } from 'vitest'
import { readTags } from '../src/shared/tags'

const JPEG = [0xff, 0xd8, 0xff, 0xe0, 1, 2, 3]
const PNG = [0x89, 0x50, 0x4e, 0x47, 4, 5]

const bytes = (...parts: Array<string | number[] | Uint8Array>): Uint8Array => {
  const chunks = parts.map((part) => (typeof part === 'string' ? new TextEncoder().encode(part) : Uint8Array.from(part)))
  const out = new Uint8Array(chunks.reduce((n, c) => n + c.length, 0))
  let i = 0
  for (const chunk of chunks) {
    out.set(chunk, i)
    i += chunk.length
  }
  return out
}
const be32 = (n: number): number[] => [(n >>> 24) & 255, (n >>> 16) & 255, (n >>> 8) & 255, n & 255]
const le32 = (n: number): number[] => be32(n).reverse()
const safe = (n: number): number[] => [(n >> 21) & 127, (n >> 14) & 127, (n >> 7) & 127, n & 127]
const buffer = (b: Uint8Array): ArrayBuffer => b.buffer.slice(b.byteOffset, b.byteOffset + b.length) as ArrayBuffer

function id3(major: 3 | 4, frames: Uint8Array): Uint8Array {
  return bytes('ID3', [major, 0, 0], safe(frames.length), frames)
}
function frame(major: 3 | 4, id: string, body: Uint8Array): Uint8Array {
  return bytes(id, major === 4 ? safe(body.length) : be32(body.length), [0, 0], body)
}

describe('readTags', () => {
  it('reads ID3v2.3 text in UTF-16 and an APIC picture', () => {
    const utf16 = (text: string): number[] => [0xff, 0xfe, ...Array.from(text).flatMap((c) => [c.charCodeAt(0), 0])]
    const frames = bytes(
      frame(3, 'TIT2', bytes([1], utf16('Ocean'))),
      frame(3, 'TPE1', bytes([1], utf16('Patrick Topping'))),
      frame(3, 'APIC', bytes([0], 'image/jpg', [0, 3], 'cover', [0], JPEG))
    )
    const tags = readTags(buffer(bytes(id3(3, frames), [0xff, 0xfb, 0, 0])))
    expect(tags.title).toBe('Ocean')
    expect(tags.artist).toBe('Patrick Topping')
    expect(tags.picture?.mime).toBe('image/jpeg')
    expect(Array.from(tags.picture!.data)).toEqual(JPEG)
  })

  it('reads ID3v2.4 UTF-8 frames with synchsafe sizes', () => {
    const frames = bytes(frame(4, 'TIT2', bytes([3], 'Glüe')), frame(4, 'TPE1', bytes([3], 'Bicep')))
    expect(readTags(buffer(id3(4, frames)))).toEqual({ title: 'Glüe', artist: 'Bicep' })
  })

  it('reads FLAC Vorbis comments and the PICTURE block', () => {
    const comments = ['TITLE=Latch', 'artist=Disclosure']
    const vorbis = bytes(le32(3), 'Dex', le32(comments.length), ...comments.flatMap((c) => [le32(c.length), c]))
    const picture = bytes(be32(3), be32(9), 'image/png', be32(0), be32(1), be32(1), be32(24), be32(0), be32(PNG.length), PNG)
    const block = (type: number, body: Uint8Array, last = false): Uint8Array =>
      bytes([(last ? 0x80 : 0) | type, (body.length >> 16) & 255, (body.length >> 8) & 255, body.length & 255], body)
    const tags = readTags(buffer(bytes('fLaC', block(0, new Uint8Array(34)), block(4, vorbis), block(6, picture, true))))
    expect(tags.title).toBe('Latch')
    expect(tags.artist).toBe('Disclosure')
    expect(Array.from(tags.picture!.data)).toEqual(PNG)
  })

  it('reads the MP4 item list', () => {
    const atom = (type: string, ...body: Uint8Array[]): Uint8Array => {
      const inner = bytes(...body)
      // Atom types are bytes: '©' is 0xa9, not UTF-8.
      return bytes(be32(8 + inner.length), Array.from(type, (c) => c.charCodeAt(0)), inner)
    }
    const data = (kind: number, payload: Uint8Array): Uint8Array => atom('data', bytes(be32(kind), be32(0), payload))
    const ilst = atom(
      'ilst',
      atom('©nam', data(1, bytes('Jealous'))),
      atom('©ART', data(1, bytes('Mochakk'))),
      atom('covr', data(13, Uint8Array.from(JPEG)))
    )
    const file = bytes(atom('ftyp', bytes('M4A ', be32(0))), atom('moov', atom('udta', atom('meta', bytes(be32(0)), ilst))))
    const tags = readTags(buffer(file))
    expect(tags.title).toBe('Jealous')
    expect(tags.artist).toBe('Mochakk')
    expect(Array.from(tags.picture!.data)).toEqual(JPEG)
  })

  it('finds the ID3 chunk in an AIFF file and ignores anything it cannot read', () => {
    const tag = id3(3, frame(3, 'TIT2', bytes([0], 'Glue')))
    const aiff = bytes('FORM', be32(4 + 8 + tag.length), 'AIFF', 'ID3 ', be32(tag.length), tag)
    expect(readTags(buffer(aiff)).title).toBe('Glue')
    expect(readTags(new ArrayBuffer(16))).toEqual({})
    expect(readTags(buffer(bytes('ID3', [3, 0, 0], safe(50))))).toEqual({})
  })
})
