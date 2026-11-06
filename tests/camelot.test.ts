import { describe, expect, it } from 'vitest'
import { camelotColour, camelotRank, compatibleKeys, parseCamelot } from '../src/shared/camelot'

describe('parseCamelot', () => {
  it('reads codes loosely and rejects anything off the wheel', () => {
    expect(parseCamelot(' 4a ')).toEqual({ number: 4, ring: 'A' })
    expect(parseCamelot('12B')).toEqual({ number: 12, ring: 'B' })
    expect(parseCamelot('13A')).toBeNull()
    expect(parseCamelot('0B')).toBeNull()
    expect(parseCamelot('F minor')).toBeNull()
    expect(parseCamelot(undefined)).toBeNull()
  })
})

describe('compatibleKeys', () => {
  it('gives the key, its neighbours on the ring and its relative', () => {
    expect(compatibleKeys('4A')).toEqual(['4A', '3A', '5A', '4B'])
    expect(compatibleKeys('8b')).toEqual(['8B', '7B', '9B', '8A'])
  })

  it('wraps round the top of the wheel', () => {
    expect(compatibleKeys('12A')).toEqual(['12A', '11A', '1A', '12B'])
    expect(compatibleKeys('1B')).toEqual(['1B', '12B', '2B', '1A'])
  })
})

describe('camelotRank and colours', () => {
  it('orders round the wheel with unknown keys last', () => {
    const codes = ['9A', undefined, '1B', '12A', '1A', '4B']
    expect([...codes].sort((a, b) => camelotRank(a) - camelotRank(b))).toEqual(['1A', '1B', '4B', '9A', '12A', undefined])
  })

  it('uses the pastel tone for minor and the saturated one for major', () => {
    expect(camelotColour('8A')).toBe('#f0a9ec')
    expect(camelotColour('8B')).toBe('#e877e4')
    expect(camelotColour('nope')).toBeNull()
  })
})
