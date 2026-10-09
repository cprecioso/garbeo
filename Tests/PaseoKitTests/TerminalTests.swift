import Foundation
import Testing
@testable import PaseoKit

/// Vectors produced by `scripts/generate-terminal-vectors.mts` from the upstream TS implementation.
private struct Vectors: Decodable {
    struct Encode: Decodable { var name: String; var opcode: UInt8; var slot: Int; var payloadHex: String; var frameHex: String }
    struct Decode: Decodable {
        struct Result: Decodable { var opcode: UInt8; var slot: UInt8; var payloadHex: String }
        var frameHex: String
        var result: Result?
    }
    struct Snapshot: Decodable { var name: String; var stateJSON: String; var ansiHex: String }
    var encode: [Encode]
    var decode: [Decode]
    var snapshots: [Snapshot]

    static let shared: Vectors = {
        let url = Bundle.module.url(forResource: "terminal-vectors", withExtension: "json", subdirectory: "Fixtures")!
        return try! JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }()
}

private extension Data {
    init(hex: String) {
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        self.init(bytes)
    }

    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

@Suite struct TerminalFrameVectorTests {
    @Test(arguments: Vectors.shared.encode.map(\.name))
    func encodesLikeTypeScript(name: String) throws {
        let vector = try #require(Vectors.shared.encode.first { $0.name == name })
        let opcode = try #require(TerminalStreamOpcode(rawValue: vector.opcode))
        let frame = TerminalStreamFrame(opcode: opcode, slot: vector.slot, payload: Data(hex: vector.payloadHex))
        #expect(frame.encoded().hex == vector.frameHex)

        let decoded = try #require(TerminalStreamFrame(decoding: Data(hex: vector.frameHex)))
        #expect(decoded.opcode == opcode)
        #expect(decoded.slot == UInt8(truncatingIfNeeded: vector.slot))
        #expect(decoded.payload.hex == vector.payloadHex)
    }

    @Test func decodesLikeTypeScript() {
        for vector in Vectors.shared.decode {
            let decoded = TerminalStreamFrame(decoding: Data(hex: vector.frameHex))
            if let expected = vector.result {
                #expect(decoded?.opcode.rawValue == expected.opcode, "\(vector.frameHex)")
                #expect(decoded?.slot == expected.slot)
                #expect(decoded?.payload.hex == expected.payloadHex)
            } else {
                #expect(decoded == nil, "\(vector.frameHex) should be rejected")
            }
        }
    }

    @Test func decodesFromSlicedData() throws {
        // Payloads must not assume a zero start index.
        let data = Data(hex: "ff0103414243").dropFirst()
        let frame = try #require(TerminalStreamFrame(decoding: data))
        #expect(frame.slot == 3)
        #expect(frame.payload == Data("ABC".utf8))
    }

    @Test func resizePayloadMatchesJSONStringify() {
        let vectors = Vectors.shared.encode
        let claim = vectors.first { $0.name == "resize-claim" }!
        let update = vectors.first { $0.name == "resize-update" }!
        #expect(TerminalFramePayload.resize(TerminalSize(rows: 24, cols: 80), intent: .claim).hex == claim.payloadHex)
        #expect(TerminalFramePayload.resize(TerminalSize(rows: 50, cols: 132), intent: .update).hex == update.payloadHex)
        #expect(String(decoding: TerminalFramePayload.resize(TerminalSize(rows: 1, cols: 2), intent: nil), as: UTF8.self)
            == #"{"rows":1,"cols":2}"#)
    }

    @Test(arguments: Vectors.shared.snapshots.map(\.name))
    func rendersSnapshotLikeTypeScript(name: String) throws {
        let vector = try #require(Vectors.shared.snapshots.first { $0.name == name })
        let state = try JSONDecoder().decode(TerminalState.self, from: Data(vector.stateJSON.utf8))
        let rendered = state.renderANSI()
        let expected = String(decoding: Data(hex: vector.ansiHex), as: UTF8.self)
        #expect(rendered == expected, "\(rendered.debugDescription) != \(expected.debugDescription)")
    }
}

@Suite struct TerminalRegistryTests {
    private func response(_ json: String) throws -> SubscribeTerminalResponse {
        try JSONDecoder().decode(SubscribeTerminalResponse.self, from: Data(json.utf8))
    }

    private func collect(_ stream: AsyncStream<TerminalStreamEvent>) async -> [String] {
        var out: [String] = []
        for await event in stream {
            switch event {
            case .output(let data): out.append("out:" + String(decoding: data, as: UTF8.self))
            case .restore(let data, let size):
                out.append("restore:\(size.map { "\($0.cols)x\($0.rows)" } ?? "-"):" + String(decoding: data, as: UTF8.self))
            }
        }
        return out
    }

    @Test func routesFramesBySlotUntilExit() async throws {
        var registry = TerminalStreamRegistry()
        let (a, ca) = AsyncStream.makeStream(of: TerminalStreamEvent.self)
        let (b, cb) = AsyncStream.makeStream(of: TerminalStreamEvent.self)
        registry.expectAttach(requestId: "r1", terminalId: "t1", continuation: ca)
        registry.expectAttach(requestId: "r2", terminalId: "t2", continuation: cb)
        registry.bindAttach(requestId: "r1", response: try response(
            #"{"terminalId":"t1","slot":4,"subscriptionId":"s1","error":null,"requestId":"r1"}"#))
        registry.bindAttach(requestId: "r2", response: try response(
            #"{"terminalId":"t2","slot":5,"subscriptionId":"s2","error":null,"requestId":"r2"}"#))

        registry.route(TerminalStreamFrame(opcode: .restore, slot: 4, payload: Data("screen".utf8)))
        registry.route(TerminalStreamFrame(opcode: .output, slot: 4, payload: Data("hi".utf8)))
        registry.route(TerminalStreamFrame(opcode: .output, slot: 5, payload: Data("other".utf8)))
        registry.route(TerminalStreamFrame(opcode: .output, slot: 9, payload: Data("nobody".utf8)))
        registry.route(TerminalStreamFrame(opcode: .output, slot: 4, payload: Data()))
        registry.exit(TerminalStreamExitPayload(subscriptionId: nil, terminalId: "t1", error: nil))
        registry.route(TerminalStreamFrame(opcode: .output, slot: 4, payload: Data("late".utf8)))
        registry.finishAll()

        #expect(await collect(a) == ["restore:-:screen", "out:hi"])
        #expect(await collect(b) == ["out:other"])
        #expect(registry.endReason(subscriptionId: "s1") == .exited(error: nil))
        #expect(registry.endReason(subscriptionId: "s2") == .disconnected)
    }

    @Test func legacySnapshotBecomesRestore() async throws {
        var registry = TerminalStreamRegistry()
        let (stream, continuation) = AsyncStream.makeStream(of: TerminalStreamEvent.self)
        registry.expectAttach(requestId: "r", terminalId: "t", continuation: continuation)
        registry.bindAttach(requestId: "r", response: try response(
            #"{"terminalId":"t","slot":0,"error":null,"requestId":"r"}"#))
        let state = #"{"rows":1,"cols":3,"grid":[[{"char":"o"},{"char":"k"}]],"scrollback":[],"cursor":{"row":0,"col":2}}"#
        registry.route(TerminalStreamFrame(opcode: .snapshot, slot: 0, payload: Data(state.utf8)))
        registry.route(TerminalStreamFrame(opcode: .snapshot, slot: 0, payload: Data("{".utf8)))
        registry.finishAll()
        #expect(await collect(stream) == ["restore:3x1:\u{1b}[?7lok\u{1b}[0m\u{1b}[1;3H\u{1b}[?25h\u{1b}[?7h"])
    }

    @Test func failedSubscribeFinishesStream() async throws {
        var registry = TerminalStreamRegistry()
        let (stream, continuation) = AsyncStream.makeStream(of: TerminalStreamEvent.self)
        registry.expectAttach(requestId: "r", terminalId: "t", continuation: continuation)
        registry.bindAttach(requestId: "r", response: try response(
            #"{"terminalId":"t","error":"Terminal not found","requestId":"r"}"#))
        registry.route(TerminalStreamFrame(opcode: .output, slot: 0, payload: Data("x".utf8)))
        #expect(await collect(stream).isEmpty)
    }

    @Test func decodesTerminalMessages() throws {
        let changed = try JSONDecoder().decode(TerminalsChanged.self, from: Data("""
        {"cwd":"/p","workspaceId":"wks_1","terminals":[{"id":"term_1","name":"Terminal 1","workspaceId":"wks_1",
        "title":"vim","activity":{"state":"working","attentionReason":null,"changedAt":1}},{"id":"term_2","name":"zsh",
        "activity":{"state":"brand-new","changedAt":2}}]}
        """.utf8))
        #expect(changed.terminals.map(\.displayName) == ["vim", "zsh"])
        #expect(changed.terminals[1].activity?.state == "brand-new")
    }
}

/// Read-only: lists terminals on the daemon at `PASEO_LIVE_URL` and checks they decode.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PASEO_LIVE_URL"] != nil))
struct LiveTerminalListTests {
    @Test func listsTerminals() async throws {
        let env = ProcessInfo.processInfo.environment
        let client = DaemonClient(
            endpoint: DaemonEndpoint(url: env["PASEO_LIVE_URL"]!, password: env["PASEO_PASSWORD"]),
            clientId: "cid_swift_terminal_list_test")
        try await client.connect()
        defer { Task { await client.disconnect() } }
        let terminals = try await client.listTerminals()
        #expect(terminals.allSatisfy { !$0.id.isEmpty })
    }
}

private actor Screen {
    var text = ""
    func append(_ data: Data) { text += String(decoding: data, as: UTF8.self) }
}

/// Creates, types into, resizes and kills a real terminal. Needs `PASEO_LIVE_URL` plus
/// `PASEO_LIVE_TERMINALS=1`, and creates the terminal in `PASEO_LIVE_WORKSPACE` (or the first workspace).
/// Point it at a throwaway daemon, never at one you are working in.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PASEO_LIVE_URL"] != nil
    && ProcessInfo.processInfo.environment["PASEO_LIVE_TERMINALS"] == "1"))
struct LiveTerminalRoundTripTests {
    @Test func createTypeResizeKill() async throws {
        let env = ProcessInfo.processInfo.environment
        let client = DaemonClient(
            endpoint: DaemonEndpoint(url: env["PASEO_LIVE_URL"]!, password: env["PASEO_PASSWORD"]),
            clientId: "cid_swift_terminal_test")
        try await client.connect()
        defer { Task { await client.disconnect() } }

        let workspaces = try await client.fetchWorkspaces(subscribe: false).entries
        let workspace = try #require(
            env["PASEO_LIVE_WORKSPACE"].flatMap { id in workspaces.first { $0.id == id } } ?? workspaces.first)

        let terminal = try await client.createTerminal(
            cwd: workspace.workspaceDirectory, workspaceId: workspace.id, name: "swift-test")
        var killed = false
        defer { if !killed { Task { try? await client.killTerminal(terminal.id) } } }

        let listed = try await client.listTerminals(workspaceId: workspace.id, cwd: workspace.workspaceDirectory)
        #expect(listed.contains { $0.id == terminal.id })

        let attachment = try await client.attachTerminal(terminal.id, claim: TerminalSize(rows: 30, cols: 100))
        let screen = Screen()
        let consumer = Task {
            for await event in attachment.events {
                switch event {
                case .output(let data), .restore(let data, _): await screen.append(data)
                }
            }
        }
        func read(until needle: String) async throws {
            let deadline = ContinuousClock.now + .seconds(15)
            while !(await screen.text.contains(needle)) {
                guard ContinuousClock.now < deadline else {
                    Issue.record("Timed out waiting for \(needle.debugDescription); got \(await screen.text.debugDescription)")
                    return
                }
                try await Task.sleep(for: .milliseconds(50))
            }
        }

        try await client.sendTerminalInput(attachment, data: Data("echo hi-$((40+2))\r".utf8))
        try await read(until: "hi-42")

        try await client.resizeTerminal(attachment, size: TerminalSize(rows: 33, cols: 91), intent: .update)
        try await Task.sleep(for: .milliseconds(300))
        try await client.sendTerminalInput(attachment, data: Data("stty size\r".utf8))
        try await read(until: "33 91")

        let capture = try await client.captureTerminal(terminal.id)
        #expect(capture.lines.contains { $0.contains("hi-42") })

        try await client.killTerminal(terminal.id)
        killed = true
        await consumer.value
        #expect(await client.endReason(of: attachment) == .exited(error: nil))
        let after = try await client.listTerminals(workspaceId: workspace.id, cwd: workspace.workspaceDirectory)
        #expect(!after.contains { $0.id == terminal.id })
    }
}
