import Foundation

// Plugin wire models and requests (packages/protocol/src/messages.ts, plugin-*.ts).
//
// Plugin UI is not declarative on the wire: `plugin.catalog.get.response` carries each plugin's
// client code as a compiled CommonJS bundle, and contributions (screens, panels, sidebar items)
// are only known after a host runs it. See App/PaseoSwift/Plugins and PluginHost/.

public enum PluginStatus: Sendable, Hashable {
    case running, disabled, failed
    case other(String)

    public init(raw: String) {
        switch raw {
        case "running": self = .running
        case "disabled": self = .disabled
        case "failed": self = .failed
        default: self = .other(raw)
        }
    }
}

/// One entry of `plugin.list.response`.
public struct PluginListItem: Decodable, Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String?
    public var icon: String?
    public var description: String?
    public var path: String?
    public var enabled: Bool
    public var statusRaw: String
    public var source: String?
    public var error: String?

    enum CodingKeys: String, CodingKey {
        case id, name, icon, description, path, enabled, source, error
        case statusRaw = "status"
    }

    public var status: PluginStatus { PluginStatus(raw: statusRaw) }
    public var displayName: String { name ?? id }
}

/// One entry of `plugin.catalog.get.response`. An empty `clientBundle` means a server-only plugin.
public struct PluginCatalogEntry: Decodable, Sendable, Identifiable, Hashable {
    public var id: String
    public var clientBundle: String
    public var requirements: Requirements?

    public struct Requirements: Decodable, Sendable, Hashable {
        public var paseo: String?
    }

    public var hasClient: Bool { !clientBundle.isEmpty }
}

public struct PluginListResponse: Decodable, Sendable {
    public var requestId: String
    public var plugins: [PluginListItem]
}

public struct PluginCatalogResponse: Decodable, Sendable {
    public var requestId: String
    public var plugins: [PluginCatalogEntry]
}

public struct PluginRpcInvokeResponse: Decodable, Sendable {
    public var requestId: String
    public var output: JSONValue?
}

/// `status` push payloads for `status.plugin_catalog_changed` / `status.plugin_settings_changed`.
public struct PluginStatusPayload: Decodable, Sendable, Hashable {
    public var status: String
    public var pluginId: String
    public var settingsId: String?
}

public enum PluginEvents {
    /// Session event names to include in `session.events.set_subscription.request`.
    public static let subscription = ["status.plugin_catalog_changed", "status.plugin_settings_changed"]
}

extension ServerInfo {
    public var supportsPlugins: Bool { supports("plugins") }
}

extension DaemonClient {
    public func listPlugins() async throws -> [PluginListItem] {
        try await request(["type": "plugin.list.request"], as: PluginListResponse.self).plugins
    }

    public func pluginCatalog() async throws -> [PluginCatalogEntry] {
        try await request(["type": "plugin.catalog.get.request"], as: PluginCatalogResponse.self).plugins
    }

    /// Calls a plugin RPC. The daemon answers `plugin.rpc.invoke.response { output }`, or
    /// `rpc_error` (thrown as `PaseoError.rpc`) when the plugin is missing or the handler throws.
    public func invokePluginRpc(pluginId: String, method: String, input: JSONValue) async throws -> JSONValue {
        let response = try await request([
            "type": "plugin.rpc.invoke.request",
            "pluginId": .string(pluginId),
            "method": .string(method),
            "input": input,
        ], as: PluginRpcInvokeResponse.self)
        return response.output ?? .null
    }
}
