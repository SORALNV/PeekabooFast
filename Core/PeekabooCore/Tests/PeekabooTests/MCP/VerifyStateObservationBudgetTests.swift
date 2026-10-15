import Testing
@testable import PeekabooAgentRuntime

struct VerifyStateObservationBudgetTests {
    @Test func `AX timeout uses only the budget remaining after resolution`() {
        let start = ContinuousClock.now
        let deadline = start.advanced(by: .seconds(1))
        let timeout = VerifyStateTool.accessibilityTimeout(until: deadline, now: start.advanced(by: .milliseconds(750)))
        #expect(timeout == 0.25)
        #expect(VerifyStateTool.accessibilityTimeout(until: deadline, now: deadline) == nil)
        #expect(VerifyStateTool.accessibilityTimeout(
            until: deadline, now: deadline.advanced(by: .milliseconds(-49))) == nil)
        #expect(VerifyStateTool.accessibilityTimeout(
            until: start.advanced(by: .seconds(20)), now: start) == 10)
    }
}
