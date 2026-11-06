import { pathToFileURL } from 'node:url'

export function trustedDocument(url: string, entry: string, devUrl?: string): boolean {
  try {
    const candidate = new URL(url)
    const expected = new URL(devUrl ?? pathToFileURL(entry).href)
    // Hash navigation is UI state; another document/path is never the app.
    return candidate.origin === expected.origin && candidate.protocol === expected.protocol && candidate.host === expected.host && candidate.pathname === expected.pathname && candidate.search === expected.search
  } catch { return false }
}

export function externalUrl(url: unknown): url is string {
  if (typeof url !== 'string' || url.length > 8192) return false
  try { const parsed = new URL(url); return ['https:', 'http:'].includes(parsed.protocol) && !parsed.username && !parsed.password } catch { return false }
}

export const MAX_AUDIO_BYTES = 512 * 1024 * 1024
export function validAudioBytes(bytes: unknown): bytes is ArrayBuffer {
  return bytes instanceof ArrayBuffer && bytes.byteLength > 0 && bytes.byteLength <= MAX_AUDIO_BYTES
}
