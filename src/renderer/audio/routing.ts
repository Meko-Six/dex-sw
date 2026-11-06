/**
 * Output routing.
 *
 * - `split`: mono master on the left ear, mono cue on the right — works on any
 *   stereo output with no setup. Default.
 * - `multichannel`: master on channels 1/2, cue on 3/4 for an Aggregate Device
 *   (e.g. BlackHole + headphones) so you can pre-listen properly.
 */
export type OutputMode = 'split' | 'multichannel'

export class OutputRouter {
  /** Crossfaded deck sum goes here. */
  readonly masterIn: GainNode
  /** Cue bus (deck taps + master blend) goes here. */
  readonly cueIn: GainNode
  /** Post-limiter master, for metering and the cue master blend. */
  readonly masterOut: GainNode
  readonly analyser: AnalyserNode

  private readonly context: BaseAudioContext
  private readonly limiter: DynamicsCompressorNode
  private readonly masterGain: GainNode
  private readonly cueGain: GainNode
  private readonly cueMixGain: GainNode
  private readonly cueMasterGain: GainNode
  private mode: OutputMode = 'split'
  private splitNodes: AudioNode[] = []
  private outputEdges: [AudioNode, AudioNode][] = []
  private meterBuffer = new Float32Array(1024)

  constructor(context: BaseAudioContext) {
    this.context = context
    this.masterIn = context.createGain()
    this.cueIn = context.createGain()
    this.masterOut = context.createGain()
    this.masterGain = context.createGain()
    this.cueGain = context.createGain()
    this.cueMixGain = context.createGain()
    this.cueMasterGain = context.createGain()

    this.limiter = context.createDynamicsCompressor()
    this.limiter.threshold.value = -3
    this.limiter.knee.value = 0
    this.limiter.ratio.value = 20
    this.limiter.attack.value = 0.003
    this.limiter.release.value = 0.15

    this.analyser = context.createAnalyser()
    this.analyser.fftSize = 1024
    this.analyser.smoothingTimeConstant = 0.4

    this.masterIn.connect(this.masterGain)
    this.masterGain.connect(this.limiter)
    this.limiter.connect(this.masterOut)
    this.masterOut.connect(this.analyser)

    // Cue bus: deck taps blended with a little master, then the cue volume.
    this.cueIn.connect(this.cueMixGain)
    this.masterOut.connect(this.cueMasterGain)
    this.cueMixGain.connect(this.cueGain)
    this.cueMasterGain.connect(this.cueGain)

    this.masterGain.gain.value = 0.85
    this.cueGain.gain.value = 1
    this.setCueMix(0.85)
    this.rebuildOutputs()
  }

  setMasterVolume(value: number): void {
    this.masterGain.gain.setTargetAtTime(Math.max(0, Math.min(1.5, value)), this.context.currentTime, 0.02)
  }

  /** 0 = cue program only, 1 = cue bus only. */
  setCueMix(mix: number): void {
    const v = Math.max(0, Math.min(1, mix))
    const now = this.context.currentTime
    this.cueMixGain.gain.setTargetAtTime(v, now, 0.02)
    this.cueMasterGain.gain.setTargetAtTime(1 - v, now, 0.02)
  }

  setCueVolume(value: number): void {
    this.cueGain.gain.setTargetAtTime(Math.max(0, Math.min(1.5, value)), this.context.currentTime, 0.02)
  }

  setMode(mode: OutputMode): void {
    if (mode === this.mode) return
    this.mode = mode
    this.rebuildOutputs()
  }

  get currentMode(): OutputMode {
    return this.mode
  }

  /** Live master level in dBFS, for the meter. */
  readLevelDb(): number {
    const buffer = this.meterBuffer
    this.analyser.getFloatTimeDomainData(buffer)
    let sum = 0
    for (let i = 0; i < buffer.length; i++) sum += buffer[i] * buffer[i]
    const rms = Math.sqrt(sum / buffer.length)
    return 20 * Math.log10(Math.max(1e-6, rms))
  }

  dispose(): void {
    for (const [source, target] of this.outputEdges) {
      try { source.disconnect(target) } catch { /* already disconnected */ }
    }
    for (const node of [...this.splitNodes, this.masterIn, this.cueIn, this.masterOut, this.masterGain, this.cueGain, this.cueMixGain, this.cueMasterGain, this.limiter, this.analyser]) node.disconnect()
    this.outputEdges = []
    this.splitNodes = []
  }

  private mono(node: AudioNode): GainNode {
    const gain = this.context.createGain()
    gain.channelCount = 1
    gain.channelCountMode = 'explicit'
    gain.channelInterpretation = 'speakers'
    node.connect(gain)
    this.outputEdges.push([node, gain])
    return gain
  }

  private rebuildOutputs(): void {
    for (const [source, target] of this.outputEdges) {
      try { source.disconnect(target) } catch { /* already disconnected */ }
    }
    this.outputEdges = []
    for (const node of this.splitNodes) {
      try {
        node.disconnect()
      } catch {
        /* already disconnected */
      }
    }
    this.splitNodes = []

    const destination = this.context.destination
    if (this.mode === 'split') {
      destination.channelCount = 2
      const masterMono = this.mono(this.masterOut)
      const cueMono = this.mono(this.cueGain)
      const merger = this.context.createChannelMerger(2)
      masterMono.connect(merger, 0, 0)
      cueMono.connect(merger, 0, 1)
      merger.connect(destination)
      this.splitNodes.push(masterMono, cueMono, merger)
      return
    }

    const maxChannels = destination.maxChannelCount ?? 2
    if (maxChannels < 4) {
      // Hardware cannot take 4 channels; fall back to split cue rather than
      // silently folding the cue into the master.
      this.mode = 'split'
      this.rebuildOutputs()
      return
    }
    destination.channelCount = 4
    destination.channelCountMode = 'explicit'
    const merger = this.context.createChannelMerger(4)
    const masterSplit = this.context.createChannelSplitter(2)
    const cueSplit = this.context.createChannelSplitter(2)
    this.masterOut.connect(masterSplit)
    this.cueGain.connect(cueSplit)
    this.outputEdges.push([this.masterOut, masterSplit], [this.cueGain, cueSplit])
    masterSplit.connect(merger, 0, 0)
    masterSplit.connect(merger, 1, 1)
    cueSplit.connect(merger, 0, 2)
    cueSplit.connect(merger, 1, 3)
    merger.connect(destination)
    this.splitNodes.push(merger, masterSplit, cueSplit)
  }
}
