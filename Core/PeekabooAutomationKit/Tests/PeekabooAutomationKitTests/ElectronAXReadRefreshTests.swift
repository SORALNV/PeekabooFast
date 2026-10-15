import CoreGraphics
import Foundation
import Testing
@testable import PeekabooAutomationKit

struct ElectronAXReadRefreshTests {
    @Test
    func `web read stays inside the exact owner and discards hit authority`() {
        var points: [CGPoint] = []
        let issued = ElectronAXReadRefresh.request(
            role: "AXWebArea",
            bounds: (
                window: CGRect(x: 10, y: 20, width: 100, height: 100),
                element: CGRect(x: 0, y: 0, width: 80, height: 80)),
            deadline: .now.advanced(by: .seconds(1)),
            ownsExactWindow: { true },
            hitTest: { points.append($0) })
        #expect(issued)
        #expect(points == [CGPoint(x: 45, y: 50)])
    }

    @Test(arguments: [0, 1, 2, 3])
    func `nonweb mismatched expired and disjoint reads cannot request a renderer hit`(_ rejection: Int) {
        var calls = 0
        let bounds = CGRect(x: 10, y: 20, width: 100, height: 100)
        let issued = ElectronAXReadRefresh.request(
            role: rejection == 0 ? "AXWindow" : "AXWebArea",
            bounds: (window: bounds, element: rejection == 3 ? CGRect(x: 300, y: 300, width: 10, height: 10) : bounds),
            deadline: .now.advanced(by: .seconds(rejection == 2 ? -1 : 1)),
            ownsExactWindow: { rejection != 1 },
            hitTest: { _ in calls += 1 })
        #expect(!issued)
        #expect(calls == 0)
    }
}
