interface Job {
  key?: string
  bytes: number
  priority: number
  run: () => Promise<unknown>
  resolve: (value: unknown) => void
  reject: (error: Error) => void
}
export const cancelled = (): Error => Object.assign(new Error('Superseded audio job'), { name: 'AbortError' })

/** One expensive decode/analysis at a time; queued ownership has a byte budget. */
export class WorkQueue {
  private jobs: Job[] = []
  private active = false
  private disposed = false
  constructor(private budget = 512 * 1024 * 1024, private maxJobs = 16) {}
  get queuedBytes(): number { return this.jobs.reduce((sum, job) => sum + job.bytes, 0) }
  cancel(key: string): void {
    const cancelledJobs = this.jobs.filter((job) => job.key === key)
    this.jobs = this.jobs.filter((job) => job.key !== key)
    for (const job of cancelledJobs) job.reject(cancelled())
  }
  run<T>(run: () => Promise<T>, options: { key?: string; bytes: number; priority?: number }): Promise<T> {
    if (this.disposed) return Promise.reject(cancelled())
    if (options.key) this.cancel(options.key)
    if (this.jobs.length >= this.maxJobs || this.queuedBytes + options.bytes > this.budget) return Promise.reject(new Error('Audio memory budget reached. Wait for the current operation to finish.'))
    return new Promise<T>((resolve, reject) => {
      this.jobs.push({ ...options, priority: options.priority ?? 0, run, resolve: resolve as (value: unknown) => void, reject })
      this.jobs.sort((a, b) => b.priority - a.priority)
      this.pump()
    })
  }
  dispose(): void {
    this.disposed = true
    for (const job of this.jobs) job.reject(cancelled())
    this.jobs = []
  }
  private pump(): void {
    if (this.active || this.disposed) return
    const job = this.jobs.shift()
    if (!job) return
    this.active = true
    void Promise.resolve().then(job.run).then(job.resolve, job.reject).finally(() => { this.active = false; this.pump() })
  }
}
