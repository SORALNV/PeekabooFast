import Foundation
import MCP
import PeekabooAutomationKit
import TachikomaMCP

public struct GetStateDiffTool: MCPTool {
    public let name = "get_state_diff"
    public let description = """
    Compare two distinct retained AX snapshots owned by this session. Does not capture a new tree or screenshot.
    First call inspect_ui twice with different snapshot IDs. Returns added/removed/changed elements.
    Only unique AX identifiers are matched; ambiguous/unidentified nodes are conservatively removed/added.
    Snapshot-local element IDs are not stable identity. This result never authorizes using old IDs for mutations.
    """
    private let context: MCPToolContext

    public var inputSchema: Value {
        SchemaBuilder.object(properties: [
            "before_snapshot": SchemaBuilder.string(description: "Explicit earlier snapshot ID."),
            "after_snapshot": SchemaBuilder.string(description: "Explicit later snapshot ID."),
        ], required: ["before_snapshot", "after_snapshot"])
    }

    public init(context: MCPToolContext = .shared) {
        self.context = context
    }

    @MainActor
    public func execute(arguments: ToolArguments) async throws -> ToolResponse {
        guard case let .string(beforeID)? = arguments.getValue(for: "before_snapshot"),
              case let .string(afterID)? = arguments.getValue(for: "after_snapshot"),
              beforeID != afterID,
              let before = await self.context.uiSnapshots.getSnapshot(id: beforeID),
              let after = await self.context.uiSnapshots.getSnapshot(id: afterID)
        else { return .error("Two distinct, retained snapshot IDs from this session are required") }
        guard let oldDetection = try await self.context.snapshots.getDetectionResult(snapshotId: beforeID),
              let newDetection = try await self.context.snapshots.getDetectionResult(snapshotId: afterID),
              let oldTarget = oldDetection.metadata.windowContext,
              let newTarget = newDetection.metadata.windowContext,
              let pid = oldTarget.applicationProcessId,
              let generation = oldTarget.applicationProcessStartIdentity,
              let window = oldTarget.windowID,
              newTarget.applicationProcessId == pid,
              newTarget.applicationProcessStartIdentity == generation, newTarget.windowID == window
        else { return .error("Snapshots must have the same recorded process generation and explicit window") }
        let diff = await UIStateDiff.compare(before: before.uiElements, after: after.uiElements)
        let result = try Value(diff)
        let data = try JSONEncoder().encode(result)
        return ToolResponse(
            content: [.text(text: String(bytes: data, encoding: .utf8) ?? "{}", annotations: nil, _meta: nil)],
            meta: .object([
                "before_snapshot": .string(beforeID),
                "after_snapshot": .string(afterID),
                "before_truncated": .bool(oldDetection.metadata.truncationInfo?.isTruncated == true),
                "after_truncated": .bool(newDetection.metadata.truncationInfo?.isTruncated == true),
            ]),
            structuredContent: result)
    }
}
