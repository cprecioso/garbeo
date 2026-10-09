import PaseoKit
import SwiftUI

/// What a workspace tab shows.
///
/// Tabs are persisted as this value (see `WorkspaceLayout`), so every kind identifies its target
/// by stable IDs only, never by runtime objects.
///
/// Adding a kind (terminal, plugin webview, …):
/// 1. write a struct conforming to `WorkspaceTabKind` (label + content view, optionally what
///    closing the tab does),
/// 2. add a `case` here and its arm in `kind`.
/// The tab bar, splits, drag and drop, and persistence need no other changes.
enum WorkspaceTabContent: Hashable, Codable, Sendable {
    case agent(AgentTab)
    case terminal(TerminalTab)
    case plugin(PluginTab)

    var kind: any WorkspaceTabKind {
        switch self {
        case .agent(let tab): tab
        case .terminal(let tab): tab
        case .plugin(let tab): tab
        }
    }

    /// The app selection while this tab is focused; the sidebar highlights its workspace.
    var sidebarSelection: SidebarSelection? {
        switch self {
        case .agent(let tab): .agent(tab.agentId)
        case .terminal(let tab): .terminal(tab.terminalId)
        case .plugin: nil
        }
    }
}

/// One kind of workspace tab: its tab-bar label and its pane content.
protocol WorkspaceTabKind: Hashable, Codable, Sendable {
    associatedtype Content: View

    /// Tab-bar label. Return nil when the target no longer exists (archived agent, exited
    /// terminal…); the tab is then closed and dropped from the saved layout.
    @MainActor func label(in model: AppModel) -> WorkspaceTabLabel?

    @MainActor @ViewBuilder func makeContent(in model: AppModel) -> Content

    /// Asked for before the user closes the tab; nil closes it right away. Default: nil.
    @MainActor func closeConfirmation(in model: AppModel) -> WorkspaceTabCloseConfirmation?

    /// What closing the tab does to its target (archive the agent, kill the terminal). The tab
    /// stays closed meanwhile. Default: nothing.
    @MainActor func close(in model: AppModel) async
}

extension WorkspaceTabKind {
    @MainActor func anyContent(in model: AppModel) -> AnyView {
        AnyView(makeContent(in: model))
    }

    func closeConfirmation(in model: AppModel) -> WorkspaceTabCloseConfirmation? { nil }

    func close(in model: AppModel) async {}
}

struct WorkspaceTabCloseConfirmation: Equatable {
    var title: String
    var message: String
    /// The destructive button's title.
    var action: String
}

struct WorkspaceTabLabel: Equatable {
    var title: String
    /// SF Symbol name.
    var icon: String
    /// Shown as the tab's dot (Bonsplit's "dirty" indicator).
    var needsAttention = false
}

// MARK: - Agent

struct AgentTab: WorkspaceTabKind {
    var agentId: String

    func label(in model: AppModel) -> WorkspaceTabLabel? {
        guard let agent = model.agents[agentId], agent.archivedAt == nil else { return nil }
        let waiting = !model.pendingPermissions(for: agentId).isEmpty
        let icon = switch agent.status {
        case _ where waiting: "hand.raised.fill"
        case .running, .initializing: "circle.dotted"
        case .error: "exclamationmark.triangle"
        default: "sparkles"
        }
        return WorkspaceTabLabel(
            title: agent.displayTitle, icon: icon, needsAttention: waiting || agent.requiresAttention == true)
    }

    func makeContent(in model: AppModel) -> some View {
        if let agent = model.agents[agentId] {
            AgentDetailView(agent: agent, chrome: .pane)
        } else {
            ContentUnavailableView("Agent unavailable", systemImage: "questionmark.bubble")
        }
    }

    func closeConfirmation(in model: AppModel) -> WorkspaceTabCloseConfirmation? {
        guard model.agents[agentId]?.status == .running else { return nil }
        return WorkspaceTabCloseConfirmation(
            title: "Archive running agent?",
            message: "This agent is still running. Archiving it will stop the agent and close the tab.",
            action: "Archive")
    }

    func close(in model: AppModel) async {
        await model.archive(agentId)
    }
}

// MARK: - Terminal

struct TerminalTab: WorkspaceTabKind {
    var terminalId: String
    /// Lets the label tell "terminal list not loaded yet" (keep the tab) from "terminal gone".
    var workspaceId: String

    func label(in model: AppModel) -> WorkspaceTabLabel? {
        // Terminal lists load after connecting; until this workspace's arrives, keep the tab.
        guard let terminals = model.terminals.byWorkspace[workspaceId] else {
            return WorkspaceTabLabel(title: "Terminal", icon: "apple.terminal")
        }
        guard let terminal = terminals.first(where: { $0.id == terminalId }) else { return nil }
        let activity = terminal.activity
        return WorkspaceTabLabel(
            title: terminal.displayName, icon: "apple.terminal",
            needsAttention: activity?.attentionReason == "needs_input" || activity?.state == "attention")
    }

    func makeContent(in model: AppModel) -> some View {
        if let terminal = model.terminals.byWorkspace[workspaceId]?.first(where: { $0.id == terminalId }) {
            TerminalDetailView(terminal: terminal, chrome: .pane, focusOnAppear: Self.focusOnAppear(terminalId, in: model))
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    func closeConfirmation(in model: AppModel) -> WorkspaceTabCloseConfirmation? {
        WorkspaceTabCloseConfirmation(
            title: "Close terminal?",
            message: "Any running process in this terminal will be stopped immediately.",
            action: "Close")
    }

    func close(in model: AppModel) async {
        guard let terminal = model.terminals.byWorkspace[workspaceId]?.first(where: { $0.id == terminalId }) else { return }
        await model.terminals.kill(terminal)
    }

    /// Focusing claims the PTY size, so only the terminal the user just selected takes focus.
    @MainActor private static func focusOnAppear(_ terminalId: String, in model: AppModel) -> Bool {
        #if DEBUG
        // Development aid: `-PaseoTerminalPassive YES` never focuses (no size claim on a live daemon).
        if UserDefaults.standard.bool(forKey: "PaseoTerminalPassive") { return false }
        #endif
        return model.selection == .terminal(terminalId)
    }
}
