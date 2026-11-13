import AVFoundation
import Dispatch
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum AudioLifecycleEvent: Sendable {
    case interruptionBegan, interruptionEnded(shouldResume: Bool)
    case outputChanged, configurationChanged, servicesLost, servicesReset, willSleep, foreground, memoryWarning
}

/// What to do with the engine's notice that its configuration changed. Starting the engine
/// sets off such notices itself, and acting on those would restart it for ever; a real change
/// of output in the same moment must still be acted on.
enum ConfigurationChange: Equatable {
    case act, wait, ignore
    /// `starting`: a start is under way, and it can't be judged until that has finished.
    /// `settling`: a start has just finished. `running` and `sameOutput`: the engine is still
    /// going, into the output that start left it feeding.
    static func decide(starting: Bool, settling: Bool, running: Bool, sameOutput: Bool) -> Self {
        if starting { return .wait }
        if settling, running, sameOutput { return .ignore }
        return .act
    }
}

/// The audio output's life, as one value: which phase it is in and what each event does. It
/// touches nothing; `NativeMixer` carries out the effects it returns, and feeds back what
/// happened (a start that finished or failed, a rebuilt engine). Every path is tested here,
/// including ones only a real device can set off.
struct AudioLifecycle: Equatable {
    enum Phase: Equatable {
        /// Nothing asked for yet.
        case idle
        /// The output is being opened. `resume`: decks to play again once it is open.
        case starting(resume: [Bool], notice: MixerNotice?, retried: Bool)
        case running
        /// Another app or a call has the audio; `resume` is what was playing.
        case interrupted(resume: [Bool])
        /// The system's media services are gone until they are reset.
        case servicesLost
        /// After a reset: the old engine is being stopped and a new graph built.
        case rebuilding
        case asleep
        /// A start failed; the next foreground or start tries again.
        case failed
        case shutDown
    }
    enum Event: Equatable {
        /// The app asks for audio. `engineRunning`: the output is already open.
        case start(engineRunning: Bool)
        /// The output opened, feeding `output`; `runningNow` and `outputNow` are as it stands now.
        case started(output: OutputLatency.Signature?, runningNow: Bool, outputNow: OutputLatency.Signature?)
        case startFailed
        /// The engine said its configuration changed, at `now`, as it stands.
        case configurationNotice(now: Double, running: Bool, output: OutputLatency.Signature?)
        /// A change of configuration to act on, already judged.
        case configurationChanged
        case outputChanged
        /// `playing`: the decks heard playing as it began.
        case interruptionBegan(playing: [Bool])
        case interruptionEnded(shouldResume: Bool)
        case servicesLost, servicesReset
        /// The new graph is built after a reset.
        case rebuilt
        case willSleep
        case foreground(engineRunning: Bool)
        case shutdown
    }
    enum Effect: Equatable {
        /// Freeze the decks where they were heard, and pause the output; any start is cancelled.
        case suspend
        /// Open the output, after `delay` seconds.
        case start(delay: Double)
        /// The output is open: decks back, `resume` played again, `notice` shown.
        case finish(resume: [Bool], notice: MixerNotice?)
        case notice(MixerNotice)
        /// Stop the old engine and build a new graph, then report `rebuilt`.
        case rebuild
        /// The start failed: no audio until the next foreground or start.
        case fail
    }

    private(set) var phase = Phase.idle
    /// Until then, a change of configuration may be the echo of the start just made.
    private var settlingUntil = -Double.infinity
    /// The engine reported a change while a start was under way; judged when it finishes.
    private(set) var changePending = false
    /// The output the last start left the engine feeding.
    private(set) var startedOutput: OutputLatency.Signature?
    /// How long a start just after a failed one waits, for an output still changing to settle.
    static let retryDelay = 0.5
    static let settleTime = 0.25

    var audioState: NativeMixer.AudioState {
        switch phase {
        case .idle, .running: .ready
        case .starting, .rebuilding: .recovering
        case .interrupted: .interrupted
        case .servicesLost, .asleep, .failed, .shutDown: .unavailable
        }
    }
    var isShutDown: Bool { phase == .shutDown }
    /// A start or a rebuild is under way.
    var busy: Bool {
        switch phase { case .starting, .rebuilding: true; default: false }
    }

    mutating func send(_ event: Event, now: Double = ProcessInfo.processInfo.systemUptime) -> [Effect] {
        if isShutDown, event != .start(engineRunning: false), event != .start(engineRunning: true) { return [] }
        switch event {
        case .start(let running):
            switch phase {
            case .interrupted, .servicesLost, .starting, .rebuilding: return []
            case .running where running: return []
            default: return begin(resume: [false, false], notice: nil, now: now)
            }
        case .started(let output, let runningNow, let outputNow):
            guard case .starting(let resume, let notice, _) = phase else { return [] }
            phase = .running
            startedOutput = output
            settlingUntil = now + Self.settleTime
            var effects: [Effect] = [.finish(resume: resume, notice: notice)]
            if changePending {
                changePending = false
                if !runningNow || outputNow != output { effects += send(.configurationChanged, now: now) }
            }
            return effects
        case .startFailed:
            switch phase {
            case .starting(_, _, let retried):
                // A change of output was under way: the output may not have settled, so one more
                // try, a moment later. Never a second, so a broken output can't loop.
                if changePending, !retried {
                    changePending = false
                    return begin(resume: [false, false], notice: .outputChangedPressPlay, now: now, retried: true, delay: Self.retryDelay)
                }
                changePending = false
                phase = .failed
                return [.fail]
            case .rebuilding:
                phase = .failed
                return [.fail]
            default: return []
            }
        case .configurationNotice(let at, let running, let output):
            switch ConfigurationChange.decide(starting: busy, settling: at < settlingUntil, running: running,
                                              sameOutput: running && output == startedOutput) {
            case .wait: changePending = true; return []
            case .ignore: return []
            case .act: return send(.configurationChanged, now: now)
            }
        case .configurationChanged:
            switch phase {
            case .interrupted, .servicesLost: return []
            default: return send(.outputChanged, now: now)
            }
        case .outputChanged:
            // Never start on its own on speakers after headphones or an interface go.
            switch phase {
            case .servicesLost: return [.suspend]
            case .interrupted:
                phase = .interrupted(resume: [false, false])
                return [.suspend, .notice(.outputChangedStaysPaused)]
            default:
                return [.suspend] + begin(resume: [false, false], notice: .outputChangedPressPlay, now: now)
            }
        case .interruptionBegan(let playing):
            switch phase {
            case .interrupted, .servicesLost: return []
            default:
                phase = .interrupted(resume: playing)
                return [.suspend, .notice(.interrupted)]
            }
        case .interruptionEnded(let shouldResume):
            guard case .interrupted(let resume) = phase else { return [] }
            return begin(resume: shouldResume ? resume : [false, false],
                         notice: shouldResume && resume.contains(true) ? nil : .readyPressPlay, now: now)
        case .servicesLost:
            phase = .servicesLost
            return [.suspend, .notice(.servicesRestarting)]
        case .servicesReset:
            phase = .rebuilding
            return [.suspend, .rebuild]
        case .rebuilt:
            guard phase == .rebuilding else { return [] }
            return begin(resume: [false, false], notice: .restoredPressPlay, now: now)
        case .willSleep:
            // Asleep with media services gone, they are still gone on waking.
            if phase != .servicesLost { phase = .asleep }
            return [.suspend, .notice(.pausedForSleep)]
        case .foreground(let running):
            switch phase {
            case .interrupted, .servicesLost, .starting, .rebuilding: return []
            default:
                guard !running else { return [] }
                return [.suspend] + begin(resume: [false, false], notice: .readyPressPlay, now: now)
            }
        case .shutdown:
            phase = .shutDown
            changePending = false
            return []
        }
    }

    private mutating func begin(resume: [Bool], notice: MixerNotice?, now: Double,
                                retried: Bool = false, delay: Double = 0) -> [Effect] {
        phase = .starting(resume: resume, notice: notice, retried: retried)
        settlingUntil = now + Self.settleTime
        return [.start(delay: delay)]
    }
}

/// Notification ownership is independent of engine ownership. Replacing an
/// engine removes its old subscriptions; callbacks capture only weak owners.
final class AudioLifecycleObservers: @unchecked Sendable {
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []
    private var pressure: DispatchSourceMemoryPressure?
    private func observe(_ name: Notification.Name, object: Any? = nil,
                         center: NotificationCenter = .default,
                         action: @escaping @Sendable (Notification) -> Void) {
        tokens.append((center, center.addObserver(forName: name, object: object, queue: .main, using: action)))
    }
    @MainActor
    func install(engine: AVAudioEngine, send: @escaping @Sendable (AudioLifecycleEvent) -> Void) {
        clear()
        observe(.AVAudioEngineConfigurationChange, object: engine) { _ in send(.configurationChanged) }
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        observe(AVAudioSession.interruptionNotification, object: session) { note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            if type == .began { send(.interruptionBegan) }
            else {
                let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                send(.interruptionEnded(shouldResume: AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume)))
            }
        }
        observe(AVAudioSession.routeChangeNotification, object: session) { note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
            if raw != AVAudioSession.RouteChangeReason.categoryChange.rawValue && raw != 0 { send(.outputChanged) }
        }
        observe(AVAudioSession.mediaServicesWereLostNotification, object: session) { _ in send(.servicesLost) }
        observe(AVAudioSession.mediaServicesWereResetNotification, object: session) { _ in send(.servicesReset) }
        observe(UIApplication.didReceiveMemoryWarningNotification) { _ in send(.memoryWarning) }
        #else
        observe(NSWorkspace.willSleepNotification, center: NSWorkspace.shared.notificationCenter) { _ in send(.willSleep) }
        observe(NSWorkspace.didWakeNotification, center: NSWorkspace.shared.notificationCenter) { _ in send(.foreground) }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { send(.memoryWarning) }
        pressure = source; source.resume()
        #endif
    }
    func clear() {
        for (center, token) in tokens { center.removeObserver(token) }
        tokens.removeAll(); pressure?.cancel(); pressure = nil
    }
    deinit { clear() }
}
