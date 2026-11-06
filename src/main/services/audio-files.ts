import { promises as fs } from 'node:fs'
import path from 'node:path'
import { isAudioFile } from '../../shared/types'
import { MAX_AUDIO_BYTES } from './security'

/** Paths are capabilities issued by a picker, real dropped File, or saved library. */
export class AudioFiles {
  private grants = new Map<string, string>()
  has(file: string): boolean { return this.grants.has(file) }
  async restore(file: string): Promise<void> {
    if (!path.isAbsolute(file) || !isAudioFile(file) || file.length > 4096) return
    // A missing saved file stays approved so unrelated edits can still save.
    this.grants.set(file, path.resolve(file))
    await this.grant(file).catch(() => undefined)
  }
  async grant(file: unknown): Promise<string> {
    if (typeof file !== 'string' || file.length > 4096 || !path.isAbsolute(file) || !isAudioFile(file)) throw new Error('Invalid audio file.')
    const canonical = await fs.realpath(file)
    const stat = await fs.stat(canonical)
    if (!stat.isFile() || stat.size > MAX_AUDIO_BYTES) throw new Error('Audio files must be smaller than 512 MiB.')
    this.grants.set(file, canonical)
    return file
  }
  async read(file: unknown): Promise<ArrayBuffer | null> {
    if (typeof file !== 'string' || !this.grants.has(file)) throw new Error('This audio file has not been approved.')
    try {
      // Resolve again to reject symlink replacement after the grant.
      const canonical = await fs.realpath(file)
      if (canonical !== this.grants.get(file)) throw new Error('The audio path changed. Add the file again.')
      const handle = await fs.open(canonical, 'r')
      try {
        const stat = await handle.stat()
        if (!stat.isFile() || stat.size > MAX_AUDIO_BYTES) throw new Error('Audio file exceeds the size limit.')
        // Fixed allocation also bounds files which grow after fstat.
        const bytes = new Uint8Array(stat.size)
        let offset = 0
        while (offset < bytes.length) {
          const { bytesRead } = await handle.read(bytes, offset, bytes.length - offset, offset)
          if (!bytesRead) break
          offset += bytesRead
        }
        return bytes.buffer.slice(0, offset)
      } finally { await handle.close() }
    } catch (error) {
      if (['ENOENT', 'ENOTDIR'].includes((error as NodeJS.ErrnoException).code ?? '')) return null
      throw error
    }
  }
}
