import Foundation

// Wire models for the Paseo daemon protocol (packages/protocol/src/messages.ts).
// Schemas are append-only upstream, so every non-identity field is optional here
// and unknown enum values are preserved as raw strings.

public enum PaseoDate {
    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let plain = Date.ISO8601FormatStyle()

    public static func parse(_ string: String?) -> Date? {
        guard let string else { return nil }
        return (try? fractional.parse(string)) ?? (try? plain.parse(string))
    }
}

public struct ServerInfo: Decodable, Sendable, Equatable {
    public var serverId: String
    public var hostname: String?
    public var version: String?
    public var protocolVersion: Int?
    public var features: [String: JSONValue]?

    public func supports(_ feature: String) -> Bool {
        features?[feature] == .bool(true)
    }
}

public struct AgentMode: Decodable, Sendable, Hashable, Identifiable {
    public var id: String
    public var label: String
    public var description: String?
}

public struct AgentUsage: Decodable, Sendable, Hashable {
    public var contextWindowMaxTokens: Int?
    public var contextWindowUsedTokens: Int?
}

public struct ActiveTurn: Decodable, Sendable, Hashable {
    public var turnId: String
    public var startedAt: String?
}

public enum AgentStatus: Sendable, Hashable {
    case initializing, idle, running, error, closed
    case other(String)

    public init(raw: String) {
        switch raw {
        case "initializing": self = .initializing
        case "idle": self = .idle
        case "running": self = .running
        case "error": self = .error
        case "closed": self = .closed
        default: self = .other(raw)
        }
    }

    public var label: String {
        switch self {
        case .initializing: "Starting"
        case .idle: "Idle"
        case .running: "Running"
        case .error: "Error"
        case .closed: "Closed"
        case .other(let raw): raw.capitalized
        }
    }
}

public struct Agent: Decodable, Sendable, Identifiable, Hashable {
    public var id: String
    public var provider: String
    public var cwd: String
    public var workspaceId: String?
    public var model: String?
    public var thinkingOptionId: String?
    public var createdAt: String?
    public var updatedAt: String?
    public var lastUserMessageAt: String?
    public var statusRaw: String
    public var title: String?
    public var currentModeId: String?
    public var availableModes: [AgentMode]?
    public var pendingPermissions: [PermissionRequest]?
    public var requiresAttention: Bool?
    public var attentionReason: String?
    public var archivedAt: String?
    public var lastUsage: AgentUsage?
    public var activeTurn: ActiveTurn?
    private var wireLabels: WireLabels?

    /// Label upstream sets on subagents, holding the parent agent's ID (agent-labels.ts).
    public static let parentAgentIdLabel = "paseo.parent-agent-id"

    /// Label a client sets to "true" while it shows this subagent in a tab (agent-labels.ts). The
    /// daemon keeps such subagents when their parent is archived.
    public static func openTabLabel(clientId: String) -> String { "paseo.open-agent-tab.\(clientId)" }

    enum CodingKeys: String, CodingKey {
        case id, provider, cwd, workspaceId, model, thinkingOptionId, createdAt, updatedAt
        case lastUserMessageAt, title, currentModeId, availableModes, pendingPermissions
        case requiresAttention, attentionReason, archivedAt, lastUsage, activeTurn
        case statusRaw = "status"
        case wireLabels = "labels"
    }

    /// String labels from the wire; missing or malformed labels decode as empty.
    public var labels: [String: String] { wireLabels?.values ?? [:] }
    /// Set when this agent is a subagent (trimmed; blank means no parent).
    public var parentAgentId: String? {
        let parent = labels[Self.parentAgentIdLabel]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return parent?.isEmpty == false ? parent : nil
    }

    public var status: AgentStatus { AgentStatus(raw: statusRaw) }
    public var displayTitle: String {
        if let title, !title.isEmpty { return title }
        return "New agent"
    }
    public var updatedDate: Date? { PaseoDate.parse(updatedAt) }
    public var createdDate: Date? { PaseoDate.parse(createdAt) }
    public var currentMode: AgentMode? { availableModes?.first { $0.id == currentModeId } }
}

/// Decodes a `Record<string, string>` without ever throwing; non-string values are dropped.
private struct WireLabels: Decodable, Sendable, Hashable {
    var values: [String: String]

    init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode([String: JSONValue].self)) ?? [:]
        values = raw.compactMapValues { if case .string(let value) = $0 { value } else { nil } }
    }
}

public struct DiffStat: Decodable, Sendable, Hashable {
    public var additions: Int
    public var deletions: Int
}

public struct GitRuntime: Decodable, Sendable, Hashable {
    public var currentBranch: String?
    public var isDirty: Bool?
    public var aheadOfOrigin: Int?
    public var behindOfOrigin: Int?
}

public struct Workspace: Decodable, Sendable, Identifiable, Hashable {
    public var id: String
    public var projectId: String
    public var projectDisplayName: String?
    public var projectCustomName: String?
    public var projectRootPath: String?
    public var workspaceDirectory: String
    public var workspaceKind: String?
    public var name: String
    public var title: String?
    public var status: String?
    public var activityAt: String?
    public var statusEnteredAt: String?
    public var pinnedAt: String?
    /// Set while the daemon archives the workspace.
    public var archivingAt: String?
    public var diffStat: DiffStat?
    public var gitRuntime: GitRuntime?

    public var projectName: String { projectCustomName ?? projectDisplayName ?? projectId }
    /// A Paseo-owned worktree, whose directory archiving removes.
    public var isWorktree: Bool { workspaceKind == "worktree" }
    public var displayName: String {
        if let title, !title.isEmpty { return title }
        return name
    }
    public var sortDate: Date? { PaseoDate.parse(activityAt ?? statusEnteredAt) }
}

public struct PageInfo: Decodable, Sendable {
    public var nextCursor: String?
    public var hasMore: Bool?
}

public struct AgentDirectoryEntry: Decodable, Sendable {
    public var agent: Agent
}

public struct FetchAgentsResponse: Decodable, Sendable {
    public var requestId: String
    public var subscriptionId: String?
    public var entries: [AgentDirectoryEntry]
    public var pageInfo: PageInfo?
}

public struct FetchWorkspacesResponse: Decodable, Sendable {
    public var requestId: String
    public var subscriptionId: String?
    public var entries: [Workspace]
    public var pageInfo: PageInfo?
}

public enum AgentUpdate: Decodable, Sendable {
    case upsert(Agent)
    case remove(agentId: String)
    case unknown

    enum CodingKeys: String, CodingKey { case kind, agent, agentId }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "upsert": self = .upsert(try c.decode(Agent.self, forKey: .agent))
        case "remove": self = .remove(agentId: try c.decode(String.self, forKey: .agentId))
        default: self = .unknown
        }
    }
}

public enum WorkspaceUpdate: Decodable, Sendable {
    case upsert(Workspace)
    case remove(id: String)
    case unknown

    enum CodingKeys: String, CodingKey { case kind, workspace, id }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "upsert": self = .upsert(try c.decode(Workspace.self, forKey: .workspace))
        case "remove": self = .remove(id: try c.decode(String.self, forKey: .id))
        default: self = .unknown
        }
    }
}

// MARK: - Timeline

public struct TaskItem: Decodable, Sendable, Hashable {
    public var text: String
    public var completed: Bool
    public var id: String?
    public var status: String?
}

public struct ToolCallDetail: Decodable, Sendable, Hashable {
    public var type: String
    public var command: String?
    public var cwd: String?
    public var output: JSONValue?
    public var exitCode: Int?
    public var filePath: String?
    public var content: String?
    public var oldString: String?
    public var newString: String?
    public var unifiedDiff: String?
    public var query: String?
    public var url: String?
    public var result: String?
    public var text: String?
    public var label: String?
    public var description: String?
    public var subAgentType: String?
    public var log: String?
    public var input: JSONValue?

    enum CodingKeys: String, CodingKey {
        case type, command, cwd, output, exitCode, filePath, content, oldString, newString
        case unifiedDiff, query, url, result, text, label, description, subAgentType, log, input
    }

    public init(type: String) { self.type = type }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = (try? c.decode(String.self, forKey: .type)) ?? "unknown"
        command = try? c.decodeIfPresent(String.self, forKey: .command)
        cwd = try? c.decodeIfPresent(String.self, forKey: .cwd)
        output = try? c.decodeIfPresent(JSONValue.self, forKey: .output)
        exitCode = try? c.decodeIfPresent(Int.self, forKey: .exitCode)
        filePath = try? c.decodeIfPresent(String.self, forKey: .filePath)
        content = try? c.decodeIfPresent(String.self, forKey: .content)
        oldString = try? c.decodeIfPresent(String.self, forKey: .oldString)
        newString = try? c.decodeIfPresent(String.self, forKey: .newString)
        unifiedDiff = try? c.decodeIfPresent(String.self, forKey: .unifiedDiff)
        query = try? c.decodeIfPresent(String.self, forKey: .query)
        url = try? c.decodeIfPresent(String.self, forKey: .url)
        result = try? c.decodeIfPresent(String.self, forKey: .result)
        text = try? c.decodeIfPresent(String.self, forKey: .text)
        label = try? c.decodeIfPresent(String.self, forKey: .label)
        description = try? c.decodeIfPresent(String.self, forKey: .description)
        subAgentType = try? c.decodeIfPresent(String.self, forKey: .subAgentType)
        log = try? c.decodeIfPresent(String.self, forKey: .log)
        input = try? c.decodeIfPresent(JSONValue.self, forKey: .input)
    }

    /// One-line summary used as the tool call subtitle.
    public var summary: String? {
        switch type {
        case "shell": command
        case "read", "edit", "write": filePath
        case "search": query
        case "fetch": url
        case "sub_agent": description ?? subAgentType
        case "plain_text": label ?? text
        default: nil
        }
    }

    /// Main body shown when a tool call is expanded.
    public var body: String? {
        switch type {
        case "shell": output?.displayString
        case "read", "write": content
        case "edit": unifiedDiff ?? lineDiff
        case "search": content
        case "fetch": result
        case "sub_agent": log
        case "plan", "plain_text": text
        default:
            [input.map { "Input:\n" + $0.displayString }, output.map { "Output:\n" + $0.displayString }]
                .compactMap { $0 }.joined(separator: "\n\n")
        }
    }

    /// Fallback when the daemon sends no `unifiedDiff`: a `+`/`-`/` ` prefixed line diff of the edit.
    var lineDiff: String? {
        guard oldString != nil || newString != nil else { return nil }
        let old = oldString.map { $0.split(separator: "\n", omittingEmptySubsequences: false) } ?? []
        let new = newString.map { $0.split(separator: "\n", omittingEmptySubsequences: false) } ?? []
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in new.difference(from: old) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var lines: [String] = []
        var i = 0, j = 0
        while i < old.count || j < new.count {
            if i < old.count, removed.contains(i) {
                lines.append("-" + old[i]); i += 1
            } else if j < new.count, inserted.contains(j) {
                lines.append("+" + new[j]); j += 1
            } else {
                lines.append(" " + old[i]); i += 1; j += 1
            }
        }
        return lines.joined(separator: "\n")
    }
}

public struct ToolCall: Decodable, Sendable, Hashable {
    public var callId: String
    public var name: String
    public var status: String
    public var detail: ToolCallDetail
    public var error: JSONValue?

    enum CodingKeys: String, CodingKey { case callId, name, status, detail, error }

    public init(callId: String, name: String, status: String, detail: ToolCallDetail, error: JSONValue? = nil) {
        self.callId = callId
        self.name = name
        self.status = status
        self.detail = detail
        self.error = error
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        callId = try c.decode(String.self, forKey: .callId)
        name = (try? c.decode(String.self, forKey: .name)) ?? "tool"
        status = (try? c.decode(String.self, forKey: .status)) ?? "running"
        detail = (try? c.decode(ToolCallDetail.self, forKey: .detail)) ?? ToolCallDetail(type: "unknown")
        error = try? c.decodeIfPresent(JSONValue.self, forKey: .error)
    }
}

public enum TimelineItem: Decodable, Sendable, Hashable {
    case userMessage(text: String, messageId: String?)
    case assistantMessage(text: String, messageId: String?)
    case reasoning(text: String)
    case toolCall(ToolCall)
    case todo([TaskItem])
    case error(message: String)
    case notification(level: String, message: String)
    case compaction(status: String)
    case unknown(type: String)

    enum CodingKeys: String, CodingKey {
        case type, text, messageId, clientMessageId, items, message, level, status
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "user_message":
            let messageId = try c.decodeIfPresent(String.self, forKey: .clientMessageId)
                ?? c.decodeIfPresent(String.self, forKey: .messageId)
            self = .userMessage(text: try c.decode(String.self, forKey: .text), messageId: messageId)
        case "assistant_message":
            self = .assistantMessage(
                text: try c.decode(String.self, forKey: .text),
                messageId: try c.decodeIfPresent(String.self, forKey: .messageId))
        case "reasoning":
            self = .reasoning(text: try c.decode(String.self, forKey: .text))
        case "tool_call":
            self = .toolCall(try ToolCall(from: decoder))
        case "todo":
            self = .todo(try c.decode([TaskItem].self, forKey: .items))
        case "error":
            self = .error(message: try c.decode(String.self, forKey: .message))
        case "notification":
            self = .notification(
                level: (try? c.decode(String.self, forKey: .level)) ?? "info",
                message: try c.decode(String.self, forKey: .message))
        case "compaction":
            self = .compaction(status: (try? c.decode(String.self, forKey: .status)) ?? "completed")
        default:
            self = .unknown(type: type)
        }
    }
}

public struct TimelineCursor: Codable, Sendable, Hashable {
    public var epoch: String
    public var seq: Int
}

public struct TimelineEntry: Decodable, Sendable {
    public var item: TimelineItem
    public var timestamp: String?
    public var seqStart: Int?
    public var seqEnd: Int?
}

public struct TimelinePage: Decodable, Sendable {
    public var requestId: String
    public var agentId: String
    public var agent: Agent?
    public var epoch: String?
    public var entries: [TimelineEntry]
    public var startCursor: TimelineCursor?
    public var endCursor: TimelineCursor?
    public var hasOlder: Bool?
    public var hasNewer: Bool?
    public var error: String?
}

// MARK: - Permissions

public struct PermissionAction: Decodable, Sendable, Hashable, Identifiable {
    public var id: String
    public var label: String
    public var behavior: String
    public var variant: String?
}

public struct PermissionRequest: Decodable, Sendable, Hashable, Identifiable {
    public var id: String
    public var provider: String?
    public var name: String
    public var kind: String
    public var title: String?
    public var description: String?
    public var input: JSONValue?
    public var detail: ToolCallDetail?
    public var actions: [PermissionAction]?
}

public struct AgentPermissionRequestPayload: Decodable, Sendable {
    public var agentId: String
    public var request: PermissionRequest
}

public struct AgentPermissionResolvedPayload: Decodable, Sendable {
    public var agentId: String
    public var requestId: String
}

// MARK: - Stream events

public enum AgentStreamEvent: Decodable, Sendable {
    case timeline(TimelineItem, turnId: String?)
    case turnStarted(turnId: String?)
    case turnCompleted(turnId: String?)
    case turnFailed(error: String, turnId: String?)
    case turnCanceled(reason: String?, turnId: String?)
    case permissionRequested(PermissionRequest)
    case permissionResolved(requestId: String)
    case modeChanged(currentModeId: String?, availableModes: [AgentMode])
    case usageUpdated(AgentUsage)
    case other(type: String)

    enum CodingKeys: String, CodingKey {
        case type, item, turnId, error, reason, request, requestId, currentModeId, availableModes, usage
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        let turnId = try? c.decodeIfPresent(String.self, forKey: .turnId)
        switch type {
        case "timeline": self = .timeline(try c.decode(TimelineItem.self, forKey: .item), turnId: turnId)
        case "turn_started": self = .turnStarted(turnId: turnId)
        case "turn_completed": self = .turnCompleted(turnId: turnId)
        case "turn_failed":
            self = .turnFailed(error: (try? c.decode(String.self, forKey: .error)) ?? "Turn failed", turnId: turnId)
        case "turn_canceled":
            self = .turnCanceled(reason: try? c.decodeIfPresent(String.self, forKey: .reason), turnId: turnId)
        case "permission_requested":
            self = .permissionRequested(try c.decode(PermissionRequest.self, forKey: .request))
        case "permission_resolved":
            self = .permissionResolved(requestId: try c.decode(String.self, forKey: .requestId))
        case "mode_changed":
            self = .modeChanged(
                currentModeId: try? c.decodeIfPresent(String.self, forKey: .currentModeId),
                availableModes: (try? c.decode([AgentMode].self, forKey: .availableModes)) ?? [])
        case "usage_updated":
            self = .usageUpdated(try c.decode(AgentUsage.self, forKey: .usage))
        default:
            self = .other(type: type)
        }
    }
}

public struct AgentStreamPayload: Decodable, Sendable {
    public var agentId: String
    public var event: AgentStreamEvent
    public var timestamp: String?
    public var seq: Int?
    public var epoch: String?
}

// MARK: - Providers

public struct ProviderAvailability: Decodable, Sendable, Hashable, Identifiable {
    public var provider: String
    public var available: Bool
    public var error: String?
    public var id: String { provider }
}

public struct ThinkingOption: Decodable, Sendable, Hashable, Identifiable {
    public var id: String
    public var label: String
    public var isDefault: Bool?
}

public struct ProviderModel: Decodable, Sendable, Hashable, Identifiable {
    public var provider: String
    public var id: String
    public var label: String
    public var description: String?
    public var isDefault: Bool?
    public var thinkingOptions: [ThinkingOption]?
    public var defaultThinkingOptionId: String?
}

public struct ListProvidersResponse: Decodable, Sendable {
    public var providers: [ProviderAvailability]
}

public struct ListModelsResponse: Decodable, Sendable {
    public var provider: String
    public var models: [ProviderModel]
}

public struct ListModesResponse: Decodable, Sendable {
    public var modes: [AgentMode]?
}

public struct SendMessageResponse: Decodable, Sendable {
    public var accepted: Bool
    public var error: String?
}

public struct AgentCreatedPayload: Decodable, Sendable {
    public var status: String
    public var agent: Agent?
    public var error: String?
}
