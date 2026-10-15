import Foundation
import MCP
import PeekabooAutomationKit
import TachikomaMCP

/// Bounded sequential dispatch through the same authority and snapshot lanes as ordinary calls.
/// The catalog injects only the tools selected for this server/session. No nested agents or batches.
public struct ExecuteStepsTool: MCPTool {
    public let name = "execute_steps"
    public let description = """
    Execute 1–64 existing tool calls sequentially in one request. Stops at the first unverified failure.
    Optional verify contains verify_state arguments and must return status=satisfied. A target-bound
    dispatched_unverified action may continue only after this explicit same-window verification succeeds.
    Use inspect_ui and verify_state between mutations when fresh targets or verification are needed.
    Optional snapshot_from_step explicitly copies snapshot_id from an earlier inspect_ui/see result
    into this call's snapshot argument (zero-based index). The child still validates freshness and ownership.
    All other arguments are literal; element IDs are never rebound across UI changes.
    Each child retains its normal execution policy, permissions, and snapshot invalidation.
    Returns every completed result, including failure details; no rollback or transaction isolation.
    """

    private let context: MCPToolContext
    private let tools: [any MCPTool]
    static let excluded: Set<String> = ["execute_steps", "agent", "shell"]

    public var inputSchema: Value {
        .object([
            "type": .string("object"),
            "properties": .object([
                "steps": .object([
                    "type": .string("array"), "minItems": .int(1), "maxItems": .int(64),
                    "items": .object([
                        "type": .string("object"),
                        "properties": .object([
                            "tool": .object(["type": .string("string")]),
                            "arguments": .object(["type": .string("object")]),
                            "snapshot_from_step": .object([
                                "type": .string("integer"), "minimum": .int(0), "maximum": .int(63),
                                "description": .string(
                                    "Earlier observation index (zero-based); exclusive with snapshot."),
                            ]),
                            "verify": VerifyStateTool(context: self.context).inputSchema,
                        ]),
                        "required": .array([.string("tool"), .string("arguments")]),
                        "additionalProperties": .bool(false),
                    ]),
                ]),
            ]),
            "required": .array([.string("steps")]),
            "additionalProperties": .bool(false),
        ])
    }

    public init(context: MCPToolContext = .shared, tools: [any MCPTool]) {
        self.context = context
        self.tools = tools
    }

    @MainActor
    public func execute(arguments: ToolArguments) async throws -> ToolResponse {
        guard case let .array(values)? = arguments.getValue(for: "steps"),
              (1...64).contains(values.count)
        else { return .error("steps must contain between 1 and 64 calls") }

        // Validate every step shape and tool exposure before any side effect.
        // Child argument and authority validation remains on the normal per-dispatch path.
        var plan: [Step] = []
        for (index, value) in values.enumerated() {
            guard case let .object(step) = value,
                  Set(step.keys).isSubset(of: ["tool", "arguments", "verify", "snapshot_from_step"]),
                  case let .string(name)? = step["tool"],
                  case let .object(childArguments)? = step["arguments"],
                  !Self.excluded.contains(name),
                  let tool = self.tools.first(where: { $0.name == name })
            else { return .error("Invalid or unavailable tool at step \(index)") }
            var snapshotSource: Int?
            if let source = step["snapshot_from_step"] {
                guard case let .int(sourceIndex) = source, sourceIndex >= 0, sourceIndex < index,
                      ["inspect_ui", "see"].contains(plan[sourceIndex].tool.name),
                      childArguments["snapshot"] == nil,
                      tool.inputSchema.objectValue?["properties"]?.objectValue?["snapshot"] != nil
                else { return .error("Invalid snapshot_from_step at step \(index)") }
                snapshotSource = sourceIndex
            }
            var verify: ToolArguments?
            if let verification = step["verify"] {
                guard case .object = verification, self.tools.contains(where: { $0.name == "verify_state" }) else {
                    return .error("verify_state is unavailable or invalid at step \(index)")
                }
                verify = ToolArguments(value: verification)
            }
            plan.append(Step(tool: tool, arguments: childArguments, verify: verify, snapshotSource: snapshotSource))
        }
        var results: [Value] = []
        var failed = false
        var snapshots: [Int: String] = [:]
        for (index, call) in plan.enumerated() {
            try Task.checkCancellation()
            let response: ToolResponse
            do {
                var childArguments = call.arguments
                if let source = call.snapshotSource {
                    guard let snapshot = snapshots[source] else {
                        throw SnapshotReferenceError.missingResult(source)
                    }
                    childArguments["snapshot"] = .string(snapshot)
                }
                response = try await self.context.execute(
                    tool: call.tool, arguments: ToolArguments(value: .object(childArguments)))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                response = .error(error.localizedDescription)
            }
            if !response.isError, ["inspect_ui", "see"].contains(call.tool.name),
               let snapshot = response.meta?.objectValue?["snapshot_id"]?.stringValue, !snapshot.isEmpty
            {
                snapshots[index] = snapshot
            }
            let recoverable = Self.isTargetBoundUnverified(response)
            let verification: ToolResponse?
            if let verify = call.verify, !response.isError || recoverable,
               let verifier = self.tools.first(where: { $0.name == "verify_state" })
            {
                if response.isError, !Self.verificationTargetsDispatch(verify, response: response) {
                    verification = .error("Verification must pin the dispatched PID, generation, and window")
                } else {
                    do {
                        verification = try await self.context.execute(tool: verifier, arguments: verify)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        verification = .error(error.localizedDescription)
                    }
                }
            } else {
                verification = nil
            }
            let verified = verification.map {
                guard !$0.isError, $0.meta?.objectValue?["status"] == .string("satisfied") else { return false }
                // The verifier awaited native work. Recheck the dispatch generation after that await,
                // so a newly reused PID cannot resolve an earlier process's uncertain mutation.
                if response.isError, let arguments = call.verify {
                    return Self.verificationTargetsDispatch(arguments, response: response)
                }
                return true
            }
            let stepFailed = (response.isError && !(recoverable && verified == true)) ||
                verified == false ||
                (call.tool.name == "verify_state" && response.meta?.objectValue?["status"] != .string("satisfied"))
            try results.append(.object([
                "index": .int(index), "tool": .string(call.tool.name),
                "is_error": .bool(response.isError),
                "step_failed": .bool(stepFailed),
                "verification": verification.map { .object([
                    "is_error": .bool($0.isError), "meta": $0.meta ?? .null,
                    "content": (try? Value($0.content)) ?? .null,
                ]) } ?? .null,
                "content": Value(response.content),
                "meta": response.meta ?? .null,
                "structured_content": response.structuredContent ?? .null,
            ]))
            if stepFailed {
                failed = true
                break
            }
        }
        let result = Value.object([
            "results": .array(results), "completed": .int(results.count),
            "total": .int(plan.count), "stopped_on_error": .bool(failed),
        ])
        let data = try JSONEncoder().encode(result)
        return ToolResponse(
            content: [.text(text: String(bytes: data, encoding: .utf8) ?? "{}", annotations: nil, _meta: nil)],
            isError: failed,
            structuredContent: result)
    }

    private struct Step {
        let tool: any MCPTool
        let arguments: [String: Value]
        let verify: ToolArguments?
        let snapshotSource: Int?
    }

    private enum SnapshotReferenceError: LocalizedError {
        case missingResult(Int)

        var errorDescription: String? {
            switch self {
            case let .missingResult(index):
                "Observation step \(index) returned no usable snapshot_id; no dependent input was dispatched."
            }
        }
    }

    private static func isTargetBoundUnverified(_ response: ToolResponse) -> Bool {
        let meta = response.meta?.objectValue
        return response.isError && meta?["state"] == .string("dispatched_unverified") &&
            meta?["effect"] == .string("unverifiable") &&
            meta?["escalation"] == .string("observe_before_retry") &&
            meta?["mutation_dispatched"] == .bool(true) && meta?["target_receipt"]?.objectValue != nil
    }

    private static func verificationTargetsDispatch(_ arguments: ToolArguments, response: ToolResponse) -> Bool {
        guard let receipt = response.meta?.objectValue?["target_receipt"]?.objectValue,
              let pid = receipt["pid"]?.intValue, let window = receipt["window_id"]?.intValue,
              arguments.getValue(for: "pid")?.intValue == pid,
              arguments.getValue(for: "window_id")?.intValue == window,
              let generation = receipt["process_start_identity_decimal"]?.stringValue.flatMap(UInt64.init),
              let processID = Int32(exactly: pid),
              SystemIdentityResolver.processStartIdentity(processID) == generation
        else { return false }
        return true
    }
}
