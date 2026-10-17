import Foundation
import PaseoKit
import Testing
@testable import Garbeo

/// ⌘T (#38): a new terminal tab in the focused window's workspace.
@MainActor
@Suite struct NewTabTests {
    @Test func targetsTheSelectionsWorkspace() throws {
        let model = AppModel()
        model.handle(.workspaceUpdate(.upsert(try workspace("wks_a"))))
        model.handle(.workspaceUpdate(.upsert(try workspace("wks_b"))))
        model.handle(.agentUpdate(.upsert(try agent("agt_1", in: "wks_b"))))

        #expect(model.selectedWorkspace == nil)
        model.selection = .workspace("wks_a")
        #expect(model.selectedWorkspace?.id == "wks_a")
        model.selection = .agent("agt_1")
        #expect(model.selectedWorkspace?.id == "wks_b")
    }

    @Test func createsATerminalInTheWorkspaceAndSelectsIt() async throws {
        let daemon = FakeDaemon()
        let client = DaemonClient(
            endpoint: DaemonEndpoint(url: "ws://fake.invalid"), clientId: "cid_test", transportFactory: { daemon })
        try await client.connect()
        defer { Task { await client.disconnect() } }

        let model = AppModel()
        let target = try workspace("wks_b")
        model.handle(.workspaceUpdate(.upsert(try workspace("wks_a"))))
        model.handle(.workspaceUpdate(.upsert(target)))
        model.selection = .workspace("wks_a")
        await model.terminals.connect(client, workspaces: [])

        await model.openNewTab(in: target)

        let request = try #require(daemon.requests(of: "create_terminal_request").first)
        #expect(request["cwd"] as? String == "/tmp/wks_b")
        #expect(request["workspaceId"] as? String == "wks_b")
        #expect(model.selection == .terminal("term_new"))
        #expect(model.terminals.terminals(in: target).map(\.id) == ["term_new"])
        #expect(model.selectedWorkspace?.id == "wks_b")
        #expect(model.lastError == nil)
    }
}

private func workspace(_ id: String) throws -> Workspace {
    try JSONDecoder().decode(Workspace.self, from: Data("""
    {"id":"\(id)","projectId":"prj_1","workspaceDirectory":"/tmp/\(id)","name":"\(id)"}
    """.utf8))
}

private func agent(_ id: String, in workspaceId: String) throws -> Agent {
    try JSONDecoder().decode(Agent.self, from: Data("""
    {"id":"\(id)","provider":"claude","cwd":"/tmp/\(workspaceId)","workspaceId":"\(workspaceId)","status":"idle"}
    """.utf8))
}

/// An in-memory daemon: answers the hello and the terminal requests, and records every request.
private final class FakeDaemon: DaemonTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var received: [[String: Any]] = []
    private let inbound = AsyncThrowingStream.makeStream(of: TransportMessage.self)

    func requests(of type: String) -> [[String: Any]] {
        lock.withLock { received.filter { $0["type"] as? String == type } }
    }

    func open() async throws {}

    func send(_ message: TransportMessage) async throws {
        guard case .text(let text) = message,
              let frame = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        else { return }
        if frame["type"] as? String == "hello" {
            reply("status", ["status": "server_info", "serverId": "srv_test", "protocolVersion": 1])
            return
        }
        guard let request = frame["message"] as? [String: Any], let type = request["type"] as? String,
              let requestId = request["requestId"] as? String
        else { return }
        lock.withLock { received.append(request) }
        let name = type.replacingOccurrences(of: "_request", with: "_response")
        switch type {
        case "list_terminals_request":
            reply(name, ["terminals": [], "requestId": requestId])
        case "subscribe_terminals_request":
            reply(name, ["cwd": request["cwd"] ?? "", "terminals": [], "requestId": requestId])
        case "create_terminal_request":
            let terminal: [String: Any] = [
                "id": "term_new", "name": "Terminal 1",
                "cwd": request["cwd"] ?? "", "workspaceId": request["workspaceId"] ?? NSNull(),
            ]
            reply(name, ["terminal": terminal, "error": NSNull(), "requestId": requestId])
        default:
            reply("rpc_error", ["error": "Unexpected \(type)", "requestId": requestId])
        }
    }

    func receive() async throws -> TransportMessage {
        var iterator = inbound.stream.makeAsyncIterator()
        guard let message = try await iterator.next() else { throw PaseoError.disconnected }
        return message
    }

    func close() { inbound.continuation.finish() }

    private func reply(_ type: String, _ payload: [String: Any]) {
        let frame: [String: Any] = ["type": "session", "message": ["type": type, "payload": payload]]
        let data = try! JSONSerialization.data(withJSONObject: frame)
        inbound.continuation.yield(.text(String(decoding: data, as: UTF8.self)))
    }
}
