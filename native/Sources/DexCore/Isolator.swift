import Foundation

/// Three-band DJ isolator maths, ported from `src/shared/isolator.ts` for the
/// engine and the tests. Linkwitz-Riley 24 dB/oct crossovers (two cascaded
/// Butterworth biquads each) split LOW, MID and HIGH; each band gets a gain and
/// the bands are summed. LOW carries the high crossover's all-pass so all three
/// at unity sum flat, and a band at gain 0 is gone without touching the others.
public enum Isolator {
    /// LOW / MID crossover. Kick fundamentals and bass sit below it.
    public static let lowHz = 220.0
    /// MID / HIGH crossover. Hats, air and vocal presence sit above it.
    public static let highHz = 3_500.0
    /// Linear Q of a second-order Butterworth section.
    public static let butterworthQ = 0.5.squareRoot()

    public enum Kind: Sendable { case lowPass, highPass, allPass }
    public struct Section: Sendable {
        public let kind: Kind
        public let frequency: Double
        public let q: Double
    }

    public static func sections() -> (low: [Section], rest: [Section], mid: [Section], high: [Section]) {
        func lr4(_ kind: Kind, _ hz: Double) -> [Section] { [Section(kind: kind, frequency: hz, q: butterworthQ), Section(kind: kind, frequency: hz, q: butterworthQ)] }
        return (lr4(.lowPass, lowHz) + [Section(kind: .allPass, frequency: highHz, q: butterworthQ)],
                lr4(.highPass, lowHz), lr4(.lowPass, highHz), lr4(.highPass, highHz))
    }

    /// One section's complex response at `hz` (RBJ cookbook, bilinear transform).
    public static func response(_ section: Section, hz: Double, sampleRate: Double) -> (re: Double, im: Double) {
        let w0 = 2 * Double.pi * section.frequency / sampleRate
        let c = cos(w0), alpha = sin(w0) / (2 * section.q)
        let b: [Double], a = [1 + alpha, -2 * c, 1 - alpha]
        switch section.kind {
        case .lowPass: b = [(1 - c) / 2, 1 - c, (1 - c) / 2]
        case .highPass: b = [(1 + c) / 2, -(1 + c), (1 + c) / 2]
        case .allPass: b = [1 - alpha, -2 * c, 1 + alpha]
        }
        let w = 2 * Double.pi * hz / sampleRate
        func poly(_ k: [Double]) -> (Double, Double) { (k[0] + k[1] * cos(w) + k[2] * cos(2 * w), -(k[1] * sin(w) + k[2] * sin(2 * w))) }
        let (nr, ni) = poly(b), (dr, di) = poly(a), d = dr * dr + di * di
        return ((nr * dr + ni * di) / d, (ni * dr - nr * di) / d)
    }

    private static func cascade(_ sections: [Section], hz: Double, sampleRate: Double) -> (re: Double, im: Double) {
        var re = 1.0, im = 0.0
        for section in sections {
            let (r, i) = response(section, hz: hz, sampleRate: sampleRate)
            (re, im) = (re * r - im * i, re * i + im * r)
        }
        return (re, im)
    }

    /// Magnitude in dB of the whole isolator at `hz`, with linear band gains.
    public static func responseDb(low: Double, mid: Double, high: Double, hz: Double, sampleRate: Double) -> Double {
        let s = sections()
        let l = cascade(s.low, hz: hz, sampleRate: sampleRate)
        let m = cascade(s.rest + s.mid, hz: hz, sampleRate: sampleRate)
        let h = cascade(s.rest + s.high, hz: hz, sampleRate: sampleRate)
        let re = low * l.re + mid * m.re + high * h.re, im = low * l.im + mid * m.im + high * h.im
        return 20 * log10(max(1e-12, (re * re + im * im).squareRoot()))
    }

    /// A band's linear gain: a kill, or a fader at the −96 dB floor, is silence.
    public static func gain(db: Float, killed: Bool) -> Float {
        killed || !(db > -96) ? 0 : pow(10, db / 20)
    }
}
