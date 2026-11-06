interface Segment {
  time: number
  position: number
  rate: number
}

/** Integrates scheduled rates without applying a new rate to elapsed audio. */
export class TransportClock {
  private segments: Segment[] = [{ time: 0, position: 0, rate: 0 }]

  positionAt(time: number): number {
    let index = this.segments.length - 1
    while (index > 0 && this.segments[index].time > time) index--
    const segment = this.segments[index]
    return segment.position + (time - segment.time) * segment.rate
  }

  schedule(time: number, rate: number, position = this.positionAt(time)): void {
    this.segments = this.segments.filter((segment) => segment.time < time)
    this.segments.push({ time, position, rate })
    // Keep recent history for position queries while a change is in flight.
    while (this.segments.length > 2 && this.segments[1].time < time - 1) this.segments.shift()
  }

  reset(time: number, position = 0): void {
    this.segments = [{ time, position, rate: 0 }]
  }
}
