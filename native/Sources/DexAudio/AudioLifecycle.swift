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
