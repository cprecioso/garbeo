import Foundation
import Testing
@testable import PaseoKit

@Suite struct AgentProfileTests {
    private static let serverInfo =
        #"{"type":"session","message":{"type":"status","payload":{"status":"server_info","serverId":"s","features":{"agentProfiles":true}}}}"#
    private static let profiles = """
    [{"id":"p1","name":"Deep","color":"violet","icon":"brain","provider":"claude","model":"opus","modeId":"plan",
      "thinkingOptionId":"high","featureValues":{"fast_mode":true},"notes":"Hard problems","future":1},
     {"id":"p2","name":"Quick","provider":"codex"}]
    """

    @Test func readsProfilesFromDaemonConfig() async throws {
        let socket = ScriptedSocket { message in
            guard case .text(let text) = message,
                  let frame = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
            else { return [] }
            if frame["type"] == "hello" { return [.text(Self.serverInfo)] }
            guard frame["message"]?["type"] == "get_daemon_config_request",
                  let requestId = frame["message"]?["requestId"]?.stringValue
            else { return [] }
            return [.text("""
            {"type":"session","message":{"type":"get_daemon_config_response","payload":{"requestId":"\(requestId)",
              "config":{"relay":{"enabled":true},"agentProfiles":\(Self.profiles)}}}}
            """)]
        }
        let client = DaemonClient(endpoint: DaemonEndpoint(url: "127.0.0.1:1"), clientId: "c", transportFactory: { socket })
        let info = try await client.connect()
        #expect(info.supportsAgentProfiles)

        let profiles = try await client.agentProfiles()

        #expect(profiles.map(\.id) == ["p1", "p2"])
        #expect(profiles[0] == AgentProfile(
            id: "p1", name: "Deep", icon: "brain", color: "violet", provider: "claude", model: "opus", modeId: "plan",
            thinkingOptionId: "high", featureValues: ["fast_mode": true], notes: "Hard problems"))
        #expect(profiles[1].model == nil)
        await client.disconnect()
    }

    @Test func configWithoutProfilesHasNone() async throws {
        let socket = ScriptedSocket { message in
            guard case .text(let text) = message,
                  let frame = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
            else { return [] }
            if frame["type"] == "hello" { return [.text(Self.serverInfo)] }
            guard let requestId = frame["message"]?["requestId"]?.stringValue else { return [] }
            return [.text("""
            {"type":"session","message":{"type":"get_daemon_config_response","payload":{"requestId":"\(requestId)","config":{}}}}
            """)]
        }
        let client = DaemonClient(endpoint: DaemonEndpoint(url: "127.0.0.1:1"), clientId: "c", transportFactory: { socket })
        try await client.connect()
        #expect(try await client.agentProfiles().isEmpty)
        await client.disconnect()
    }

    @Test func configChangesAreEvents() async throws {
        let socket = ScriptedSocket { message in
            guard case .text(let text) = message, text.contains(#""type":"hello""#) else { return [] }
            return [
                .text(Self.serverInfo),
                .text("""
                {"type":"session","message":{"type":"status","payload":{"status":"daemon_config_changed",
                  "config":{"agentProfiles":\(Self.profiles)}}}}
                """),
            ]
        }
        let client = DaemonClient(endpoint: DaemonEndpoint(url: "127.0.0.1:1"), clientId: "c", transportFactory: { socket })
        try await client.connect()

        var changed: DaemonConfigChanged?
        for await event in client.events {
            if case .daemonConfigChanged(let change) = event { changed = change; break }
        }

        #expect(changed?.config.agentProfiles?.map(\.name) == ["Deep", "Quick"])
        await client.disconnect()
    }

    @Test func featureValuesGoInTheAgentConfig() {
        let message = DaemonClient.CreateAgentOptions(
            provider: "codex", cwd: "/repo", featureValues: ["fast_mode": true], prompt: "Hi"
        ).message(clientMessageId: "m1")
        #expect(message["config"] == ["provider": "codex", "cwd": "/repo", "featureValues": ["fast_mode": true]])
    }
}
