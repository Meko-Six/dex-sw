import Foundation

/// Preparation-side accounting only. No lock or reservation runs on the audio render thread.
/// The engine's cache is fixed memory, held for the engine's life: it's counted here, but on
/// top of the preparation limit, so it never leaves loads and analysis without room, memory
/// pressure included.
final class AudioMemoryBudget: @unchecked Sendable {
    static let shared = AudioMemoryBudget(limit: 128 * 1024 * 1024)
    private let lock = NSLock()
    private let normalLimit: Int64
    private var limit: Int64
    private var used: Int64 = 0
    /// Fixed memory: counted in `used` and added to the limit.
    private var fixed: Int64 = 0
    private var pressureUntil = 0.0
    init(limit: Int64) { self.limit = limit; normalLimit = limit }
    final class Lease: @unchecked Sendable {
        private let owner: AudioMemoryBudget
        let bytes: Int64
        fileprivate let isFixed: Bool
        fileprivate init(owner: AudioMemoryBudget, bytes: Int64, fixed: Bool) { self.owner = owner; self.bytes = bytes; isFixed = fixed }
        deinit { owner.release(self) }
    }
    func reserve(_ bytes: Int64) throws -> Lease {
        lock.lock(); defer { lock.unlock() }
        if pressureUntil > 0 && ProcessInfo.processInfo.systemUptime >= pressureUntil {
            limit = normalLimit; pressureUntil = 0
        }
        guard bytes > 0, bytes <= limit + fixed - used else { throw BudgetError.exhausted }
        used += bytes
        return Lease(owner: self, bytes: bytes, fixed: false)
    }
    /// Memory held for as long as its owner lives, such as the engine's cache. It always
    /// succeeds, and leaves the preparation limit as it was.
    func reserveFixed(_ bytes: Int64) -> Lease {
        lock.lock(); defer { lock.unlock() }
        used += bytes; fixed += bytes
        return Lease(owner: self, bytes: bytes, fixed: true)
    }
    private func release(_ lease: Lease) {
        lock.lock()
        used -= lease.bytes
        if lease.isFixed { fixed -= lease.bytes }
        lock.unlock()
    }
    var reservedBytes: Int64 { lock.lock(); defer { lock.unlock() }; return used }
    func setPressure(_ active: Bool) {
        lock.lock(); limit = active ? normalLimit / 2 : normalLimit
        pressureUntil = active ? ProcessInfo.processInfo.systemUptime + 30 : 0
        lock.unlock()
    }
    enum BudgetError: Error { case exhausted }
}
