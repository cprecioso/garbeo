import Foundation

// What a plugin host learns by running client bundles (PluginHost/src/main.tsx `reportContributions`),
// and where the app shows it. Not a daemon wire model: the daemon only ships the bundles.

/// Contribution metadata reported by the registry page after it runs every client bundle.
public struct PluginContributions: Decodable, Sendable, Identifiable, Hashable {
    public struct Screen: Decodable, Sendable, Hashable { public var id: String; public var title: String? }
    public struct SettingsScreen: Decodable, Sendable, Hashable { public var id: String; public var title: String; public var icon: String }
    public struct Panel: Decodable, Sendable, Hashable, Identifiable {
        public var id: String
        public var title: String
        public var icon: String
        public var context: String
        public var locations: [String]
    }
    public struct Command: Decodable, Sendable, Hashable, Identifiable {
        public var id: String
        public var title: String
        public var icon: String
        public var context: String
        public var keywords: [String]
    }
    public struct LegacySidebarItem: Decodable, Sendable, Hashable, Identifiable {
        public var id: String
        public var title: String
        public var icon: String
        public var surface: String
    }

    public var id: String
    public var screens: [Screen]
    public var settingsScreens: [SettingsScreen]
    public var panels: [Panel]
    public var commands: [Command]
    public var legacySidebarItems: [LegacySidebarItem]
    public var unsupported: [String]
}

/// A contribution with the plugin it belongs to; ids are only unique within a plugin.
public struct PluginItem<Item: Identifiable & Hashable & Sendable>: Identifiable, Hashable, Sendable where Item.ID == String {
    public var pluginId: String
    public var item: Item
    public var id: String { "\(pluginId)/\(item.id)" }

    public init(pluginId: String, item: Item) {
        self.pluginId = pluginId
        self.item = item
    }
}

extension Array where Element == PluginContributions {
    /// Panels that can open for a workspace (and, for agent panels, a given agent).
    public func panels(agent: Bool) -> [PluginItem<PluginContributions.Panel>] {
        flatMap { plugin in
            plugin.panels.filter { ($0.context == "agent") == agent }.map { PluginItem(pluginId: plugin.id, item: $0) }
        }
    }

    public func commands(context: String) -> [PluginItem<PluginContributions.Command>] {
        flatMap { plugin in
            plugin.commands.filter { $0.context == context }.map { PluginItem(pluginId: plugin.id, item: $0) }
        }
    }
}

/// The plugin entries of a workspace menu.
///
/// A menu that opens tabs lists only panels placed in the workspace: commands are actions, not
/// tabs, and plugins often pair a panel with a command that just opens it (gh-stack's "Stack" and
/// "Open stack"). A workspace's context menu lists both.
public struct PluginWorkspaceMenu: Sendable, Hashable {
    public var panels: [PluginItem<PluginContributions.Panel>]
    public var commands: [PluginItem<PluginContributions.Command>]

    public init(_ contributions: [PluginContributions], opensTabs: Bool) {
        let panels = contributions.panels(agent: false)
        if opensTabs {
            self.panels = panels.filter { $0.item.locations.contains("workspace") }
            commands = []
        } else {
            self.panels = panels
            commands = contributions.commands(context: "workspace")
        }
    }

    public var isEmpty: Bool { panels.isEmpty && commands.isEmpty }
}
