import PaseoKit
import SwiftUI

/// What to ask before archiving a workspace, like Paseo's sidebar: Paseo worktrees are archived
/// (their directory removed), asking only when work would be lost; other workspaces are only
/// hidden from the sidebar, which always asks.
struct WorkspaceArchiveConfirmation: Equatable {
    var title: String
    var message: String
    /// The destructive button's title.
    var action: String
}

extension Workspace {
    /// The menu title of archiving this workspace.
    var archiveTitle: String { isWorktree ? "Archive Workspace" : "Hide Workspace from Sidebar" }

    var archiveSystemImage: String { isWorktree ? "archivebox" : "eye.slash" }

    /// Nil archives right away.
    var archiveConfirmation: WorkspaceArchiveConfirmation? {
        guard isWorktree else {
            return WorkspaceArchiveConfirmation(
                title: "Hide workspace?",
                message: "Hide \"\(displayName)\" from the sidebar?\n\nFiles on disk will not be changed.",
                action: "Hide")
        }
        let risks = archiveRisks
        guard !risks.isEmpty else { return nil }
        return WorkspaceArchiveConfirmation(
            title: "Archive \"\(displayName)\"?", message: risks.joined(separator: "\n"), action: "Archive")
    }

    /// Work archiving the worktree would lose: uncommitted changes and unpushed commits.
    var archiveRisks: [String] {
        var risks: [String] = []
        let changes = diffStat.flatMap { diff -> String? in
            var parts: [String] = []
            if diff.additions > 0 { parts.append(diff.additions == 1 ? "1 added line" : "\(diff.additions) added lines") }
            if diff.deletions > 0 { parts.append(diff.deletions == 1 ? "1 deleted line" : "\(diff.deletions) deleted lines") }
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        }
        // Without git status, a diff means uncommitted changes.
        if gitRuntime?.isDirty ?? (changes != nil) {
            risks.append(changes.map { "Uncommitted changes (\($0))" } ?? "Uncommitted changes")
        }
        if let ahead = gitRuntime?.aheadOfOrigin, ahead > 0 {
            risks.append(ahead == 1 ? "1 unpushed commit" : "\(ahead) unpushed commits")
        }
        return risks
    }
}

extension View {
    /// Asks `model.commandCenter.workspaceToArchive`'s confirmation, then archives it.
    func workspaceArchiveConfirmation() -> some View { modifier(WorkspaceArchiveConfirmationPresenter()) }
}

private struct WorkspaceArchiveConfirmationPresenter: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        let center = model.commandCenter
        let pending = center.workspaceToArchive.flatMap { workspace in
            workspace.archiveConfirmation.map { (workspace, $0) }
        }
        content.confirmationDialog(
            Text(pending?.1.title ?? ""),
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { center.workspaceToArchive = nil } }),
            presenting: pending
        ) { workspace, confirmation in
            Button(confirmation.action, role: .destructive) {
                Task { await model.archive(workspace) }
            }
        } message: { _, confirmation in
            Text(confirmation.message)
        }
    }
}
