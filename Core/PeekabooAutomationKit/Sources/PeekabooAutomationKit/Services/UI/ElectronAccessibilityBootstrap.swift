import ApplicationServices
import Foundation

/// Requests Electron's native AX tree without activation, pointer input, or VoiceOver mode.
/// Electron can accept this request while reading AXManualAccessibility back as false. Neither
/// that readback nor setter acceptance proves usable actions; callers must inspect fresh state.
enum ElectronAccessibilityBootstrap {
    static func request(
        isElectron: Bool,
        deadline: ContinuousClock.Instant,
        validateIdentity: () throws -> Void,
        setManualAccessibility: () -> AXError) throws
    {
        guard isElectron, ContinuousClock.now < deadline else { return }
        try Task.checkCancellation()
        try validateIdentity()
        guard ContinuousClock.now < deadline else { return }
        // Unsupported or rejected requests simply leave observation to report its actual evidence.
        // Never broaden this into AXEnhancedUserInterface or an app/window focus fallback.
        _ = setManualAccessibility()
        try validateIdentity()
    }
}
