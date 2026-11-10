import SwiftUI

/// The controls, their values, the meters they show, and the touches working them.
///
/// Touch routing lives here, not in the views, so several fingers can each own a
/// control (deck A's LEVEL up while deck B's comes down) and the logic can be tested
/// without a screen. A finger owns the control it first touched for as long as it
/// stays down, wherever it travels.
@MainActor @Observable
public final class SliderBank {
    public struct Control: Sendable, Equatable {
        public var spec: SliderSpec
        public var value: Double
    }

    /// An open panel.
    public struct Panel: Sendable, Equatable {
        public var layout: PanelLayout
        /// The chip it grew out of, which it shrinks back into.
        public var origin: CGRect
        public var touching = true
        public var closing = false
        /// Points pulled past an end; the view turns this into the stretch.
        public var overshoot = 0.0
        /// The drag speed: 1, or ½, ¼, ⅒ when fine.
        public var factor = 1.0
    }

    public private(set) var controls: [SliderID: Control] = [:]
    public private(set) var panels: [SliderID: Panel] = [:]
    public var meters: [MeterKey: MeterValue] = [:]
    public var tuning: SliderTuning
    /// Counts each pull against an end, to drive a haptic tick where there is one.
    public private(set) var limitBumps = 0

    /// Called for every value the user sets, for the audio.
    @ObservationIgnored public var onChange: ((SliderID, Double) -> Void)?

    @ObservationIgnored private(set) var frames: [SliderID: CGRect] = [:]
    @ObservationIgnored var bounds: CGRect = .zero

    private struct Touch {
        let id: SliderID
        var drag: SliderDrag
        let isReset: Bool
    }
    @ObservationIgnored private var touches: [AnyHashable: Touch] = [:]
    /// Touches that landed outside every chip: ignored until they lift.
    @ObservationIgnored private var strays: Set<AnyHashable> = []
    @ObservationIgnored private var lastTap: [SliderID: (time: TimeInterval, at: CGPoint)] = [:]
    @ObservationIgnored private var generation: [SliderID: Int] = [:]

    public init(tuning: SliderTuning = SliderTuning()) {
        self.tuning = tuning
    }

    // MARK: Controls

    public func add(_ id: SliderID, spec: SliderSpec, value: Double) {
        controls[id] = Control(spec: spec, value: spec.snap(spec.clamp(value)))
    }

    public func setSpec(_ spec: SliderSpec, for id: SliderID) {
        controls[id]?.spec = spec
    }

    public func value(_ id: SliderID) -> Double { controls[id]?.value ?? 0 }

    /// A change from elsewhere (a new track's AUTO, MIDI): moves the chip, not a drag.
    public func setValue(_ value: Double, for id: SliderID) {
        guard let spec = controls[id]?.spec else { return }
        controls[id]?.value = spec.snap(spec.clamp(value))
    }

    public func meter(_ key: MeterKey) -> MeterValue { meters[key] ?? .silent }

    /// What a control's panel shows, and what its chip outline follows.
    public func meterValue(for spec: SliderSpec) -> MeterValue {
        switch spec.meter {
        case .deck(let key): meter(key)
        case .master: .louder(meter(.masterL), meter(.masterR))
        }
    }

    public func isTouched(_ id: SliderID) -> Bool { panels[id]?.touching ?? false }

    // MARK: Geometry

    public func setFrame(_ frame: CGRect, for id: SliderID) { frames[id] = frame }
    public func frame(_ id: SliderID) -> CGRect? { frames[id] }
    public func setBounds(_ bounds: CGRect) { self.bounds = bounds }

    /// An open panel's bar first, so a panel still up after release can be grabbed
    /// again; then the chips, with a little slop around each.
    func hit(_ point: CGPoint) -> SliderID? {
        if let open = panels.first(where: { !$0.value.closing && $0.value.layout.bar.insetBy(dx: -8, dy: -8).contains(point) }) {
            return open.key
        }
        return frames.first { $0.value.insetBy(dx: -6, dy: -6).contains(point) }?.key
    }

    // MARK: Touches

    /// Feeds SwiftUI's spatial events through the router. The first `.active` for an
    /// id is its touch-down: the API has no separate began phase.
    public func handle(_ events: SpatialEventCollection, ended: Bool = false) {
        for event in events {
            let key = AnyHashable(event.id)
            switch event.phase {
            case .active:
                if touches[key] != nil {
                    touchMoved(key, to: event.location)
                } else if !strays.contains(key) {
                    touchDown(key, at: event.location, time: event.timestamp)
                }
            default:
                touchUp(key, at: event.location, time: event.timestamp)
            }
        }
        // The gesture ended: nothing can still be down.
        if ended {
            for key in Array(touches.keys) { touchUp(key, at: .zero, time: .infinity) }
            strays.removeAll()
        }
    }

    public func touchDown(_ key: AnyHashable, at point: CGPoint, time: TimeInterval) {
        guard let id = hit(point), let control = controls[id],
              !touches.values.contains(where: { $0.id == id }) else {
            strays.insert(key)
            return
        }
        var isReset = false
        if let reset = control.spec.reset, let tap = lastTap[id],
           time - tap.time < tuning.doubleTapWindow,
           hypot(Double(point.x - tap.at.x), Double(point.y - tap.at.y)) < 40 {
            set(reset, for: id)
            isReset = true
            lastTap[id] = nil
        }
        let value = controls[id]?.value ?? control.value
        touches[key] = Touch(id: id, drag: SliderDrag(spec: control.spec, value: value, at: point), isReset: isReset)
        open(id, finger: point)
    }

    public func touchMoved(_ key: AnyHashable, to point: CGPoint) {
        guard var touch = touches[key] else { return }
        let value = touch.drag.move(to: point, travel: tuning.barHeight, tuning: tuning)
        touches[key] = touch
        set(value, for: touch.id)
        guard var panel = panels[touch.id] else { return }
        let overshoot = touch.drag.overshoot(travel: tuning.barHeight)
        if overshoot != 0 && panel.overshoot == 0 { limitBumps += 1 }
        panel.overshoot = overshoot
        panel.factor = touch.drag.factor
        panels[touch.id] = panel
    }

    public func touchUp(_ key: AnyHashable, at point: CGPoint, time: TimeInterval) {
        strays.remove(key)
        guard let touch = touches.removeValue(forKey: key) else { return }
        let id = touch.id
        if !touch.drag.moved && !touch.isReset {
            lastTap[id] = (time, touch.drag.start)
        }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.72)) {
            panels[id]?.overshoot = 0
        }
        panels[id]?.touching = false
        panels[id]?.factor = 1
        scheduleClose(id)
    }

    private func set(_ value: Double, for id: SliderID) {
        guard let old = controls[id]?.value, old != value else { return }
        controls[id]?.value = value
        onChange?(id, value)
    }

    // MARK: Panels

    private func open(_ id: SliderID, finger: CGPoint) {
        generation[id, default: 0] += 1
        if panels[id] != nil {
            // Still up from a moment ago: keep it where it is rather than jump.
            panels[id]?.touching = true
            panels[id]?.closing = false
            return
        }
        guard let chip = frames[id], let control = controls[id] else { return }
        let others = panels.filter { $0.key != id && !$0.value.closing }.map { $0.value.layout.frame }
        let layout = PanelPlacer.place(chip: chip, finger: finger, fill: control.spec.fill(control.value),
                                       bounds: bounds, tuning: tuning, avoiding: others)
        panels[id] = Panel(layout: layout, origin: chip)
    }

    private func scheduleClose(_ id: SliderID) {
        let mine = generation[id, default: 0]
        let hold = tuning.holdAfterRelease
        let shrink = max(0.15, tuning.openResponse * 1.4)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(hold))
            guard let self, self.generation[id] == mine, self.panels[id]?.touching == false else { return }
            self.panels[id]?.closing = true
            try? await Task.sleep(for: .seconds(shrink))
            guard self.generation[id] == mine, self.panels[id]?.closing == true else { return }
            self.panels[id] = nil
        }
    }
}
