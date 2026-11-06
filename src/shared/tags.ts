/**
 * Artist, title and cover art from an audio file's tags, for the track
 * windows. Covers what a DJ crate holds: ID3v2 (MP3, and the ID3 chunk in
 * AIFF and WAV), FLAC's Vorbis comments and PICTURE block, and the MP4 item
 * list (M4A / AAC). Anything else, or a malformed tag, reads as empty.
 */

export interface TagPicture {
  mime: string
  data: Uint8Array
}

export interface Tags {
  artist?: string
  title?: string
  picture?: TagPicture
}

export function readTags(buffer: ArrayBuffer): Tags {
  try {
    const bytes = new Uint8Array(buffer)
    if (ascii(bytes, 0, 3) === 'ID3') return readId3(bytes, 0)
    if (ascii(bytes, 0, 4) === 'fLaC') return readFlac(bytes)
    if (ascii(bytes, 4, 4) === 'ftyp') return readMp4(bytes)
    if (ascii(bytes, 0, 4) === 'FORM' || ascii(bytes, 0, 4) === 'RIFF') return readChunks(bytes)
  } catch {
    // A truncated or odd tag is not worth failing a load over.
  }
  return {}
}

const ascii = (bytes: Uint8Array, at: number, length: number): string =>
  String.fromCharCode(...bytes.subarray(at, at + length))

const u32be = (b: Uint8Array, i: number): number => ((b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3]) >>> 0
const u32le = (b: Uint8Array, i: number): number => (b[i] | (b[i + 1] << 8) | (b[i + 2] << 16) | (b[i + 3] << 24)) >>> 0
const synchsafe = (b: Uint8Array, i: number): number => (b[i] << 21) | (b[i + 1] << 14) | (b[i + 2] << 7) | b[i + 3]

const clean = (text: string): string | undefined => {
  const value = text.replace(/\0+$/, '').trim()
  return value || undefined
}

function decodeText(bytes: Uint8Array, encoding: number): string {
  if (encoding === 1 || encoding === 2) {
    let little = encoding === 1
    let start = 0
    if (encoding === 1 && bytes.length >= 2) {
      if (bytes[0] === 0xff && bytes[1] === 0xfe) start = 2
      else if (bytes[0] === 0xfe && bytes[1] === 0xff) {
        little = false
        start = 2
      }
    }
    return new TextDecoder(little ? 'utf-16le' : 'utf-16be').decode(bytes.subarray(start, start + ((bytes.length - start) & ~1)))
  }
  return new TextDecoder(encoding === 3 ? 'utf-8' : 'latin1').decode(bytes)
}

/** Index of the terminator that ends an encoded string, and its width. */
function terminator(bytes: Uint8Array, from: number, encoding: number): [number, number] {
  if (encoding === 1 || encoding === 2) {
    for (let i = from; i + 1 < bytes.length; i += 2) if (bytes[i] === 0 && bytes[i + 1] === 0) return [i, 2]
    return [bytes.length, 0]
  }
  const i = bytes.indexOf(0, from)
  return i < 0 ? [bytes.length, 0] : [i, 1]
}

function readId3(bytes: Uint8Array, at: number): Tags {
  const major = bytes[at + 3]
  const flags = bytes[at + 5]
  const end = Math.min(bytes.length, at + 10 + synchsafe(bytes, at + 6))
  const v22 = major === 2
  const idLength = v22 ? 3 : 4
  const headerLength = v22 ? 6 : 10
  let i = at + 10
  // An extended header (v2.3 / v2.4) sits between the tag header and the frames.
  if (!v22 && flags & 0x40) i += major === 4 ? synchsafe(bytes, i) : u32be(bytes, i) + 4
  const tags: Tags = {}
  while (i + headerLength <= end) {
    const id = ascii(bytes, i, idLength)
    if (!/^[A-Z0-9]+$/.test(id)) break
    const size = v22
      ? (bytes[i + 3] << 16) | (bytes[i + 4] << 8) | bytes[i + 5]
      : major === 4
        ? synchsafe(bytes, i + 4)
        : u32be(bytes, i + 4)
    const body = bytes.subarray(i + headerLength, Math.min(end, i + headerLength + size))
    i += headerLength + size
    if (body.length === 0) continue
    if (id === 'TIT2' || id === 'TT2') tags.title ??= clean(decodeText(body.subarray(1), body[0]))
    else if (id === 'TPE1' || id === 'TP1') tags.artist ??= clean(decodeText(body.subarray(1), body[0]))
    else if ((id === 'APIC' || id === 'PIC') && !tags.picture) {
      const encoding = body[0]
      let mime: string
      let p: number
      if (v22) {
        const format = ascii(body, 1, 3).toUpperCase()
        mime = format === 'PNG' ? 'image/png' : 'image/jpeg'
        p = 4
      } else {
        const [mimeEnd] = terminator(body, 1, 0)
        mime = ascii(body, 1, mimeEnd - 1) || 'image/jpeg'
        p = mimeEnd + 1
      }
      const [descEnd, width] = terminator(body, p + 1, encoding)
      const data = body.subarray(descEnd + width)
      if (data.length > 0) tags.picture = { mime: normaliseMime(mime, data), data }
    }
  }
  return tags
}

function readFlac(bytes: Uint8Array): Tags {
  const tags: Tags = {}
  let i = 4
  while (i + 4 <= bytes.length) {
    const header = bytes[i]
    const type = header & 0x7f
    const length = (bytes[i + 1] << 16) | (bytes[i + 2] << 8) | bytes[i + 3]
    const block = bytes.subarray(i + 4, i + 4 + length)
    if (type === 4) {
      const comments = vorbisComments(block)
      tags.title ??= comments.title
      tags.artist ??= comments.artist
    }
    else if (type === 6 && !tags.picture) {
      let p = 4
      const mimeLength = u32be(block, p)
      const mime = ascii(block, p + 4, mimeLength)
      p += 4 + mimeLength
      p += 4 + u32be(block, p) + 16
      const dataLength = u32be(block, p)
      const data = block.subarray(p + 4, p + 4 + dataLength)
      if (data.length > 0) tags.picture = { mime: normaliseMime(mime, data), data }
    }
    i += 4 + length
    if (header & 0x80) break
  }
  return tags
}

function vorbisComments(block: Uint8Array): Tags {
  const tags: Tags = {}
  const utf8 = new TextDecoder('utf-8')
  let p = 4 + u32le(block, 0)
  const count = u32le(block, p)
  p += 4
  for (let n = 0; n < count && p + 4 <= block.length; n++) {
    const length = u32le(block, p)
    const entry = utf8.decode(block.subarray(p + 4, p + 4 + length))
    p += 4 + length
    const eq = entry.indexOf('=')
    const key = entry.slice(0, eq).toUpperCase()
    const value = clean(entry.slice(eq + 1))
    if (key === 'TITLE') tags.title ??= value
    else if (key === 'ARTIST') tags.artist ??= value
  }
  return tags
}

const MP4_CONTAINERS = new Set(['moov', 'udta', 'meta', 'ilst'])

function readMp4(bytes: Uint8Array): Tags {
  const tags: Tags = {}
  const walk = (from: number, to: number): void => {
    let i = from
    while (i + 8 <= to) {
      let size = u32be(bytes, i)
      const type = ascii(bytes, i + 4, 4)
      let header = 8
      if (size === 1) {
        size = u32be(bytes, i + 8) * 2 ** 32 + u32be(bytes, i + 12)
        header = 16
      } else if (size === 0) size = to - i
      if (size < header) return
      const end = Math.min(to, i + size)
      if (MP4_CONTAINERS.has(type)) walk(i + header + (type === 'meta' ? 4 : 0), end)
      else if (type === '©nam' || type === '©ART' || type === 'covr') {
        const data = mp4Data(i + header, end)
        if (data) {
          if (type === 'covr') tags.picture ??= { mime: normaliseMime(data.kind === 14 ? 'image/png' : 'image/jpeg', data.body), data: data.body }
          else if (type === '©nam') tags.title ??= clean(new TextDecoder('utf-8').decode(data.body))
          else tags.artist ??= clean(new TextDecoder('utf-8').decode(data.body))
        }
      }
      i = end
    }
  }
  const mp4Data = (from: number, to: number): { kind: number; body: Uint8Array } | null => {
    if (from + 16 > to || ascii(bytes, from + 4, 4) !== 'data') return null
    const size = Math.min(to - from, u32be(bytes, from))
    return { kind: u32be(bytes, from + 8) & 0xffffff, body: bytes.subarray(from + 16, from + size) }
  }
  walk(0, bytes.length)
  return tags
}

/** AIFF and WAV keep ID3 in a chunk of their own. */
function readChunks(bytes: Uint8Array): Tags {
  const big = ascii(bytes, 0, 4) === 'FORM'
  let i = 12
  while (i + 8 <= bytes.length) {
    const id = ascii(bytes, i, 4)
    const size = big ? u32be(bytes, i + 4) : u32le(bytes, i + 4)
    if (id.toUpperCase() === 'ID3 ' && ascii(bytes, i + 8, 3) === 'ID3') return readId3(bytes, i + 8)
    i += 8 + size + (size & 1)
  }
  return {}
}

/** Trust the bytes over the label: many taggers write image/jpg or nothing. */
function normaliseMime(mime: string, data: Uint8Array): string {
  if (data[0] === 0x89 && data[1] === 0x50) return 'image/png'
  if (data[0] === 0xff && data[1] === 0xd8) return 'image/jpeg'
  return /^image\//.test(mime) ? mime.replace('image/jpg', 'image/jpeg') : 'image/jpeg'
}
