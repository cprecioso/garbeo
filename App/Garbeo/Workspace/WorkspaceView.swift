#if os(macOS)
import Bonsplit
import PaseoKit
import SwiftUI

/// A workspace as tabs that can be dragged into nested split panes (macOS).
struct WorkspaceView: View {
    @Environment(AppModel.self) private var model
    let workspace: Workspace
    let tabs: WorkspaceTabs
    @State private var pendingClose: PendingClose?
    /// Tabs being closed; a subagent's tab stays open until the daemon accepts it's no longer shown.
    @State private var closing: Set<WorkspaceTabContent> = []

    private struct PendingClose {
        var content: WorkspaceTabContent
        var confirmation: WorkspaceTabCloseConfirmation
    }

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
            EmptyWorkspacePane(workspace: workspace, tabs: tabs, paneId: paneId)
                .environment(model)
        }
        .safeAreaInset(edge: .top, spacing: 0) { WorkspaceSetupBanner(workspace: workspace) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Workspace.view)
        .navigationTitle(workspace.displayName)
        .navigationSubtitle((workspace.workspaceDirectory as NSString).abbreviatingWithTildeInPath)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    ForEach(openTabMenu(agents: agents, terminals: terminals)) { section in
                        Section(section.title) {
                            ForEach(section.entries) { entry in
                                if let systemImage = entry.systemImage {
                                    Button(entry.title, systemImage: systemImage, action: entry.action)
                                } else {
                                    Button(entry.title, action: entry.action)
                                }
                            }
                        }
                    }
                } label: {
                    Label("Open Tab", systemImage: "plus.rectangle.on.rectangle")
                }
                .accessibilityIdentifier(AccessibilityID.Workspace.openTabMenu)
                .help("Open an agent or terminal of this workspace in a tab")
            }
        }
        .task {
            tabs.start()
            Task { await model.loadSetupStatus(for: workspace.id) }
            #if DEBUG
            DebugSnapshot.describeWorkspace = { [tabs] in tabs.debugDescription }
            await tabs.debugSplitIfRequested()
            #endif
        }
        .onChange(of: model.tabMembers(of: workspace)) { _, members in tabs.reconcile(members: members) }
        .task(id: subagentTabsToMark) {
            // Tell the daemon which subagents this client shows in tabs, retrying until it accepts.
            var remaining = subagentTabsToMark
            while !remaining.isEmpty, !Task.isCancelled {
                var failed: [String] = []
                for agentId in remaining {
                    do { try await model.setOpenTab(true, for: agentId) } catch { failed.append(agentId) }
                }
                remaining = failed
                if !remaining.isEmpty { try? await Task.sleep(for: .seconds(2)) }
            }
        }
        .onChange(of: tabs.closeRequest) { _, content in
            guard let content else { return }
            tabs.closeRequest = nil
            if let confirmation = content.kind.closeConfirmation(in: model) {
                pendingClose = PendingClose(content: content, confirmation: confirmation)
            } else {
                close(content)
            }
        }
        .confirmationDialog(
            Text(pendingClose?.confirmation.title ?? ""),
            isPresented: Binding(get: { pendingClose != nil }, set: { if !$0 { pendingClose = nil } }),
            presenting: pendingClose
        ) { pending in
            Button(pending.confirmation.action, role: .destructive) { close(pending.content) }
        } message: { pending in
            Text(pending.confirmation.message)
        }
        .onChange(of: labels) { tabs.refreshLabels() }
        .onChange(of: tabs.layout) { _, layout in tabs.layoutChanged(layout) }
        .onChange(of: model.selection, initial: true) { _, selection in
            // Selecting an agent or terminal (a new one, a debug launch flag) focuses (or opens) its tab.
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
        .onChange(of: model.commandCenter.openTabMenuWorkspaceId) { _, workspaceId in
            // ⌘T shows the Open Tab menu.
            guard workspaceId == workspace.id else { return }
            model.commandCenter.openTabMenuWorkspaceId = nil
            let sections = openTabMenu(agents: agents, terminals: terminals)
            Task { OpenTabSection.popUp(sections) }
        }
        .onChange(of: model.plugins.tabRequest, initial: true) { _, request in
            // Plugin panels for this workspace (from menus, commands or plugin code) open as tabs.
            guard let request, case .panel(_, let workspaceId, _) = request.kind, workspaceId == workspace.id else { return }
            model.plugins.tabRequest = nil
            tabs.open(.plugin(PluginTab(target: request)))
        }
        .onChange(of: tabs.focusedContent) { _, content in
            // ...and the selection follows the focused tab (the sidebar highlights its workspace).
            guard tabs.isReady else { return }
            let selection = content?.sidebarSelection ?? .workspace(workspace.id)
            if model.selection != selection { model.selection = selection }
        }
    }

    /// Closes the tab the way its kind does it (archiving its agent, killing its terminal…).
    private func close(_ content: WorkspaceTabContent) {
        closing.insert(content)
        Task {
            await content.kind.close(in: model) { tabs.close(content) }
            closing.remove(content)
        }
    }

    /// The Open Tab menu's entries, for the toolbar menu and ⌘T.
    private func openTabMenu(agents: [Agent], terminals: [TerminalInfo]) -> [OpenTabSection] {
        func agentEntries(_ agents: [Agent]) -> [OpenTabSection.Entry] {
            agents.map { agent in .init(id: agent.id, title: agent.displayTitle) { tabs.open(.agent(AgentTab(agentId: agent.id))) } }
        }
        var sections = [OpenTabSection(title: "Agents", entries: agentEntries(agents.filter(model.isWorkspaceRoot)))]
        let subagents = agents.filter { !model.isWorkspaceRoot($0) }
        if !subagents.isEmpty {
            sections.append(OpenTabSection(title: "Subagents", entries: agentEntries(subagents)))
        }
        sections.append(OpenTabSection(title: "Terminals", entries: terminals.map { terminal in
            .init(id: terminal.id, title: terminal.displayName) { tabs.open(workspace.tab(for: terminal)) }
        } + [.init(id: "new-terminal", title: "New Terminal", systemImage: "apple.terminal") {
            Task { await model.terminals.create(in: workspace) }
        }]))
        let plugins = model.plugins
        let panels = PluginWorkspaceMenu(plugins.contributions, opensTabs: true).panels
        if !panels.isEmpty {
            sections.append(OpenTabSection(title: "Plugins", entries: panels.map { entry in
                let (pluginId, panel) = (entry.pluginId, entry.item)
                return .init(id: entry.id, title: panel.title, systemImage: LucideSymbols.symbol(for: panel.icon)) {
                    plugins.open(.panel(pluginId: pluginId, panelId: panel.id, workspaceId: workspace.id))
                }
            }))
        }
        return sections
    }

    /// Subagents open in a tab here that the daemon doesn't know this client shows.
    private var subagentTabsToMark: [String] {
        tabs.contents.values.compactMap { content -> String? in
            guard !closing.contains(content), case .agent(let tab) = content, let agent = model.agents[tab.agentId], agent.parentAgentId != nil,
                  agent.labels[model.openTabLabel] != "true"
            else { return nil }
            return agent.id
        }
        .sorted()
    }
}

/// A section of the Open Tab menu.
private struct OpenTabSection: Identifiable {
    struct Entry: Identifiable {
        let id: String
        let title: String
        var systemImage: String?
        let action: @MainActor () -> Void
    }

    let title: String
    let entries: [Entry]
    var id: String { title }

    /// SwiftUI can't open a `Menu` from code, so ⌘T pops up the same entries as an `NSMenu` under
    /// the key window's Open Tab toolbar item.
    @MainActor static func popUp(_ sections: [OpenTabSection]) {
        guard let window = NSApp.keyWindow, let view = window.toolbar?.items.first(where: { $0.label == "Open Tab" })?.view
        else { return }
        let menu = NSMenu()
        for section in sections {
            menu.addItem(.sectionHeader(title: section.title))
            for entry in section.entries {
                let item = ActionMenuItem(title: entry.title, action: entry.action)
                item.image = entry.systemImage.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
                menu.addItem(item)
            }
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.isFlipped ? view.bounds.maxY : 0), in: view)
    }
}

@MainActor
private final class ActionMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(title: String, action: @escaping @MainActor () -> Void) {
        handler = action
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func run() { handler() }
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
                Button("New Agent") { model.startNewAgent(in: workspace) }
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
