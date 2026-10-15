import Foundation
import PaseoKit

/// What a plugin pane shows: a plugin screen (with its params) or a workspace panel.
/// Codable and Hashable so pane containers (tabs, split panes) can persist and key it.
struct PluginPaneTarget: Hashable, Codable, Identifiable, Sendable {
    enum Kind: Hashable, Codable, Sendable {
        case screen(id: String, params: [String: String])
        case panel(id: String, workspaceId: String, agentId: String?)
    }

    var pluginId: String
    var kind: Kind

    static func screen(pluginId: String, screenId: String, params: [String: String] = [:]) -> Self {
        Self(pluginId: pluginId, kind: .screen(id: screenId, params: params))
    }

    static func panel(pluginId: String, panelId: String, workspaceId: String, agentId: String? = nil) -> Self {
        Self(pluginId: pluginId, kind: .panel(id: panelId, workspaceId: workspaceId, agentId: agentId))
    }

    var id: String {
        switch kind {
        case .screen(let screenId, let params):
            let query = params.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
            return "\(pluginId)/screen/\(screenId)?\(query)"
        case .panel(let panelId, let workspaceId, let agentId):
            return "\(pluginId)/panel/\(panelId)/\(workspaceId)/\(agentId ?? "-")"
        }
    }

    /// The JSON the plugin host page expects in its `init.target`.
    var bridgeValue: JSONValue {
        switch kind {
        case .screen(let screenId, let params):
            return [
                "kind": "screen", "pluginId": .string(pluginId), "screenId": .string(screenId),
                "params": .object(params.mapValues(JSONValue.string)),
            ]
        case .panel(let panelId, let workspaceId, let agentId):
            return [
                "kind": "panel", "pluginId": .string(pluginId), "panelId": .string(panelId),
                "workspaceId": .string(workspaceId), "agentId": agentId.map(JSONValue.string) ?? .null,
            ]
        }
    }
}
