import Foundation
import DexCore

/// The console's readout maths, ported from `src/shared/mixer.ts`,
/// `curves.ts` and `useMixDrags.ts` so native and Electron print the same.
/// The fader law itself lives in DexCore, where the engine uses it too.
enum MixerMath {
    static let tempoRange = 0.16

    static func faderDb(_ position: Double) -> Double { FaderLaw.db(position) }
    static func faderGain(_ position: Double) -> Double { FaderLaw.gain(position) }
    /// "0.0", "−3.0", "+1.4", "−∞".
    static func formatDb(_ db: Double) -> String {
        if db == -.infinity { return "−∞" }
        if abs(db) < 0.05 { return "0.0" }
        return (db > 0 ? "+" : "−") + String(format: "%.1f", abs(db))
    }
    /// TRIM's readout: "0.0", "+1.4", "−3.0".
    static func formatTrim(_ db: Double) -> String {
        abs(db) < 0.05 ? "0.0" : (db > 0 ? "+" : "−") + String(format: "%.1f", abs(db))
    }
    /// The tempo fader's position for a rate: the top is −16%.
    static func tempoToFader(_ rate: Double) -> Double { 0.5 - (rate - 1) / (2 * tempoRange) }
    static func faderToTempo(_ position: Double) -> Double { 1 + (0.5 - position) * 2 * tempoRange }
    /// "+2.31%" under the tempo fader.
    static func tempoText(_ rate: Double) -> String {
        let parts = tempoParts(rate)
        return "\(parts.sign)\(parts.digits)%"
    }
}
