import AVFoundation
import Dispatch

/// Blocking AVFoundation control calls share one serial, default-QoS lane.
/// UI code never synchronously waits for it; the render callback never uses it.
final class AudioControlExecutor: Sendable {
    static let shared = AudioControlExecutor()
    private let queue = DispatchQueue(label: "Dex.audio.control", qos: .default)
    func submit(_ operation: @escaping @Sendable () -> Void) { queue.async(execute: operation) }
    func run<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try operation() }) }
        }
    }
    func drain() async { _ = try? await run {} }
}

/// Hands an engine or node to the control lane, its only cross-thread user.
/// Older SDKs (CI's Xcode 26) do not mark AVFoundation objects Sendable.
struct ControlHandle<Object: AnyObject>: @unchecked Sendable { let object: Object }

/// Cancellation can arrive while a blocking system call is in progress. A
/// stale startup must never restart output after interruption, reset or shutdown.
final class AudioControlTicket: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}
