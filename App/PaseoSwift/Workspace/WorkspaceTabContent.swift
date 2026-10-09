import PaseoKit
import SwiftUI

/// What a workspace tab shows.
///
/// Tabs are persisted as this value (see `WorkspaceLayout`), so every kind identifies its target
/// by stable IDs only, never by runtime objects.
///
/// Adding a kind (terminal, plugin webview, …):
/// 1. write a struct conforming to `WorkspaceTabKind` (label + content view),
/// 2. add a `case` here and its arm in `kind`.
/// The tab bar, splits, drag and drop, and persistence need no other changes.
enum WorkspaceTabContent: Hashable, Codable, Sendable {
    case agent(AgentTab)
    case terminal(TerminalTab)

    var kind: any WorkspaceTabKind {
        switch self {
        case .agent(let tab): tab
        case .terminal(let tab): tab
        }
    }

    var agentId: String? {
        if case .agent(let tab) = self { tab.agentId } else { nil }
    }

    /// The sidebar row for this tab, if it has one; the sidebar follows the focused tab.
    var sidebarSelection: SidebarSelection? {
        switch self {
        case .agent(let tab): .agent(tab.agentId)
        case .terminal(let tab): .terminal(tab.terminalId)
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
}

extension WorkspaceTabKind {
    @MainActor func anyContent(in model: AppModel) -> AnyView {
        AnyView(makeContent(in: model))
    }
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

    /// Focusing claims the PTY size, so only the terminal the user just selected takes focus.
    @MainActor private static func focusOnAppear(_ terminalId: String, in model: AppModel) -> Bool {
        #if DEBUG
        // Development aid: `-PaseoTerminalPassive YES` never focuses (no size claim on a live daemon).
        if UserDefaults.standard.bool(forKey: "PaseoTerminalPassive") { return false }
        #endif
        return model.selection == .terminal(terminalId)
    }
}
