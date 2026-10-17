import Observation
import PaseoKit
import SwiftUI

/// An action offered in both the menu bar and the Command Center, so it has a keyboard shortcut,
/// shows up in the Help menu's search on macOS, and can be found by typing in the palette.
struct AppCommand: Identifiable {
    enum Menu { case file, agent, go, daemon, plugins }

    let id: String
    let title: String
    let systemImage: String
    let menu: Menu
    var shortcut: KeyboardShortcut?
    var keywords: [String] = []
    /// The palette row's tag, e.g. the contributing plugin's name.
    var category = "Command"
    var isEnabled = true
    /// Whether the Command Center lists it; false for the command that opens it.
    var inCommandCenter = true
    let action: @MainActor () -> Void
}

/// Presentation state the menu bar and the Command Center drive: the palette itself and the sheets
/// its commands open.
@MainActor @Observable
final class CommandCenter {
    var isPresented = false
    var showingNewWorkspace = false
    var showingNewProject = false
    /// The workspace whose archive confirmation is shown, see `AppModel.requestArchive(_:)`.
    var workspaceToArchive: Workspace?
    /// Recently activated palette rows, newest first; they lead the list before anything is typed.
    private(set) var recentIds: [String] = UserDefaults.app.stringArray(forKey: "commandCenterRecents") ?? []

    func record(_ id: String) {
        recentIds.removeAll { $0 == id }
        recentIds.insert(id, at: 0)
        recentIds = Array(recentIds.prefix(20))
        UserDefaults.app.set(recentIds, forKey: "commandCenterRecents")
    }
}

extension AppModel {
    /// Every command, including disabled ones (menus show those greyed out; the palette hides them).
    var appCommands: [AppCommand] {
        let connected = connection.isConnected
        let center = commandCenter
        let workspace = selectedWorkspace
        let agent = selectedAgent
        var commands = [
            AppCommand(
                id: "new-agent", title: "New Agent", systemImage: "square.and.pencil", menu: .file,
                shortcut: KeyboardShortcut("n"), keywords: ["create", "start"], isEnabled: connected
            ) { self.startNewAgent() },
            AppCommand(
                id: "new-workspace", title: "New Workspace", systemImage: "folder.badge.plus", menu: .file,
                shortcut: KeyboardShortcut("n", modifiers: [.command, .shift]),
                keywords: ["create", "worktree", "branch", "pull request"], isEnabled: connected
            ) { center.showingNewWorkspace = true },
            AppCommand(
                id: "new-project", title: "New Project…", systemImage: "plus.rectangle.on.folder", menu: .file,
                shortcut: KeyboardShortcut("n", modifiers: [.command, .option]),
                keywords: ["create", "add", "directory", "folder", "repository"], isEnabled: connected
            ) { center.showingNewProject = true },
            AppCommand(
                id: "new-terminal", title: Self.newTerminalTitle, systemImage: "apple.terminal", menu: .file,
                shortcut: KeyboardShortcut("t"), keywords: ["shell", "create", "tab"], isEnabled: connected && workspace != nil
            ) {
                guard let workspace else { return }
                Task { await self.openNewTab(in: workspace) }
            },
            AppCommand(
                id: "archive-workspace", title: workspace?.archiveTitle ?? "Archive Workspace",
                systemImage: workspace?.archiveSystemImage ?? "archivebox", menu: .file,
                shortcut: KeyboardShortcut(.delete, modifiers: [.command, .shift]),
                keywords: ["archive", "hide", "remove", "worktree", "close"],
                isEnabled: connected && workspace != nil
            ) {
                guard let workspace else { return }
                self.requestArchive(workspace)
            },
            AppCommand(
                id: "stop-agent", title: "Stop Agent", systemImage: "stop.circle", menu: .agent,
                shortcut: KeyboardShortcut("."), keywords: ["cancel", "interrupt", "turn"],
                isEnabled: agent?.status == .running
            ) {
                guard let agent else { return }
                Task { await self.cancel(agent.id) }
            },
            AppCommand(
                id: "archive-agent", title: "Archive Agent", systemImage: "archivebox", menu: .agent,
                isEnabled: agent != nil
            ) {
                guard let agent else { return }
                Task { await self.archive(agent.id) }
            },
            AppCommand(
                id: "command-center", title: "Command Center…", systemImage: "command", menu: .go,
                shortcut: KeyboardShortcut("k"), inCommandCenter: false
            ) { center.isPresented = true },
            AppCommand(
                id: "reconnect", title: "Reconnect", systemImage: "arrow.clockwise", menu: .daemon,
                shortcut: KeyboardShortcut("r", modifiers: [.command, .shift]), keywords: ["daemon", "retry"],
                isEnabled: endpoint != nil
            ) { self.retryNow() },
            AppCommand(
                id: "disconnect", title: "Disconnect", systemImage: "xmark.circle", menu: .daemon,
                keywords: ["daemon", "forget", "host"], isEnabled: endpoint != nil
            ) { self.forgetEndpoint() },
        ]
        commands += pluginCommands(workspace: workspace, agent: agent)
        return commands
    }

    /// ⌘T opens the terminal as a workspace tab on macOS, and in the detail on iOS.
    private static var newTerminalTitle: String {
        #if os(macOS)
        "New Terminal Tab"
        #else
        "New Terminal"
        #endif
    }

    /// Plugin Command Center items and screens, plus workspace and agent panels and commands for
    /// the current selection, like Paseo's own Command Center.
    private func pluginCommands(workspace: Workspace?, agent: Agent?) -> [AppCommand] {
        var commands: [AppCommand] = []
        func command(_ pluginId: String, _ kind: String, _ id: String, title: String, icon: String, keywords: [String] = [], action: @escaping @MainActor () -> Void) {
            commands.append(AppCommand(
                id: "plugin:\(pluginId)/\(kind)/\(id)", title: title, systemImage: LucideSymbols.symbol(for: icon),
                menu: .plugins, keywords: keywords, category: plugins.displayName(of: pluginId), action: action))
        }
        for plugin in plugins.contributions {
            for item in plugin.legacySidebarItems {
                command(plugin.id, "screen", item.surface, title: item.title, icon: item.icon) {
                    self.plugins.open(.screen(pluginId: plugin.id, screenId: item.surface))
                }
            }
            for item in plugin.commands where item.context == "global" {
                command(plugin.id, "command", item.id, title: item.title, icon: item.icon, keywords: item.keywords) {
                    self.plugins.runCommand(pluginId: plugin.id, commandId: item.id)
                }
            }
            guard let workspace else { continue }
            for panel in plugin.panels where panel.context == "workspace" || (panel.context == "agent" && agent != nil) {
                command(plugin.id, "panel", panel.id, title: panel.title, icon: panel.icon) {
                    self.plugins.open(.panel(pluginId: plugin.id, panelId: panel.id, workspaceId: workspace.id, agentId: panel.context == "agent" ? agent?.id : nil))
                }
            }
            for item in plugin.commands where item.context == "workspace" || (item.context == "agent" && agent != nil) {
                command(plugin.id, "command", item.id, title: item.title, icon: item.icon, keywords: item.keywords) {
                    self.plugins.runCommand(pluginId: plugin.id, commandId: item.id, workspaceId: workspace.id, agentId: agent?.id)
                }
            }
        }
        return commands
    }
}

extension KeyboardShortcut {
    /// How menus spell the shortcut, e.g. ⇧⌘N.
    var label: String {
        var label = ""
        if modifiers.contains(.control) { label += "⌃" }
        if modifiers.contains(.option) { label += "⌥" }
        if modifiers.contains(.shift) { label += "⇧" }
        if modifiers.contains(.command) { label += "⌘" }
        let key = switch key {
        case .delete: "⌫"
        default: String(key.character).uppercased()
        }
        return label + key
    }
}
