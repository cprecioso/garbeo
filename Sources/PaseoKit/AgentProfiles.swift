import Foundation

// Agent profiles: named launch bundles (provider, model, mode, thinking, features) kept in the
// daemon's config (packages/protocol/src/agent-profile.ts). Read through `get_daemon_config_request`,
// kept current by `status.daemon_config_changed`.

public struct AgentProfile: Decodable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    /// A key into the client's icon registry (`wrench`, `bot`, …). Unknown keys draw the default.
    public var icon: String?
    /// An identity color name (`violet`, `sky`, …). Unknown values draw unthemed.
    public var color: String?
    public var provider: String
    public var model: String?
    public var modeId: String?
    public var thinkingOptionId: String?
    /// Provider-specific feature values, applied as `featureValues` of the agent's config.
    public var featureValues: [String: JSONValue]?
    /// Free text for orchestrating agents (the `list_profiles` MCP tool).
    public var notes: String?

    public init(
        id: String, name: String, icon: String? = nil, color: String? = nil, provider: String, model: String? = nil,
        modeId: String? = nil, thinkingOptionId: String? = nil, featureValues: [String: JSONValue]? = nil,
        notes: String? = nil
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.color = color
        self.provider = provider
        self.model = model
        self.modeId = modeId
        self.thinkingOptionId = thinkingOptionId
        self.featureValues = featureValues
        self.notes = notes
    }
}

/// The parts of the daemon's mutable config this client reads.
public struct DaemonConfig: Decodable, Sendable, Equatable {
    public var agentProfiles: [AgentProfile]?
}

/// `status.daemon_config_changed`: the daemon's config after a change.
public struct DaemonConfigChanged: Decodable, Sendable {
    public var config: DaemonConfig
}

struct GetDaemonConfigResponse: Decodable {
    var config: DaemonConfig
}

extension ServerInfo {
    /// Whether the daemon keeps agent profiles in its config (v0.3.2+).
    public var supportsAgentProfiles: Bool { supports("agentProfiles") }
}

extension DaemonClient {
    /// The agent profiles configured on the daemon, in their configured order.
    public func agentProfiles() async throws -> [AgentProfile] {
        try await request(["type": "get_daemon_config_request"], as: GetDaemonConfigResponse.self).config.agentProfiles ?? []
    }
}
