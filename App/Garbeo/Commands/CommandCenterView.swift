import CommandPaletteKit
import PaseoKit
import SwiftUI

extension View {
    /// Presents the Command Center (⌘K) while `model.commandCenter.isPresented`.
    func commandCenter() -> some View { modifier(CommandCenterPresenter()) }
}

private struct CommandCenterPresenter: ViewModifier {
    @Environment(AppModel.self) private var model
    /// The activated row's action, run once the palette's sheet is gone so that commands which
    /// present their own sheet don't race its dismissal.
    @State private var pending: (@MainActor () -> Void)?

    func body(content: Content) -> some View {
        @Bindable var center = model.commandCenter
        content.sheet(isPresented: $center.isPresented, onDismiss: runPending) {
            #if os(macOS)
            palette(width: 620, height: 460)
            #else
            GeometryReader { palette(width: $0.size.width, height: $0.size.height) }
            #endif
        }
    }

    private func palette(width: CGFloat, height: CGFloat) -> some View {
        CommandPaletteView(
            placeholder: "Search agents, workspaces, and commands",
            noMatchesMessage: "Nothing matches.",
            resultLimit: 60,
            width: width,
            height: height,
            onActivate: { result in
                model.commandCenter.record(result.id)
                pending = result.action
                model.commandCenter.isPresented = false
            },
            candidates: { model.commandCenterCandidates }
        )
        .commandPaletteRecentIDs(model.commandCenter.recentIds)
        .commandPaletteExtendedKeyboardNavigation()
    }

    private func runPending() {
        pending?()
        pending = nil
    }
}

extension AppModel {
    /// Before anything is typed: recents, agents that need the user, commands, then (macOS)
    /// workspaces and the remaining agents. Terminals only show up when searched for.
    var commandCenterCandidates: [PaletteResult] {
        let live = agents.values
            .filter { $0.archivedAt == nil }
            .sorted { ($0.updatedDate ?? .distantPast) > ($1.updatedDate ?? .distantPast) }
        let (waiting, rest) = live.reduce(into: ([Agent](), [Agent]())) { split, agent in
            if needsUser(agent) { split.0.append(agent) } else { split.1.append(agent) }
        }

        var results = waiting.map(agentResult)
        results += appCommands.filter { $0.inCommandCenter && $0.isEnabled }.map { command in
            PaletteResult(
                id: "command:\(command.id)", title: command.title, category: command.category,
                systemImage: command.systemImage, keyboardShortcut: command.shortcut?.label,
                searchText: ([command.title] + command.keywords).joined(separator: " "), action: command.action)
        }
        #if os(macOS)
        // iOS has no workspace detail; its agents and terminals are searchable by workspace name.
        results += projects.flatMap(\.workspaces).map { workspace in
            PaletteResult(
                id: "workspace:\(workspace.id)", title: workspace.displayName, subtitle: workspace.projectName,
                category: "Workspace",
                systemImage: workspace.isWorktree ? "arrow.triangle.branch" : "folder"
            ) { self.selection = .workspace(workspace.id) }
        }
        #endif
        results += rest.map(agentResult)
        results += workspaces.values.flatMap { workspace in
            terminals.terminals(in: workspace).map { terminal in
                PaletteResult(
                    id: "terminal:\(terminal.id)", title: terminal.displayName, subtitle: workspace.displayName,
                    category: "Terminal", systemImage: "apple.terminal",
                    searchText: "\(terminal.displayName) \(workspace.displayName) \(workspace.projectName)",
                    showsOnlyWhenSearching: true
                ) { self.selection = .terminal(terminal.id) }
            }
        }
        return results
    }

    private func needsUser(_ agent: Agent) -> Bool {
        !pendingPermissions(for: agent.id).isEmpty || agent.requiresAttention == true || agent.status == .error
    }

    private func agentResult(_ agent: Agent) -> PaletteResult {
        let workspace = workspace(for: agent)
        let symbol =
            if !pendingPermissions(for: agent.id).isEmpty { "hand.raised.fill" }
            else if agent.status == .error { "exclamationmark.circle" }
            else if agent.status == .running || agent.status == .initializing { "ellipsis.circle" }
            else { "sparkle" }
        let subtitle = [workspace?.displayName, agent.provider].compactMap(\.self).joined(separator: " · ")
        return PaletteResult(
            id: "agent:\(agent.id)", title: agent.displayTitle, subtitle: subtitle, category: "Agent",
            systemImage: symbol,
            searchText: [agent.displayTitle, workspace?.displayName, workspace?.projectName].compactMap(\.self).joined(separator: " ")
        ) { self.selection = .agent(agent.id) }
    }
}
