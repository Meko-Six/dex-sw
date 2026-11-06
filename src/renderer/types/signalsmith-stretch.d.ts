declare module 'signalsmith-stretch' {
  export interface StretchScheduleOptions {
    /** Audio-context time at which the change takes effect. */
    output?: number
    active?: boolean
    /** Position within the input buffer, in seconds. */
    input?: number
    /** Playback rate (1 = original tempo). */
    rate?: number
    semitones?: number
    tonalityHz?: number
    formantSemitones?: number
    formantCompensation?: boolean
    formantBaseHz?: number
    loopStart?: number
    loopEnd?: number
  }

  export interface StretchConfigureOptions {
    blockMs?: number
    intervalMs?: number
    splitComputation?: boolean
    preset?: 'default' | 'cheaper'
  }

  export interface StretchNode extends AudioWorkletNode {
    /** Worklet read-head position in seconds, including processing lookahead. */
    readonly inputTime: number
    start(when?: number): Promise<void>
    stop(when?: number): Promise<void>
    schedule(options: StretchScheduleOptions): Promise<void>
    addBuffers(buffers: Float32Array[], transfer?: ArrayBuffer[]): Promise<number>
    dropBuffers(toSeconds?: number): Promise<number | { start: number; end: number }>
    latency(): Promise<number>
    configure(options: StretchConfigureOptions): Promise<void>
    setUpdateInterval(seconds: number, callback?: (time: number) => void): Promise<void>
  }

  export default function SignalsmithStretch(
    context: BaseAudioContext,
    options?: AudioWorkletNodeOptions
  ): Promise<StretchNode>
}
