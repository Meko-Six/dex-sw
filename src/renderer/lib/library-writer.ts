/** Coalesce changes while one acknowledged save is in flight. Retain failures for retry. */
export class LibraryWriter {
  private latest: string | null = null
  private running: Promise<void> | null = null
  constructor(private save: (json: string) => Promise<void>, private status: (state: 'saved' | 'saving' | 'error', error?: unknown) => void) {}
  enqueue(json: string): void {
    this.latest = json
    void this.flush().catch(() => undefined)
  }
  async flush(): Promise<void> {
    if (!this.running && this.latest !== null) {
      this.running = Promise.resolve().then(() => {
        this.status('saving')
        return this.drain()
      }).finally(() => { this.running = null })
    }
    await this.running
    // Include a mutation caused by a save-status subscriber before closing.
    if (this.latest !== null) await this.flush()
  }
  private async drain(): Promise<void> {
    try {
      while (this.latest !== null) {
        const json = this.latest
        await this.save(json)
        if (this.latest === json) this.latest = null
      }
      this.status('saved')
    } catch (error) {
      this.status('error', error)
      throw error
    }
  }
}
