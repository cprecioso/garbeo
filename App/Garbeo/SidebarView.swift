import PaseoKit
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Binding var showingNewWorkspace: Bool
    @Binding var showingNewProject: Bool
    @State private var search = ""

    var body: some View {
        List(selection: selection) {
            ConnectionBanner()
            PluginSidebarSection()

            ForEach(model.projects) { project in
                let workspaces = project.workspaces.filter { matches($0) }
                if !workspaces.isEmpty {
                    Section {
                        ForEach(workspaces) { workspace in
                            #if os(macOS)
                            // A workspace's agents and terminals are its tabs, not sidebar rows.
                            WorkspaceLabel(workspace: workspace, showsStatus: true)
                                .tag(SidebarSelection.workspace(workspace.id))
                            #else
                            WorkspaceSection(
                                workspace: workspace, agents: model.agents(in: workspace).filter(matches),
                                terminals: model.terminals.terminals(in: workspace).filter(matches))
                            #endif
                        }
                    } header: {
                        Text(project.name)
                            .accessibilityIdentifier(AccessibilityID.Sidebar.project(project.name))
                    }
                }
            }

            let unplaced = model.unplacedAgents.filter(matches)
            if !unplaced.isEmpty {
                Section("Other agents") {
                    ForEach(unplaced) { AgentRow(agent: $0).tag(SidebarSelection.agent($0.id)) }
                }
            }
        }
        .accessibilityIdentifier(AccessibilityID.Sidebar.list)
        .searchable(text: $search, placement: .sidebar, prompt: searchPrompt)
        .safeAreaInset(edge: .bottom, spacing: 0) { ConnectionFooter() }
        .navigationTitle(model.serverInfo?.hostname ?? "Garbeo")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.startNewAgent()
                } label: {
                    Label("New Agent", systemImage: "square.and.pencil")
                }
                .accessibilityIdentifier(AccessibilityID.Sidebar.newAgent)
                .disabled(!model.connection.isConnected)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingNewWorkspace = true
                } label: {
                    Label("New Workspace", systemImage: "folder.badge.plus")
                }
                .disabled(!model.connection.isConnected)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingNewProject = true
                } label: {
                    Label("New Project", systemImage: "plus.rectangle.on.folder")
                }
                .disabled(!model.connection.isConnected)
                .accessibilityIdentifier(AccessibilityID.Sidebar.newProject)
            }
            #if os(iOS)
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.commandCenter.isPresented = true
                } label: {
                    Label("Command Center", systemImage: "command")
                }
            }
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button("Reconnect", systemImage: "arrow.clockwise") { model.retryNow() }
                    Button("Disconnect", systemImage: "xmark.circle", role: .destructive) { model.forgetEndpoint() }
                } label: {
                    Label("Daemon", systemImage: "server.rack")
                }
            }
            #endif
        }
        .refreshable { model.retryNow() }
    }

    /// On macOS an agent or terminal selection is a tab of its workspace, so the workspace row
    /// stays highlighted.
    private var selection: Binding<SidebarSelection?> {
        @Bindable var model = model
        #if os(macOS)
        return Binding(
            get: { model.selectedWorkspace.map { .workspace($0.id) } ?? model.selection },
            set: { model.selection = $0 })
        #else
        return $model.selection
        #endif
    }

    private var searchPrompt: String {
        #if os(macOS)
        "Filter workspaces"
        #else
        "Filter agents"
        #endif
    }

    private func matches(_ workspace: Workspace) -> Bool {
        guard !search.isEmpty else { return true }
        return workspace.displayName.localizedCaseInsensitiveContains(search)
            || model.agents(in: workspace).contains(where: matches)
            || model.terminals.terminals(in: workspace).contains(where: matches)
    }

    private func matches(_ agent: Agent) -> Bool {
        search.isEmpty || agent.displayTitle.localizedCaseInsensitiveContains(search)
    }

    private func matches(_ terminal: TerminalInfo) -> Bool {
        search.isEmpty || terminal.displayName.localizedCaseInsensitiveContains(search)
    }
}

private struct ConnectionBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if case .reconnecting(let attempt, let error) = model.connection {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Reconnecting… (attempt \(attempt))").font(.callout.weight(.medium))
                    if let error { Text(error).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                }
                Spacer()
                Button("Retry") { model.retryNow() }.buttonStyle(.borderless)
            }
            .padding(.vertical, 4)
        }
    }
}

private struct WorkspaceSection: View {
    @Environment(AppModel.self) private var model
    let workspace: Workspace
    let agents: [Agent]
    let terminals: [TerminalInfo]
    @State private var isExpanded = true
    @State private var showingSetup = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            if let setup = model.setups[workspace.id], setup.isWorthShowing {
                Button { showingSetup = true } label: { WorkspaceSetupSummary(setup: setup) }
                    .foregroundStyle(.primary)
                    .swipeActions {
                        if setup.status != .running {
                            Button("Dismiss") { model.dismissSetupStatus(for: workspace.id) }
                        }
                    }
            }
            if agents.isEmpty && terminals.isEmpty {
                Text("No agents").font(.caption).foregroundStyle(.tertiary)
            }
            ForEach(agents) { AgentRow(agent: $0).tag(SidebarSelection.agent($0.id)) }
            ForEach(terminals) { TerminalRow(terminal: $0).tag(SidebarSelection.terminal($0.id)) }
        } label: {
            WorkspaceLabel(workspace: workspace)
        }
        .sheet(isPresented: $showingSetup) { WorkspaceSetupView(workspace: workspace) }
        .task { await model.loadSetupStatus(for: workspace.id) }
    }
}

private struct WorkspaceLabel: View {
    @Environment(AppModel.self) private var model
    let workspace: Workspace
    /// Summarizes the workspace's agents, for when they aren't listed below it.
    var showsStatus = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: workspace.isWorktree ? "arrow.triangle.branch" : "folder")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(workspace.displayName).lineLimit(1)
                .accessibilityIdentifier(AccessibilityID.Sidebar.workspaceRow)
            Spacer(minLength: 4)
            if showsStatus { WorkspaceStatusIndicator(agents: model.agents(in: workspace)) }
            if let diff = workspace.diffStat, diff.additions + diff.deletions > 0 {
                DiffStatView(diff: diff)
            }
        }
        .contextMenu {
            Button("New Terminal", systemImage: "apple.terminal") {
                Task { await model.terminals.create(in: workspace) }
            }
            PluginWorkspaceMenuItems(workspaceId: workspace.id)
            Divider()
            Button(workspace.archiveTitle, systemImage: workspace.archiveSystemImage) {
                model.requestArchive(workspace)
            }
        }
    }
}

/// The most pressing state among a workspace's agents: waiting for permission, running, failed,
/// or needing attention. Nothing when all are idle.
private struct WorkspaceStatusIndicator: View {
    @Environment(AppModel.self) private var model
    let agents: [Agent]

    var body: some View {
        let waiting = agents.count(where: { !model.pendingPermissions(for: $0.id).isEmpty })
        let running = agents.count(where: { $0.status == .running || $0.status == .initializing })
        let failed = agents.count(where: { $0.status == .error })
        let attention = agents.count(where: { $0.requiresAttention == true })
        if waiting > 0 {
            Image(systemName: "hand.raised.fill").foregroundStyle(.orange).font(.caption)
                .help("Waiting for permission (\(waiting))")
        } else if running > 0 {
            ProgressView().controlSize(.mini).help("Running (\(running))")
        } else if failed > 0 {
            Circle().fill(.red).frame(width: 8, height: 8).help("Error (\(failed))")
        } else if attention > 0 {
            Circle().fill(Color.accentColor).frame(width: 8, height: 8).help("Needs attention (\(attention))")
        }
    }
}

struct DiffStatView: View {
    let diff: DiffStat

    var body: some View {
        HStack(spacing: 3) {
            Text("+\(diff.additions)").foregroundStyle(.green)
            Text("-\(diff.deletions)").foregroundStyle(.red)
        }
        .font(.caption2.monospacedDigit())
    }
}

struct AgentRow: View {
    @Environment(AppModel.self) private var model
    let agent: Agent

    var body: some View {
        HStack(spacing: 8) {
            StatusIndicator(agent: agent, hasPermission: !model.pendingPermissions(for: agent.id).isEmpty)
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.displayTitle).lineLimit(1)
                HStack(spacing: 4) {
                    Text(agent.provider)
                    if let model = agent.model { Text("·"); Text(model) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 4)
            if let date = agent.updatedDate {
                Text(date, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .contextMenu {
            if agent.status == .running {
                Button("Stop", systemImage: "stop.circle") { Task { await model.cancel(agent.id) } }
            }
            Button("Archive", systemImage: "archivebox") { Task { await model.archive(agent.id) } }
        }
    }
}

struct StatusIndicator: View {
    let agent: Agent
    var hasPermission = false

    var body: some View {
        ZStack {
            if hasPermission {
                Image(systemName: "hand.raised.fill").foregroundStyle(.orange).font(.caption)
            } else {
                switch agent.status {
                case .running, .initializing:
                    ProgressView().controlSize(.mini)
                case .error:
                    Circle().fill(.red).frame(width: 8, height: 8)
                case .closed:
                    Circle().strokeBorder(.secondary, lineWidth: 1).frame(width: 8, height: 8)
                default:
                    Circle()
                        .fill(agent.requiresAttention == true ? Color.accentColor : Color.secondary.opacity(0.4))
                        .frame(width: 8, height: 8)
                }
            }
        }
        .frame(width: 16, height: 16)
        .help(hasPermission ? "Waiting for permission" : agent.status.label)
    }
}
