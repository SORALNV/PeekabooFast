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
            process: (identifier: 42, generation: 1),
            deadline: .now.advanced(by: .seconds(1)),
            ledger: .init(),
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
            process: (identifier: 42, generation: 1),
            deadline: .now.advanced(by: .seconds(-1)),
            ledger: .init(),
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
                process: (identifier: 42, generation: 1),
                deadline: .now.advanced(by: .seconds(1)),
                ledger: .init(),
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
            process: (identifier: 42, generation: 1),
            deadline: .now.advanced(by: .seconds(1)),
            ledger: .init(),
            validateIdentity: {},
            setManualAccessibility: { writes += 1; return result })
        #expect(writes == 1)
    }

    @Test
    func `polling cannot restart the Electron debounce and PID reuse requests a new handshake`() throws {
        let ledger = ElectronAccessibilityBootstrap.RequestLedger()
        var writes = 0
        var validations = 0
        for generation in [UInt64(1), 1, 1, 2, 2] {
            try ElectronAccessibilityBootstrap.request(
                isElectron: true,
                process: (identifier: 42, generation: generation),
                deadline: .now.advanced(by: .seconds(1)),
                ledger: ledger,
                validateIdentity: { validations += 1 },
                setManualAccessibility: { writes += 1; return .success })
        }
        #expect(writes == 2)
        #expect(validations == 7)
    }

    @Test
    func `quiet period expires without sleeping and ledger eviction stays bounded`() {
        let now = ContinuousClock.now
        let ledger = ElectronAccessibilityBootstrap.RequestLedger(quietPeriod: .seconds(3), capacity: 2)
        #expect(ledger.claim(processIdentifier: 1, generation: 1, now: now))
        #expect(!ledger.claim(processIdentifier: 1, generation: 1, now: now.advanced(by: .seconds(2))))
        #expect(ledger.claim(processIdentifier: 1, generation: 1, now: now.advanced(by: .seconds(3))))
        #expect(ledger.claim(processIdentifier: 2, generation: 1, now: now.advanced(by: .seconds(4))))
        #expect(ledger.claim(processIdentifier: 3, generation: 1, now: now.advanced(by: .seconds(5))))
        #expect(ledger.claim(processIdentifier: 1, generation: 1, now: now.advanced(by: .seconds(6))))
        #expect(!ledger.claim(processIdentifier: 3, generation: 1, now: now.advanced(by: .seconds(6))))
    }
}
