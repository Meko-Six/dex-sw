import Foundation

/// Compact streaming features; audio PCM never enters or survives this model.
public struct RhythmFeatures: Sendable {
    public var low: [Float] = []
    public var mid: [Float] = []
    public var high: [Float] = []
    public var flux: [Float] = []
    public var lowFlux: [Float] = []
    public var frameSeconds: Double
    public var rms: Double = 0
    public var duration: Double = 0
    public init(frameSeconds: Double) { self.frameSeconds = frameSeconds }
}

public struct DetectedGrid: Codable, Equatable, Sendable {
    public let grid: BeatGrid?
    public let uncertain: Bool
    public let alternatives: [Alternative]
    public struct Alternative: Codable, Equatable, Sendable {
        public let bpm: Double
        public let offsetMs: Double
        public let relation: String
        public let salience: Double
    }
    public init(grid: BeatGrid?, uncertain: Bool, alternatives: [Alternative]) {
        self.grid = grid
        self.uncertain = uncertain
        self.alternatives = alternatives
    }
    public static let unavailable = DetectedGrid(grid: nil, uncertain: true, alternatives: [])
}

/// Port of the reference spectral-flux / global-comb / folded-kick detector.
/// Defaults preserve its 70–180 BPM interpretation window and 122 BPM prior.
public enum BeatDetector {
    private static let fps = 11025.0 / 128
    private static func clamp(_ value: Double) -> Double { min(1, max(0, value)) }
    private static func wrap(_ value: Double, _ period: Double) -> Double {
        value - floor(value / period) * period
    }
    private static func round(_ value: Double) -> Double { floor(value + 0.5) }
    private static func foldBPM(_ value: Double) -> Double {
        var value = value
        while value > 0 && value < 70 { value *= 2 }
        while value > 180 { value /= 2 }
        return value
    }
    public static func detect(_ features: RhythmFeatures) throws -> DetectedGrid {
        guard features.duration >= 6, features.rms >= 1e-4, features.flux.count > Int(fps * 4),
              features.low.count == features.mid.count, features.low.count == features.high.count,
              features.flux.count == features.lowFlux.count, features.frameSeconds > 0, features.frameSeconds.isFinite else { return .unavailable }
        let env = envelope(features)
        let tempo = estimateTempo(env)
        let coarse = try comb(env, guess: 60 / tempo.bpm * fps)
        let refined = try refine(features, guess: foldBPM(60 * fps / coarse.period))
        let choice = choose(features, bpm: refined.bpm)
        let final = abs(choice.bpm - refined.bpm) < 0.01 ? refined : try refine(features, guess: choice.bpm, span: 0.05)
        let placed = place(features, bpm: final.bpm)
        let envRMS = sqrt(env.reduce(0) { $0 + $1 * $1 } / Double(env.count))
        let contrast = coarse.mean / max(1e-6, envRMS)
        let combConfidence = clamp(0.45 * clamp((contrast - 0.9) / 1.6) + 0.3 * clamp(tempo.strength * 1.2)
                                  + 0.15 * clamp(coarse.coverage) + 0.1 * clamp(1 - jitter(env, grid: coarse) / 0.03))
        let confidence = clamp((0.6 * clamp((final.sharpness - 0.3) / 0.4) + 0.2 * clamp(placed.margin / 0.08)
                                + 0.2 * combConfidence) * (choice.uncertain ? 0.7 : 1))
        // Do not turn silence/noise into a confidently armed 120 BPM grid.
        guard confidence >= 0.2, final.sharpness > 0.3 else { return .unavailable }
        let grid = try BeatGrid(bpm: final.bpm, offsetMs: placed.offset, confidence: confidence)
        let alternatives = choice.hypotheses.filter { $0.relation != "1" }.prefix(3).map {
            DetectedGrid.Alternative(bpm: $0.bpm, offsetMs: place(features, bpm: $0.bpm).offset,
                                     relation: $0.relation, salience: $0.salience)
        }
        return DetectedGrid(grid: grid, uncertain: choice.uncertain || confidence < 0.65, alternatives: alternatives)
    }
    private static func envelope(_ f: RhythmFeatures) -> [Double] {
        let n = f.flux.count
        let fluxMean = max(1e-12, f.flux.reduce(0.0) { $0 + Double($1) } / Double(n))
        let lowMean = max(1e-12, f.lowFlux.reduce(0.0) { $0 + Double($1) } / Double(n))
        let values = (0..<n).map { 0.6 * Double(f.flux[$0]) / fluxMean + 0.4 * Double(f.lowFlux[$0]) / lowMean }
        let radius = Int(round(fps * 0.5))
        var prefix = [Double](repeating: 0, count: n + 1)
        for i in 0..<n { prefix[i + 1] = prefix[i] + values[i] }
        var out = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let lo = max(0, i - radius), hi = min(n, i + radius + 1)
            out[i] = max(0, values[i] - (prefix[hi] - prefix[lo]) / Double(hi - lo))
        }
        let mean = out.reduce(0, +) / Double(n)
        let deviation = sqrt(out.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(n))
        if deviation > 1e-6 { for i in 0..<n { out[i] = (out[i] - mean) / deviation } }
        return out
    }
    private static func estimateTempo(_ env: [Double]) -> (bpm: Double, strength: Double) {
        let lo = max(2, Int(floor(60 / 205 * fps)))
        let hi = min(env.count - 2, Int(ceil(fps)))
        guard hi > lo + 2 else { return (120, 0) }
        var ac = [Double](repeating: 0, count: hi + 2)
        for lag in lo...hi {
            var sum = 0.0
            for i in 0..<(env.count - lag) { sum += env[i] * env[i + lag] }
            ac[lag] = sum / Double(env.count - lag)
        }
        func at(_ lag: Int) -> Double { (lo...hi).contains(lag) ? ac[lag] : 0 }
        var best = -Double.infinity, bestLag = lo
        for lag in lo...hi {
            let prior = exp(-0.5 * pow(log2(60 * fps / Double(lag) / 122) / 0.9, 2))
            let score = (ac[lag] + 0.3 * at(Int(round(Double(lag) / 2)))) * prior
            if score > best { best = score; bestLag = lag }
        }
        let y0 = at(bestLag - 1), y1 = at(bestLag), y2 = at(bestLag + 1)
        let denominator = y0 - 2 * y1 + y2
        let delta = abs(denominator) > 1e-12 ? min(0.5, max(-0.5, 0.5 * (y0 - y2) / denominator)) : 0
        let energy = max(1e-9, env.reduce(0) { $0 + $1 * $1 } / Double(env.count))
        return (foldBPM(60 * fps / (Double(bestLag) + delta)), clamp(y1 / energy * 1.15))
    }
    private struct Comb { var period: Double; var offset: Double; var score: Double; var mean: Double; var coverage: Double }
    private static func at(_ values: [Double], _ position: Double) -> Double {
        guard position >= 0 && position < Double(values.count - 1) else { return 0 }
        let i = Int(position), fraction = position - Double(Int(position))
        return values[i] * (1 - fraction) + values[i + 1] * fraction
    }
    private static func comb(_ env: [Double], guess: Double) throws -> Comb {
        var best = Comb(period: guess, offset: 0, score: -.infinity, mean: 0, coverage: 0)
        func evaluate(_ period: Double, _ offset: Double) {
            var sum = 0.0, count = 0.0, hits = 0.0, position = offset
            while position < Double(env.count) {
                let value = at(env, position)
                sum += value; count += 1; if value > 0.5 { hits += 1 }; position += period
            }
            let mean = sum / max(1, count), coverage = hits / max(1, count)
            let score = mean - 0.08 * abs(period - guess) - 1.5 * max(0, 0.3 - coverage)
            if score > best.score { best = Comb(period: period, offset: offset, score: score, mean: mean, coverage: coverage) }
        }
        for period in stride(from: guess * 0.97, through: guess * 1.03, by: max(0.01, guess * 0.0008)) {
            try Task.checkCancellation()
            for offset in stride(from: 0.0, to: period, by: 1) { evaluate(period, offset) }
        }
        let p0 = best.period, o0 = best.offset, span = guess * 0.0015
        for period in stride(from: p0 - span, through: p0 + span, by: span / 8) {
            for d in stride(from: -1.5, through: 1.5, by: 0.1) { evaluate(period, wrap(o0 + d, period)) }
        }
        return best
    }
    private static func jitter(_ env: [Double], grid: Comb) -> Double {
        var sum = 0.0, count = 0.0
        let radius = max(1, Int(round(grid.period * 0.2)))
        for position in stride(from: grid.offset, to: Double(env.count), by: grid.period) {
            let center = Int(round(position))
            let lo = max(0, center - radius), hi = min(env.count - 1, center + radius)
            if hi < lo { continue }
            let peak = (lo...hi).max { env[$0] < env[$1] }!
            if env[peak] > 0.3 { sum += abs(Double(peak) - position); count += 1 }
        }
        return count > 0 ? sum / count / fps : 0.1
    }
    private static func fold(_ values: [Float], period: Double, bins: Int) -> [Double] {
        var sum = [Double](repeating: 0, count: bins), count = sum
        let scale = Double(bins) / period
        var position = 0.5 * scale
        for i in values.indices {
            if i & 4095 == 0 { position = wrap((Double(i) + 0.5) * scale, Double(bins)) }
            let bin = min(bins - 1, Int(position))
            sum[bin] += Double(values[i]); count[bin] += 1
            position += scale
            if position >= Double(bins) { position -= Double(bins) }
        }
        for i in sum.indices { sum[i] = count[i] > 0 ? sum[i] / count[i] : 0 }
        return sum
    }
    private static func sharpness(_ profile: [Double]) -> Double {
        let mean = profile.reduce(0, +) / Double(profile.count)
        guard mean > 0 else { return 0 }
        return sqrt(profile.reduce(0) { $0 + pow($1 - mean, 2) } / Double(profile.count)) / mean
    }
    private static func refine(_ bands: RhythmFeatures, guess: Double, span: Double = 0.5) throws -> (bpm: Double, sharpness: Double) {
        var low = [Float](repeating: 0, count: bands.low.count / 4)
        for i in low.indices { for j in 0..<4 { low[i] += bands.low[i * 4 + j] } }
        let frameSec = bands.frameSeconds * 4
        func score(_ bpm: Double) -> Double { sharpness(fold(low, period: 60 / bpm / frameSec, bins: 120)) }
        let beats = max(16, Double(low.count) * frameSec * guess / 60)
        let step = min(0.02, 0.25 * guess / beats)
        var best = guess, strength = -Double.infinity
        for bpm in stride(from: guess - span, through: guess + span + 1e-9, by: step) {
            try Task.checkCancellation()
            let s = score(bpm); if s > strength { strength = s; best = bpm }
        }
        let center = best
        for bpm in stride(from: center - step, through: center + step + 1e-9, by: step / 10) {
            let s = score(bpm); if s > strength { strength = s; best = bpm }
        }
        let whole = round(best), wholeStrength = score(whole)
        if abs(whole - best) <= span && wholeStrength >= 0.97 * strength { return (whole, wholeStrength) }
        return (best, strength)
    }
    private struct CircularMean {
        let prefix: [Double]
        let count: Int
        init(_ values: [Double]) {
            count = values.count
            var sums = [Double](repeating: 0, count: count * 2 + 1)
            for i in 0..<(count * 2) { sums[i + 1] = sums[i] + values[i % count] }
            prefix = sums
        }
        func mean(_ from: Int, _ length: Int) -> Double {
            let start = ((from % count) + count) % count
            return (prefix[start + length] - prefix[start]) / Double(length)
        }
    }
    private struct KickProfile { let onset: [Double]; let high: CircularMean; let binSeconds: Double }
    private static func kickProfile(_ f: RhythmFeatures, bpm: Double) -> KickProfile {
        let period = 60 / bpm / f.frameSeconds, bins = max(16, Int(round(period)))
        let seconds = 60 / bpm / Double(bins)
        func toBins(_ ms: Double) -> Int { max(1, Int(round(ms / 1000 / seconds))) }
        let low = CircularMean(fold(f.low, period: period, bins: bins))
        let high = CircularMean(fold(f.high, period: period, bins: bins))
        let onset = (0..<bins).map { max(0, low.mean($0 + toBins(10), toBins(70)) - low.mean($0 - toBins(20), toBins(20))) }
        return KickProfile(onset: onset, high: high, binSeconds: seconds)
    }
    private static func locate(_ f: RhythmFeatures, bpm: Double) -> (offset: Double, contrast: Double) {
        let profile = kickProfile(f, bpm: bpm)
        let bins = profile.onset.count, strongest = profile.onset.max() ?? 0
        func toBins(_ ms: Double) -> Int { max(1, Int(round(ms / 1000 / profile.binSeconds))) }
        func at(_ k: Int) -> Double { profile.onset[((k % bins) + bins) % bins] }
        struct Candidate { let onset: Double; let click: Double; let attack: Int }
        func candidate(_ lowAt: Int) -> Candidate {
            var click = -Double.infinity, attack = lowAt
            for d in (-toBins(60))...toBins(15) {
                let k = lowAt + d
                let value = profile.high.mean(k, toBins(3)) - profile.high.mean(k - toBins(6), toBins(6))
                if value > click { click = value; attack = k }
            }
            return Candidate(onset: at(lowAt), click: max(0, click), attack: attack)
        }
        var candidates = [Candidate]()
        for k in 0..<bins where at(k) >= 0.3 * strongest && at(k) > 0 {
            let peak = (1...toBins(30)).allSatisfy { at(k - $0) <= at(k) && at(k + $0) <= at(k) }
            if peak { candidates.append(candidate(k)) }
        }
        if candidates.isEmpty { candidates.append(candidate((0..<bins).max { at($0) < at($1) } ?? 0)) }
        let loudest = max(1e-12, candidates.map(\.click).max() ?? 0)
        func score(_ c: Candidate) -> Double { pow(c.onset / max(1e-12, strongest), 2) * c.click / loudest }
        let kick = candidates.max { score($0) < score($1) }!
        let offset = wrap(Double(kick.attack), Double(bins)) * profile.binSeconds
        let mean = profile.onset.reduce(0, +) / Double(bins)
        return (offset, mean > 0 ? kick.onset / mean : 0)
    }
    private struct Hypothesis { let bpm: Double; let relation: String; let salience: Double }
    private static func choose(_ f: RhythmFeatures, bpm: Double) -> (bpm: Double, hypotheses: [Hypothesis], uncertain: Bool) {
        let ratios: [(Double, String)] = [(0.5,"1/2"),(2.0/3,"2/3"),(0.75,"3/4"),(1,"1"),(4.0/3,"4/3"),(1.5,"3/2"),(2,"2")]
        var cache = [Double: Double]()
        func strength(_ bpm: Double) -> Double {
            if let value = cache[bpm] { return value }
            let value = kickProfile(f, bpm: bpm).onset.max() ?? 0
            cache[bpm] = value
            return value
        }
        func around(_ center: Double) -> [(bpm: Double, relation: String, strength: Double)] {
            ratios.compactMap { ratio, relation in
                var value = center * ratio
                guard (70...180).contains(value) else { return nil }
                if abs(value - round(value)) < 0.01 { value = round(value) }
                return (value, relation, strength(value))
            }
        }
        let first = around(bpm)
        guard !first.isEmpty else { return (bpm, [Hypothesis(bpm: bpm, relation: "1", salience: 1)], true) }
        let firstStrongest = max(1e-12, first.map(\.strength).max() ?? 0)
        let byTempo = first.sorted { $0.bpm > $1.bpm }
        let pick = byTempo.first { $0.strength >= 0.75 * firstStrongest } ?? byTempo[0]
        let second = around(pick.bpm), strongest = max(firstStrongest, second.map(\.strength).max() ?? 0)
        let hypotheses = second.map { Hypothesis(bpm: $0.bpm, relation: $0.relation, salience: $0.strength / strongest) }.sorted { $0.salience > $1.salience }
        let chosen = hypotheses.first { $0.relation == "1" } ?? hypotheses[0]
        let uncertain = hypotheses.contains { $0.bpm > chosen.bpm && $0.salience >= 0.6 } || chosen.salience < 0.875
        return (chosen.bpm, hypotheses, uncertain)
    }
    private static func place(_ f: RhythmFeatures, bpm: Double) -> (offset: Double, margin: Double) {
        let kick = locate(f, bpm: bpm), period = 60 / bpm
        let first = kick.offset > period - 0.02 ? kick.offset - period : kick.offset
        let bar = barPhase(f, bpm: bpm, first: first)
        return (wrap((first + Double(bar.beat) * period) * 1000, 4 * period * 1000), bar.margin)
    }
    private static func barPhase(_ f: RhythmFeatures, bpm: Double, first: Double) -> (beat: Int, margin: Double) {
        let period = 60 / bpm / f.frameSeconds, start = first / f.frameSeconds
        let count = Int(floor((Double(f.low.count) - max(0, start)) / period))
        guard count >= 16 else { return (0, 0) }
        let bands = [f.low, f.mid, f.high]
        var perBeat = [[Double]]()
        for k in 0..<count {
            let lo = max(0, Int(round(start + Double(k) * period)))
            let hi = min(f.low.count, Int(round(start + Double(k + 1) * period)))
            perBeat.append(bands.map { band in
                var sum = 0.0
                if hi > lo { for i in lo..<hi { sum += Double(band[i]) } }
                return log(sum / Double(max(1, hi - lo)) + 1e-9)
            })
        }
        var beatChange = [Double](repeating: 0, count: 4)
        var barChange = [(beat: Int, value: Double)]()
        for k in 4..<(count - 4) {
            var step = 0.0, bar = 0.0
            for b in 0..<3 {
                step += abs(perBeat[k][b] - perBeat[k - 1][b])
                var before = 0.0, after = 0.0
                for i in 0..<4 { after += perBeat[k + i][b]; before += perBeat[k - 1 - i][b] }
                bar += abs(after - before) / 4
            }
            beatChange[k % 4] += step; barChange.append((k, bar))
        }
        barChange.sort { $0.value > $1.value }
        let median = barChange[barChange.count / 2].value
        var big = [Double](repeating: 1, count: 4)
        for change in barChange.prefix(max(1, Int(round(Double(barChange.count) * 0.05)))) {
            if change.value >= max(3 * median, 0.5) { big[change.beat % 4] += change.value / max(0.5, median) }
        }
        let stepTotal = max(1e-12, beatChange.reduce(0, +)), bigTotal = big.reduce(0, +)
        let scores = (0..<4).map { beatChange[$0] / stepTotal + big[$0] / bigTotal + ($0 == 0 ? 0.02 : 0) }
        let order = (0..<4).sorted { scores[$0] > scores[$1] }
        return (order[0], (scores[order[0]] - scores[order[1]]) / 2)
    }
}
