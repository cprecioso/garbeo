import Foundation

// MARK: - Wire models

public struct TerminalActivity: Decodable, Sendable, Hashable {
    /// `idle`, `working`, or `attention`; unknown states should be treated as idle.
    public var state: String
    /// `finished` or `needs_input`.
    public var attentionReason: String?
    public var changedAt: Double?
}

public struct TerminalInfo: Decodable, Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var cwd: String?
    public var workspaceId: String?
    public var title: String?
    public var activity: TerminalActivity?

    public var displayName: String {
        if let title, !title.isEmpty { return title }
        return name
    }
}

public struct TerminalsChanged: Decodable, Sendable {
    public var subscriptionId: String?
    public var workspaceId: String?
    public var cwd: String
    public var terminals: [TerminalInfo]
}

public struct TerminalCapture: Decodable, Sendable {
    public var terminalId: String
    public var lines: [String]
    public var totalLines: Int
}

struct ListTerminalsResponse: Decodable {
    var terminals: [TerminalInfo]
}

struct CreateTerminalResponse: Decodable {
    var terminal: TerminalInfo?
    var error: String?
}

struct SubscribeTerminalResponse: Decodable {
    var terminalId: String
    var slot: Int?
    var subscriptionId: String?
    var error: String?
}

struct KillTerminalResponse: Decodable {
    var terminalId: String
    var success: Bool
}

struct TerminalStreamExitPayload: Decodable {
    var subscriptionId: String?
    var terminalId: String
    var error: String?
}

// MARK: - Streams

public enum TerminalStreamEvent: Sendable {
    /// Raw PTY output to append.
    case output(Data)
    /// ANSI that repaints the whole screen. Reset the emulator before feeding it.
    /// `size` is set when the daemon told us the PTY geometry the content was captured at.
    case restore(Data, size: TerminalSize?)
}

public enum TerminalRestoreMode: Sendable, Equatable {
    /// No catch-up; only output produced after attaching.
    case live
    /// The visible screen plus up to `scrollbackLines` (daemon caps at 500).
    case visibleSnapshot(scrollbackLines: Int)
    /// The visible screen plus the daemon's whole scrollback.
    case fullSnapshot

    var json: JSONValue {
        switch self {
        case .live: ["mode": "live"]
        case .visibleSnapshot(let lines): ["mode": "visible-snapshot", "scrollbackLines": .number(Double(lines))]
        case .fullSnapshot: ["mode": "full-snapshot"]
        }
    }
}

/// A live subscription to one terminal's output, bound to a daemon-assigned binary slot.
public struct TerminalAttachment: Sendable {
    public let terminalId: String
    public let slot: UInt8
    public let subscriptionId: String?
    /// Output and restore frames, in order. Finishes when the stream exits, is detached, or the socket closes;
    /// `exitReason` then tells why.
    public let events: AsyncStream<TerminalStreamEvent>
}

public enum TerminalStreamEnd: Sendable, Equatable {
    case detached
    case exited(error: String?)
    case disconnected
}

/// Routes binary frames to attachments by slot. Owned by the `DaemonClient` actor.
struct TerminalStreamRegistry {
    struct Registration {
        var terminalId: String
        var subscriptionId: String?
        var continuation: AsyncStream<TerminalStreamEvent>.Continuation
    }

    private var pendingAttaches: [String: Registration] = [:]
    private var slots: [UInt8: Registration] = [:]
    private(set) var endReasons: [String: TerminalStreamEnd] = [:]

    mutating func expectAttach(requestId: String, terminalId: String, continuation: AsyncStream<TerminalStreamEvent>.Continuation) {
        pendingAttaches[requestId] = Registration(terminalId: terminalId, continuation: continuation)
    }

    mutating func cancelAttach(requestId: String) {
        pendingAttaches.removeValue(forKey: requestId)?.continuation.finish()
    }

    /// Binds the slot synchronously while the frame is being handled, so the restore frame that follows
    /// the response on the socket is never dropped.
    mutating func bindAttach(requestId: String, response: SubscribeTerminalResponse) {
        guard var registration = pendingAttaches.removeValue(forKey: requestId) else { return }
        guard response.error == nil, let rawSlot = response.slot, let slot = UInt8(exactly: rawSlot) else {
            registration.continuation.finish()
            return
        }
        registration.subscriptionId = response.subscriptionId
        // A slot is only reassigned after its previous stream ended; drop any stale local binding.
        slots.removeValue(forKey: slot)?.continuation.finish()
        slots[slot] = registration
    }

    func route(_ frame: TerminalStreamFrame) {
        guard let registration = slots[frame.slot] else { return }
        switch frame.opcode {
        case .output:
            if !frame.payload.isEmpty { registration.continuation.yield(.output(frame.payload)) }
        case .restore:
            registration.continuation.yield(.restore(frame.payload, size: nil))
        case .snapshot:
            guard let state = try? JSONDecoder().decode(TerminalState.self, from: frame.payload) else { return }
            let size = TerminalSize(rows: state.rows, cols: state.cols)
            registration.continuation.yield(.restore(Data(state.renderANSI().utf8), size: size))
        case .input, .resize:
            break
        }
    }

    mutating func end(slot: UInt8, reason: TerminalStreamEnd) {
        guard let registration = slots.removeValue(forKey: slot) else { return }
        if let id = registration.subscriptionId { endReasons[id] = reason }
        registration.continuation.finish()
    }

    mutating func exit(_ payload: TerminalStreamExitPayload) {
        let matching = slots.filter { _, registration in
            registration.terminalId == payload.terminalId
                && (payload.subscriptionId == nil || registration.subscriptionId == payload.subscriptionId)
        }
        for slot in matching.keys { end(slot: slot, reason: .exited(error: payload.error)) }
    }

    mutating func endReason(subscriptionId: String?) -> TerminalStreamEnd? {
        subscriptionId.flatMap { endReasons.removeValue(forKey: $0) }
    }

    mutating func finishAll() {
        for registration in pendingAttaches.values { registration.continuation.finish() }
        pendingAttaches.removeAll()
        for slot in Array(slots.keys) { end(slot: slot, reason: .disconnected) }
    }
}

// MARK: - API

extension DaemonClient {
    /// Daemon feature flags that change how terminals are driven.
    public var terminalFeatures: (restoreModes: Bool, sizeOwnership: Bool, workspaceTerminals: Bool) {
        let info = serverInfo
        return (
            info?.supports("terminal-restore-modes") ?? false,
            info?.supports("terminal-size-ownership") ?? false,
            info?.supports("workspaceTerminals") ?? false
        )
    }

    /// Lists terminals. With `workspaceId` the daemon filters by ownership; with only `cwd`, by workspace root;
    /// with neither, returns every terminal.
    public func listTerminals(workspaceId: String? = nil, cwd: String? = nil) async throws -> [TerminalInfo] {
        var message: [String: JSONValue] = ["type": "list_terminals_request"]
        if let workspaceId, terminalFeatures.workspaceTerminals { message["workspaceId"] = .string(workspaceId) }
        if let cwd { message["cwd"] = .string(cwd) }
        return try await request(message, as: ListTerminalsResponse.self).terminals
    }

    /// Subscribes to `terminals_changed` for a workspace root and returns the initial list.
    /// Later changes arrive as `DaemonEvent.terminalsChanged`.
    public func subscribeTerminals(cwd: String, workspaceId: String? = nil) async throws -> TerminalsChanged {
        var message: [String: JSONValue] = ["type": "subscribe_terminals_request", "cwd": .string(cwd)]
        if let workspaceId { message["workspaceId"] = .string(workspaceId) }
        return try await request(message, as: TerminalsChanged.self)
    }

    public func createTerminal(
        cwd: String, workspaceId: String? = nil, name: String? = nil, command: String? = nil, args: [String]? = nil,
        size: TerminalSize? = nil
    ) async throws -> TerminalInfo {
        var message: [String: JSONValue] = ["type": "create_terminal_request", "cwd": .string(cwd)]
        if let workspaceId { message["workspaceId"] = .string(workspaceId) }
        if let name { message["name"] = .string(name) }
        if let command { message["command"] = .string(command) }
        if let args { message["args"] = .array(args.map(JSONValue.string)) }
        if let size { message["size"] = ["rows": .number(Double(size.rows)), "cols": .number(Double(size.cols))] }
        let response = try await request(message, as: CreateTerminalResponse.self)
        guard let terminal = response.terminal else {
            throw PaseoError.rpc(response.error ?? "The daemon did not create a terminal")
        }
        return terminal
    }

    public func killTerminal(_ terminalId: String) async throws {
        let response = try await request(
            ["type": "kill_terminal_request", "terminalId": .string(terminalId)], as: KillTerminalResponse.self)
        if !response.success { throw PaseoError.rpc("Failed to kill terminal") }
    }

    public func captureTerminal(
        _ terminalId: String, start: Int? = nil, end: Int? = nil, stripAnsi: Bool = true
    ) async throws -> TerminalCapture {
        var message: [String: JSONValue] = [
            "type": "capture_terminal_request", "terminalId": .string(terminalId), "stripAnsi": .bool(stripAnsi),
        ]
        if let start { message["start"] = .number(Double(start)) }
        if let end { message["end"] = .number(Double(end)) }
        return try await request(message, as: TerminalCapture.self)
    }

    /// Opens a binary output stream for a terminal.
    ///
    /// - Parameter claim: when set, claims PTY size ownership with this geometry before subscribing.
    ///   Pass it only when the user is actively opening/focusing the terminal; passive attaches must not
    ///   steal the size from another client (last-interacting-client-wins).
    public func attachTerminal(
        _ terminalId: String, restore: TerminalRestoreMode = .visibleSnapshot(scrollbackLines: 200),
        claim: TerminalSize? = nil
    ) async throws -> TerminalAttachment {
        if let claim { try await claimTerminalSize(terminalId, size: claim) }
        let requestId = UUID().uuidString.lowercased()
        var message: [String: JSONValue] = [
            "type": "subscribe_terminal_request", "terminalId": .string(terminalId), "requestId": .string(requestId),
        ]
        // Without restore modes the daemon replies with a legacy JSON `Snapshot` frame instead.
        if terminalFeatures.restoreModes { message["restore"] = restore.json }

        let (events, continuation) = AsyncStream.makeStream(of: TerminalStreamEvent.self, bufferingPolicy: .unbounded)
        terminalStreams.expectAttach(requestId: requestId, terminalId: terminalId, continuation: continuation)
        do {
            let response = try await request(message, as: SubscribeTerminalResponse.self)
            if let error = response.error { throw PaseoError.rpc(error) }
            guard let slot = response.slot.flatMap(UInt8.init(exactly:)) else {
                throw PaseoError.decoding("subscribe_terminal_response without a slot")
            }
            return TerminalAttachment(
                terminalId: terminalId, slot: slot, subscriptionId: response.subscriptionId, events: events)
        } catch {
            terminalStreams.cancelAttach(requestId: requestId)
            throw error
        }
    }

    /// Why an attachment's event stream finished. Consumes the recorded reason.
    public func endReason(of attachment: TerminalAttachment) -> TerminalStreamEnd {
        terminalStreams.endReason(subscriptionId: attachment.subscriptionId) ?? .disconnected
    }

    public func detachTerminal(_ attachment: TerminalAttachment) async {
        terminalStreams.end(slot: attachment.slot, reason: .detached)
        _ = terminalStreams.endReason(subscriptionId: attachment.subscriptionId)
        if let subscriptionId = attachment.subscriptionId {
            try? await send([
                "type": "subscription.release.request",
                "requestId": .string(UUID().uuidString.lowercased()),
                "subscriptionId": .string(subscriptionId),
            ])
        } else {
            try? await send(["type": "unsubscribe_terminal_request", "terminalId": .string(attachment.terminalId)])
        }
    }

    /// Sends keyboard input on an attached stream.
    public func sendTerminalInput(_ attachment: TerminalAttachment, data: Data) async throws {
        guard !data.isEmpty else { return }
        try await sendBinary(TerminalStreamFrame(opcode: .input, slot: attachment.slot, payload: data).encoded())
    }

    /// Sends a resize on an attached stream. Use `.claim` on focus/interaction and `.update` for later
    /// geometry changes while this client owns the size.
    public func resizeTerminal(_ attachment: TerminalAttachment, size: TerminalSize, intent: TerminalResizeIntent) async throws {
        let payload = TerminalFramePayload.resize(size, intent: terminalFeatures.sizeOwnership ? intent : nil)
        try await sendBinary(TerminalStreamFrame(opcode: .resize, slot: attachment.slot, payload: payload).encoded())
    }

    /// Claims the PTY size through the JSON path; usable before a stream slot exists.
    public func claimTerminalSize(_ terminalId: String, size: TerminalSize) async throws {
        var resize: [String: JSONValue] = [
            "type": "resize", "rows": .number(Double(size.rows)), "cols": .number(Double(size.cols)),
        ]
        if terminalFeatures.sizeOwnership { resize["intent"] = "claim" }
        try await send(["type": "terminal_input", "terminalId": .string(terminalId), "message": .object(resize)])
    }
}
