import DexSlider
import Foundation
import Observation

/// Dex's LEVEL and EQ fader law (DexCore `FaderLaw`): position to dB.
enum FaderLaw {
    static let points: [(position: Double, db: Double)] = [(1, 0), (0.8, -3), (0.6, -6), (0.4, -12), (0.2, -24), (0.03, -48)]
    static let floor = 0.005

    static func db(_ position: Double) -> Double {
        let p = min(1, max(0, position))
        if p <= floor { return -.infinity }
        let last = points[points.count - 1]
        if p < last.position { return last.db - (last.position - p) / (last.position - floor) * 22 }
        for index in 1..<points.count {
            let (p0, d0) = points[index - 1], (p1, d1) = points[index]
            if p >= p1 { return d1 + (d0 - d1) * (p - p1) / (p0 - p1) }
        }
        return last.db
    }

    static func gain(_ position: Double) -> Double {
        let db = db(position)
        return db == -.infinity ? 0 : pow(10, db / 20)
    }
}

/// A stand-in for real music until the lab plays tracks: a beatmatched four-on-the-
/// floor pattern per deck (kick, clap, hats) whose peaks follow TRIM, the EQ and
/// LEVEL as Dex's mixer would, summed into a master before the limiter.
///
/// Peaks vary hit to hit and the track's true peak arrives only now and then, so
/// setting TRIM by eye works the way it does with music: play a loud part and push
/// until the top rung just catches.
@MainActor @Observable
final class TestSignal {
    enum Source: String, CaseIterable, Identifiable {
        case hot = "HOT", normal = "NORMAL", quiet = "QUIET"
        var id: String { rawValue }
        /// The track's loudest peak, before TRIM.
        var peakDB: Double {
            switch self {
            case .hot: -0.8
            case .normal: -3.5
            case .quiet: -9.0
            }
        }
        /// What AUTO would set for it.
        var autoTrimDB: Double {
            switch self {
            case .hot: -1.4
            case .normal: 1.0
            case .quiet: 4.6
            }
        }
    }

    struct Deck {
        var playing = true
        var source = Source.normal
    }

    var decks: [String: Deck] = ["A": Deck(source: .normal), "B": Deck(source: .hot)]
    /// Dex's master volume, linear, at its default.
    let masterVolume = 0.7
    let tempo = 124.0

    @ObservationIgnored private let bank: SliderBank
    @ObservationIgnored private var ballistics: [MeterKey: (value: MeterValue, heldAt: Double)] = [:]
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private let started = Date()

    init(bank: SliderBank) {
        self.bank = bank
        for deck in ["A", "B"] {
            let source = decks[deck]!.source
            bank.add(SliderID(deck, .trim), spec: .trim(deck: deck, auto: source.autoTrimDB), value: source.autoTrimDB)
            for band in [SliderRole.hi, .mid, .low] {
                bank.add(SliderID(deck, band), spec: .eq(deck: deck), value: 1)
            }
            // Deck A playing out, deck B cued in at zero: ready to swap.
            bank.add(SliderID(deck, .level), spec: .level(deck: deck), value: deck == "A" ? 1 : 0)
        }
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            var last = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16))
                guard let self else { return }
                let now = Date()
                self.tick(now: now.timeIntervalSince(self.started), dt: now.timeIntervalSince(last))
                last = now
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// A new track on the deck: AUTO is measured again and TRIM goes back to it.
    func load(_ source: Source, on deck: String) {
        decks[deck]?.source = source
        bank.setSpec(.trim(deck: deck, auto: source.autoTrimDB), for: SliderID(deck, .trim))
        bank.setValue(source.autoTrimDB, for: SliderID(deck, .trim))
    }

    func togglePlay(_ deck: String) {
        decks[deck]?.playing.toggle()
    }

    // MARK: The signal

    private func tick(now: Double, dt: Double) {
        let a = deckPeak("A", now: now, dt: dt)
        let b = deckPeak("B", now: now, dt: dt)
        let master = (a.post + b.post) * masterVolume
        // A touch of width so L and R don't move as one.
        let wobble = 0.03 * sin(now * 2.1)
        let readings: [MeterKey: Double] = [
            .deckA: decibels(a.pre),
            .deckB: decibels(b.pre),
            .masterL: decibels(master * (1 + wobble)),
            .masterR: decibels(master * (1 - wobble)),
        ]
        let tuning = bank.tuning
        var meters: [MeterKey: MeterValue] = [:]
        for (key, read) in readings {
            var state = ballistics[key] ?? (MeterValue.silent, 0)
            let read = max(MeterValue.floor, read)
            let fall = tuning.releaseDBPerSecond * min(0.1, dt)
            state.value.level = read >= state.value.level ? read : max(read, state.value.level - fall)
            if state.value.level >= state.value.hold || now - state.heldAt > tuning.peakHold {
                state.value.hold = state.value.level
                state.heldAt = now
            }
            ballistics[key] = state
            meters[key] = state.value
        }
        bank.meters = meters
    }

    /// The deck's peak over the last `dt`, linear: before LEVEL (after TRIM and EQ),
    /// and after it.
    private func deckPeak(_ id: String, now: Double, dt: Double) -> (pre: Double, post: Double) {
        guard let deck = decks[id], deck.playing else { return (0, 0) }
        let beat = 60 / tempo
        let low = FaderLaw.gain(bank.value(SliderID(id, .low)))
        let mid = FaderLaw.gain(bank.value(SliderID(id, .mid)))
        let hi = FaderLaw.gain(bank.value(SliderID(id, .hi)))

        // Each part's loudest point in the window: its last hit inside it, or the
        // window's start as it decays.
        func part(every: Double, offset: Double, decay: Double, body: Double) -> (Double, Int) {
            let from = now - dt
            let hitIndex = ((now - offset) / every).rounded(.down)
            let hitTime = hitIndex * every + offset
            let since = hitTime >= from ? 0 : from - hitTime
            return (body + (1 - body) * exp(-since / decay), Int(hitIndex))
        }
        let (kick, kickIndex) = part(every: beat, offset: 0, decay: 0.12, body: 0.06)
        let (clap, _) = part(every: beat * 2, offset: beat, decay: 0.16, body: 0.25)
        let (hats, _) = part(every: beat, offset: beat / 2, decay: 0.05, body: 0.2)
        // Scaled so the loudest moment, kick and clap together on beats 2 and 4, is 1.
        let mix = (kick * 0.78 * low + clap * 0.42 * mid + hats * 0.26 * hi) / (0.78 + 0.42 + 0.26 * 0.2)

        // Every beat lands a little under the track's peak, the odd one right on it;
        // a breakdown every 16 bars drops it by 7 dB.
        let bar = kickIndex / 4
        let breakdown = bar % 16 >= 12
        let jitter = -1.6 * pow(unitHash(kickIndex &+ (id == "B" ? 7919 : 0)), 0.6)
        let db = deck.source.peakDB + jitter + (breakdown ? -7 : 0) + bank.value(SliderID(id, .trim))
        let pre = mix * pow(10, db / 20)
        return (pre, pre * FaderLaw.gain(bank.value(SliderID(id, .level))))
    }

    private func unitHash(_ n: Int) -> Double {
        var x = UInt64(bitPattern: Int64(n)) &* 0x9E37_79B9_7F4A_7C15
        x ^= x >> 31
        x &*= 0xBF58_476D_1CE4_E5B9
        x ^= x >> 29
        return Double(x % 10_000) / 10_000
    }

    private func decibels(_ linear: Double) -> Double {
        linear > 0 ? 20 * log10(linear) : MeterValue.floor
    }
}
