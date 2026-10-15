import Foundation
import Testing
@testable import PaseoKit

private func decodeFrame<P: Decodable>(_ json: String, as type: P.Type) throws -> P {
    try JSONDecoder().decode(SessionFrame<P>.self, from: Data(json.utf8)).message.payload
}

private func stream(_ seq: Int, _ item: String, epoch: String = "e1") throws -> AgentStreamPayload {
    try JSONDecoder().decode(AgentStreamPayload.self, from: Data("""
    {"agentId":"a1","event":{"type":"timeline","provider":"claude","item":\(item)},
     "timestamp":"2026-10-09T09:31:54.474Z","seq":\(seq),"epoch":"\(epoch)"}
    """.utf8))
}

private func page(_ entries: String, endSeq: Int, epoch: String = "e1") throws -> TimelinePage {
    try JSONDecoder().decode(TimelinePage.self, from: Data("""
    {"requestId":"r","agentId":"a1","epoch":"\(epoch)","entries":[\(entries)],
     "startCursor":{"epoch":"\(epoch)","seq":1},"endCursor":{"epoch":"\(epoch)","seq":\(endSeq)},
     "hasOlder":false,"hasNewer":false,"error":null}
    """.utf8))
}

@Suite struct EndpointTests {
    @Test func normalizesHostPort() throws {
        #expect(try DaemonEndpoint(url: "127.0.0.1:6767").webSocketURL().absoluteString == "ws://127.0.0.1:6767/ws")
        #expect(try DaemonEndpoint(url: "https://box.ts.net").webSocketURL().absoluteString == "wss://box.ts.net/ws")
        #expect(try DaemonEndpoint(url: "ws://localhost:6767/ws").webSocketURL().absoluteString == "ws://localhost:6767/ws")
    }

    @Test func rejectsGarbage() {
        #expect(throws: PaseoError.self) { try DaemonEndpoint(url: "ftp://x").webSocketURL() }
    }
}

@Suite struct PaseoDateTests {
    @Test func parsesWithAndWithoutFractionalSeconds() {
        #expect(PaseoDate.parse("2026-10-09T09:31:54.474Z")?.timeIntervalSince1970 == 1_791_538_314.474)
        #expect(PaseoDate.parse("2026-10-09T09:31:54Z")?.timeIntervalSince1970 == 1_791_538_314)
        #expect(PaseoDate.parse("2026-10-09T11:31:54+02:00")?.timeIntervalSince1970 == 1_791_538_314)
        #expect(PaseoDate.parse("2026-10-09") == nil)
        #expect(PaseoDate.parse(nil) == nil)
    }
}

@Suite struct DecodingTests {
    @Test func decodesServerInfo() throws {
        let info = try decodeFrame("""
        {"type":"session","message":{"type":"status","payload":{"status":"server_info","protocolVersion":1,
        "serverId":"srv_1","hostname":"Box","version":"0.11.1","features":{"ownedSubscriptions":true}}}}
        """, as: ServerInfo.self)
        #expect(info.serverId == "srv_1")
        #expect(info.supports("ownedSubscriptions"))
        #expect(!info.supports("missing"))
    }

    @Test func decodesAgentsResponseTolerantly() throws {
        let response = try decodeFrame("""
        {"type":"session","message":{"type":"fetch_agents_response","payload":{"requestId":"a1","subscriptionId":"s",
        "entries":[{"agent":{"id":"ag","provider":"claude","cwd":"/tmp","status":"running","title":"Fix it",
        "availableModes":[{"id":"plan","label":"Plan"}],"currentModeId":"plan","futureField":{"x":1},
        "pendingPermissions":[]},"project":null}],"pageInfo":{"hasMore":false}}}}
        """, as: FetchAgentsResponse.self)
        let agent = try #require(response.entries.first?.agent)
        #expect(agent.status == .running)
        #expect(agent.currentMode?.label == "Plan")
        #expect(agent.displayTitle == "Fix it")
    }

    @Test func decodesUnknownStatusAndTimelineItems() throws {
        let agent = try JSONDecoder().decode(Agent.self, from: Data(#"{"id":"a","provider":"x","cwd":"/","status":"hibernating"}"#.utf8))
        #expect(agent.status == .other("hibernating"))
        let item = try JSONDecoder().decode(TimelineItem.self, from: Data(#"{"type":"plugin","pluginId":"p"}"#.utf8))
        #expect(item == .unknown(type: "plugin"))
    }

    @Test func derivesParentAgentIdFromLabels() throws {
        func agent(labels: String?) throws -> Agent {
            let field = labels.map { #","labels":\#($0)"# } ?? ""
            return try JSONDecoder().decode(Agent.self, from: Data(#"{"id":"a","provider":"x","cwd":"/","status":"idle"\#(field)}"#.utf8))
        }
        let topLevel = try agent(labels: nil)
        #expect(topLevel.labels.isEmpty)
        #expect(topLevel.parentAgentId == nil)

        let child = try agent(labels: #"{"paseo.parent-agent-id":" parent-1 ","team":"core"}"#)
        #expect(child.parentAgentId == "parent-1")
        #expect(child.labels == ["paseo.parent-agent-id": " parent-1 ", "team": "core"])

        #expect(try agent(labels: #"{"paseo.parent-agent-id":"   "}"#).parentAgentId == nil)
        #expect(try agent(labels: #"{"paseo.parent-agent-id":""}"#).parentAgentId == nil)

        let mixed = try agent(labels: #"{"paseo.parent-agent-id":42,"flag":true,"team":"core"}"#)
        #expect(mixed.parentAgentId == nil)
        #expect(mixed.labels == ["team": "core"])

        #expect(try agent(labels: "null").labels.isEmpty)
        #expect(try agent(labels: #"["paseo.parent-agent-id"]"#).labels.isEmpty)
        #expect(Agent.parentAgentIdLabel == "paseo.parent-agent-id")
    }

    @Test func decodesToolCallDetail() throws {
        let item = try JSONDecoder().decode(TimelineItem.self, from: Data("""
        {"type":"tool_call","callId":"t1","name":"Bash","status":"completed","error":null,
         "detail":{"type":"shell","command":"ls","output":"a\\nb","exitCode":0}}
        """.utf8))
        guard case .toolCall(let call) = item else { Issue.record("not a tool call"); return }
        #expect(call.detail.summary == "ls")
        #expect(call.detail.body == "a\nb")
        #expect(call.detail.exitCode == 0)
    }

    @Test func editWithoutUnifiedDiffFallsBackToLineDiff() throws {
        func detail(_ json: String) throws -> ToolCallDetail {
            try JSONDecoder().decode(ToolCallDetail.self, from: Data(json.utf8))
        }
        let edit = try detail(#"{"type":"edit","oldString":"a\nb\nc\nd","newString":"a\nB\nc\nd\ne"}"#)
        #expect(edit.body == " a\n-b\n+B\n c\n d\n+e")
        #expect(try detail(#"{"type":"edit","newString":"x\ny"}"#).body == "+x\n+y")
        #expect(try detail(#"{"type":"edit","oldString":"x\ny","newString":"z","unifiedDiff":"@@ raw"}"#).body == "@@ raw")
        #expect(try detail(#"{"type":"edit"}"#).body == nil)
    }

    @Test func decodesPermissionRequest() throws {
        let payload = try decodeFrame("""
        {"type":"session","message":{"type":"agent_permission_request","payload":{"agentId":"a1",
        "request":{"id":"p1","provider":"claude","name":"Bash","kind":"tool","title":"Run ls",
        "input":{"command":"ls"},"actions":[{"id":"yes","label":"Allow","behavior":"allow"}]}}}}
        """, as: AgentPermissionRequestPayload.self)
        #expect(payload.request.actions?.first?.behavior == "allow")
        #expect(payload.request.input?["command"] == .string("ls"))
    }

    @Test func frameHeaderExtractsRequestId() throws {
        let header = try JSONDecoder().decode(FrameHeader.self, from: Data("""
        {"type":"session","message":{"type":"rpc_error","payload":{"requestId":"r9","error":"nope"}}}
        """.utf8))
        #expect(header.message?.payload?.requestId == "r9")
        let pong = try JSONDecoder().decode(FrameHeader.self, from: Data(#"{"type":"pong"}"#.utf8))
        #expect(pong.message == nil)
    }
}

@Suite struct TimelineTests {
    @Test func mergesStreamingChunks() throws {
        var timeline = AgentTimeline()
        timeline.replace(with: try page(#"{"item":{"type":"user_message","text":"hi"},"seqStart":1,"seqEnd":1}"#, endSeq: 1))
        #expect(timeline.apply(try stream(2, #"{"type":"reasoning","text":"Thin"}"#)) == .applied)
        #expect(timeline.apply(try stream(3, #"{"type":"reasoning","text":"king"}"#)) == .applied)
        #expect(timeline.apply(try stream(4, #"{"type":"assistant_message","text":"Hel"}"#)) == .applied)
        #expect(timeline.apply(try stream(5, #"{"type":"assistant_message","text":"lo"}"#)) == .applied)
        #expect(timeline.rows.count == 3)
        #expect(timeline.rows[1].kind == .reasoning(text: "Thinking"))
        #expect(timeline.rows[2].kind == .assistant(text: "Hello", messageId: nil))
    }

    @Test func updatesToolCallsInPlace() throws {
        var timeline = AgentTimeline()
        timeline.replace(with: try page("", endSeq: 0))
        _ = timeline.apply(try stream(1, #"{"type":"tool_call","callId":"c","name":"Bash","status":"running","error":null,"detail":{"type":"shell","command":"ls"}}"#))
        _ = timeline.apply(try stream(2, #"{"type":"tool_call","callId":"c","name":"Bash","status":"completed","error":null,"detail":{"type":"shell","command":"ls","output":"x"}}"#))
        #expect(timeline.rows.count == 1)
        guard case .tool(let call) = timeline.rows[0].kind else { Issue.record("expected tool"); return }
        #expect(call.status == "completed")
        #expect(call.detail.command == "ls")
        #expect(call.detail.output == .string("x"))
    }

    @Test func detectsGapsAndDuplicates() throws {
        var timeline = AgentTimeline()
        timeline.replace(with: try page("", endSeq: 10))
        #expect(timeline.apply(try stream(10, #"{"type":"reasoning","text":"old"}"#)) == .ignored)
        #expect(timeline.apply(try stream(12, #"{"type":"reasoning","text":"skip"}"#)) == .gap)
        #expect(timeline.apply(try stream(11, #"{"type":"reasoning","text":"ok"}"#, epoch: "e2")) == .gap)
        #expect(timeline.apply(try stream(11, #"{"type":"reasoning","text":"ok"}"#)) == .applied)
    }

    @Test func ignoresStreamBeforeInitialLoad() throws {
        var timeline = AgentTimeline()
        #expect(timeline.apply(try stream(5, #"{"type":"reasoning","text":"early"}"#)) == .ignored)
        #expect(timeline.rows.isEmpty)
    }

    @Test func confirmsOptimisticUserMessage() throws {
        var timeline = AgentTimeline()
        timeline.replace(with: try page("", endSeq: 3))
        timeline.addPendingUserMessage(text: "do it", messageId: "m1")
        #expect(timeline.rows.count == 1)
        _ = timeline.apply(try stream(4, #"{"type":"user_message","text":"do it","messageId":"m1"}"#))
        #expect(timeline.rows.count == 1)
        #expect(timeline.rows[0].kind == .user(text: "do it", messageId: "m1", pending: false))
    }

    @Test func replaceKeepsUndeliveredPendingMessages() throws {
        var timeline = AgentTimeline()
        timeline.replace(with: try page("", endSeq: 0))
        timeline.addPendingUserMessage(text: "a", messageId: "m1")
        timeline.addPendingUserMessage(text: "b", messageId: "m2")
        timeline.replace(with: try page(#"{"item":{"type":"user_message","text":"a","messageId":"m1"},"seqStart":1}"#, endSeq: 1))
        #expect(timeline.rows.count == 2)
        #expect(timeline.rows[1].kind == .user(text: "b", messageId: "m2", pending: true))
    }
}

/// Runs against a real daemon when `PASEO_LIVE_URL` is set (for example `127.0.0.1:6767`).
/// Read-only: lists workspaces/agents and fetches one timeline.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PASEO_LIVE_URL"] != nil))
struct LiveDaemonTests {
    @Test func handshakeListsAndTimeline() async throws {
        let url = try #require(ProcessInfo.processInfo.environment["PASEO_LIVE_URL"])
        let client = DaemonClient(
            endpoint: DaemonEndpoint(url: url, password: ProcessInfo.processInfo.environment["PASEO_PASSWORD"]),
            clientId: "garbeo-tests")
        let info = try await client.connect()
        #expect(!info.serverId.isEmpty)

        let workspaces = try await client.fetchWorkspaces()
        let agents = try await client.fetchAgents()
        print("live: \(workspaces.entries.count) workspaces, \(agents.entries.count) agents")
        let providers = try await client.listProviders()
        #expect(!providers.isEmpty)

        if let agent = agents.entries.first?.agent {
            try await client.setTimelineSubscription(agentIds: [agent.id])
            let page = try await client.fetchTimeline(agentId: agent.id, limit: 50)
            var timeline = AgentTimeline()
            timeline.replace(with: page)
            print("live: agent \(agent.id) timeline rows \(timeline.rows.count) from \(page.entries.count) entries")
            #expect(timeline.isLoaded)
        }

        await #expect(throws: PaseoError.self) {
            _ = try await client.requestData(["type": "definitely_not_a_message"], timeout: .seconds(3))
        }
        await client.disconnect()
    }
}

/// Creates real (cheap) agents and drives them end to end. Writes to the daemon, so it is
/// opt-in: set `PASEO_LIVE_URL` plus `PASEO_LIVE_WRITE=1`.
///
/// Creating an agent without a workspace makes the daemon create one. Cleanup archives that
/// workspace only when it did not exist before the test ran; otherwise just the test's agent.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PASEO_LIVE_URL"] != nil
    && ProcessInfo.processInfo.environment["PASEO_LIVE_WRITE"] == "1"))
struct LiveAgentRoundTripTests {
    private static let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().path

    private func connectedClient(_ name: String) async throws -> (DaemonClient, Set<String>) {
        let env = ProcessInfo.processInfo.environment
        let client = DaemonClient(
            endpoint: DaemonEndpoint(url: env["PASEO_LIVE_URL"]!, password: env["PASEO_PASSWORD"]), clientId: name)
        try await client.connect()
        let existing = Set(try await client.fetchWorkspaces().entries.map(\.id))
        _ = try await client.fetchAgents()
        return (client, existing)
    }

    private func cleanUp(_ agent: Agent, client: DaemonClient, preexistingWorkspaces: Set<String>) async throws {
        if let workspaceId = agent.workspaceId, !preexistingWorkspaces.contains(workspaceId) {
            _ = try await client.requestData(["type": "archive_workspace_request", "workspaceId": .string(workspaceId)])
        } else {
            try await client.archiveAgent(agentId: agent.id)
        }
        await client.disconnect()
    }

    private func createAgent(_ client: DaemonClient, modeId: String, prompt: String) async throws -> Agent {
        try await client.createAgent(.init(
            provider: "claude", cwd: Self.repoRoot,
            model: ProcessInfo.processInfo.environment["PASEO_LIVE_MODEL"] ?? "claude-haiku-4-5",
            modeId: modeId, prompt: prompt))
    }

    @Test(.timeLimit(.minutes(3))) func createStreamSendArchive() async throws {
        let (client, preexisting) = try await connectedClient("garbeo-tests-write")
        let agent = try await createAgent(client, modeId: "plan", prompt: "Reply with exactly the single word: pong. Do not use any tools.")
        print("live-write: created \(agent.id) in \(agent.workspaceId ?? "-")")

        var timeline = AgentTimeline()
        try await client.setTimelineSubscription(agentIds: [agent.id])
        timeline.replace(with: try await client.fetchTimeline(agentId: agent.id))

        func assistantText() -> String {
            timeline.rows.compactMap { if case .assistant(let text, _) = $0.kind { text } else { nil } }.joined(separator: "\n")
        }

        /// Applies live events until `condition` holds, refetching the tail on gaps.
        func waitFor(_ condition: () -> Bool) async throws {
            var events = client.events.makeAsyncIterator()
            while !condition() {
                guard let event = await events.next() else { throw PaseoError.disconnected }
                if case .agentStream(let payload) = event, payload.agentId == agent.id {
                    if timeline.apply(payload) == .gap {
                        timeline.replace(with: try await client.fetchTimeline(agentId: agent.id))
                    }
                }
                if case .agentUpdate(.upsert(let updated)) = event, updated.id == agent.id, updated.status == .idle {
                    timeline.replace(with: try await client.fetchTimeline(agentId: agent.id))
                }
            }
        }

        try await waitFor { assistantText().lowercased().contains("pong") }
        print("live-write: first reply: \(assistantText())")

        timeline.addPendingUserMessage(text: "Now reply with exactly: ping", messageId: "swift-test-1")
        try await client.sendMessage(agentId: agent.id, text: "Now reply with exactly: ping", messageId: "swift-test-1")
        try await waitFor { assistantText().lowercased().contains("ping") }
        let users = timeline.rows.filter { if case .user = $0.kind { true } else { false } }
        #expect(users.count == 2)
        #expect(!users.contains { if case .user(_, _, true) = $0.kind { true } else { false } })

        try await cleanUp(agent, client: client, preexistingWorkspaces: preexisting)
    }

    @Test(.timeLimit(.minutes(3))) func permissionRequestIsAnswered() async throws {
        let (client, preexisting) = try await connectedClient("garbeo-tests-permission")
        try await client.subscribeToSessionEvents(["agent_permission_request", "agent_permission_resolved"])
        let agent = try await createAgent(client, modeId: "default",
            prompt: "Use the Write tool to create the file /tmp/garbeo-permission-check.txt containing `ok`, then reply with: done.")

        var requested: PermissionRequest?
        var resolved = false
        var sawRunning = false
        loop: for await event in client.events {
            switch event {
            case .permissionRequested(let payload) where payload.agentId == agent.id:
                requested = payload.request
                print("live-permission: \(payload.request.name) \(payload.request.kind) actions=\(payload.request.actions?.map(\.label) ?? [])")
                try await client.respondToPermission(agentId: agent.id, permissionId: payload.request.id, allow: true)
            case .permissionResolved(let payload) where payload.agentId == agent.id:
                resolved = payload.requestId == requested?.id
                if resolved { break loop }
            case .agentUpdate(.upsert(let updated)) where updated.id == agent.id:
                if updated.status == .running { sawRunning = true }
                // The turn ended without ever asking; stop instead of waiting for the time limit.
                if sawRunning, updated.status == .idle || updated.status == .error { break loop }
            default:
                break
            }
        }
        try await cleanUp(agent, client: client, preexistingWorkspaces: preexisting)
        #expect(requested != nil, "The provider finished the turn without requesting permission")
        #expect(resolved)
    }
}
