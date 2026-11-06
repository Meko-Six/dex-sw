import QuartzCore
import SwiftUI

/// Drives `ConsoleClock.frame` from the display of the window it sits in, with the
/// time the coming frame will appear. It only runs while `ConsoleClock.running`.
@MainActor final class FrameLink: NSObject {
    private let clock: ConsoleClock
    private var stop: (() -> Void)?

    init(clock: ConsoleClock) { self.clock = clock }

    #if os(macOS)
    func attach(to view: NSView) {
        if #available(macOS 14, *) {
            run(view.displayLink(target: self, selector: #selector(frame(_:))))
        } else {
            let timer = Timer(timeInterval: 1 / 60, repeats: true) { [clock] _ in
                MainActor.assumeIsolated { clock.frame(ahead: 1 / 60) }
            }
            RunLoop.main.add(timer, forMode: .common)
            stop = { timer.invalidate() }
        }
    }
    #else
    func attach(to view: UIView) { run(CADisplayLink(target: self, selector: #selector(frame(_:)))) }
    #endif

    @available(macOS 14, *)
    private func run(_ link: CADisplayLink) {
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        link.isPaused = !clock.running
        link.add(to: .main, forMode: .common)
        clock.setLinkRunning = { link.isPaused = !$0 }
        stop = { link.invalidate() }
    }

    @available(macOS 14, *)
    @objc private func frame(_ link: CADisplayLink) { clock.frame(ahead: link.targetTimestamp - CACurrentMediaTime()) }

    func detach() {
        clock.setLinkRunning = nil
        stop?(); stop = nil
    }
}

#if os(macOS)
struct FrameLinkView: NSViewRepresentable {
    let clock: ConsoleClock
    func makeCoordinator() -> FrameLink { FrameLink(clock: clock) }
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.attach(to: view)
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
    static func dismantleNSView(_ view: NSView, coordinator: FrameLink) { coordinator.detach() }
}
#else
struct FrameLinkView: UIViewRepresentable {
    let clock: ConsoleClock
    func makeCoordinator() -> FrameLink { FrameLink(clock: clock) }
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        context.coordinator.attach(to: view)
        return view
    }
    func updateUIView(_ view: UIView, context: Context) {}
    static func dismantleUIView(_ view: UIView, coordinator: FrameLink) { coordinator.detach() }
}
#endif
