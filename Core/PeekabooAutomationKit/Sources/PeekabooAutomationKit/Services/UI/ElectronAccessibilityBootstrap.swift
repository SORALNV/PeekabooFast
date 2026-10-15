import ApplicationServices
import Foundation
import os

/// Requests Electron's native AX tree without activation, pointer input, or VoiceOver mode.
/// Electron can accept this request while reading AXManualAccessibility back as false. Neither
/// that readback nor setter acceptance proves usable actions; callers must inspect fresh state.
enum ElectronAccessibilityBootstrap {
    /// Electron debounces this setter for two seconds. Repeating it in every verify sample
    /// postpones activation indefinitely. This ledger suppresses requests, never AX validation.
    final class RequestLedger: Sendable {
        private struct Attempt: Sendable {
            let generation: UInt64
            let time: ContinuousClock.Instant
        }

        private let attempts = OSAllocatedUnfairLock(initialState: [Int32: Attempt]())
        private let quietPeriod: Duration
        private let capacity: Int

        init(quietPeriod: Duration = .seconds(30), capacity: Int = 256) {
            self.quietPeriod = quietPeriod
            self.capacity = max(1, capacity)
        }

        func claim(processIdentifier: Int32, generation: UInt64, now: ContinuousClock.Instant) -> Bool {
            self.attempts.withLock { attempts in
                if let previous = attempts[processIdentifier], previous.generation == generation,
                   now < previous.time.advanced(by: self.quietPeriod)
                {
                    return false
                }
                if attempts[processIdentifier] == nil, attempts.count >= self.capacity,
                   let oldest = attempts.min(by: { $0.value.time < $1.value.time })?.key
                {
                    attempts.removeValue(forKey: oldest)
                }
                attempts[processIdentifier] = Attempt(generation: generation, time: now)
                return true
            }
        }
    }

    private static let sharedLedger = RequestLedger()

    static func request(
        isElectron: Bool,
        process: (identifier: Int32, generation: UInt64),
        deadline: ContinuousClock.Instant,
        ledger: RequestLedger = sharedLedger,
        validateIdentity: () throws -> Void,
        setManualAccessibility: () -> AXError) throws
    {
        guard isElectron, ContinuousClock.now < deadline else { return }
        try Task.checkCancellation()
        try validateIdentity()
        guard ContinuousClock.now < deadline else { return }
        guard ledger.claim(
            processIdentifier: process.identifier, generation: process.generation, now: .now)
        else { return }
        // Unsupported or rejected requests simply leave observation to report its actual evidence.
        // Never broaden this into AXEnhancedUserInterface or an app/window focus fallback.
        _ = setManualAccessibility()
        try validateIdentity()
    }
}
