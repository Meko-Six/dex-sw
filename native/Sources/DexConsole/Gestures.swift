import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#endif

/// The decks' playheads, published apart from `ConsoleState` so a running
/// track redraws only the lanes, overviews, platters and time readouts, not
/// the whole console. Snapshots have no clock and draw `Deck.position`.
@MainActor public final class ConsoleClock {
    private var decks: [String: DeckClock] = [:]
    private var lanes: [String: LaneClock] = [:]
    public let meter = MeterClock()
    public init() {}
    /// Whether a deck is moving and the display should drive the lanes.
    public var running = false {
        didSet {
            guard running != oldValue else { return }
            setLinkRunning?(running)
            if !running { lanes.values.forEach { $0.settle() } }
        }
    }
    var setLinkRunning: ((Bool) -> Void)?
    /// A display frame is coming up in `ahead` seconds: move the lanes to it.
    public func frame(ahead: Double) {
        for lane in lanes.values { lane.frame(ahead: ahead) }
    }
    /// What moves with `id` about 30 times a second: its readouts, overview and platter.
    public func deck(_ id: String) -> DeckClock {
        if let clock = decks[id] { return clock }
        let clock = DeckClock(); decks[id] = clock
        return clock
    }
    /// What moves with `id` every display frame: its zoom lane.
    public func lane(_ id: String) -> LaneClock {
        if let clock = lanes[id] { return clock }
        let clock = LaneClock(); lanes[id] = clock
        return clock
    }
}

/// Each listens only for its own changes, so one deck's clock redraws nothing of the other's.
@MainActor public final class DeckClock: ObservableObject {
    @Published public var position: Double?
    public init() {}
}

@MainActor public final class MeterClock: ObservableObject {
    /// The four meters, read each display frame while there's something to show; nil at rest.
    @Published public var meters: Meters?
    public init() {}
}

/// A zoom lane's position. While a deck plays the display sets `moving` once a
/// frame; otherwise the position only changes when something moves the deck.
@MainActor public final class LaneClock: ObservableObject {
    /// The position heard this many seconds from now, or nil when the deck is still.
    public var heard: ((Double) -> Double?)?
    /// Where the lane is for the coming display frame; nil when it is at rest.
    @Published public private(set) var moving: Double?
    /// Where the lane rests. Updates quietly while it moves.
    public private(set) var position: Double?
    public init() {}
    public func set(_ value: Double, publish: Bool) {
        if publish { objectWillChange.send() }
        position = value
    }
    func frame(ahead: Double) {
        // A still lane stays quiet while the other deck's frames go by.
        let next = heard?(ahead)
        if next != moving { moving = next }
    }
    func settle() { if moving != nil { moving = nil } }
}

private struct ClockKey: EnvironmentKey {
    static let defaultValue: ConsoleClock? = nil
}

private struct StageScaleKey: EnvironmentKey {
    static let defaultValue = 1.0
}

private struct SnapshotKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// How much the fitted stage is enlarged, for what is drawn ahead of time. Never below 1.
    var stageScale: Double {
        get { self[StageScaleKey.self] }
        set { self[StageScaleKey.self] = newValue }
    }
    var consoleClock: ConsoleClock? {
        get { self[ClockKey.self] }
        set { self[ClockKey.self] = newValue }
    }
    /// Drawn offline by `ImageRenderer`, which cannot draw platform views:
    /// text fields, scroll views and drag-and-drop targets draw as plain views.
    var consoleSnapshot: Bool {
        get { self[SnapshotKey.self] }
        set { self[SnapshotKey.self] = newValue }
    }
}

extension View {
    /// Applies `transform` only in the live console, not in snapshots.
    @ViewBuilder func live<Output: View>(_ snapshot: Bool, _ transform: (Self) -> Output) -> some View {
        if snapshot { self } else { transform(self) }
    }
}

/// `content` with the deck at its live position.
struct Live<Content: View>: View {
    let deck: ConsoleState.Deck
    @ViewBuilder let content: (ConsoleState.Deck) -> Content
    @Environment(\.consoleClock) private var clock

    var body: some View {
        if let clock { Clocked(clock: clock.deck(deck.id), deck: deck, content: content) } else { content(deck) }
    }

    private struct Clocked: View {
        @ObservedObject var clock: DeckClock
        let deck: ConsoleState.Deck
        let content: (ConsoleState.Deck) -> Content

        var body: some View {
            content(clock.position.map { position in deck.with { $0.position = position } } ?? deck)
        }
    }
}

/// `content` with the live meters, or `fallback` without a clock.
struct LiveMeters<Content: View>: View {
    let fallback: Meters
    @ViewBuilder let content: (Meters) -> Content
    @Environment(\.consoleClock) private var clock

    var body: some View {
        if let clock { Clocked(clock: clock.meter, fallback: fallback, content: content) } else { content(fallback) }
    }

    private struct Clocked: View {
        @ObservedObject var clock: MeterClock
        let fallback: Meters
        let content: (Meters) -> Content

        var body: some View { content(clock.meters ?? fallback) }
    }
}

/// Which controls are under a finger, for the drag looks: the FINE readouts,
/// the dragging borders and held kill pads (`active` and `held` in
/// `useMixDrags.ts`). Keys are "A-level", "B-low", "xfade" and so on.
@MainActor final class ControlTouches: ObservableObject {
    @Published private(set) var speeds: [String: Double] = [:]
    @Published private(set) var held: Set<String> = []

    func set(_ key: String, speed: Double?) {
        if speeds[key] != speed { speeds[key] = speed }
    }
    func hold(_ key: String, _ on: Bool) {
        if on { held.insert(key) } else { held.remove(key) }
    }
}

/// Time for taps and holds, in seconds.
private func now() -> Double { ProcessInfo.processInfo.systemUptime }

extension View {
    /// Runs `released` when a gesture state falls back to its reset value:
    /// the cleanup for a touch the system cancelled without an `onEnded`.
    func onRelease(_ held: Bool, perform released: @escaping () -> Void) -> some View {
        onValueChange(of: held) { down in if !down { released() } }
    }

    /// `onChange(of:)` with the new value, on every OS the console runs on.
    func onValueChange<Value: Equatable>(of value: Value, perform action: @escaping (Value) -> Void) -> some View {
        modifier(ChangeObserver(value: value, action: action))
    }

    /// The chassis drag, as in `useMixDrags.ts`: the control moves by the
    /// finger's travel, never to the finger, after 3 pt of movement. Moving
    /// the finger 60 pt across the control slows it to ¼, 120 pt to ⅒. A
    /// double tap sets `reset`. `travel` is the run of the cap's centre.
    func relativeDrag(_ key: String, horizontal: Bool = false, travel: CGFloat, value: Double, reset: Double,
                      enabled: Bool = true, set: @escaping (Double) -> Void) -> some View {
        modifier(RelativeDrag(key: key, horizontal: horizontal, travel: travel, value: value, reset: reset, enabled: enabled, set: set))
    }

    /// A press reported at touch-down, then its release wherever the finger
    /// went; `up` gets nil when the system cancels the touch. Locations are
    /// in units of the control's size, so (1.5, 0.5) is half a width to its
    /// right. On iPad a UIKit control owns the touch, so a held press never
    /// waits on SwiftUI recognising a gesture or redrawing.
    func press(enabled: Bool = true, down: @escaping () -> Void, moved: @escaping (CGPoint) -> Void = { _ in },
               up: @escaping (CGPoint?) -> Void) -> some View {
        modifier(Press(enabled: enabled, down: down, moved: moved, up: up))
    }
}

private struct ChangeObserver<Value: Equatable>: ViewModifier {
    let value: Value
    let action: (Value) -> Void

    func body(content: Content) -> some View {
        if #available(macOS 14, iOS 17, *) {
            content.onChange(of: value) { _, new in action(new) }
        } else {
            content.onChange(of: value, perform: action)
        }
    }
}

private struct RelativeDrag: ViewModifier {
    let key: String
    let horizontal: Bool
    let travel: CGFloat
    let value: Double
    let reset: Double
    let enabled: Bool
    let set: (Double) -> Void
    @EnvironmentObject private var touches: ControlTouches
    @GestureState private var touching = false
    @State private var drag: Drag?
    @State private var lastTap = -1.0

    private struct Drag {
        var start: CGPoint
        var last: CGFloat
        var travelled: CGFloat = 0
        var moved = false
        /// The value this drag has set, so moves never wait on a redraw.
        var value: Double
    }

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .updating($touching) { _, state, _ in state = true }
                .onChanged(changed)
                .onEnded { _ in ended() },
                     including: enabled ? .all : .subviews)
            .onRelease(touching) { finish() }
    }

    private func changed(_ gesture: DragGesture.Value) {
        let along = horizontal ? gesture.location.x : gesture.location.y
        guard var d = drag, d.start == gesture.startLocation else {
            drag = Drag(start: gesture.startLocation, last: along, value: value)
            return
        }
        // Up and right raise the value (for tempo, up is slower, as on a CDJ).
        let delta = horizontal ? along - d.last : d.last - along
        d.last = along
        let cross = abs(horizontal ? gesture.location.y - d.start.y : gesture.location.x - d.start.x)
        let speed = cross >= 120 ? 0.1 : cross >= 60 ? 0.25 : 1
        d.travelled += abs(delta)
        if !d.moved {
            guard d.travelled >= 3 else { drag = d; return }
            d.moved = true
        }
        touches.set(key, speed: speed)
        d.value = min(1, max(0, d.value + Double(delta / travel) * speed))
        set(d.value)
        drag = d
    }

    private func ended() {
        guard let d = drag, !d.moved else { return }
        let time = now()
        if time - lastTap < 0.32 {
            set(reset)
            lastTap = -1
        } else {
            lastTap = time
        }
    }

    private func finish() {
        drag = nil
        touches.set(key, speed: nil)
    }
}

private struct Press: ViewModifier {
    let enabled: Bool
    let down: () -> Void
    let moved: (CGPoint) -> Void
    let up: (CGPoint?) -> Void
#if !os(iOS)
    @GestureState private var touching = false
    @State private var pressed = false
#endif

    func body(content: Content) -> some View {
#if os(iOS)
        content.overlay {
            PressSurface(enabled: enabled, down: down, moved: moved, up: up)
        }
#else
        GeometryReader { geometry in
            let unit = { (point: CGPoint) in
                CGPoint(x: point.x / max(1, geometry.size.width), y: point.y / max(1, geometry.size.height))
            }
            content
                .frame(width: geometry.size.width, height: geometry.size.height)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .updating($touching) { _, state, _ in state = true }
                    .onChanged { gesture in
                        guard enabled else { return }
                        if !pressed { pressed = true; down() } else { moved(unit(gesture.location)) }
                    }
                    .onEnded { gesture in
                        guard pressed else { return }
                        pressed = false
                        up(unit(gesture.location))
                    })
                .onRelease(touching) {
                    guard pressed else { return }
                    pressed = false
                    up(nil)
                }
        }
#endif
    }
}

#if os(iOS)
private struct PressSurface: UIViewRepresentable {
    let enabled: Bool
    let down: () -> Void
    let moved: (CGPoint) -> Void
    let up: (CGPoint?) -> Void

    func makeUIView(context: Context) -> PressControl {
        let control = PressControl()
        control.backgroundColor = .clear
        control.isExclusiveTouch = false
        // The SwiftUI view under it owns accessibility.
        control.isAccessibilityElement = false
        update(control)
        return control
    }
    func updateUIView(_ control: PressControl, context: Context) { update(control) }
    static func dismantleUIView(_ control: PressControl, coordinator: ()) { control.release(at: nil) }

    private func update(_ control: PressControl) {
        control.down = down; control.moved = moved; control.up = up
        if !enabled { control.release(at: nil) }
        control.isEnabled = enabled
    }
}

final class PressControl: UIControl {
    var down: () -> Void = {}
    var moved: (CGPoint) -> Void = { _ in }
    var up: (CGPoint?) -> Void = { _ in }
    private var holding = false

    private func unit(_ touch: UITouch) -> CGPoint {
        let point = touch.location(in: self)
        return CGPoint(x: point.x / max(1, bounds.width), y: point.y / max(1, bounds.height))
    }
    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard isEnabled, !holding else { return false }
        holding = true
        down()
        return true
    }
    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard holding else { return false }
        moved(unit(touch))
        return true
    }
    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        release(at: touch.map(unit))
    }
    override func cancelTracking(with event: UIEvent?) {
        release(at: nil)
        super.cancelTracking(with: event)
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { release(at: nil) }
    }
    func release(at point: CGPoint?) {
        guard holding else { return }
        holding = false
        up(point)
    }
}
#endif

/// Files and library rows dropped on a deck's window or lane. While one is
/// held over the deck its window says what will happen; a playing deck
/// refuses. Ports `useDeckDrop` in `drop.ts`.
struct DeckDrop: DropDelegate {
    let deck: ConsoleState.Deck
    /// The library row being dragged: a drag picks its row.
    let row: String?
    let actions: ConsoleActions

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.audio, .plainText]) }

    func dropEntered(info: DropInfo) {
        let files = info.itemProviders(for: [.audio]).count
        let label = files > 1 ? "\(files) files · analysed, the last one loaded"
            : files == 1 ? "Audio file · analysed, then loaded"
            : row.map { "\($0) · from the library" } ?? "From the library"
        actions.setDrop(ConsoleState.Drop(deck: deck.id, label: label))
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: deck.playing ? .forbidden : .copy) }

    func dropExited(info: DropInfo) { actions.setDrop(nil) }

    func performDrop(info: DropInfo) -> Bool {
        actions.setDrop(nil)
        guard !deck.playing else { return false }
        // The console's actions are only ever called back on the main actor.
        nonisolated(unsafe) let actions = actions
        let id = deck.id
        let files = info.itemProviders(for: [.audio])
        if !files.isEmpty {
            // Each file arrives as a temporary copy, valid only in its callback.
            Task {
                var urls: [URL] = []
                for provider in files { if let url = await Self.copy(provider) { urls.append(url) } }
                if !urls.isEmpty { await MainActor.run { actions.dropFiles(id, urls) } }
            }
            return true
        }
        guard let provider = info.itemProviders(for: [.plainText]).first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { item, _ in
            guard let item = item as? NSString else { return }
            let track = item as String
            Task { @MainActor in actions.dropTrack(id, track) }
        }
        return true
    }

    private static func copy(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: UTType.audio.identifier) { url, _ in
                guard let url else { return continuation.resume(returning: nil) }
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                let copy = folder.appendingPathComponent(url.lastPathComponent)
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: url, to: copy)
                    continuation.resume(returning: copy)
                } catch { continuation.resume(returning: nil) }
            }
        }
    }
}
