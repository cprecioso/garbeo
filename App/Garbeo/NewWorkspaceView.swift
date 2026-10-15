import PaseoKit
import SwiftUI

struct NewWorkspaceView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var worktree = WorktreeDraft()
    @State private var startsAgent = false
    @State private var agent = AgentDraft()
    @State private var isCreating = false
    @State private var error: String?

    private var project: ProjectGroup? { worktree.project(in: model) }

    var body: some View {
        NavigationStack {
            Form {
                WorktreeFields(draft: $worktree)

                Section {
                    Toggle("Start an agent", isOn: $startsAgent)
                }
                if startsAgent {
                    AgentFields(draft: agent, cwd: project?.rootPath)
                }

                if let error = error ?? (startsAgent ? agent.error : nil) {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("New Workspace")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isCreating {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Create", action: create).disabled(!canCreate)
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 420)
        #endif
        .task { worktree.selectDefaultProject(in: model) }
    }

    private var canCreate: Bool {
        worktree.options(in: model) != nil && (!startsAgent || agent.isComplete)
    }

    private func create() {
        guard let options = worktree.options(in: model, firstAgentPrompt: startsAgent ? agent.trimmedPrompt : nil)
        else { return }
        isCreating = true
        error = nil
        let firstAgent: ((Workspace) -> DaemonClient.CreateAgentOptions)? = if startsAgent {
            { [agent] in agent.options(cwd: $0.workspaceDirectory, workspaceId: $0.id) }
        } else {
            nil
        }
        Task {
            do {
                try await model.createWorkspace(options, firstAgent: firstAgent)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            isCreating = false
        }
    }
}

/// Where a new worktree comes from, being filled in by the New Workspace and New Agent sheets.
@MainActor
struct WorktreeDraft {
    enum Start: Hashable {
        case newBranch, existingBranch, pullRequest
    }

    var projectId: String?
    var start = Start.newBranch
    var baseRef = ""
    var branch = ""
    var pullRequest = ""
    var slug = ""

    func project(in model: AppModel) -> ProjectGroup? {
        projectId.flatMap { id in model.projects.first { $0.id == id } }
    }

    /// Defaults to the selected workspace's project.
    mutating func selectDefaultProject(in model: AppModel) {
        guard projectId == nil else { return }
        projectId = model.selectedWorkspace?.projectId ?? model.projects.first?.id
    }

    /// The request for this draft, or nil while it is incomplete.
    func options(in model: AppModel, firstAgentPrompt: String? = nil) -> CreateWorktreeOptions? {
        guard let project = project(in: model), let cwd = project.rootPath else { return nil }
        let source: CreateWorktreeOptions.Source
        switch start {
        case .newBranch:
            source = .branchOff(base: Self.nonEmpty(baseRef))
        case .existingBranch:
            guard let branch = Self.nonEmpty(branch) else { return nil }
            source = .checkoutBranch(branch)
        case .pullRequest:
            let digits = pullRequest.trimmingCharacters(in: .whitespaces).trimmingPrefix("#")
            guard let number = Int(digits), number > 0 else { return nil }
            source = .checkoutPullRequest(number)
        }
        return CreateWorktreeOptions(
            cwd: cwd, projectId: project.id, source: source, worktreeSlug: Self.nonEmpty(slug),
            firstAgentPrompt: firstAgentPrompt.flatMap(Self.nonEmpty))
    }

    private static func nonEmpty(_ string: String) -> String? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// The "Project" and "Worktree" form sections for a `WorktreeDraft`.
struct WorktreeFields: View {
    @Environment(AppModel.self) private var model
    @Binding var draft: WorktreeDraft

    var body: some View {
        Section("Project") {
            Picker("Project", selection: $draft.projectId) {
                Text("Choose…").tag(String?.none)
                ForEach(model.projects) { Text($0.name).tag(Optional($0.id)) }
            }
            if let path = draft.project(in: model)?.rootPath {
                Text((path as NSString).abbreviatingWithTildeInPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }

        Section {
            Picker("Start from", selection: $draft.start) {
                Text("New branch").tag(WorktreeDraft.Start.newBranch)
                Text("Existing branch").tag(WorktreeDraft.Start.existingBranch)
                Text("Pull request").tag(WorktreeDraft.Start.pullRequest)
            }
            let repository = draft.project(in: model)?.rootPath
            switch draft.start {
            case .newBranch:
                BranchField(title: "Branch off", text: $draft.baseRef, prompt: "Default branch", repository: repository)
            case .existingBranch:
                BranchField(title: "Branch", text: $draft.branch, prompt: "feature/name", repository: repository)
            case .pullRequest:
                TextField("Number", text: $draft.pullRequest, prompt: Text("123"))
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
            }
            TextField("Name", text: $draft.slug, prompt: Text("Automatic"))
                .autocorrectionDisabled()
        } header: {
            Text("Worktree")
        } footer: {
            Text(draft.start == .newBranch
                ? "The name is used for the worktree's directory and its new branch."
                : "The name is used for the worktree's directory.")
        }
        #if os(iOS)
        .textInputAutocapitalization(.never)
        #endif
    }
}

/// A text field for a branch name that suggests the repository's matching branches.
private struct BranchField: View {
    @Environment(AppModel.self) private var model
    let title: String
    @Binding var text: String
    let prompt: String
    let repository: String?
    @State private var suggestions: [BranchSuggestion] = []
    #if os(iOS)
    @FocusState private var isFocused: Bool
    #endif

    var body: some View {
        TextField(title, text: $text, prompt: Text(prompt))
            .autocorrectionDisabled()
            #if os(macOS)
            .textInputSuggestions(suggestions) { Text($0.name).textInputCompletion($0.name) }
            #else
            .focused($isFocused)
            #endif
            .task(id: [repository, text]) {
                guard let repository else { suggestions = []; return }
                // Debounce typing; a newer keystroke cancels this task.
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled,
                      let found = try? await model.branchSuggestions(cwd: repository, query: text),
                      !Task.isCancelled
                else { return }
                suggestions = found
            }
        #if os(iOS)
        // iOS has no completion popup, so matches are rows below the field.
        if isFocused {
            ForEach(suggestions.prefix(5).filter { $0.name != text }) { suggestion in
                Button {
                    text = suggestion.name
                    isFocused = false
                } label: {
                    Label(suggestion.name, systemImage: "arrow.triangle.branch").font(.callout)
                }
            }
        }
        #endif
    }
}
