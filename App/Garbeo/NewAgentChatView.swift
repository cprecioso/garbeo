import PaseoKit
import SwiftUI

/// A new agent before it exists on the daemon: where it runs, its settings, and the message being
/// written. Sending that first message creates the agent (see `send(in:)`).
@MainActor @Observable
final class NewAgentChat {
    /// An existing workspace, or a worktree created along with the agent.
    enum Destination: Hashable {
        case workspace(String)
        case newWorktree
    }

    let id = UUID()
    var destination: Destination?
    var worktree = WorktreeDraft()
    /// Provider, model, thinking and mode; its prompt is the composer's text.
    let agent = AgentDraft()
    private(set) var isCreating = false
    /// The first message, shown while the agent is being created.
    private(set) var sentMessage: String?
    var error: String?

    init(workspace: Workspace?, provider: String?) {
        destination = workspace.map { .workspace($0.id) }
        worktree.projectId = workspace?.projectId
        if let provider { agent.provider = provider }
    }

    func workspace(in model: AppModel) -> Workspace? {
        if case .workspace(let id) = destination { model.workspaces[id] } else { nil }
    }

    /// Where models and modes are looked up.
    func cwd(in model: AppModel) -> String? {
        switch destination {
        case .workspace: workspace(in: model)?.workspaceDirectory
        case .newWorktree: worktree.project(in: model)?.rootPath
        case nil: nil
        }
    }

    /// Whether the agent has a destination, a provider and a first message.
    func isComplete(in model: AppModel) -> Bool {
        let hasDestination = switch destination {
        case .workspace: workspace(in: model) != nil
        case .newWorktree: worktree.options(in: model) != nil
        case nil: false
        }
        return hasDestination && agent.isComplete
    }

    /// Creates the agent with the composer's text as its first message; `model` then selects it. On
    /// failure the text goes back into the composer and `error` says why.
    func send(in model: AppModel) async {
        guard !isCreating, isComplete(in: model) else { return }
        let prompt = agent.prompt
        let destination = destination
        let workspace = workspace(in: model)
        let worktreeOptions = worktree.options(in: model, firstAgentPrompt: agent.trimmedPrompt)
        // Taken now: the composer is cleared while the agent is created.
        let template = agent.options(cwd: "", workspaceId: nil)
        let options = { (workspace: Workspace) in
            var options = template
            options.cwd = workspace.workspaceDirectory
            options.workspaceId = workspace.id
            return options
        }
        isCreating = true
        error = nil
        sentMessage = agent.trimmedPrompt
        agent.prompt = ""
        do {
            switch destination {
            case .workspace:
                if let workspace { try await model.createAgent(options(workspace)) }
            case .newWorktree:
                if let worktreeOptions { try await model.createWorkspace(worktreeOptions, firstAgent: options) }
            case nil:
                break
            }
            model.closeNewAgentTab(id)
        } catch {
            self.error = error.localizedDescription
            agent.prompt = prompt
        }
        sentMessage = nil
        isCreating = false
    }
}

/// A chat for an agent that doesn't exist yet. Its settings sit above the composer, which has focus;
/// sending the first message creates the agent, which then replaces this view.
struct NewAgentChatView: View {
    @Environment(AppModel.self) private var model
    let chat: NewAgentChat
    /// `.window` drives the window's title; `.pane` (a workspace tab) leaves it to the workspace.
    var chrome: AgentDetailView.Chrome = .window

    private var content: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 14) {
                    if let message = chat.sentMessage {
                        HStack {
                            Spacer(minLength: 60)
                            Text(message)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .opacity(0.6)
                        }
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Starting agent…")
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ContentUnavailableView {
                            Label("New Agent", systemImage: "sparkles")
                        } description: {
                            Text(placeholder)
                        }
                        .padding(.top, 40)
                        .accessibilityIdentifier(AccessibilityID.NewAgent.placeholder)
                    }
                    if let error = chat.error ?? chat.agent.error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier(AccessibilityID.NewAgent.error)
                    }
                }
                .padding()
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom, for: .sizeChanges)

            VStack(alignment: .leading, spacing: 8) {
                NewAgentOptions(chat: chat, agent: chat.agent)
                ComposerField(
                    text: Bindable(chat.agent).prompt, canSend: canSend, focusOnAppear: true,
                    send: { Task { await chat.send(in: model) } }
                ) {}
            }
            .padding()
        }
    }

    var body: some View {
        switch chrome {
        case .window:
            content
                .navigationTitle("New Agent")
                #if os(macOS)
                .navigationSubtitle(chat.cwd(in: model).map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "")
                #else
                .navigationBarTitleDisplayMode(.inline)
                #endif
        case .pane:
            content
        }
    }

    private var canSend: Bool {
        !chat.isCreating && model.connection.isConnected && chat.isComplete(in: model)
    }

    private var placeholder: String {
        switch chat.destination {
        case .workspace: "Send a message to start an agent in \(chat.workspace(in: model)?.displayName ?? "this workspace")."
        case .newWorktree: "Send a message to create a worktree and start an agent in it."
        case nil: "Choose a workspace, then send a message to start an agent."
        }
    }
}

/// The new agent's settings as compact menus above the composer: workspace (or a new worktree),
/// provider, model, thinking level and mode.
private struct NewAgentOptions: View {
    @Environment(AppModel.self) private var model
    @Bindable var chat: NewAgentChat
    @Bindable var agent: AgentDraft
    @State private var showingWorktree = false

    var body: some View {
        let cwd = chat.cwd(in: model)
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                Picker("Workspace", selection: $chat.destination) {
                    Text("Choose workspace…").tag(NewAgentChat.Destination?.none)
                    ForEach(model.projects) { project in
                        Section(project.name) {
                            ForEach(project.workspaces) { workspace in
                                Text(workspace.displayName).tag(Optional(NewAgentChat.Destination.workspace(workspace.id)))
                            }
                        }
                    }
                    Divider()
                    Text("New worktree…").tag(Optional(NewAgentChat.Destination.newWorktree))
                }
                .accessibilityIdentifier(AccessibilityID.NewAgent.workspace)
                if chat.destination == .newWorktree {
                    Button {
                        showingWorktree = true
                    } label: {
                        Label(worktreeSummary, systemImage: "arrow.triangle.branch")
                    }
                    .help("Worktree options")
                    .popover(isPresented: $showingWorktree) {
                        Form { WorktreeFields(draft: $chat.worktree) }
                            .formStyle(.grouped)
                            #if os(macOS)
                            .frame(width: 440, height: 360)
                            #endif
                            .environment(model)
                    }
                }
                Picker("Provider", selection: $agent.provider) {
                    ForEach(agent.providers.filter(\.available)) { Text($0.provider.capitalized).tag($0.provider) }
                }
                .accessibilityIdentifier(AccessibilityID.NewAgent.provider)
                Picker("Model", selection: $agent.modelId) {
                    Text("Default model").tag("")
                    ForEach(agent.models) { Text($0.label).tag($0.id) }
                }
                .disabled(agent.models.isEmpty)
                .accessibilityIdentifier(AccessibilityID.NewAgent.model)
                if let options = agent.selectedModel?.thinkingOptions, !options.isEmpty {
                    Picker("Thinking", selection: $agent.thinkingId) {
                        Text("Default thinking").tag("")
                        ForEach(options) { Text($0.label).tag($0.id) }
                    }
                }
                if !agent.modes.isEmpty {
                    Picker("Mode", selection: $agent.modeId) {
                        Text("Default mode").tag("")
                        ForEach(agent.modes) { Text($0.label).tag($0.id) }
                    }
                    .accessibilityIdentifier(AccessibilityID.NewAgent.mode)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            #if os(macOS)
            .buttonStyle(.borderless)
            .controlSize(.small)
            #endif
        }
        .scrollIndicators(.hidden)
        .task { await agent.loadProviders(from: model) }
        .task(id: [agent.provider, cwd]) { await agent.loadDetails(from: model, cwd: cwd) }
        .onChange(of: agent.modelId) { agent.thinkingId = "" }
    }

    private var worktreeSummary: String {
        switch chat.worktree.start {
        case .newBranch: "New branch"
        case .existingBranch: chat.worktree.branch.isEmpty ? "Existing branch" : chat.worktree.branch
        case .pullRequest: chat.worktree.pullRequest.isEmpty ? "Pull request" : "#\(chat.worktree.pullRequest.trimmingPrefix("#"))"
        }
    }
}
