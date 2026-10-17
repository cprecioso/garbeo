import PaseoKit
import Testing
@testable import Garbeo

@Suite struct ActivityGroupTests {
    private func row(_ id: String, _ kind: TimelineRow.Kind) -> TimelineRow {
        TimelineRow(id: id, kind: kind, timestamp: nil)
    }

    private func call(_ id: String) -> TimelineRow.Kind {
        .tool(ToolCall(callId: id, name: "Read", status: "completed", detail: ToolCallDetail(type: "read")))
    }

    @Test func titleCountsToolCalls() {
        #expect(ActivityGroup.title(of: [row("a", call("a")), row("b", call("b"))]) == "2 tool calls")
    }

    @Test func titleMentionsThinking() {
        #expect(ActivityGroup.title(of: [row("r", .reasoning(text: "hm")), row("a", call("a"))]) == "Thinking, 1 tool call")
        #expect(ActivityGroup.title(of: [row("r", .reasoning(text: "hm")), row("s", .reasoning(text: "so"))]) == "Thinking")
    }
}
