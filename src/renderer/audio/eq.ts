import { dbToGain, EQ_KILL_DB, eqDbFromKnob, FILTER_BASE_Q, FILTER_FLAT_HZ, filterSetting } from '../../shared/curves'
import { isolatorSections, webAudioQ, type IsoBiquad } from '../../shared/isolator'

export type EqBand = 'low' | 'mid' | 'high'

/**
 * The deck's tone section: a three-band isolator (see shared/isolator.ts)
 * followed by a one-knob sweep filter. Linkwitz-Riley crossovers split the
 * signal into LOW / MID / HIGH, each band gets a gain, and the bands are
 * summed, so all three at unity are flat and a kill removes one band without
 * touching the other two. EQ knobs run -1 … +1 with full-left as a kill (see
 * eqDbFromKnob); a kill is a true mute (gain 0), not a deep cut. The filter is
 * transparent at centre and feeds the crossfader and cue buses only after the
 * EQ stage.
 */
export class EqChain {
  readonly input: GainNode
  readonly output: AudioNode
  private readonly gains: Record<EqBand, GainNode>
  private readonly sum: GainNode
  private readonly filter: BiquadFilterNode
  private readonly nodes: AudioNode[] = []
  private readonly context: BaseAudioContext

  constructor(context: BaseAudioContext) {
    this.context = context
    this.input = context.createGain()
    this.sum = context.createGain()
    this.gains = { low: context.createGain(), mid: context.createGain(), high: context.createGain() }

    // LOW: low-pass at the low crossover, then the phase-matching all-pass.
    // MID and HIGH share the high-pass at the low crossover, then split.
    const sections = isolatorSections()
    const low = this.chain(sections.low)
    const rest = this.chain(sections.rest)
    const mid = this.chain(sections.mid)
    const high = this.chain(sections.high)
    this.input.connect(low.first)
    low.last.connect(this.gains.low)
    this.input.connect(rest.first)
    rest.last.connect(mid.first)
    rest.last.connect(high.first)
    mid.last.connect(this.gains.mid)
    high.last.connect(this.gains.high)
    for (const gain of Object.values(this.gains)) gain.connect(this.sum)

    this.filter = context.createBiquadFilter()
    this.filter.type = 'lowpass'
    this.filter.frequency.value = FILTER_FLAT_HZ
    this.filter.Q.value = FILTER_BASE_Q

    this.sum.connect(this.filter)
    this.output = this.filter
  }

  /** Builds a cascade of biquads and returns its two ends. */
  private chain(sections: IsoBiquad[]): { first: BiquadFilterNode; last: BiquadFilterNode } {
    const filters = sections.map((section) => {
      const filter = this.context.createBiquadFilter()
      filter.type = section.type
      filter.frequency.value = section.frequency
      filter.Q.value = webAudioQ(section)
      this.nodes.push(filter)
      return filter
    })
    for (let i = 1; i < filters.length; i++) filters[i - 1].connect(filters[i])
    return { first: filters[0], last: filters[filters.length - 1] }
  }

  /** Knob form (−1 … +1, kill at full left), kept for the self-test's measurements. */
  setBand(band: EqBand, knob: number): void {
    const db = eqDbFromKnob(knob)
    this.setBandGain(band, db <= EQ_KILL_DB ? 0 : dbToGain(db))
  }

  /** Linear band gain: the mixer's cut-only faders and kills land here. */
  setBandGain(band: EqBand, gain: number): void {
    const param = this.gains[band].gain
    const now = this.context.currentTime
    if (typeof param.setTargetAtTime === 'function') {
      param.setTargetAtTime(gain, now, 0.02)
    } else {
      param.value = gain
    }
  }

  /** One-knob sweep filter: left is low-pass, right is high-pass, centre off. */
  setFilter(knob: number): void {
    const setting = filterSetting(knob)
    const now = this.context.currentTime
    if (this.filter.type !== setting.type) this.filter.type = setting.type
    const frequency = this.filter.frequency
    const q = this.filter.Q
    if (typeof frequency.setTargetAtTime === 'function') {
      frequency.setTargetAtTime(setting.frequency, now, 0.02)
      q.setTargetAtTime(setting.q, now, 0.02)
    } else {
      frequency.value = setting.frequency
      q.value = setting.q
    }
  }

  disconnect(): void {
    this.input.disconnect()
    for (const node of this.nodes) node.disconnect()
    for (const gain of Object.values(this.gains)) gain.disconnect()
    this.sum.disconnect()
    this.filter.disconnect()
  }
}
