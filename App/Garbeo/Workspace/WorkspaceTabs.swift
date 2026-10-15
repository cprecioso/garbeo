#if os(macOS)
import Bonsplit
import Foundation
import PaseoKit

/// Tabs and splits of one workspace: a Bonsplit controller plus what each of its tabs shows.
///
/// Every member of the workspace (`AppModel.tabMembers(of:)`) gets a tab; members that show up
/// later are added in the background, without taking focus. Closing a tab archives its agent or
/// kills its terminal (see `closeRequest`).
///
/// Bonsplit owns the tree (panes, tab order, selection, drag and drop). Not every change goes
/// through its delegate (drag-to-split, in-bar selection), so the saved layout is derived from
/// `treeSnapshot()` whenever the observable controller changes rather than from callbacks.
@MainActor @Observable
final class WorkspaceTabs {
    typealias LabelProvider = @MainActor (WorkspaceTabContent) -> WorkspaceTabLabel?

    let workspaceId: String
    let controller = BonsplitController(configuration: BonsplitConfiguration(allowCloseLastPane: false))
    private(set) var contents: [TabID: WorkspaceTabContent] = [:]
    /// A tab the user asked to close. `WorkspaceView` confirms if needed, then calls `close(_:)`.
    var closeRequest: WorkspaceTabContent?
    /// False while a saved layout is rebuilt; layout changes aren't saved meanwhile.
    private(set) var isReady = false

    @ObservationIgnored private var tabsByUUID: [String: TabID] = [:]
    @ObservationIgnored private var members: [WorkspaceTabContent]
    /// Members whose tab was closed while their agent is archived or terminal killed, so reconcile
    /// doesn't reopen them meanwhile. Session only.
    @ObservationIgnored private var hidden: Set<WorkspaceTabContent> = []
    /// Set while we close a tab ourselves; the user closing one goes through `closeRequest`.
    @ObservationIgnored private var isClosingInternally = false
    @ObservationIgnored private var pendingRestore: WorkspaceLayout?
    @ObservationIgnored private var pendingFocus: WorkspaceTabContent?
    @ObservationIgnored private var started = false
    @ObservationIgnored private let label: LabelProvider
    @ObservationIgnored private let save: (WorkspaceLayout?) -> Void
    @ObservationIgnored private var lastSaved: WorkspaceLayout?
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    /// - Parameters:
    ///   - members: what gets a tab automatically, in tab order.
    ///   - saved: a previously saved layout. Tabs whose target is gone are dropped; members missing
    ///     from it get a tab once it's rebuilt.
    init(workspaceId: String, members: [WorkspaceTabContent], saved: WorkspaceLayout?,
         label: @escaping LabelProvider, save: @escaping (WorkspaceLayout?) -> Void)
    {
        self.workspaceId = workspaceId
        self.members = members
        self.label = label
        self.save = save
        let placeholders = controller.allTabIds  // Bonsplit starts with a "Welcome" tab
        if let layout = saved?.pruned(keeping: { label($0) != nil }) {
            pendingRestore = layout
            lastSaved = layout
        } else {
            let opened = members.compactMap { addTab($0, in: nil) }
            if let first = opened.first { controller.selectTab(first) }
        }
        placeholders.forEach { controller.closeTab($0) }
        controller.delegate = self
    }

    // MARK: Queries

    func tabID(for content: WorkspaceTabContent) -> TabID? {
        contents.first { $0.value == content }?.key
    }

    /// What the focused pane's selected tab shows.
    var focusedContent: WorkspaceTabContent? {
        controller.focusedPaneId.flatMap { controller.selectedTab(inPane: $0) }.flatMap { contents[$0.id] }
    }

    /// The selected tab of every pane, in tree order.
    var visibleContents: [WorkspaceTabContent] {
        controller.allPaneIds.compactMap { controller.selectedTab(inPane: $0) }.compactMap { contents[$0.id] }
    }

    /// The current layout, rebuilt from Bonsplit's tree. Nil when no tab is open.
    var layout: WorkspaceLayout? {
        guard let root = node(from: controller.treeSnapshot()) else { return nil }
        return WorkspaceLayout(root: root, focused: focusedContent)
    }

    private func node(from tree: ExternalTreeNode) -> WorkspaceLayout.Node? {
        switch tree {
        case .pane(let pane):
            let tabs = pane.tabs.compactMap { tabsByUUID[$0.id].flatMap { contents[$0] } }
            guard !tabs.isEmpty else { return nil }
            let selected = pane.selectedTabId.flatMap { tabsByUUID[$0] }.flatMap { contents[$0] }
            return .pane(.init(tabs: tabs, selected: selected))
        case .split(let split):
            let first = node(from: split.first)
            let second = node(from: split.second)
            guard let first, let second else { return first ?? second }
            return .split(.init(
                axis: split.orientation == "vertical" ? .vertical : .horizontal,
                divider: (split.dividerPosition * 1000).rounded() / 1000,
                first: first, second: second))
        }
    }

    // MARK: Opening tabs

    /// Selects the tab showing `content`, or opens one in `pane` (default: the focused pane).
    /// With `moveHere`, an existing tab elsewhere is moved into `pane` instead.
    func open(_ content: WorkspaceTabContent, in pane: PaneID? = nil, moveHere: Bool = false) {
        guard isReady else {
            pendingFocus = content
            return
        }
        if let existing = tabID(for: content) {
            guard moveHere, let pane, !controller.tabs(inPane: pane).contains(where: { $0.id == existing }) else {
                controller.selectTab(existing)
                return
            }
            closeInternally(existing)
        }
        addTab(content, in: pane)
    }

    @discardableResult
    private func addTab(_ content: WorkspaceTabContent, in pane: PaneID?) -> TabID? {
        let label = label(content) ?? WorkspaceTabLabel(title: "…", icon: "questionmark.square.dashed")
        guard let id = controller.createTab(
            title: label.title, icon: label.icon, isDirty: label.needsAttention, inPane: pane)
        else { return nil }
        contents[id] = content
        if let uuid = bonsplitUUID(id) { tabsByUUID[uuid] = id }
        hidden.remove(content)
        return id
    }

    /// Appends tabs to the focused pane without changing which tab it shows (Bonsplit selects
    /// every tab it creates, and inserts it after the selected one).
    private func addInBackground(_ new: [WorkspaceTabContent]) {
        guard !new.isEmpty, let pane = controller.focusedPaneId ?? controller.allPaneIds.first else { return }
        let selected = controller.selectedTab(inPane: pane)?.id
        if let last = controller.tabs(inPane: pane).last { controller.selectTab(last.id) }
        let added = new.compactMap { addTab($0, in: pane) }
        if let keep = selected ?? added.first { controller.selectTab(keep) }
    }

    private func closeInternally(_ id: TabID) {
        isClosingInternally = true
        defer { isClosingInternally = false }
        controller.closeTab(id)
    }

    /// Closes `content`'s tab and keeps it closed while its agent is archived or terminal killed.
    func close(_ content: WorkspaceTabContent) {
        hidden.insert(content)
        if let id = tabID(for: content) { closeInternally(id) }
    }

    // MARK: Keeping in sync with the model

    /// Gives a tab to every member that has none.
    func reconcile(members: [WorkspaceTabContent]) {
        self.members = members
        guard isReady else { return }
        let open = Set(contents.values)
        addInBackground(members.filter { !open.contains($0) && !hidden.contains($0) })
    }

    /// Re-reads every tab's label and closes tabs whose target is gone.
    func refreshLabels() {
        for (id, content) in contents {
            guard let label = label(content) else {
                closeInternally(id)
                continue
            }
            guard let tab = controller.tab(id),
                  tab.title != label.title || tab.icon != label.icon || tab.isDirty != label.needsAttention
            else { continue }
            controller.updateTab(id, title: label.title, icon: .some(label.icon), isDirty: label.needsAttention)
        }
    }

    // MARK: Persistence

    func layoutChanged(_ layout: WorkspaceLayout?) {
        guard isReady, layout != lastSaved else { return }
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            lastSaved = layout
            save(layout)
        }
    }

    /// Rebuilds the saved layout, if any. Call once the view is on screen: Bonsplit animates every
    /// new split from its container's laid-out size, so splits are created one at a time.
    func start() {
        guard !started else { return }
        started = true
        guard let layout = pendingRestore, let root = controller.allPaneIds.first else {
            becomeReady()
            return
        }
        pendingRestore = nil
        Task {
            await build(layout.root, in: root)
            // Let the split animations (which reset dividers to 0.5) finish first.
            try? await Task.sleep(for: .milliseconds(300))
            applyDividers(layout.root, controller.treeSnapshot())
            if let focused = layout.focused, let id = tabID(for: focused) { controller.selectTab(id) }
            becomeReady()
        }
    }

    private func becomeReady() {
        isReady = true
        reconcile(members: members)
        if let content = pendingFocus {
            pendingFocus = nil
            open(content)
        }
    }

    private func build(_ node: WorkspaceLayout.Node, in pane: PaneID) async {
        switch node {
        case .pane(let saved):
            for content in saved.tabs { addTab(content, in: pane) }
            if let selected = saved.selected, let id = tabID(for: selected) { controller.selectTab(id) }
        case .split(let split):
            let orientation: SplitOrientation = split.axis == .vertical ? .vertical : .horizontal
            guard let newPane = controller.splitPane(pane, orientation: orientation) else {
                await build(split.first, in: pane)
                await build(split.second, in: pane)
                return
            }
            try? await Task.sleep(for: .milliseconds(200))
            await build(split.first, in: pane)
            await build(split.second, in: newPane)
        }
    }

    private func applyDividers(_ saved: WorkspaceLayout.Node, _ live: ExternalTreeNode) {
        guard case .split(let savedSplit) = saved, case .split(let liveSplit) = live else { return }
        if let id = UUID(uuidString: liveSplit.id) {
            controller.setDividerPosition(savedSplit.divider, forSplit: id, fromExternal: true)
        }
        applyDividers(savedSplit.first, liveSplit.first)
        applyDividers(savedSplit.second, liveSplit.second)
    }
}

extension WorkspaceTabs: @preconcurrency BonsplitDelegate {
    func splitTabBar(_ controller: BonsplitController, shouldCloseTab tab: Tab, inPane pane: PaneID) -> Bool {
        guard !isClosingInternally, let content = contents[tab.id] else { return true }
        closeRequest = content
        return false
    }

    func splitTabBar(_ controller: BonsplitController, didCloseTab tabId: TabID, fromPane pane: PaneID) {
        contents[tabId] = nil
        if let uuid = bonsplitUUID(tabId) { tabsByUUID[uuid] = nil }
    }
}

/// Bonsplit keeps the UUIDs inside `TabID`/`PaneID` internal but names tabs and panes by UUID
/// string in its tree snapshots; the IDs' Codable form (`{"id": "<uuid>"}`) bridges the two.
func bonsplitUUID(_ id: some Encodable) -> String? {
    guard let data = try? JSONEncoder().encode(id),
          let object = try? JSONDecoder().decode([String: String].self, from: data)
    else { return nil }
    return object["id"]
}

/// Keeps each visited workspace's tabs for the session, restoring saved layouts on first use.
@MainActor
final class WorkspaceTabsRegistry {
    private var tabs: [String: WorkspaceTabs] = [:]

    func tabs(for workspace: Workspace, model: AppModel) -> WorkspaceTabs {
        if let existing = tabs[workspace.id] { return existing }
        let server = model.serverInfo?.serverId ?? model.endpoint?.url ?? "default"
        let workspaceId = workspace.id
        let created = WorkspaceTabs(
            workspaceId: workspaceId,
            members: model.tabMembers(of: workspace),
            saved: WorkspaceLayoutStore.load(server: server, workspace: workspaceId),
            label: { [weak model] content in model.flatMap { content.kind.label(in: $0) } },
            save: { WorkspaceLayoutStore.save($0, server: server, workspace: workspaceId) })
        tabs[workspaceId] = created
        return created
    }
}

extension AppModel {
    /// What gets a tab in `workspace` automatically: its agents except subagents working alongside
    /// their parent (most recent first), then its terminals. Those subagents open from the Open Tab
    /// menu.
    func tabMembers(of workspace: Workspace) -> [WorkspaceTabContent] {
        agents(in: workspace).filter(isWorkspaceRoot).map { .agent(AgentTab(agentId: $0.id)) }
            + terminals.terminals(in: workspace).map(workspace.tab(for:))
    }
}
#endif
