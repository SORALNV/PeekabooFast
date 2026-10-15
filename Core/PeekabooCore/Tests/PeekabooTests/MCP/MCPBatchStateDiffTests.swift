import Foundation
import MCP
import PeekabooAutomationKit
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime

@MainActor
struct MCPBatchStateDiffTests {
    private func steps(_ calls: [(String, [String: Value])]) -> ToolArguments {
        ToolArguments(value: .object(["steps": .array(calls.map {
            .object(["tool": .string($0.0), "arguments": .object($0.1)])
        })]))
    }

    @Test func `ordered results and failure stop`() async throws {
        let context = await MCPToolTestHelpers.makeContext()
        let tool = ExecuteStepsTool(context: context, tools: [SleepTool()])
        let response = try await context.execute(tool: tool, arguments: self.steps([
            ("sleep", ["duration": .int(1)]), ("sleep", ["duration": .int(-1)]),
            ("sleep", ["duration": .int(1)]),
        ]))
        #expect(response.isError)
        #expect(response.structuredContent?.objectValue?["completed"] == .int(2))
        #expect(response.structuredContent?.objectValue?["stopped_on_error"] == .bool(true))
    }

    @Test func `bounds and unavailable tools`() async throws {
        let context = await MCPToolTestHelpers.makeContext()
        let tool = ExecuteStepsTool(context: context, tools: [SleepTool()])
        for count in [0, 65] {
            let result = try await tool.execute(arguments: self.steps(
                Array(repeating: ("sleep", ["duration": .int(1)]), count: count)))
            #expect(result.isError)
        }
        for name in ["execute_steps", "agent", "shell", "click"] {
            let result = try await tool.execute(arguments: self.steps([(name, [:])]))
            #expect(result.isError)
        }
        let full = try await tool.execute(arguments: self.steps(
            Array(repeating: ("sleep", ["duration": .int(1)]), count: 64)))
        #expect(!full.isError)
        #expect(full.structuredContent?.objectValue?["completed"] == .int(64))
    }

    @Test func `child authority is enforced`() async throws {
        let context = await MCPToolTestHelpers.makeContext(executionPolicy: .backgroundOnly)
        let tool = ExecuteStepsTool(context: context, tools: [ClickTool(context: context), SleepTool()])
        let response = try await context.execute(tool: tool, arguments: self.steps([
            ("click", ["coords": .string("1,1"), "background": .bool(false)]),
            ("sleep", ["duration": .int(1)]),
        ]))
        #expect(response.isError)
        #expect(response.structuredContent?.objectValue?["completed"] == .int(1))
    }

    @Test func `explicit snapshot reference binds only the selected observation`() async throws {
        let context = await MCPToolTestHelpers.makeContext(executionPolicy: .backgroundOnly)
        let observation = BatchResponseFixture(name: "inspect_ui", response: .text("observed", meta: .object([
            "snapshot_id": .string("selected-snapshot"),
        ])))
        let tool = ExecuteStepsTool(context: context, tools: [observation, BatchSnapshotFixture()])
        let response = try await tool.execute(arguments: ToolArguments(value: .object(["steps": .array([
            .object(["tool": .string("inspect_ui"), "arguments": .object([:])]),
            .object([
                "tool": .string("sleep"), "arguments": .object([:]), "snapshot_from_step": .int(0),
            ]),
        ])])))
        #expect(!response.isError)
        #expect(response.structuredContent?.objectValue?["completed"] == .int(2))
    }

    @Test func `invalid snapshot references refuse the whole plan before dispatch`() async throws {
        let context = await MCPToolTestHelpers.makeContext()
        let observation = BatchResponseFixture(name: "inspect_ui", response: .error("must never execute"))
        let tool = ExecuteStepsTool(context: context, tools: [observation, BatchSnapshotFixture()])
        for source in [Value.int(-1), .int(1), .double(0.5), .string("0")] {
            let response = try await tool.execute(arguments: ToolArguments(value: .object(["steps": .array([
                .object(["tool": .string("inspect_ui"), "arguments": .object([:])]),
                .object([
                    "tool": .string("sleep"), "arguments": .object([:]), "snapshot_from_step": source,
                ]),
            ])])))
            #expect(response.isError)
            #expect(response.structuredContent == nil)
        }
        let competing = try await tool.execute(arguments: ToolArguments(value: .object(["steps": .array([
            .object(["tool": .string("inspect_ui"), "arguments": .object([:])]),
            .object([
                "tool": .string("sleep"), "arguments": .object(["snapshot": .string("other")]),
                "snapshot_from_step": .int(0),
            ]),
        ])])))
        #expect(competing.isError)
        #expect(competing.structuredContent == nil)
    }

    @Test func `missing observation snapshot stops without dispatching dependent input`() async throws {
        let context = await MCPToolTestHelpers.makeContext()
        let observation = BatchResponseFixture(name: "inspect_ui", response: .text("no snapshot"))
        let tool = ExecuteStepsTool(context: context, tools: [observation, BatchSnapshotFixture()])
        let response = try await tool.execute(arguments: ToolArguments(value: .object(["steps": .array([
            .object(["tool": .string("inspect_ui"), "arguments": .object([:])]),
            .object([
                "tool": .string("sleep"), "arguments": .object([:]), "snapshot_from_step": .int(0),
            ]),
        ])])))
        #expect(response.isError)
        let results = try #require(response.structuredContent?.objectValue?["results"]?.arrayValue)
        #expect(results.count == 2)
        #expect(String(describing: results[1]).contains("no dependent input was dispatched"))
    }

    @Test func `snapshot references cannot bypass session ownership for background typing`() async throws {
        let context = await MCPToolTestHelpers.makeContext(executionPolicy: .backgroundOnly)
        let other = context.replacingSnapshotOwner(with: MCPToolSnapshotOwner())
        let foreign = try await MCPToolTestHelpers.createSnapshot(in: other)
        let observation = await BatchResponseFixture(name: "inspect_ui", response: .text("observed", meta: .object([
            "snapshot_id": .string(foreign.id),
        ])))
        let tool = ExecuteStepsTool(context: context, tools: [observation, TypeTool(context: context), SleepTool()])
        let response = try await tool.execute(arguments: ToolArguments(value: .object(["steps": .array([
            .object(["tool": .string("inspect_ui"), "arguments": .object([:])]),
            .object([
                "tool": .string("type"), "arguments": .object(["text": .string("must not type")]),
                "snapshot_from_step": .int(0),
            ]),
            .object(["tool": .string("sleep"), "arguments": .object(["duration": .int(1)])]),
        ])])))
        #expect(response.isError)
        #expect(response.structuredContent?.objectValue?["completed"] == .int(2))
        let results = try #require(response.structuredContent?.objectValue?["results"]?.arrayValue)
        #expect(results[1].objectValue?["meta"]?.objectValue?["mutation_dispatched"] == .bool(false))
    }

    @Test func `catalog filters apply inside batch`() async throws {
        let context = await MCPToolTestHelpers.makeContext()
        let filters = ToolFilters(
            allow: ["execute_steps", "sleep"],
            deny: ["sleep"],
            allowSource: .env,
            denySources: ["sleep": .env])
        let tools = MCPToolCatalog.tools(context: context, inputPolicy: .init(), filters: filters)
        let batch = try #require(tools.first { $0.name == "execute_steps" })
        let response = try await batch.execute(arguments: self.steps([("sleep", ["duration": .int(1)])]))
        #expect(response.isError)
    }

    @Test func `diff rejects absent and other session snapshots`() async throws {
        let context = await MCPToolTestHelpers.makeContext()
        let response = try await context.execute(tool: GetStateDiffTool(context: context), arguments: ToolArguments(
            raw: ["before_snapshot": "missing", "after_snapshot": "other"]))
        #expect(response.isError)
    }

    @Test func `diff uses recorded targets and isolates owners`() async throws {
        let context = await MCPToolTestHelpers.makeContext()
        let before = try await MCPToolTestHelpers.createSnapshot(in: context)
        let after = try await MCPToolTestHelpers.createSnapshot(in: context)
        let target = WindowContext(applicationProcessId: 42, applicationProcessStartIdentity: 1001, windowID: 7)
        for snapshot in [before, after] {
            await snapshot.setTargetMetadata(from: target)
            try await MCPToolTestHelpers.publishSnapshotMetadata(snapshot, in: context)
        }
        let old = UIElement(
            id: "1",
            elementId: "1",
            role: "AXTextField",
            value: "before",
            identifier: "field",
            frame: .zero,
            isActionable: true)
        let new = UIElement(
            id: "2",
            elementId: "2",
            role: "AXTextField",
            value: "after",
            identifier: "field",
            frame: .zero,
            isActionable: true)
        await before.setUIElements([old])
        await after.setUIElements([new])
        let arguments = await ToolArguments(raw: ["before_snapshot": before.id, "after_snapshot": after.id])
        let result = try await context.execute(tool: GetStateDiffTool(context: context), arguments: arguments)
        #expect(!result.isError)
        #expect(result.structuredContent?.objectValue?["changed"]?.arrayValue?.count == 1)
        let other = context.replacingSnapshotOwner(with: MCPToolSnapshotOwner())
        let refusal = try await other.execute(tool: GetStateDiffTool(context: other), arguments: arguments)
        #expect(refusal.isError)
        await after.setTargetMetadata(from: WindowContext(
            applicationProcessId: 43, applicationProcessStartIdentity: 2001, windowID: 7))
        try await MCPToolTestHelpers.publishSnapshotMetadata(after, in: context)
        let mismatch = try await GetStateDiffTool(context: context).execute(arguments: arguments)
        #expect(mismatch.isError)
    }

    @Test func `cancellation propagates`() async throws {
        let context = await MCPToolTestHelpers.makeContext()
        let tool = ExecuteStepsTool(context: context, tools: [SleepTool()])
        let arguments = self.steps([("sleep", ["duration": .int(60000)])])
        let task = Task { try await tool.execute(arguments: arguments) }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancellation must propagate")
        } catch is CancellationError {
            // Expected; no subsequent calls execute.
        }
    }

    @Test func `unknown verification stops even without tool error`() async throws {
        let context = await MCPToolTestHelpers.makeContext()
        let batch = ExecuteStepsTool(context: context, tools: [VerifyStateTool(context: context), SleepTool()])
        let response = try await batch.execute(arguments: self.steps([
            ("verify_state", [
                "pid": .int(999_999),
                "timeout_ms": .int(100),
                "predicates": .array([.object([
                    "kind": .string("window_exists"),
                    "expected": .bool(true),
                ])]),
            ]),
            ("sleep", ["duration": .int(1)]),
        ]))
        #expect(response.isError)
        #expect(response.structuredContent?.objectValue?["completed"] == .int(1))
    }

    @Test func `explicit same target verification can resolve unverified action`() async throws {
        let context = await MCPToolTestHelpers.makeContext()
        let pid = ProcessInfo.processInfo.processIdentifier
        let generation = try #require(SystemIdentityResolver.processStartIdentity(pid))
        let dispatch = ToolResponse.error("unverified", meta: .object([
            "state": .string("dispatched_unverified"), "effect": .string("unverifiable"),
            "escalation": .string("observe_before_retry"), "mutation_dispatched": .bool(true),
            "target_receipt": .object([
                "pid": .int(Int(pid)),
                "window_id": .int(7),
                "process_start_identity_decimal": .string(String(generation)),
            ]),
        ]))
        let action = BatchResponseFixture(name: "sleep", response: dispatch)
        let verifier = BatchResponseFixture(name: "verify_state", response: .text("verified", meta: .object([
            "status": .string("satisfied"),
        ])))
        let tool = ExecuteStepsTool(context: context, tools: [action, verifier])
        for (targetPID, shouldFail) in [(Int(pid), false), (Int(pid) + 1, true)] {
            let arguments = ToolArguments(value: .object(["steps": .array([.object([
                "tool": .string("sleep"), "arguments": .object([:]),
                "verify": .object(["pid": .int(targetPID), "window_id": .int(7)]),
            ])])]))
            let result = try await tool.execute(arguments: arguments)
            #expect(result.isError == shouldFail)
        }
    }
}

private struct BatchSnapshotFixture: MCPTool {
    let name = "sleep"
    let description = "snapshot argument validation fixture"
    var inputSchema: Value {
        .object(["type": .string("object"), "properties": .object([
            "snapshot": .object(["type": .string("string")]),
        ]), "required": .array([.string("snapshot")])])
    }

    func execute(arguments: ToolArguments) async throws -> ToolResponse {
        arguments.getString("snapshot") == "selected-snapshot" ? .text("bound") : .error("wrong snapshot")
    }
}

private struct BatchResponseFixture: MCPTool {
    let name: String
    let response: ToolResponse
    let description = "test fixture"
    var inputSchema: Value {
        .object(["type": .string("object"), "properties": .object([
            "pid": .object(["type": .string("integer")]), "window_id": .object(["type": .string("integer")]),
        ])])
    }

    func execute(arguments: ToolArguments) async throws -> ToolResponse {
        self.response
    }
}
