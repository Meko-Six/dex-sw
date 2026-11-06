import { describe, expect, it } from 'vitest'
import { camelotFor, chromaVector, estimateKey, estimateKeyFromChroma, harmonicNeighbours, keyName } from '../src/shared/key'
import { renderChord } from '../src/shared/synth'

const SR = 22050

describe('Camelot mapping', () => {
  it('maps the reference keys correctly', () => {
    expect(camelotFor(0, 'major')).toBe('8B') // C major
    expect(camelotFor(9, 'minor')).toBe('8A') // A minor
    expect(camelotFor(6, 'minor')).toBe('11A') // F# minor
    expect(camelotFor(2, 'major')).toBe('10B') // D major
    expect(camelotFor(1, 'minor')).toBe('12A') // C# minor
    expect(camelotFor(11, 'major')).toBe('1B') // B major
  })

  it('covers all 24 keys without duplicates', () => {
    const codes = new Set<string>()
    for (let tonic = 0; tonic < 12; tonic++) {
      codes.add(camelotFor(tonic, 'major'))
      codes.add(camelotFor(tonic, 'minor'))
    }
    expect(codes.size).toBe(24)
  })

  it('names keys', () => {
    expect(keyName(6, 'minor')).toBe('F# minor')
    expect(keyName(0, 'major')).toBe('C major')
  })

  it('returns harmonic neighbours on the wheel', () => {
    expect(harmonicNeighbours('8A')).toEqual({ relative: '8B', previous: '7A', next: '9A' })
    expect(harmonicNeighbours('1B')).toEqual({ relative: '1A', previous: '12B', next: '2B' })
    expect(harmonicNeighbours('nope')).toBeNull()
  })
})

describe('chromaVector', () => {
  it('puts energy on the three notes of a triad', () => {
    const audio = renderChord({ root: 0, mode: 'major', seconds: 4, sampleRate: SR })
    const chroma = chromaVector(audio, SR)
    const order = [...chroma.keys()].sort((a, b) => chroma[b] - chroma[a])
    expect(new Set(order.slice(0, 3))).toEqual(new Set([0, 4, 7]))
  })

  it('does not take the slope below the band for a note at its edge', () => {
    // A loud 90 Hz bass sits under the 110 Hz band edge. Its skirt falls away
    // through the first bin (107.7 Hz, which rounds to A). Compared with an
    // unfilled zero below it, that bin read as a peak in every frame and took
    // the whole vector for A; against its real neighbour it is just slope.
    const bass = new Float32Array(SR * 4)
    for (let i = 0; i < bass.length; i++) bass[i] = 0.8 * Math.sin((2 * Math.PI * 90 * i) / SR)
    const chroma = chromaVector(bass, SR)
    expect(chroma[9]).toBeLessThan(0.2)
  })

  it('returns an all-zero vector for silence', () => {
    const chroma = chromaVector(new Float32Array(SR * 2), SR)
    expect([...chroma].every((value) => value === 0)).toBe(true)
  })
})

describe('estimateKey', () => {
  const cases: Array<{ root: number; mode: 'major' | 'minor'; camelot: string }> = [
    { root: 0, mode: 'major', camelot: '8B' },
    { root: 9, mode: 'minor', camelot: '8A' },
    { root: 6, mode: 'minor', camelot: '11A' },
    { root: 7, mode: 'major', camelot: '9B' },
    { root: 4, mode: 'minor', camelot: '9A' },
    { root: 3, mode: 'major', camelot: '5B' }
  ]

  for (const { root, mode, camelot } of cases) {
    it(`identifies ${keyName(root, mode)} from a pure triad`, () => {
      const audio = renderChord({ root, mode, seconds: 6, sampleRate: SR, partials: 1 })
      const estimate = estimateKey(audio, SR)
      expect(estimate.camelot).toBe(camelot)
      expect(estimate.confidence).toBeGreaterThan(0.3)
      expect(estimate.candidates).toHaveLength(3)
    })
  }

  it('calls a track with no third minor, and keeps a clear major third major', () => {
    // C, D, F, G, A, B: a C major scale with its third taken out.
    const noThird = new Float32Array(12)
    for (const pitch of [0, 2, 5, 7, 9, 11]) noThird[pitch] = 1
    noThird[0] = 2
    noThird[7] = 1.5
    expect(estimateKeyFromChroma(noThird).key).toBe('C minor')
    expect(estimateKeyFromChroma(noThird).candidates).toHaveLength(3)

    const withThird = Float32Array.from(noThird)
    withThird[4] = 1.2
    expect(estimateKeyFromChroma(withThird).key).toBe('C major')
  })

  it('survives harmonic-rich triads', () => {
    const audio = renderChord({ root: 6, mode: 'minor', seconds: 6, sampleRate: SR, partials: 4 })
    const estimate = estimateKey(audio, SR)
    expect(estimate.key).toBe('F# minor')
  })

  it('ignores a kick drum fundamental that is not in the key', () => {
    // A-ish kick (55 Hz) under an F# minor chord must not turn the key into A.
    const chord = renderChord({ root: 6, mode: 'minor', seconds: 6, sampleRate: SR })
    const withKick = Float32Array.from(chord)
    for (let i = 0; i < withKick.length; i++) {
      const t = i / SR
      withKick[i] += Math.sin(2 * Math.PI * 48 * t) * 0.35 * Math.exp(-((t % 0.5) * 8))
    }
    const estimate = estimateKey(withKick, SR)
    expect(estimate.key).toBe('F# minor')
  })

  it('reports low confidence rather than a confident wrong answer on noise', () => {
    // Seeded, so the test is the same every run: over 100 seeds the
    // confidence on noise has a median of 0.16 and tops out near 0.5.
    for (const seed of [1, 7, 42, 1234, 99991]) {
      let state = seed
      const random = (): number => (state = (state * 1664525 + 1013904223) >>> 0) / 4294967296
      const noise = new Float32Array(SR * 6)
      for (let i = 0; i < noise.length; i++) noise[i] = (random() * 2 - 1) * 0.3
      expect(estimateKey(noise, SR).confidence).toBeLessThan(0.6)
    }
  })
})
