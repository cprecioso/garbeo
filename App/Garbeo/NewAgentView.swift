import PaseoKit
import SwiftUI

struct NewAgentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    /// An existing workspace, or a worktree created along with the agent.
    private enum Destination: Hashable {
        case workspace(String)
        case newWorktree
    }

    @State private var destination: Destination?
    @State private var worktree = WorktreeDraft()
    @State private var agent = AgentDraft()
    @State private var isCreating = false
    @State private var error: String?

    private var selectedWorkspace: Workspace? {
        if case .workspace(let id) = destination { model.workspaces[id] } else { nil }
    }

    /// Where models and modes are looked up.
    private var cwd: String? {
        switch destination {
        case .workspace: selectedWorkspace?.workspaceDirectory
        case .newWorktree: worktree.project(in: model)?.rootPath
        case nil: nil
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Where") {
                    Picker("Workspace", selection: $destination) {
                        Text("Choose…").tag(Destination?.none)
                        ForEach(model.projects) { project in
                            Section(project.name) {
                                ForEach(project.workspaces) { workspace in
                                    Text(workspace.displayName).tag(Optional(Destination.workspace(workspace.id)))
                                }
                            }
                        }
                        Divider()
                        Text("New worktree…").tag(Optional(Destination.newWorktree))
                    }
                    if let workspace = selectedWorkspace {
                        Text((workspace.workspaceDirectory as NSString).abbreviatingWithTildeInPath)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }

                if destination == .newWorktree {
                    WorktreeFields(draft: $worktree)
                }

                AgentFields(draft: agent, cwd: cwd)

                if let error = error ?? agent.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("New Agent")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isCreating {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Create", action: create)
                            .disabled(!canCreate)
                            .accessibilityIdentifier(AccessibilityID.NewAgent.createButton)
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 560)
        #endif
        .task {
            if destination == nil {
                destination = (model.selectedWorkspace ?? model.projects.first?.workspaces.first)
                    .map { .workspace($0.id) }
            }
        }
        .onChange(of: destination) {
            if destination == .newWorktree { worktree.selectDefaultProject(in: model) }
        }
    }

    private var canCreate: Bool {
        let hasDestination = switch destination {
        case .workspace: selectedWorkspace != nil
        case .newWorktree: worktree.options(in: model) != nil
        case nil: false
        }
        return hasDestination && agent.isComplete
    }

    private func create() {
        isCreating = true
        error = nil
        let destination = destination
        let worktreeOptions = worktree.options(in: model, firstAgentPrompt: agent.trimmedPrompt)
        let workspace = selectedWorkspace
        Task {
            do {
                switch destination {
                case .workspace:
                    guard let workspace else { break }
                    try await model.createAgent(agent.options(cwd: workspace.workspaceDirectory, workspaceId: workspace.id))
                case .newWorktree:
                    guard let worktreeOptions else { break }
                    try await model.createWorkspace(worktreeOptions) { [agent] in
                        agent.options(cwd: $0.workspaceDirectory, workspaceId: $0.id)
                    }
                case nil:
                    break
                }
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            isCreating = false
        }
    }
}
