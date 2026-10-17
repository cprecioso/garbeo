import PaseoKit
import SwiftUI

// Where plugin contributions surface in the app's own UI:
// - sidebar items (rendered by the plugin, drawn as native rows), legacy sidebar items and
//   global Command Center items in a "Plugins" sidebar section;
// - workspace panels and workspace commands in a workspace's context menu;
// - workspace panels alone in a workspace's Open Tab menu;
// - workspace/agent panels and commands in the agent toolbar's Plugins menu.

struct PluginSidebarSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let plugins = model.plugins
        let legacy = plugins.contributions.flatMap { plugin in plugin.legacySidebarItems.map { PluginItem(pluginId: plugin.id, item: $0) } }
        let commands = plugins.commands(context: "global")
        if !plugins.sidebarRows.isEmpty || !legacy.isEmpty || !commands.isEmpty || !plugins.failures.isEmpty {
            Section("Plugins") {
                ForEach(plugins.sidebarRows) { row in
                    PluginRowButton(title: row.label, symbol: LucideSymbols.symbol(for: row.icon), active: row.active) {
                        plugins.press(row)
                    }
                    .help("\(row.label) · \(plugins.displayName(of: row.pluginId))")
                }
                ForEach(legacy) { entry in
                    let (pluginId, item) = (entry.pluginId, entry.item)
                    let target = PluginPaneTarget.screen(pluginId: pluginId, screenId: item.surface)
                    PluginRowButton(title: item.title, symbol: LucideSymbols.symbol(for: item.icon), active: plugins.activePane == target) {
                        plugins.open(target)
                    }
                }
                ForEach(commands) { entry in
                    let (pluginId, command) = (entry.pluginId, entry.item)
                    PluginRowButton(title: command.title, symbol: LucideSymbols.symbol(for: command.icon), active: false) {
                        plugins.runCommand(pluginId: pluginId, commandId: command.id)
                    }
                }
                ForEach(plugins.failures, id: \.pluginId) { failure in
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(plugins.displayName(of: failure.pluginId))
                            Text(failure.message).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                }
            }
        }
    }
}

private struct PluginRowButton: View {
    let title: String
    let symbol: String
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .fontWeight(active ? .semibold : .regular)
                .foregroundStyle(active ? Color.accentColor : Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Plugin entries of a workspace's context menu, or of its Open Tab menu (`opensTabs`), which
/// leaves out commands; see `PluginWorkspaceMenu`.
struct PluginWorkspaceMenuItems: View {
    @Environment(AppModel.self) private var model
    let workspaceId: String
    var opensTabs = false

    var body: some View {
        let plugins = model.plugins
        let menu = PluginWorkspaceMenu(plugins.contributions, opensTabs: opensTabs)
        if !menu.isEmpty {
            Section("Plugins") {
                ForEach(menu.panels) { entry in
                    let (pluginId, panel) = (entry.pluginId, entry.item)
                    Button(panel.title, systemImage: LucideSymbols.symbol(for: panel.icon)) {
                        plugins.open(.panel(pluginId: pluginId, panelId: panel.id, workspaceId: workspaceId))
                    }
                }
                ForEach(menu.commands) { entry in
                    let (pluginId, command) = (entry.pluginId, entry.item)
                    Button(command.title, systemImage: LucideSymbols.symbol(for: command.icon)) {
                        plugins.runCommand(pluginId: pluginId, commandId: command.id, workspaceId: workspaceId)
                    }
                }
            }
        }
    }
}

/// The agent toolbar's Plugins menu: panels and commands for the agent and its workspace.
struct PluginAgentToolbar: ToolbarContent {
    @Environment(AppModel.self) private var model
    let agent: Agent

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            let plugins = model.plugins
            let workspaceId = agent.workspaceId ?? model.workspaces.values.first { $0.workspaceDirectory == agent.cwd }?.id
            let workspacePanels = plugins.panels(agent: false)
            let agentPanels = plugins.panels(agent: true)
            let commands = plugins.commands(context: "workspace") + plugins.commands(context: "agent")
            if let workspaceId, !(workspacePanels.isEmpty && agentPanels.isEmpty && commands.isEmpty) {
                Menu {
                    ForEach(workspacePanels) { entry in
                        let (pluginId, panel) = (entry.pluginId, entry.item)
                        Button(panel.title, systemImage: LucideSymbols.symbol(for: panel.icon)) {
                            plugins.open(.panel(pluginId: pluginId, panelId: panel.id, workspaceId: workspaceId))
                        }
                    }
                    ForEach(agentPanels) { entry in
                        let (pluginId, panel) = (entry.pluginId, entry.item)
                        Button(panel.title, systemImage: LucideSymbols.symbol(for: panel.icon)) {
                            plugins.open(.panel(pluginId: pluginId, panelId: panel.id, workspaceId: workspaceId, agentId: agent.id))
                        }
                    }
                    if !commands.isEmpty { Divider() }
                    ForEach(commands) { entry in
                    let (pluginId, command) = (entry.pluginId, entry.item)
                        Button(command.title, systemImage: LucideSymbols.symbol(for: command.icon)) {
                            plugins.runCommand(pluginId: pluginId, commandId: command.id, workspaceId: workspaceId, agentId: agent.id)
                        }
                    }
                } label: {
                    Label("Plugins", systemImage: "puzzlepiece.extension")
                }
                .help("Plugin panels and commands")
            }
        }
    }
}
