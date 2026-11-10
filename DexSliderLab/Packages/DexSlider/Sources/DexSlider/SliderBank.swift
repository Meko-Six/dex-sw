import SwiftUI

/// The controls, their values, the meters they show, and the touches working them.
///
/// Touch routing lives here, not in the views, so several fingers can each own a
/// control (deck A's LEVEL up while deck B's comes down) and the logic can be tested
/// without a screen. A finger owns the control it first touched for as long as it
/// stays down, wherever it travels.
///
/// Two kinds of control share the routing: chips, which open a panel while touched,
/// and faders (LEVEL, TEMPO), which are always drawn and only show a readout.
@MainActor @Observable
public final class SliderBank {
    public enum Kind: Sendable, Equatable { case chip, fader }

    public struct Control: Sendable, Equatable {
        public var spec: SliderSpec
        public var value: Double
        public var kind: Kind
    }

    /// An open chip panel.
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

    /// A fader being worked, or just let go.
    public struct FaderTouch: Sendable, Equatable {
        public var touching = true
        public var overshoot = 0.0
        public var factor = 1.0
    }

    /// The effect list a finger held still on an FX chip brings up in place of its
    /// panel. Slide to an effect and lift to take it, or lift without sliding and
    /// tap one.
    public struct Picker: Sendable, Equatable {
        public var options: [DeckEffect]
        public var rows: [CGRect]
        /// The effect in use.
        public var current: Int
        /// The row under the finger, if any.
        public var highlighted: Int?
        /// Still under the finger that brought it up; false once it waits for a tap.
        public var touching = true
        public var frame: CGRect { rows.dropFirst().reduce(rows.first ?? .zero) { $0.union($1) } }
    }

    public private(set) var controls: [SliderID: Control] = [:]
    public private(set) var panels: [SliderID: Panel] = [:]
    public private(set) var faders: [SliderID: FaderTouch] = [:]
    public private(set) var pickers: [SliderID: Picker] = [:]
    /// Controls that ignore touches: TEMPO while SYNC holds it.
    public private(set) var locked: Set<SliderID> = []
    public var meters: [MeterKey: MeterValue] = [:]
    public var tuning: SliderTuning
    /// Counts each pull against an end and each arrival in a detent, to drive a
    /// haptic tick where there is one.
    public private(set) var ticks = 0

    /// Called for every value the user sets, for the audio.
    @ObservationIgnored public var onChange: ((SliderID, Double) -> Void)?

    @ObservationIgnored private(set) var frames: [SliderID: CGRect] = [:]
    @ObservationIgnored var bounds: CGRect = .zero

    private struct Touch {
        let id: SliderID
        var drag: SliderDrag
        let travel: Double
        let isReset: Bool
        /// Working the effect list rather than the value.
        var picking = false
        /// Moved since the list came up, so lifting takes the row under it.
        var slid = false
    }
    @ObservationIgnored private var touches: [AnyHashable: Touch] = [:]
    /// Touches that landed outside every control: ignored until they lift.
    @ObservationIgnored private var strays: Set<AnyHashable> = []
    @ObservationIgnored private var lastTap: [SliderID: (time: TimeInterval, at: CGPoint)] = [:]
    @ObservationIgnored private var generation: [SliderID: Int] = [:]

    public init(tuning: SliderTuning = SliderTuning()) {
        self.tuning = tuning
    }

    // MARK: Controls

    /// A chip: TRIM, the EQ, CUE/MST, PHONES, MASTER.
    public func add(_ id: SliderID, spec: SliderSpec, value: Double) {
        controls[id] = Control(spec: spec, value: spec.snap(spec.clamp(value)), kind: .chip)
    }

    /// An always-visible fader: LEVEL, TEMPO.
    public func addFader(_ id: SliderID, spec: SliderSpec, value: Double) {
        controls[id] = Control(spec: spec, value: spec.snap(spec.clamp(value)), kind: .fader)
    }

    public func setSpec(_ spec: SliderSpec, for id: SliderID) {
        controls[id]?.spec = spec
    }

    public func value(_ id: SliderID) -> Double { controls[id]?.value ?? 0 }

    /// A change from elsewhere (a new track's AUTO, SYNC, MIDI): moves the control,
    /// not a drag.
    public func setValue(_ value: Double, for id: SliderID) {
        guard let spec = controls[id]?.spec else { return }
        controls[id]?.value = spec.snap(spec.clamp(value))
    }

    /// Locks a control against touches, and lets go of any finger on it.
    public func setLocked(_ isLocked: Bool, for id: SliderID) {
        if isLocked {
            locked.insert(id)
            for (key, touch) in touches where touch.id == id { touchUp(key, at: .zero, time: .infinity) }
        } else {
            locked.remove(id)
        }
    }

    public func isLocked(_ id: SliderID) -> Bool { locked.contains(id) }

    public func meter(_ key: MeterKey) -> MeterValue { meters[key] ?? .silent }

    /// What a control's panel shows, and what its chip outline follows; nil for none.
    public func meterValue(for spec: SliderSpec) -> MeterValue? {
        switch spec.meter {
        case .deck(let key): meter(key)
        case .master: .louder(meter(.masterL), meter(.masterR))
        case .none: nil
        }
    }

    public func isTouched(_ id: SliderID) -> Bool {
        panels[id]?.touching ?? faders[id]?.touching ?? false
    }

    // MARK: Geometry

    public func setFrame(_ frame: CGRect, for id: SliderID) { frames[id] = frame }
    public func frame(_ id: SliderID) -> CGRect? { frames[id] }
    public func setBounds(_ bounds: CGRect) { self.bounds = bounds }

    /// An open panel's bar first, so a panel still up after release can be grabbed
    /// again; then the controls, with a little slop around each.
    func hit(_ point: CGPoint) -> SliderID? {
        if let open = panels.first(where: { !$0.value.closing && $0.value.layout.bar.insetBy(dx: -8, dy: -8).contains(point) }) {
            return open.key
        }
        return frames.first { $0.value.insetBy(dx: -6, dy: -6).contains(point) }?.key
    }

    private func travel(_ id: SliderID, _ kind: Kind) -> Double {
        kind == .fader ? tuning.faderTravel(id.role) : tuning.barHeight
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
        // A list waiting for a tap: a tap on a row takes it, anything else puts it away.
        if let (id, row) = waitingRow(at: point) {
            choose(row, for: id)
            strays.insert(key)
            return
        }
        for (id, picker) in pickers where !picker.touching { closePicker(id) }

        guard let id = hit(point), let control = controls[id], !locked.contains(id),
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
        let travel = travel(id, control.kind)
        let detent = travel > 0 ? tuning.detentPoints / travel * control.spec.span : 0
        touches[key] = Touch(id: id,
                             drag: SliderDrag(spec: control.spec, value: value, at: point, detentWidth: detent),
                             travel: travel, isReset: isReset)
        generation[id, default: 0] += 1
        switch control.kind {
        case .chip:
            open(id, finger: point)
            if control.spec.effect != nil { scheduleLongPress(key, id) }
        case .fader:
            if faders[id] != nil {
                faders[id]?.touching = true
            } else {
                withAnimation(.spring(response: tuning.openResponse, dampingFraction: 1 - tuning.openBounce)) {
                    faders[id] = FaderTouch()
                }
            }
        }
    }

    public func touchMoved(_ key: AnyHashable, to point: CGPoint) {
        guard var touch = touches[key] else { return }
        if touch.picking {
            if hypot(Double(point.x - touch.drag.start.x), Double(point.y - touch.drag.start.y)) > SliderDrag.tapSlop {
                touch.slid = true
                touches[key] = touch
            }
            let row = pickers[touch.id]?.rows.firstIndex { $0.insetBy(dx: -6, dy: -2).contains(point) }
            if row != pickers[touch.id]?.highlighted {
                pickers[touch.id]?.highlighted = row
                if row != nil { ticks += 1 }
            }
            return
        }
        let wasInDetent = touch.drag.inDetent
        let value = touch.drag.move(to: point, travel: touch.travel, tuning: tuning)
        touches[key] = touch
        if touch.drag.inDetent && !wasInDetent { ticks += 1 }
        set(value, for: touch.id)
        let overshoot = touch.drag.overshoot(travel: touch.travel)
        let id = touch.id
        if var panel = panels[id] {
            if overshoot != 0 && panel.overshoot == 0 { ticks += 1 }
            panel.overshoot = overshoot
            panel.factor = touch.drag.factor
            panels[id] = panel
        } else if var fader = faders[id] {
            if overshoot != 0 && fader.overshoot == 0 { ticks += 1 }
            fader.overshoot = overshoot
            fader.factor = touch.drag.factor
            faders[id] = fader
        }
    }

    public func touchUp(_ key: AnyHashable, at point: CGPoint, time: TimeInterval) {
        strays.remove(key)
        guard let touch = touches.removeValue(forKey: key) else { return }
        let id = touch.id
        if touch.picking {
            if !touch.slid {
                pickers[id]?.touching = false
            } else if let row = pickers[id]?.highlighted {
                choose(row, for: id)
            } else {
                closePicker(id)
            }
            return
        }
        if !touch.drag.moved && !touch.isReset {
            lastTap[id] = (time, touch.drag.start)
        }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.72)) {
            panels[id]?.overshoot = 0
            faders[id]?.overshoot = 0
        }
        panels[id]?.touching = false
        panels[id]?.factor = 1
        faders[id]?.touching = false
        faders[id]?.factor = 1
        scheduleClose(id)
    }

    private func set(_ value: Double, for id: SliderID) {
        guard let old = controls[id]?.value, old != value else { return }
        controls[id]?.value = value
        onChange?(id, value)
    }

    // MARK: The effect list

    private func scheduleLongPress(_ key: AnyHashable, _ id: SliderID) {
        let mine = generation[id, default: 0]
        let wait = tuning.longPress
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard let self, self.generation[id] == mine else { return }
            self.longPress(key)
        }
    }

    /// A finger held still on an FX chip: its panel gives way to the effect list,
    /// the current effect under the finger. The long-press timer calls this; tests
    /// and the lab's demos call it directly.
    public func longPress(_ key: AnyHashable) {
        guard var touch = touches[key], !touch.picking, !touch.drag.moved,
              let effect = controls[touch.id]?.spec.effect else { return }
        let id = touch.id
        touch.picking = true
        touches[key] = touch
        let options = DeckEffect.allCases
        let current = options.firstIndex(of: effect) ?? 0
        let rows = PickerPlacer.place(finger: touch.drag.start, count: options.count, current: current,
                                      bounds: bounds, tuning: tuning)
        withAnimation(.easeOut(duration: 0.15)) {
            pickers[id] = Picker(options: options, rows: rows, current: current, highlighted: current)
        }
        ticks += 1
        // The panel shrinks back into the chip.
        panels[id]?.touching = false
        panels[id]?.closing = true
        let shrink = max(0.15, tuning.openResponse * 1.4)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(shrink))
            guard let self, self.panels[id]?.closing == true else { return }
            self.panels[id] = nil
        }
    }

    private func waitingRow(at point: CGPoint) -> (SliderID, Int)? {
        for (id, picker) in pickers where !picker.touching {
            if let row = picker.rows.firstIndex(where: { $0.insetBy(dx: -4, dy: -2).contains(point) }) {
                return (id, row)
            }
        }
        return nil
    }

    /// Takes an effect from the list. The amount stays where it was, as a hardware
    /// knob would.
    private func choose(_ row: Int, for id: SliderID) {
        if let picker = pickers[id], picker.options.indices.contains(row), let spec = controls[id]?.spec {
            controls[id]?.spec = spec.with(picker.options[row])
        }
        closePicker(id)
    }

    private func closePicker(_ id: SliderID) {
        withAnimation(.easeOut(duration: 0.15)) { pickers[id] = nil }
    }

    // MARK: Panels and readouts

    private func open(_ id: SliderID, finger: CGPoint) {
        if panels[id] != nil {
            // Still up from a moment ago: keep it where it is rather than jump.
            panels[id]?.touching = true
            panels[id]?.closing = false
            return
        }
        guard let chip = frames[id], let control = controls[id] else { return }
        let others = panels.filter { $0.key != id && !$0.value.closing }.map { $0.value.layout.frame }
        let layout = PanelPlacer.place(chip: chip, finger: finger, fill: control.spec.fill(control.value),
                                       bounds: bounds, tuning: tuning, meter: control.spec.meter != .none,
                                       avoiding: others)
        panels[id] = Panel(layout: layout, origin: chip)
    }

    private func scheduleClose(_ id: SliderID) {
        let mine = generation[id, default: 0]
        let hold = tuning.holdAfterRelease
        let shrink = max(0.15, tuning.openResponse * 1.4)
        let spring = Animation.spring(response: tuning.openResponse, dampingFraction: 1 - tuning.openBounce)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(hold))
            guard let self, self.generation[id] == mine else { return }
            if self.faders[id]?.touching == false {
                withAnimation(spring) { self.faders[id] = nil }
                return
            }
            guard self.panels[id]?.touching == false else { return }
            self.panels[id]?.closing = true
            try? await Task.sleep(for: .seconds(shrink))
            guard self.generation[id] == mine, self.panels[id]?.closing == true else { return }
            self.panels[id] = nil
        }
    }
}
