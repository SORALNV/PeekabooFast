import ApplicationServices
import Foundation
import Testing
@testable import PeekabooAutomationKit

struct ElectronAccessibilityBootstrapTests {
    @Test(arguments: [false, true])
    func `only Electron targets receive the accessibility handshake`(_ isElectron: Bool) throws {
        var validations = 0
        var writes = 0
        try ElectronAccessibilityBootstrap.request(
            isElectron: isElectron,
            deadline: .now.advanced(by: .seconds(1)),
            validateIdentity: { validations += 1 },
            setManualAccessibility: { writes += 1; return .success })
        #expect(writes == (isElectron ? 1 : 0))
        #expect(validations == (isElectron ? 2 : 0))
    }

    @Test
    func `expired observation never requests accessibility`() throws {
        var writes = 0
        try ElectronAccessibilityBootstrap.request(
            isElectron: true,
            deadline: .now.advanced(by: .seconds(-1)),
            validateIdentity: { Issue.record("Expired observation must not resolve a target") },
            setManualAccessibility: { writes += 1; return .success })
        #expect(writes == 0)
    }

    @Test
    func `changed process identity prevents the handshake`() {
        var writes = 0
        #expect(throws: CancellationError.self) {
            try ElectronAccessibilityBootstrap.request(
                isElectron: true,
                deadline: .now.advanced(by: .seconds(1)),
                validateIdentity: { throw CancellationError() },
                setManualAccessibility: { writes += 1; return .success })
        }
        #expect(writes == 0)
    }

    @Test(arguments: [AXError.attributeUnsupported, .cannotComplete, .failure])
    func `a rejected handshake never tries an alternate setting`(_ result: AXError) throws {
        var writes = 0
        try ElectronAccessibilityBootstrap.request(
            isElectron: true,
            deadline: .now.advanced(by: .seconds(1)),
            validateIdentity: {},
            setManualAccessibility: { writes += 1; return result })
        #expect(writes == 1)
    }
}
