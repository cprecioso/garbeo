#if os(macOS)
import Bonsplit
import PaseoKit
import SwiftUI

/// A workspace as tabs that can be dragged into nested split panes (macOS).
struct WorkspaceView: View {
    @Environment(AppModel.self) private var model
    let workspace: Workspace
    let tabs: WorkspaceTabs
    @Binding var showingNewAgent: Bool

    var body: some View {
        let agents = model.agents(in: workspace)
        let terminals = model.terminals.terminals(in: workspace)
        let labels = tabs.contents.mapValues { $0.kind.label(in: model) }
        BonsplitView(controller: tabs.controller) { tab, paneId in
            if let content = tabs.contents[tab.id] {
                content.kind.anyContent(in: model)
                    // Pane hosting views pass SwiftUI's minimum size on to NSSplitView, where a
                    // wide minimum squeezes sibling panes to nothing. Let content shrink instead.
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                    .environment(model)
                    .id(tab.id)
                    .simultaneousGesture(TapGesture().onEnded { tabs.controller.focusPane(paneId) })
            }
        } emptyPane: { paneId in
            EmptyWorkspacePane(workspace: workspace, tabs: tabs, paneId: paneId, showingNewAgent: $showingNewAgent)
                .environment(model)
        }
        .navigationTitle(workspace.displayName)
        .navigationSubtitle((workspace.workspaceDirectory as NSString).abbreviatingWithTildeInPath)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Section("Agents") {
                        ForEach(agents) { agent in
                            Button(agent.displayTitle) { tabs.open(.agent(AgentTab(agentId: agent.id))) }
                        }
                    }
                    Section("Terminals") {
                        ForEach(terminals) { terminal in
                            Button(terminal.displayName) { tabs.open(workspace.tab(for: terminal)) }
                        }
                        Button("New Terminal", systemImage: "apple.terminal") {
                            Task { await model.terminals.create(in: workspace) }
                        }
                    }
                    PluginWorkspaceMenuItems(workspaceId: workspace.id)
                } label: {
                    Label("Open Tab", systemImage: "plus.rectangle.on.rectangle")
                }
                .help("Open an agent or terminal of this workspace in a tab")
            }
        }
        .task {
            tabs.start()
            #if DEBUG
            DebugSnapshot.describeWorkspace = { [tabs] in tabs.debugDescription }
            await tabs.debugSplitIfRequested()
            #endif
        }
        .onChange(of: agents.map(\.id)) { _, agentIds in tabs.reconcile(agentIds: agentIds) }
        .onChange(of: labels) { tabs.refreshLabels() }
        .onChange(of: tabs.layout) { _, layout in tabs.layoutChanged(layout) }
        .onChange(of: model.selection, initial: true) { _, selection in
            // Selecting an agent or terminal in the sidebar focuses (or opens) its tab.
            switch selection {
            case .agent(let agentId) where agents.contains { $0.id == agentId }:
                tabs.open(.agent(AgentTab(agentId: agentId)))
            case .terminal(let terminalId):
                if let terminal = terminals.first(where: { $0.id == terminalId }) {
                    tabs.open(workspace.tab(for: terminal))
                }
            default:
                break
            }
        }
        .onChange(of: model.plugins.tabRequest, initial: true) { _, request in
            // Plugin panels for this workspace (from menus, commands or plugin code) open as tabs.
            guard let request, case .panel(_, let workspaceId, _) = request.kind, workspaceId == workspace.id else { return }
            model.plugins.tabRequest = nil
            tabs.open(.plugin(PluginTab(target: request)))
        }
        .onChange(of: tabs.focusedContent) { _, content in
            // ...and the sidebar follows the focused tab.
            guard tabs.isReady else { return }
            let selection = content?.sidebarSelection ?? .workspace(workspace.id)
            if model.selection != selection { model.selection = selection }
        }
    }
}

extension Workspace {
    func tab(for terminal: TerminalInfo) -> WorkspaceTabContent {
        .terminal(TerminalTab(terminalId: terminal.id, workspaceId: id))
    }
}

#if DEBUG
extension WorkspaceTabContent {
    var debugName: String {
        switch self {
        case .agent(let tab): "agent:\(tab.agentId)"
        case .terminal(let tab): "terminal:\(tab.terminalId)"
        case .plugin(let tab): "plugin:\(tab.target.id)"
        }
    }
}

extension WorkspaceTabs {
    var debugDescription: String {
        let layoutJSON = (try? JSONEncoder().encode(layout)).map { String(decoding: $0, as: UTF8.self) } ?? "-"
        return """
        workspace: \(workspaceId) ready=\(isReady) panes=\(controller.allPaneIds.count) tabs=\(contents.count)
        visibleTabs: \(visibleContents.map(\.debugName)) focused: \(focusedContent?.debugName ?? "-")
        layout: \(layoutJSON)
        """
    }

    private static var didDebugSplit = false

    /// Development aid: `-PaseoSplit horizontal[:0.3][,vertical…]` splits the focused pane once per
    /// entry (optionally moving the divider) and moves a not-yet-visible tab into each new pane,
    /// as a drag would.
    func debugSplitIfRequested() async {
        guard !Self.didDebugSplit, let spec = UserDefaults.standard.string(forKey: "PaseoSplit") else { return }
        Self.didDebugSplit = true
        while !isReady { try? await Task.sleep(for: .milliseconds(100)) }
        for entry in spec.split(separator: ",") {
            let parts = entry.split(separator: ":")
            guard let newPane = controller.splitPane(orientation: parts[0] == "vertical" ? .vertical : .horizontal)
            else { continue }
            try? await Task.sleep(for: .milliseconds(300))
            if parts.count > 1, let fraction = Double(parts[1]),
               let splitId = Self.split(containing: bonsplitUUID(newPane), in: controller.treeSnapshot())
            {
                controller.setDividerPosition(fraction, forSplit: splitId, fromExternal: true)
            }
            let visible = Set(visibleContents)
            if let content = contents.values.sorted(by: { "\($0)" < "\($1)" }).first(where: { !visible.contains($0) }) {
                open(content, in: newPane, moveHere: true)
            }
            try? await Task.sleep(for: .milliseconds(300))
        }
    }

    private static func split(containing paneId: String?, in node: ExternalTreeNode) -> UUID? {
        guard case .split(let split) = node else { return nil }
        if case .pane(let pane) = split.second, pane.id == paneId { return UUID(uuidString: split.id) }
        return Self.split(containing: paneId, in: split.first) ?? Self.split(containing: paneId, in: split.second)
    }
}
#endif

private struct EmptyWorkspacePane: View {
    @Environment(AppModel.self) private var model
    let workspace: Workspace
    let tabs: WorkspaceTabs
    let paneId: PaneID
    @Binding var showingNewAgent: Bool

    var body: some View {
        let agents = model.agents(in: workspace)
        let terminals = model.terminals.terminals(in: workspace)
        VStack(spacing: 14) {
            Image(systemName: "rectangle.split.2x1").font(.system(size: 36)).foregroundStyle(.tertiary)
            Text("No open tabs").font(.headline).foregroundStyle(.secondary)
            if !agents.isEmpty || !terminals.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(agents.prefix(8)) { agent in
                        Button {
                            tabs.open(.agent(AgentTab(agentId: agent.id)), in: paneId, moveHere: true)
                        } label: {
                            HStack(spacing: 6) {
                                StatusIndicator(agent: agent)
                                Text(agent.displayTitle).lineLimit(1)
                            }
                        }
                        .buttonStyle(.borderless)
                    }
                    ForEach(terminals.prefix(4)) { terminal in
                        Button {
                            tabs.open(workspace.tab(for: terminal), in: paneId, moveHere: true)
                        } label: {
                            Label(terminal.displayName, systemImage: "apple.terminal").lineLimit(1)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            HStack {
                Button("New Agent") { showingNewAgent = true }
                if tabs.controller.allPaneIds.count > 1 {
                    Button("Close Pane") { tabs.controller.closePane(paneId) }
                }
            }
        }
        .padding()
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .clipped()
        .contentShape(Rectangle())
        .onTapGesture { tabs.controller.focusPane(paneId) }
    }
}
#endif
