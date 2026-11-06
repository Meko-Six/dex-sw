import { promises as fs } from 'node:fs'
import path from 'node:path'
import { randomUUID } from 'node:crypto'
import { MAX_LIBRARY_BYTES, parseLibrary } from '../../shared/library-schema'

/** One writer owns atomic replacement and the last known good revision. */
export class LibraryRepository {
  private tail: Promise<void> = Promise.resolve()
  private writable = false
  private loaded = false
  constructor(readonly target: string) {}

  async load(): Promise<string | null> {
    await this.tail
    try {
      const json = await this.read(this.target)
      parseLibrary(json)
      this.loaded = this.writable = true
      return json
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === 'ENOENT') {
        this.loaded = this.writable = true
        return null
      }
      // Preserve the primary before permitting recovery to overwrite it.
      try {
        const backup = await this.read(`${this.target}.bak`)
        parseLibrary(backup)
        await fs.copyFile(this.target, `${this.target}.damaged-${Date.now()}`)
        await this.atomicWrite(this.target, backup)
        this.loaded = this.writable = true
        return backup
      } catch {
        this.writable = false
        throw new Error('The saved library could not be read. Its files have been preserved; saving is disabled to protect them.')
      }
    }
  }

  save(json: string): Promise<void> {
    // Validate at admission, before scheduling any I/O or overwriting a backup.
    parseLibrary(json)
    const write = this.tail.catch(() => undefined).then(async () => {
      if (!this.loaded || !this.writable) throw new Error('Load a valid library before saving.')
      await fs.mkdir(path.dirname(this.target), { recursive: true })
      try {
        const previous = await this.read(this.target)
        parseLibrary(previous)
        await this.atomicWrite(`${this.target}.bak`, previous)
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error
      }
      await this.atomicWrite(this.target, json)
    })
    this.tail = write
    return write
  }

  async flush(): Promise<void> { await this.tail }

  private async read(target: string): Promise<string> {
    const handle = await fs.open(target, 'r')
    try {
      const stat = await handle.stat()
      if (stat.size > MAX_LIBRARY_BYTES) throw new Error('The saved library exceeds the size limit.')
      return await handle.readFile('utf8')
    } finally { await handle.close() }
  }

  private async atomicWrite(target: string, json: string): Promise<void> {
    const temp = `${target}.${randomUUID()}.tmp`
    try {
      const handle = await fs.open(temp, 'wx', 0o600)
      try { await handle.writeFile(json, 'utf8'); await handle.sync() } finally { await handle.close() }
      await fs.rename(temp, target)
      // Make the rename durable where the filesystem supports directory fsync.
      const directory = await fs.open(path.dirname(target), 'r')
      try { await directory.sync().catch(() => undefined) } finally { await directory.close() }
    } finally {
      await fs.rm(temp, { force: true }).catch(() => undefined)
    }
  }
}
