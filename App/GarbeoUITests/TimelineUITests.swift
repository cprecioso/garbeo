import PaseoKit
import XCTest

/// Drives the app against a real daemon, with a real (cheap) agent. Writes to the daemon, so it is
/// opt-in like PaseoKit's live tests: pass `TEST_RUNNER_PASEO_LIVE_URL=127.0.0.1:6767` and
/// `TEST_RUNNER_PASEO_LIVE_WRITE=1` to `xcodebuild test`. Needs a Debug build (`-PaseoConnect`).
@MainActor
final class TimelineUITests: XCTestCase {
    private static let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().path

    func testToolCallsCollapseIntoOneRow() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["PASEO_LIVE_URL"], env["PASEO_LIVE_WRITE"] == "1" else {
            throw XCTSkip("Set TEST_RUNNER_PASEO_LIVE_URL and TEST_RUNNER_PASEO_LIVE_WRITE=1 to run against a daemon")
        }
        let agentId = try await createFinishedAgent(url: url, password: env["PASEO_PASSWORD"],
            prompt: "Use the Read tool to read README.md, then use it again to read Package.swift, then reply with exactly: done.")

        let app = XCUIApplication()
        app.launchArguments = ["-PaseoConnect", url, "-PaseoSelectAgent", agentId]
        app.launch()

        let group = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "tool calls")).firstMatch
        XCTAssertTrue(group.waitForExistence(timeout: 30), "The reads should collapse into one row")
        let reply = app.staticTexts.matching(NSPredicate(format: "label ==[c] %@", "done")).firstMatch
        XCTAssertTrue(reply.exists, "The reply stays visible")
        let reads = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Read"))
        XCTAssertEqual(reads.count, 0, "The reads are hidden while collapsed")

        group.tap()
        XCTAssertTrue(reads.firstMatch.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(reads.count, 2)

        group.tap()
        XCTAssertTrue(reads.firstMatch.waitForNonExistence(timeout: 5))
    }

    /// Creates an agent, waits for it to reply, and archives it (or the workspace the daemon made
    /// for it) when the test ends.
    private func createFinishedAgent(url: String, password: String?, prompt: String) async throws -> String {
        let client = DaemonClient(endpoint: DaemonEndpoint(url: url, password: password), clientId: "garbeo-ui-tests")
        try await client.connect()
        let existing = Set(try await client.fetchWorkspaces().entries.map(\.id))
        _ = try await client.fetchAgents()
        try await client.subscribeToSessionEvents(["agent_permission_request"])
        let agent = try await client.createAgent(.init(
            provider: "claude", cwd: Self.repoRoot,
            model: ProcessInfo.processInfo.environment["PASEO_LIVE_MODEL"] ?? "claude-haiku-4-5",
            modeId: "default", prompt: prompt))
        addTeardownBlock {
            if let workspaceId = agent.workspaceId, !existing.contains(workspaceId) {
                _ = try await client.requestData(["type": "archive_workspace_request", "workspaceId": .string(workspaceId)])
            } else {
                try await client.archiveAgent(agentId: agent.id)
            }
            await client.disconnect()
        }

        var sawRunning = false
        for await event in client.events {
            switch event {
            case .permissionRequested(let payload) where payload.agentId == agent.id:
                try await client.respondToPermission(agentId: agent.id, permissionId: payload.request.id, allow: true)
            case .agentUpdate(.upsert(let updated)) where updated.id == agent.id:
                if updated.status == .running { sawRunning = true }
                guard sawRunning, updated.status == .idle || updated.status == .error else { continue }
                var timeline = AgentTimeline()
                timeline.replace(with: try await client.fetchTimeline(agentId: agent.id))
                if timeline.rows.contains(where: { if case .assistant = $0.kind { true } else { false } }) { return agent.id }
            default:
                break
            }
        }
        throw PaseoError.disconnected
    }
}
