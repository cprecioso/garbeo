import PaseoKit
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Binding var showingNewAgent: Bool
    @State private var search = ""

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selectedAgentId) {
            ConnectionBanner()
            PluginSidebarSection()

            ForEach(model.projects) { project in
                let workspaces = project.workspaces.filter { matches($0) }
                if !workspaces.isEmpty {
                    Section(project.name) {
                        ForEach(workspaces) { workspace in
                            WorkspaceSection(workspace: workspace, agents: model.agents(in: workspace).filter(matches))
                        }
                    }
                }
            }

            let unplaced = model.unplacedAgents.filter(matches)
            if !unplaced.isEmpty {
                Section("Other agents") {
                    ForEach(unplaced) { AgentRow(agent: $0).tag($0.id) }
                }
            }
        }
        .searchable(text: $search, placement: .sidebar, prompt: "Filter agents")
        .navigationTitle(model.serverInfo?.hostname ?? "Paseo")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingNewAgent = true
                } label: {
                    Label("New Agent", systemImage: "square.and.pencil")
                }
                .keyboardShortcut("n")
                .disabled(!model.connection.isConnected)
            }
            #if os(iOS)
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

    private func matches(_ workspace: Workspace) -> Bool {
        guard !search.isEmpty else { return true }
        return workspace.displayName.localizedCaseInsensitiveContains(search)
            || model.agents(in: workspace).contains(where: matches)
    }

    private func matches(_ agent: Agent) -> Bool {
        search.isEmpty || agent.displayTitle.localizedCaseInsensitiveContains(search)
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
    let workspace: Workspace
    let agents: [Agent]
    @State private var isExpanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            if agents.isEmpty {
                Text("No agents").font(.caption).foregroundStyle(.tertiary)
            }
            ForEach(agents) { AgentRow(agent: $0).tag($0.id) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: workspace.workspaceKind == "worktree" ? "arrow.triangle.branch" : "folder")
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(workspace.displayName).lineLimit(1)
                Spacer(minLength: 4)
                if let diff = workspace.diffStat, diff.additions + diff.deletions > 0 {
                    DiffStatView(diff: diff)
                }
            }
            .contextMenu { PluginWorkspaceMenuItems(workspaceId: workspace.id) }
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
