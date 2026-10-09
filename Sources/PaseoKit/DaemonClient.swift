import Foundation

public enum PaseoError: LocalizedError, Sendable, Equatable {
    case invalidURL(String)
    case helloRejected(reason: String)
    case rpc(String)
    case timeout
    case disconnected
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let url): "Invalid daemon URL: \(url)"
        case .helloRejected(let reason):
            switch reason {
            case "password_required": "This daemon requires a password."
            case "incorrect_password": "Incorrect password."
            case "incompatible_protocol": "This daemon speaks an incompatible protocol version."
            default: "Connection rejected: \(reason)"
            }
        case .rpc(let message): message
        case .timeout: "The daemon did not respond in time."
        case .disconnected: "Disconnected from the daemon."
        case .decoding(let message): "Unexpected response: \(message)"
        }
    }
}

public enum DaemonEvent: Sendable {
    case agentUpdate(AgentUpdate)
    case workspaceUpdate(WorkspaceUpdate)
    case agentStream(AgentStreamPayload)
    case permissionRequested(AgentPermissionRequestPayload)
    case permissionResolved(AgentPermissionResolvedPayload)
    case serverInfo(ServerInfo)
    case pluginStatus(PluginStatusPayload)
    case disconnected(String?)
}

public struct DaemonEndpoint: Sendable, Hashable, Codable {
    public var url: String
    public var password: String?

    public init(url: String, password: String? = nil) {
        self.url = url
        self.password = password
    }

    /// Accepts `host:port`, `http(s)://`, or `ws(s)://` forms and normalizes to a `/ws` WebSocket URL.
    public func webSocketURL() throws -> URL {
        var raw = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.contains("://") { raw = "ws://" + raw }
        guard var components = URLComponents(string: raw), components.host?.isEmpty == false else {
            throw PaseoError.invalidURL(url)
        }
        switch components.scheme?.lowercased() {
        case "http", "ws": components.scheme = "ws"
        case "https", "wss": components.scheme = "wss"
        default: throw PaseoError.invalidURL(url)
        }
        if components.path.isEmpty || components.path == "/" { components.path = "/ws" }
        guard let result = components.url else { throw PaseoError.invalidURL(url) }
        return result
    }
}

/// One physical WebSocket connection to a Paseo daemon.
///
/// Speaks the daemon's JSON protocol: a `hello` handshake answered by `status.server_info`,
/// `session`-wrapped request/response pairs correlated by `requestId`, subscription-scoped
/// push events, and the application-level `ping`/`pong` liveness lease.
public actor DaemonClient {
    public nonisolated let events: AsyncStream<DaemonEvent>
    private let eventContinuation: AsyncStream<DaemonEvent>.Continuation

    private let endpoint: DaemonEndpoint
    private let clientId: String
    private let clientType: String
    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var pending: [String: CheckedContinuation<Data, Error>] = [:]
    private var receiveLoop: Task<Void, Never>?
    private var pingLoop: Task<Void, Never>?
    private var lastInbound = Date()
    private var closed = false
    public private(set) var serverInfo: ServerInfo?

    public static let capabilities: JSONValue = [
        "hello_rejection": true,
        "owned_subscriptions": true,
        "explicit_event_subscriptions": true,
        "selective_agent_timeline": true,
        "timeline_notifications": true,
        "all_providers": true,
    ]

    public init(endpoint: DaemonEndpoint, clientId: String, clientType: String = DaemonClient.defaultClientType) {
        self.endpoint = endpoint
        self.clientId = clientId
        self.clientType = clientType
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: configuration)
        (events, eventContinuation) = AsyncStream.makeStream(of: DaemonEvent.self, bufferingPolicy: .unbounded)
    }

    public static var defaultClientType: String {
        #if os(iOS)
        "mobile"
        #else
        "browser"
        #endif
    }

    // MARK: Connection

    @discardableResult
    public func connect(timeout: Duration = .seconds(10)) async throws -> ServerInfo {
        let url = try endpoint.webSocketURL()
        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = 64 * 1024 * 1024
        self.task = task
        task.resume()

        var hello: [String: JSONValue] = [
            "type": "hello",
            "clientId": .string(clientId),
            "clientType": .string(clientType),
            "protocolVersion": 1,
            "capabilities": Self.capabilities,
        ]
        if let password = endpoint.password, !password.isEmpty {
            hello["auth"] = ["kind": "password", "password": .string(password)]
        }

        do {
            try await sendRaw(.object(hello))
            // The task group waits for every child, so a timeout must also unblock `receive()`.
            let info = try await withTimeout(timeout, onTimeout: { task.cancel(with: .goingAway, reason: nil) }) {
                try await Self.awaitServerInfo(task)
            }
            serverInfo = info
            lastInbound = Date()
            startLoops()
            return info
        } catch {
            task.cancel(with: .goingAway, reason: nil)
            self.task = nil
            throw error
        }
    }

    public func disconnect() {
        guard !closed else { return }
        closed = true
        task?.cancel(with: .normalClosure, reason: nil)
        teardown(reason: nil)
    }

    private static func awaitServerInfo(_ task: URLSessionWebSocketTask) async throws -> ServerInfo {
        while true {
            let data: Data
            switch try await task.receive() {
            case .string(let text): data = Data(text.utf8)
            case .data: continue
            @unknown default: continue
            }
            let header = try JSONDecoder().decode(FrameHeader.self, from: data)
            if header.type == "hello.rejected" {
                throw PaseoError.helloRejected(reason: header.reason ?? "unknown")
            }
            if header.type == "session", header.message?.type == "status",
               header.message?.payload?.status == "server_info"
            {
                return try JSONDecoder().decode(SessionFrame<ServerInfo>.self, from: data).message.payload
            }
        }
    }

    private func startLoops() {
        receiveLoop = Task { [weak self] in
            await self?.runReceiveLoop()
        }
        pingLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self, !Task.isCancelled else { return }
                await self.tickLiveness()
            }
        }
    }

    private func tickLiveness() async {
        guard !closed else { return }
        if Date().timeIntervalSince(lastInbound) > 35 {
            task?.cancel(with: .goingAway, reason: nil)
            teardown(reason: "Connection timed out")
            return
        }
        try? await sendRaw(["type": "ping"])
    }

    private func runReceiveLoop() async {
        while let task, !closed {
            do {
                let message = try await task.receive()
                lastInbound = Date()
                if case .string(let text) = message {
                    handleFrame(Data(text.utf8))
                }
            } catch {
                teardown(reason: closed ? nil : error.localizedDescription)
                return
            }
        }
    }

    private func teardown(reason: String?) {
        let wasOpen = task != nil
        task = nil
        closed = true
        receiveLoop?.cancel()
        pingLoop?.cancel()
        let waiting = pending
        pending.removeAll()
        for continuation in waiting.values {
            continuation.resume(throwing: PaseoError.disconnected)
        }
        if wasOpen { eventContinuation.yield(.disconnected(reason)) }
        eventContinuation.finish()
    }

    // MARK: Frame routing

    private func handleFrame(_ data: Data) {
        let decoder = JSONDecoder()
        guard let header = try? decoder.decode(FrameHeader.self, from: data),
              header.type == "session", let message = header.message
        else { return }

        if let requestId = message.payload?.requestId, let continuation = pending.removeValue(forKey: requestId) {
            if message.type == "rpc_error" {
                let error = (try? decoder.decode(SessionFrame<RpcErrorPayload>.self, from: data))?.message.payload
                continuation.resume(throwing: PaseoError.rpc(error?.error ?? "Request failed"))
            } else {
                continuation.resume(returning: data)
            }
            return
        }

        func decode<P: Decodable>(_ type: P.Type) -> P? {
            (try? decoder.decode(SessionFrame<P>.self, from: data))?.message.payload
        }

        let event: DaemonEvent? = switch message.type {
        case "agent_stream": decode(AgentStreamPayload.self).map(DaemonEvent.agentStream)
        case "agent_update": decode(AgentUpdate.self).map(DaemonEvent.agentUpdate)
        case "workspace_update": decode(WorkspaceUpdate.self).map(DaemonEvent.workspaceUpdate)
        case "agent_permission_request": decode(AgentPermissionRequestPayload.self).map(DaemonEvent.permissionRequested)
        case "agent_permission_resolved": decode(AgentPermissionResolvedPayload.self).map(DaemonEvent.permissionResolved)
        case "status" where message.payload?.status == "server_info": decode(ServerInfo.self).map(DaemonEvent.serverInfo)
        case "status" where message.payload?.status?.hasPrefix("plugin_") == true:
            decode(PluginStatusPayload.self).map(DaemonEvent.pluginStatus)
        default: nil
        }
        if let event { eventContinuation.yield(event) }
    }

    // MARK: Requests

    private func sendRaw(_ value: JSONValue) async throws {
        guard let task else { throw PaseoError.disconnected }
        let data = try JSONEncoder().encode(value)
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
    }

    /// Sends a session message without waiting for a reply.
    public func send(_ message: [String: JSONValue]) async throws {
        try await sendRaw(["type": "session", "message": .object(message)])
    }

    /// Sends a session request and returns the raw frame of its correlated response.
    public func requestData(_ message: [String: JSONValue], timeout: Duration = .seconds(60)) async throws -> Data {
        guard task != nil, !closed else { throw PaseoError.disconnected }
        let requestId = UUID().uuidString.lowercased()
        var message = message
        message["requestId"] = .string(requestId)
        let envelope: JSONValue = ["type": "session", "message": .object(message)]

        return try await withTimeout(timeout, onTimeout: { await self.cancelPending(requestId) }) {
            try await withCheckedThrowingContinuation { continuation in
                Task { await self.register(requestId, continuation: continuation, envelope: envelope) }
            }
        }
    }

    public func request<P: Decodable>(
        _ message: [String: JSONValue], as type: P.Type, timeout: Duration = .seconds(60)
    ) async throws -> P {
        let data = try await requestData(message, timeout: timeout)
        do {
            return try JSONDecoder().decode(SessionFrame<P>.self, from: data).message.payload
        } catch {
            throw PaseoError.decoding(String(describing: error))
        }
    }

    private func register(_ requestId: String, continuation: CheckedContinuation<Data, Error>, envelope: JSONValue) async {
        guard task != nil, !closed else {
            continuation.resume(throwing: PaseoError.disconnected)
            return
        }
        pending[requestId] = continuation
        do {
            try await sendRaw(envelope)
        } catch {
            pending.removeValue(forKey: requestId)?.resume(throwing: error)
        }
    }

    private func cancelPending(_ requestId: String) {
        pending.removeValue(forKey: requestId)?.resume(throwing: PaseoError.timeout)
    }
}

// MARK: - High-level API

extension DaemonClient {
    public func fetchAgents(subscribe: Bool = true) async throws -> FetchAgentsResponse {
        var message: [String: JSONValue] = [
            "type": "fetch_agents_request",
            "page": ["limit": 200],
            "sort": [["key": "updated_at", "direction": "desc"]],
        ]
        if subscribe { message["subscribe"] = [:] }
        return try await request(message, as: FetchAgentsResponse.self)
    }

    public func fetchWorkspaces(subscribe: Bool = true) async throws -> FetchWorkspacesResponse {
        var message: [String: JSONValue] = ["type": "fetch_workspaces_request", "page": ["limit": 200]]
        if subscribe { message["subscribe"] = [:] }
        return try await request(message, as: FetchWorkspacesResponse.self)
    }

    public func subscribeToSessionEvents(_ events: [String]) async throws {
        _ = try await requestData([
            "type": "session.events.set_subscription.request",
            "events": .array(events.map(JSONValue.string)),
        ])
    }

    /// Replaces the set of agents whose live `agent_stream` events this socket receives.
    public func setTimelineSubscription(agentIds: [String]) async throws {
        _ = try await requestData([
            "type": "agent.timeline.set_subscription.request",
            "agentIds": .array(agentIds.map(JSONValue.string)),
        ])
    }

    public func fetchTimeline(
        agentId: String, direction: String = "tail", cursor: TimelineCursor? = nil, limit: Int = 200
    ) async throws -> TimelinePage {
        var message: [String: JSONValue] = [
            "type": "fetch_agent_timeline_request",
            "agentId": .string(agentId),
            "direction": .string(direction),
            "limit": .number(Double(limit)),
            "projection": "projected",
        ]
        if let cursor {
            message["cursor"] = ["epoch": .string(cursor.epoch), "seq": .number(Double(cursor.seq))]
        }
        let page = try await request(message, as: TimelinePage.self)
        if let error = page.error { throw PaseoError.rpc(error) }
        return page
    }

    public func sendMessage(agentId: String, text: String, messageId: String) async throws {
        let response = try await request([
            "type": "send_agent_message_request",
            "agentId": .string(agentId),
            "text": .string(text),
            "messageId": .string(messageId),
        ], as: SendMessageResponse.self)
        if !response.accepted { throw PaseoError.rpc(response.error ?? "Message was not accepted") }
    }

    public func cancelAgent(agentId: String) async throws {
        _ = try await requestData(["type": "cancel_agent_request", "agentId": .string(agentId)])
    }

    public func archiveAgent(agentId: String) async throws {
        _ = try await requestData(["type": "archive_agent_request", "agentId": .string(agentId)])
    }

    public func setMode(agentId: String, modeId: String) async throws {
        _ = try await requestData([
            "type": "set_agent_mode_request", "agentId": .string(agentId), "modeId": .string(modeId),
        ])
    }

    public func respondToPermission(
        agentId: String, permissionId: String, allow: Bool, actionId: String? = nil, message: String? = nil
    ) async throws {
        var response: [String: JSONValue] = ["behavior": allow ? "allow" : "deny"]
        if let actionId { response["selectedActionId"] = .string(actionId) }
        if !allow, let message { response["message"] = .string(message) }
        // The daemon acknowledges by broadcasting `agent_permission_resolved`; there is no correlated reply.
        try await send([
            "type": "agent_permission_response",
            "agentId": .string(agentId),
            "requestId": .string(permissionId),
            "response": .object(response),
        ])
    }

    public func listProviders() async throws -> [ProviderAvailability] {
        try await request(["type": "list_available_providers_request"], as: ListProvidersResponse.self).providers
    }

    public func listModels(provider: String, cwd: String? = nil) async throws -> [ProviderModel] {
        var message: [String: JSONValue] = ["type": "list_provider_models_request", "provider": .string(provider)]
        if let cwd { message["cwd"] = .string(cwd) }
        return try await request(message, as: ListModelsResponse.self).models
    }

    public func listModes(provider: String, cwd: String? = nil) async throws -> [AgentMode] {
        var message: [String: JSONValue] = ["type": "list_provider_modes_request", "provider": .string(provider)]
        if let cwd { message["cwd"] = .string(cwd) }
        return try await request(message, as: ListModesResponse.self).modes ?? []
    }

    public struct CreateAgentOptions: Sendable {
        public var provider: String
        public var cwd: String
        public var workspaceId: String?
        public var model: String?
        public var modeId: String?
        public var thinkingOptionId: String?
        public var prompt: String

        public init(
            provider: String, cwd: String, workspaceId: String? = nil, model: String? = nil,
            modeId: String? = nil, thinkingOptionId: String? = nil, prompt: String
        ) {
            self.provider = provider
            self.cwd = cwd
            self.workspaceId = workspaceId
            self.model = model
            self.modeId = modeId
            self.thinkingOptionId = thinkingOptionId
            self.prompt = prompt
        }
    }

    public func createAgent(_ options: CreateAgentOptions) async throws -> Agent {
        var config: [String: JSONValue] = ["provider": .string(options.provider), "cwd": .string(options.cwd)]
        if let model = options.model { config["model"] = .string(model) }
        if let modeId = options.modeId { config["modeId"] = .string(modeId) }
        if let thinking = options.thinkingOptionId { config["thinkingOptionId"] = .string(thinking) }
        var message: [String: JSONValue] = [
            "type": "create_agent_request",
            "config": .object(config),
            "initialPrompt": .string(options.prompt),
            "clientMessageId": .string(UUID().uuidString.lowercased()),
            "labels": [:],
        ]
        if let workspaceId = options.workspaceId { message["workspaceId"] = .string(workspaceId) }
        let payload = try await request(message, as: AgentCreatedPayload.self, timeout: .seconds(120))
        guard payload.status == "agent_created", let agent = payload.agent else {
            throw PaseoError.rpc(payload.error ?? "Agent creation failed")
        }
        return agent
    }
}

// MARK: - Envelope decoding

struct FrameHeader: Decodable {
    var type: String
    var reason: String?
    var message: Message?

    struct Message: Decodable {
        var type: String
        var payload: Payload?
    }

    struct Payload: Decodable {
        var requestId: String?
        var status: String?

        enum CodingKeys: String, CodingKey { case requestId, status }

        init(from decoder: Decoder) throws {
            // Payloads are not always objects; tolerate anything.
            let container = try? decoder.container(keyedBy: CodingKeys.self)
            requestId = try? container?.decodeIfPresent(String.self, forKey: .requestId)
            status = try? container?.decodeIfPresent(String.self, forKey: .status)
        }
    }
}

struct SessionFrame<P: Decodable>: Decodable {
    var message: Inner
    struct Inner: Decodable {
        var type: String
        var payload: P
    }
}

struct RpcErrorPayload: Decodable {
    var error: String
    var code: String?
}

// MARK: - Timeout helper

func withTimeout<T: Sendable>(
    _ duration: Duration,
    onTimeout: (@Sendable () async -> Void)? = nil,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: duration)
            await onTimeout?()
            throw PaseoError.timeout
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else { throw PaseoError.timeout }
        return result
    }
}
