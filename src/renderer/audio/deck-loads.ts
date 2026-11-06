/** Per-deck latest-request ordering, with serialized worklet commits. */
export class DeckLoads {
  private versions = [0, 0]
  private tails: Promise<unknown>[] = [Promise.resolve(), Promise.resolve()]

  request(index: 0 | 1): number { return ++this.versions[index] }
  current(index: 0 | 1, version: number): boolean { return this.versions[index] === version }
  invalidate(): void { this.versions[0]++; this.versions[1]++ }

  async commit(index: 0 | 1, version: number, action: () => Promise<void>): Promise<boolean> {
    let committed = false
    const next = this.tails[index].catch(() => undefined).then(async () => {
      if (!this.current(index, version)) return
      await action()
      committed = true
    })
    this.tails[index] = next
    await next
    return committed
  }
}
