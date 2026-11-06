import Combine
import DexCore
import Foundation

/// What the jog asks of the engine, which owns the scrub's sound. The jog only keeps its
/// gesture and `JogFling` physics, and steers the engine onto them.
@MainActor
struct JogEngineControl {
    let enter: (Double) -> Bool
    let speed: (Double, Double) -> Bool
    let rendered: () -> Double?
    let leave: () -> Void
}

/// Shared audible jog lifecycle. A narrow observer drives only waveform motion;
/// the normal playback latch is kept separately by NativeDeck.
@MainActor
public final class DeckJog: ObservableObject {
    @Published public private(set) var position: Double?
    @Published public private(set) var coasting = false
    public var active: Bool { position != nil }
    public private(set) var gestureID: UUID?
    var engine: JogEngineControl?
    private var sentSpeed = 0.0
    var now: () -> Double = { ProcessInfo.processInfo.systemUptime }
    var located: ((Double) -> Void)?
    var finished: ((Double) -> Void)?
    var failed: ((String) -> Void)?
    private var session: UInt64 = 0
    private var trackDuration = 0.0
    private var origin = 0.0
    private var lastVelocity = 0.0
    private var velocity = JogVelocity()
    private var coast: JogCoast?
    private var coastStart = 0.0
    private var motionTask: Task<Void, Never>?
    private var lastInput = 0.0
    private var coastDamping = JogFling.referenceDamping

    func begin(position: Double, duration: Double) {
        cancel()
        session += 1; if session == 0 { session = 1 }
        trackDuration = duration; origin = position
        gestureID = UUID()
        self.position = position; lastVelocity = 0; velocity = JogVelocity()
        lastInput = now()
        velocity.add(position: position, at: lastInput)
        sentSpeed = 0
        if let engine, !engine.enter(position) {
            failed?("Scrub control is busy. Try the gesture again.")
            finishNow(position)
            return
        }
        let ticket = session
        motionTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, active, session == ticket else { return }
                service()
                do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
            }
        }
    }
    /// displacement is source seconds, with its sign already mapped from the
    /// finger/platter. Velocity never exceeds eight source seconds per second.
    public func move(displacement: Double, velocity suppliedVelocity: Double? = nil) {
        guard active, !coasting, displacement.isFinite else { return }
        let time = now(), target = min(trackDuration, max(0, origin + displacement))
        guard abs(target - (position ?? origin)) > 1e-9 else { return }
        velocity.add(position: target, at: time)
        let estimate = suppliedVelocity.flatMap { $0.isFinite ? $0 : nil } ?? velocity.velocity(at: time)
        lastVelocity = min(8, max(-8, estimate))
        position = target; lastInput = time
        located?(target)
        publish()
    }
    /// `span` is the source seconds a lane shows, which scales its coast.
    public func release(velocity suppliedVelocity: Double? = nil, span: Double = JogFling.referenceSpan) {
        guard active, !coasting, let position else { return }
        let time = now()
        let estimate = suppliedVelocity.flatMap { $0.isFinite ? $0 : nil }
            ?? (time - lastInput > 0.05 ? 0 : velocity.velocity(at: time))
        let speed = min(8, max(-8, estimate))
        coastDamping = JogFling.damping(velocity: estimate, speed: speed, span: span)
        guard let coast = JogCoast(position: position, velocity: speed, bounds: 0...trackDuration,
                                damping: coastDamping, stopSpeed: 0.06, maximumDuration: 6),
              coast.duration > 0 else { complete(position); return }
        self.coast = coast; coastStart = time
        lastVelocity = speed; coasting = true
        publish()
    }
    /// The sound follows the finger from the engine's next block: there's nothing to prepare.
    var ready: Bool { active }
    var renderedPosition: Double? {
        guard active, let value = engine?.rendered(), value.isFinite else { return nil }
        return min(trackDuration, max(0, value))
    }
    var currentPosition: Double? {
        guard active else { return nil }
        return coast?.sample(at: now() - coastStart).position ?? position
    }
    func service() {
        guard active else { return }
        if let coast {
            // The engine coasts on the damping it was given; only the display follows here.
            let sample = coast.sample(at: now() - coastStart)
            position = sample.position; located?(sample.position)
            if sample.finished { complete(sample.position) }
            return
        }
        // No further pointer events means the finger is stationary.
        if now() - lastInput > 0.05, lastVelocity != 0 { lastVelocity = 0 }
        publish() // The engine keeps closing on the finger between events.
    }
    /// How quickly the engine's platter closes on the finger.
    private static let followSeconds = 0.03
    private func publish() {
        guard let position, let engine else { return }
        var speed = lastVelocity
        var damping = 0.0
        if coast != nil { damping = coastDamping }
        else if let rendered = engine.rendered() {
            speed += (position - rendered) / Self.followSeconds
            if lastVelocity == 0, abs(speed) < 0.02 { speed = 0 }
        }
        speed = min(8, max(-8, speed))
        if coast == nil, abs(speed - sentSpeed) < 1e-3 { return }
        sentSpeed = speed
        if !engine.speed(speed, damping) {
            failed?("Scrub control is busy. Try the gesture again.")
            complete(position)
        }
    }
    private func complete(_ target: Double) {
        cancel()
        finished?(target)
    }
    private func finishNow(_ target: Double) { position = nil; gestureID = nil; finished?(target) }
    public func cancel() {
        if active { engine?.leave() }
        motionTask?.cancel(); motionTask = nil
        coast = nil; coasting = false; gestureID = nil
        position = nil
    }
}
