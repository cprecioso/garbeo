import Foundation
import Testing
@testable import PaseoKit

@Suite struct AgentCreationTests {
    @Test func firstMessageIsInitialPrompt() {
        let message = DaemonClient.CreateAgentOptions(
            provider: "claude", cwd: "/repo", workspaceId: "w1", model: "opus", modeId: "plan",
            thinkingOptionId: "high", prompt: "Fix the login bug"
        ).message(clientMessageId: "m1")
        #expect(message == [
            "type": "create_agent_request",
            "config": ["provider": "claude", "cwd": "/repo", "model": "opus", "modeId": "plan", "thinkingOptionId": "high"],
            "initialPrompt": "Fix the login bug",
            "clientMessageId": "m1",
            "labels": [:],
            "workspaceId": "w1",
        ])
    }

    @Test func defaultsAreLeftToTheDaemon() {
        let message = DaemonClient.CreateAgentOptions(provider: "codex", cwd: "/repo", prompt: "Hi")
            .message(clientMessageId: "m1")
        #expect(message["config"] == ["provider": "codex", "cwd": "/repo"])
        #expect(message["workspaceId"] == nil)
    }

    @Test func createsAgentOverTheWire() async throws {
        let socket = ScriptedSocket { message in
            guard case .text(let text) = message,
                  let frame = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
            else { return [] }
            if frame["type"] == "hello" {
                return [.text(#"{"type":"session","message":{"type":"status","payload":{"status":"server_info","serverId":"s"}}}"#)]
            }
            guard let requestId = frame["message"]?["requestId"]?.stringValue else { return [] }
            return [.text("""
            {"type":"session","message":{"type":"status","payload":{"requestId":"\(requestId)","status":"agent_created",
              "agent":{"id":"a1","provider":"claude","cwd":"/repo","workspaceId":"w1","status":"initializing"}}}}
            """)]
        }
        let client = DaemonClient(endpoint: DaemonEndpoint(url: "127.0.0.1:1"), clientId: "c", transportFactory: { socket })
        try await client.connect()

        let agent = try await client.createAgent(.init(provider: "claude", cwd: "/repo", workspaceId: "w1", prompt: "Hi"))

        #expect(agent.id == "a1")
        #expect(agent.workspaceId == "w1")
        let sent = await socket.sent.compactMap { message -> JSONValue? in
            guard case .text(let text) = message else { return nil }
            return try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        }
        let request = try #require(sent.first { $0["message"]?["type"] == "create_agent_request" })
        #expect(request["message"]?["initialPrompt"] == "Hi")
        await client.disconnect()
    }

    @Test func failedCreationThrowsDaemonError() async throws {
        let socket = ScriptedSocket { message in
            guard case .text(let text) = message,
                  let frame = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
            else { return [] }
            if frame["type"] == "hello" {
                return [.text(#"{"type":"session","message":{"type":"status","payload":{"status":"server_info","serverId":"s"}}}"#)]
            }
            guard let requestId = frame["message"]?["requestId"]?.stringValue else { return [] }
            return [.text("""
            {"type":"session","message":{"type":"status","payload":{"requestId":"\(requestId)","status":"agent_create_failed",
              "error":"Provider unavailable"}}}
            """)]
        }
        let client = DaemonClient(endpoint: DaemonEndpoint(url: "127.0.0.1:1"), clientId: "c", transportFactory: { socket })
        try await client.connect()

        await #expect(throws: PaseoError.rpc("Provider unavailable")) {
            try await client.createAgent(.init(provider: "claude", cwd: "/repo", prompt: "Hi"))
        }
        await client.disconnect()
    }
}

/// Creates an agent in an existing workspace the way a new agent chat does when its first message is
/// sent. Opt-in, since it starts a real agent: `PASEO_LIVE_URL`, `PASEO_LIVE_WORKSPACE` and
/// `PASEO_LIVE_WRITE=1`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PASEO_LIVE_URL"] != nil
    && ProcessInfo.processInfo.environment["PASEO_LIVE_WORKSPACE"] != nil
    && ProcessInfo.processInfo.environment["PASEO_LIVE_WRITE"] == "1"))
struct LiveAgentCreationTests {
    @Test(.timeLimit(.minutes(2))) func firstMessageCreatesAgentInWorkspace() async throws {
        let env = ProcessInfo.processInfo.environment
        let client = DaemonClient(
            endpoint: DaemonEndpoint(url: env["PASEO_LIVE_URL"]!, password: env["PASEO_PASSWORD"]),
            clientId: "garbeo-tests-new-agent")
        try await client.connect()
        let workspaceId = env["PASEO_LIVE_WORKSPACE"]!
        let workspace = try #require(try await client.fetchWorkspaces(subscribe: false).entries.first { $0.id == workspaceId })
        let provider = try #require(try await client.listProviders().first(where: \.available), "an available provider")
        let models = try await client.listModels(provider: provider.provider, cwd: workspace.workspaceDirectory)
        let prompt = "Reply with exactly the single word: pong. Do not use any tools."

        let agent = try await client.createAgent(.init(
            provider: provider.provider, cwd: workspace.workspaceDirectory, workspaceId: workspace.id,
            model: models.first { $0.id.contains("haiku") }?.id, prompt: prompt))
        print("live-write: created \(agent.id) with \(provider.provider) in \(workspace.id)")

        #expect(agent.workspaceId == workspace.id)
        #expect(agent.cwd == workspace.workspaceDirectory)
        var firstUserMessage: String?
        for _ in 0..<20 where firstUserMessage == nil {
            var timeline = AgentTimeline()
            timeline.replace(with: try await client.fetchTimeline(agentId: agent.id))
            firstUserMessage = timeline.rows.lazy.compactMap { if case .user(let text, _, _) = $0.kind { text } else { nil } }.first
            if firstUserMessage == nil { try await Task.sleep(for: .milliseconds(500)) }
        }
        #expect(firstUserMessage == prompt)

        try await client.archiveAgent(agentId: agent.id)
        await client.disconnect()
    }
}
