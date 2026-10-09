import Foundation

/// One application-level WebSocket frame. The opcode (text vs binary) is preserved end to end.
public enum TransportMessage: Sendable, Equatable {
    case text(String)
    case binary(Data)
}

/// A bidirectional message pipe to a daemon. `DaemonClient` speaks the JSON protocol over any
/// implementation: a plain WebSocket for direct connections, or `RelayE2EETransport` for the relay.
public protocol DaemonTransport: Sendable {
    /// Connects and completes once application frames can flow (after any handshake).
    func open() async throws
    func send(_ message: TransportMessage) async throws
    /// Returns the next frame. Must only be called from one task at a time.
    func receive() async throws -> TransportMessage
    func close()
}

public enum TransportKind: String, Sendable, Codable {
    case direct
    case relay

    public var label: String {
        switch self {
        case .direct: "Direct"
        case .relay: "Relay (E2EE)"
        }
    }
}

/// The peer closed the socket with a WebSocket close frame.
public struct TransportClosed: LocalizedError, Equatable {
    public var code: Int
    public var reason: String

    public var errorDescription: String? {
        reason.isEmpty ? "Connection closed (code \(code))" : reason
    }
}

/// `URLSessionWebSocketTask` wrapper.
public final class WebSocketTransport: DaemonTransport, @unchecked Sendable {
    // `URLSessionWebSocketTask` is thread-safe; nothing here is mutated after init.
    private let task: URLSessionWebSocketTask

    public init(url: URL, session: URLSession) {
        task = session.webSocketTask(with: url)
        task.maximumMessageSize = 64 * 1024 * 1024
    }

    public func open() async throws {
        // Frames sent before the upgrade completes are queued by the task; failures surface on send/receive.
        task.resume()
    }

    public func send(_ message: TransportMessage) async throws {
        switch message {
        case .text(let text): try await task.send(.string(text))
        case .binary(let data): try await task.send(.data(data))
        }
    }

    public func receive() async throws -> TransportMessage {
        while true {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await task.receive()
            } catch {
                if task.closeCode != .invalid {
                    // Some close frames surface with their 2-byte status code still in front of the reason.
                    let raw = task.closeReason.map { String(decoding: $0, as: UTF8.self) } ?? ""
                    let reason = String(raw.drop { !$0.isASCII || $0.isNewline || ($0.asciiValue ?? 0) < 0x20 })
                    throw TransportClosed(code: task.closeCode.rawValue, reason: reason)
                }
                throw error
            }
            switch message {
            case .string(let text): return .text(text)
            case .data(let data): return .binary(data)
            @unknown default: continue
            }
        }
    }

    public func close() {
        task.cancel(with: .goingAway, reason: nil)
    }
}

// MARK: - Endpoint → transport

extension DaemonEndpoint {
    /// A relay endpoint whose `url` is the canonical `relay://` connection URI (password kept separate).
    public static func relay(_ connection: RelayConnection, password: String? = nil) -> DaemonEndpoint {
        DaemonEndpoint(url: connection.connectionURI(), password: password)
    }

    /// Builds an endpoint from a pairing link (`#offer=`, `relay://`, or `#connect=`).
    /// A password embedded in the link is used unless `password` is given.
    public static func fromPairingLink(_ link: String, password: String? = nil) throws -> DaemonEndpoint {
        let parsed = try PairingLink.parse(link)
        return .relay(parsed.connection, password: password ?? parsed.password)
    }

    public var transportKind: TransportKind {
        PairingLink.isPairingLink(url) ? .relay : .direct
    }

    /// A human-readable address that never includes the daemon key or password.
    public var displayAddress: String {
        guard transportKind == .relay else { return url }
        guard let relay = try? relayConnection() else { return "Relay" }
        return "\(relay.serverId) via \(relay.endpoint)"
    }

    public func relayConnection() throws -> RelayConnection? {
        transportKind == .relay ? try PairingLink.parse(url).connection : nil
    }

    func makeTransport(session: URLSession) throws -> any DaemonTransport {
        guard let relay = try relayConnection() else {
            return WebSocketTransport(url: try webSocketURL(), session: session)
        }
        let socket = WebSocketTransport(url: try relay.webSocketURL(), session: session)
        return try RelayE2EETransport(inner: socket, daemonPublicKeyB64: relay.daemonPublicKeyB64)
    }
}
