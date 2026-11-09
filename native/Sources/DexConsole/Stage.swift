import SwiftUI

/// The console's fixed stage, in points: the 11" iPad Pro canvas less the
/// mockup's bezel. Matches `src/renderer/console/layout.ts`.
public enum Stage {
    public static let width: CGFloat = 1174
    public static let height: CGFloat = 814
    /// Spare height a taller window gives the zoom lanes, up to 4:3 (the 13" iPads).
    public static let maxStretch: CGFloat = width * 3 / 4 - height

    /// A deck's platter on the stage, for panels that sit over it.
    public static func platter(_ deck: String, stretch: CGFloat = 0) -> CGRect {
        // The chassis and its 1 pt top line end the stage.
        return Layout.platterRect(deck).offsetBy(dx: 0, dy: height + stretch - 475)
    }

    /// Uniform scale to fit `size`, and the stretch (in stage points) that
    /// fills its spare height. Same rule as the Electron app's `useFit`.
    public static func fit(_ size: CGSize) -> (scale: CGFloat, stretch: CGFloat) {
        let scale = min(size.width / width, size.height / height)
        guard scale.isFinite, scale > 0 else { return (1, 0) }
        return (scale, min(maxStretch, max(0, size.height / scale - height)))
    }
}

/// The console at stage size; `stretch` grows the zoom lanes. Popovers,
/// the library and the sheets draw over it as in the Electron app's `App`.
public struct ConsoleStage: View {
    let state: ConsoleState
    let actions: ConsoleActions
    let stretch: CGFloat
    let libraryStart: LibraryView
    let snapshot: Bool
    @StateObject private var touches = ControlTouches()

    /// `snapshot` draws platform views (fields, scrolling) as plain views, for `ImageRenderer`.
    public init(state: ConsoleState, actions: ConsoleActions = ConsoleActions(), stretch: CGFloat = 0,
                libraryStart: LibraryView = LibraryView(), snapshot: Bool = false) {
        self.state = state; self.actions = actions; self.stretch = stretch; self.libraryStart = libraryStart
        self.snapshot = snapshot
    }

    public var body: some View {
        let more = state.more.flatMap { state.library.track($0.track) }
        let sheet = state.gridDeck != nil || state.sheet != nil || more != nil
        let height = Stage.height + stretch
        ZStack(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                console
                if !state.libraryOpen { mixerPopover(above: height - 475 - 8) }
                if state.volumeOpen { VolumePop(state: state, actions: actions).offset(x: Stage.width - 10 - VolumePop.width, y: 40) }
                LibraryPane(state: state, actions: actions, start: libraryStart)
                    .frame(width: Stage.width, height: height - 258)
                    .offset(y: state.libraryOpen ? 258 : height * 1.02)
                    .allowsHitTesting(state.libraryOpen)
                    .accessibilityHidden(!state.libraryOpen)
                if let alert = state.alert {
                    AlertBar(alert: alert, dismiss: actions.dismissAlert)
                        .frame(width: Stage.width).offset(y: 38)
                }
            }
            // `backdrop-filter: blur(7px)` under the sheet.
            .blur(radius: sheet ? 7 : 0)
            if sheet {
                SheetLayer(close: closeSheet) {
                    if let more, let open = state.more {
                        MoreSheet(track: more, more: open, state: state, actions: actions)
                    } else if let id = state.gridDeck, let deck = state.decks.first(where: { $0.id == id }) {
                        GridSheet(deck: deck, track: state.library.track(deck.trackID), actions: actions).id(id)
                    } else if state.sheet == .shortcuts {
                        ShortcutsSheet(actions: actions)
                    } else if state.sheet == .tap {
                        TapSheet(state: state, actions: actions)
                    }
                }
            }
        }
        .blur(radius: state.help != nil ? 4 : 0)
        .overlay {
            if let help = state.help {
                SheetLayer(dim: 0.7, close: { actions.setHelp(nil) }) { HelpSheet(topic: help, actions: actions) }
            }
        }
        .frame(width: Stage.width, height: height, alignment: .topLeading)
        .clipped()
        .animation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.24), value: state.libraryOpen)
        .environmentObject(touches)
        .environment(\.consoleSnapshot, snapshot)
    }

    /// These controls sit above the mixer so the meters and LEVEL stay visible.
    @ViewBuilder private func mixerPopover(above bottom: CGFloat) -> some View {
        switch state.mixPop {
        case .trim(let id):
            if let deck = state.decks.first(where: { $0.id == id }) {
                TrimPop(deck: deck, actions: actions).offset(x: id == "A" ? 60 : 814, y: bottom - TrimPop.height)
            }
        case .filter(let id):
            if let deck = state.decks.first(where: { $0.id == id }) {
                FilterPop(deck: deck, actions: actions)
                    .offset(x: Layout.filterButton(id).midX - FilterPop.width / 2, y: bottom - FilterPop.height)
            }
        case .master:
            VolumePop(state: state, actions: actions, masterOnly: true)
                .offset(x: (Stage.width - VolumePop.width) / 2, y: bottom - VolumePop.masterHeight)
        default:
            EmptyView()
        }
    }

    private var console: some View {
        VStack(spacing: 0) {
            Head(state: state, actions: actions)
            // Library open: the zoom lanes fold away.
            Screen(state: state, actions: actions, stretch: stretch)
                .frame(height: state.libraryOpen ? 0 : 162 + stretch, alignment: .top)
                .clipped()
            TrackWindows(state: state, actions: actions)
            Chassis(state: state, actions: actions)
        }
        .frame(width: Stage.width, height: Stage.height + stretch, alignment: .top)
        .background(Palette.stage)
    }

    /// A tap outside the sheet closes it.
    private func closeSheet() {
        if state.more != nil { actions.library.setMore(nil) } else if state.gridDeck != nil { actions.closeGrid() } else { actions.setSheet(nil) }
    }
}

/// The stage scaled to fit any window, letterboxed in black beyond 4:3.
/// `accessory` draws over the stage in its points, given the stretch.
public struct FittedConsole<Accessory: View>: View {
    let state: ConsoleState
    let actions: ConsoleActions
    let clock: ConsoleClock?
    let accessory: (CGFloat) -> Accessory
    var libraryStart = LibraryView()

    /// `clock`, when given, moves the playheads between state changes.
    public init(state: ConsoleState, actions: ConsoleActions = ConsoleActions(), clock: ConsoleClock? = nil,
                @ViewBuilder accessory: @escaping (CGFloat) -> Accessory) {
        self.state = state; self.actions = actions; self.clock = clock; self.accessory = accessory
    }

    public var body: some View {
        GeometryReader { geometry in
            let fit = Stage.fit(geometry.size)
            ConsoleStage(state: state, actions: actions, stretch: fit.stretch, libraryStart: libraryStart)
                .environment(\.consoleClock, clock)
                .environment(\.stageScale, max(1, (fit.scale * 100).rounded() / 100))
                .overlay(alignment: .topLeading) { accessory(fit.stretch) }
                .scaleEffect(fit.scale)
                .frame(width: Stage.width * fit.scale, height: (Stage.height + fit.stretch) * fit.scale)
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
        .background { if let clock { FrameLinkView(clock: clock) } }
        .background(Color.black)
    }
}

extension FittedConsole where Accessory == EmptyView {
    public init(state: ConsoleState, actions: ConsoleActions = ConsoleActions(), clock: ConsoleClock? = nil) {
        self.init(state: state, actions: actions, clock: clock) { _ in EmptyView() }
    }
}
