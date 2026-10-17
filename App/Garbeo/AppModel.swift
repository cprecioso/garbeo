import Foundation
import Observation
import PaseoKit

enum ConnectionState: Equatable {
    case idle
    case connecting
    case connected(ServerInfo)
    case reconnecting(attempt: Int, error: String?)
    case failed(String)

    var isConnected: Bool { if case .connected = self { true } else { false } }
}

/// What the sidebar has selected. iOS selects agents and terminals. The macOS sidebar lists only
/// workspaces, which open as tabs; there an agent or terminal selection is the focused tab (or a
/// tab to focus), and the sidebar highlights its workspace.
enum SidebarSelection: Hashable {
    case agent(String)
    case workspace(String)
    case terminal(String)
}

struct ProjectGroup: Identifiable {
    var id: String
    var name: String
    var workspaces: [Workspace]

    /// The repository root, where new worktrees branch from.
    var rootPath: String? { workspaces.lazy.compactMap(\.projectRootPath).first ?? workspaces.first?.workspaceDirectory }
}

/// Owns the daemon connection and the replicated directory (workspaces, agents) plus live
/// timelines for every agent on screen.
@MainActor @Observable
final class AppModel {
    private(set) var connection: ConnectionState = .idle
    private(set) var workspaces: [String: Workspace] = [:]
    private(set) var agents: [String: Agent] = [:]
    private(set) var permissions: [String: [PermissionRequest]] = [:]
    /// Setup script progress by workspace ID, see `loadSetupStatus(for:)`.
    private(set) var setups: [String: WorkspaceSetupSnapshot] = [:]
    /// Live timelines of the agents currently shown, see `showTimeline(_:viewer:)`.
    private(set) var timelines = TimelineRegistry()
    /// The single selection driving the detail column. Terminal selection made by
    /// `TerminalDirectory` (new terminal, terminal gone) goes through `terminals.selectedTerminalId`,
    /// which reads and writes this.
    var selection: SidebarSelection? {
        didSet { if let workspace = selectedWorkspace { lastWorkspaceId = workspace.id } }
    }
    let terminals = TerminalDirectory()
    var lastError: String?
    let plugins = PluginStore()

    var endpoint: DaemonEndpoint? {
        didSet { Self.saveEndpoint(endpoint) }
    }

    private(set) var client: DaemonClient?
    private var eventTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var generation = 0
    private let clientId: String
    /// The workspace the most recent selection belonged to; macOS keeps it open on deselect.
    @ObservationIgnored private var lastWorkspaceId: String?
    @ObservationIgnored private var subscriptionSync: TimelineSubscriptionSync!

    init() {
        let defaults = UserDefaults.app
        if let existing = defaults.string(forKey: "clientId") {
            clientId = existing
        } else {
            clientId = "cid_swift_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            defaults.set(clientId, forKey: "clientId")
        }
        endpoint = Self.loadEndpoint()
        plugins.app = self
        terminals.onError = { [weak self] in self?.lastError = $0 }
        terminals.selection = (
            get: { [weak self] in if case .terminal(let id) = self?.selection { id } else { nil } },
            set: { [weak self] id in
                guard let self else { return }
                if let id {
                    selection = .terminal(id)
                } else if case .terminal = selection {
                    clearSelection()
                }
            })
        subscriptionSync = TimelineSubscriptionSync(
            send: { [weak self] agentIds in
                guard let client = self?.client else { throw PaseoError.disconnected }
                try await client.setTimelineSubscription(agentIds: agentIds)
            },
            acknowledged: { [weak self] agentIds in
                self?.timelines.subscriptionAcknowledged(agentIds)
                self?.fetchTails()
            })
    }

    // MARK: Derived state

    var serverInfo: ServerInfo? {
        if case .connected(let info) = connection { info } else { nil }
    }

    var selectedAgentId: String? {
        if case .agent(let id) = selection { id } else { nil }
    }

    var selectedAgent: Agent? { selectedAgentId.flatMap { agents[$0] } }

    /// The workspace the selection belongs to: the selected workspace, or the selected agent's.
    var selectedWorkspace: Workspace? {
        switch selection {
        case .workspace(let id): workspaces[id]
        case .agent(let id): agents[id].flatMap(workspace(for:))
        case .terminal: terminals.selectedTerminal.flatMap(terminals.workspaceId(of:)).flatMap { workspaces[$0] }
        case nil: nil
        }
    }

    func workspace(for agent: Agent) -> Workspace? {
        if let id = agent.workspaceId { return workspaces[id] }
        return workspaces.values.first { $0.workspaceDirectory == agent.cwd }
    }

    var projects: [ProjectGroup] {
        let grouped = Dictionary(grouping: workspaces.values, by: \.projectId)
        return grouped.map { projectId, workspaces in
            ProjectGroup(
                id: projectId,
                name: workspaces.first?.projectName ?? projectId,
                workspaces: workspaces.sorted { ($0.sortDate ?? .distantPast) > ($1.sortDate ?? .distantPast) })
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func agents(in workspace: Workspace) -> [Agent] {
        agents.values
            .filter { $0.archivedAt == nil && ($0.workspaceId == workspace.id || ($0.workspaceId == nil && $0.cwd == workspace.workspaceDirectory)) }
            .sorted { ($0.updatedDate ?? .distantPast) > ($1.updatedDate ?? .distantPast) }
    }

    var unplacedAgents: [Agent] {
        let directories = Set(workspaces.values.map(\.workspaceDirectory))
        return agents.values
            .filter { agent in
                agent.archivedAt == nil && (agent.workspaceId.map { workspaces[$0] == nil } ?? true)
                    && !directories.contains(agent.cwd)
            }
            .sorted { ($0.updatedDate ?? .distantPast) > ($1.updatedDate ?? .distantPast) }
    }

    /// Whether `agent` gets a tab in its workspace automatically: top-level agents, and subagents
    /// whose parent works in another workspace (upstream's workspace-root policy).
    func isWorkspaceRoot(_ agent: Agent) -> Bool {
        guard let parentId = agent.parentAgentId else { return true }
        guard let workspaceId = workspace(for: agent)?.id,
              let parentWorkspaceId = agents[parentId].flatMap(workspace(for:))?.id
        else { return false }
        return workspaceId != parentWorkspaceId
    }

    func pendingPermissions(for agentId: String) -> [PermissionRequest] {
        permissions[agentId] ?? []
    }

    var attentionCount: Int {
        agents.values.filter { $0.archivedAt == nil && ($0.requiresAttention == true || !(permissions[$0.id] ?? []).isEmpty) }.count
    }

    // MARK: Connection lifecycle

    func connect(to endpoint: DaemonEndpoint) async {
        self.endpoint = endpoint
        reconnectTask?.cancel()
        await openConnection(isReconnect: false)
    }

    func disconnect() {
        generation += 1
        reconnectTask?.cancel()
        eventTask?.cancel()
        let old = client
        client = nil
        Task { await old?.disconnect() }
        connection = .idle
        plugins.detach(keepPane: false)
        workspaces = [:]
        agents = [:]
        permissions = [:]
        setups = [:]
        timelines = TimelineRegistry()
        subscriptionSync.desired = []
        subscriptionSync.reset()
        selection = nil
        terminals.reset()
    }

    func forgetEndpoint() {
        disconnect()
        endpoint = nil
    }

    private func openConnection(isReconnect: Bool, attempt: Int = 0) async {
        guard let endpoint else { return }
        generation += 1
        let myGeneration = generation
        eventTask?.cancel()
        if let old = client { await old.disconnect() }

        if !isReconnect { connection = .connecting }
        let client = DaemonClient(endpoint: endpoint, clientId: clientId)
        do {
            let info = try await client.connect()
            guard myGeneration == generation else { await client.disconnect(); return }
            self.client = client
            eventTask = Task { [weak self] in
                for await event in client.events {
                    guard let self, myGeneration == self.generation else { return }
                    self.handle(event)
                }
            }
            try await bootstrap(client)
            guard myGeneration == generation else { return }
            connection = .connected(info)
            plugins.attach(client: client, info: info)
        } catch {
            guard myGeneration == generation else { return }
            await client.disconnect()
            let message = error.localizedDescription
            if let paseoError = error as? PaseoError, case .helloRejected = paseoError {
                connection = .failed(message)
            } else if isReconnect || attempt > 0 {
                scheduleReconnect(attempt: attempt + 1, error: message)
            } else {
                connection = .failed(message)
            }
        }
    }

    private func bootstrap(_ client: DaemonClient) async throws {
        async let workspacesResponse = client.fetchWorkspaces()
        async let agentsResponse = client.fetchAgents()
        let (ws, ag) = try await (workspacesResponse, agentsResponse)
        workspaces = Dictionary(ws.entries.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let agentList = ag.entries.map(\.agent)
        agents = Dictionary(agentList.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        permissions = Dictionary(agentList.compactMap { agent in
            agent.pendingPermissions.flatMap { $0.isEmpty ? nil : (agent.id, $0) }
        }, uniquingKeysWith: { _, last in last })
        let pluginEvents = await client.serverInfo?.supportsPlugins == true ? PluginEvents.subscription : []
        try await client.subscribeToSessionEvents([
            "agent_permission_request", "agent_permission_resolved", "agent_attention_required",
            "workspace_setup_progress",
        ] + pluginEvents)
        // Terminal lists aren't needed to show the sidebar; don't hold up the connection for them.
        Task {
            await terminals.connect(client, workspaces: Array(workspaces.values))
            #if DEBUG
            // Development aid: `-PaseoSelectTerminal first|new|<terminalId>` opens a terminal on launch.
            if let requested = UserDefaults.standard.string(forKey: "PaseoSelectTerminal") {
                await terminals.applyDebugSelection(requested, workspaces: projects.flatMap(\.workspaces))
            }
            #endif
        }
        switch selection {
        case .agent(let id) where agents[id] == nil: selection = nil
        case .workspace(let id) where workspaces[id] == nil: selection = nil
        default: break
        }
        // The new socket has no timeline subscriptions; resubscribe and refetch what's on screen.
        timelines.connectionReset()
        subscriptionSync.reset()
        subscriptionSync.desired = timelines.visibleAgentIds
        await subscriptionSync.flush()
        #if DEBUG
        // Development aids: `-PaseoSelectAgent first|<agentId>` opens an agent on launch,
        // `-PaseoSelectWorkspace first|<workspaceId>` a workspace.
        if selection == nil, let requested = UserDefaults.standard.string(forKey: "PaseoSelectAgent") {
            selection = (requested == "first"
                ? projects.flatMap(\.workspaces).flatMap(agents(in:)).first?.id : requested).map(SidebarSelection.agent)
        }
        if selection == nil, let requested = UserDefaults.standard.string(forKey: "PaseoSelectWorkspace") {
            selection = (requested == "first"
                ? projects.flatMap(\.workspaces).first { !agents(in: $0).isEmpty }?.id : requested).map(SidebarSelection.workspace)
        }
        #endif
    }

    private func scheduleReconnect(attempt: Int, error: String?) {
        connection = .reconnecting(attempt: attempt, error: error)
        reconnectTask?.cancel()
        let delay = min(30.0, pow(2.0, Double(min(attempt, 5))) * 0.5)
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.openConnection(isReconnect: true, attempt: attempt)
        }
    }

    func retryNow() {
        reconnectTask?.cancel()
        Task { await openConnection(isReconnect: true, attempt: 1) }
    }

    // MARK: Events

    private func handle(_ event: DaemonEvent) {
        switch event {
        case .agentUpdate(.upsert(let agent)):
            agents[agent.id] = agent
            if let pending = agent.pendingPermissions { permissions[agent.id] = pending }
        case .agentUpdate(.remove(let agentId)):
            agents[agentId] = nil
            permissions[agentId] = nil
            timelines.removeAgent(agentId)
            if selectedAgentId == agentId { clearSelection() }
        case .workspaceUpdate(.upsert(let workspace)):
            workspaces[workspace.id] = workspace
            Task { await terminals.observe(workspace) }
        case .workspaceUpdate(.remove(let id)):
            workspaces[id] = nil
            setups[id] = nil
            terminals.forget(workspaceId: id)
        case .terminalsChanged(let change):
            terminals.apply(change)
        case .agentStream(let payload):
            handleStream(payload)
        case .permissionRequested(let payload):
            var list = permissions[payload.agentId] ?? []
            list.removeAll { $0.id == payload.request.id }
            list.append(payload.request)
            permissions[payload.agentId] = list
        case .permissionResolved(let payload):
            permissions[payload.agentId]?.removeAll { $0.id == payload.requestId }
        case .serverInfo(let info):
            if connection.isConnected { connection = .connected(info) }
        case .pluginStatus(let status):
            plugins.handle(status)
        case .workspaceSetupProgress(let progress):
            setups[progress.workspaceId] = progress.snapshot
        case .disconnected(let reason):
            client = nil
            plugins.detach(keepPane: true)
            scheduleReconnect(attempt: 1, error: reason)
        case .agentUpdate(.unknown), .workspaceUpdate(.unknown):
            break
        }
    }

    private func handleStream(_ payload: AgentStreamPayload) {
        switch payload.event {
        case .permissionRequested(let request):
            var list = permissions[payload.agentId] ?? []
            if !list.contains(where: { $0.id == request.id }) { list.append(request) }
            permissions[payload.agentId] = list
        case .permissionResolved(let requestId):
            permissions[payload.agentId]?.removeAll { $0.id == requestId }
        default:
            break
        }
        if timelines.apply(payload) { fetchTails() }
    }

    // MARK: Visible timelines

    /// Registers that `viewer` (one mounted agent view) shows `agentId`. The union over all viewers
    /// is the daemon timeline subscription; each shown agent gets its own live timeline.
    func showTimeline(_ agentId: String, viewer: UUID) {
        timelines.show(agentId, viewer: viewer)
        syncTimelineSubscription()
    }

    func hideTimeline(viewer: UUID) {
        timelines.hide(viewer: viewer)
        syncTimelineSubscription()
    }

    /// The error to show instead of a timeline that hasn't loaded.
    func timelineError(for agentId: String) -> String? {
        timelines[agentId]?.error ?? (timelines.subscribed.contains(agentId) ? nil : subscriptionSync.lastError)
    }

    private func syncTimelineSubscription() {
        fetchTails()
        let visible = timelines.visibleAgentIds
        guard subscriptionSync.desired != visible else { return }
        subscriptionSync.desired = visible
        Task { await subscriptionSync.flush() }
    }

    private func fetchTails() {
        guard let client else { return }
        for (agentId, token) in timelines.takeTailFetches() {
            Task {
                do {
                    let page = try await client.fetchTimeline(agentId: agentId)
                    timelines.tailFetched(page, agentId: agentId, token: token)
                    if let agent = page.agent { agents[agent.id] = agent }
                } catch {
                    timelines.tailFailed(agentId: agentId, token: token, error: error.localizedDescription)
                }
            }
        }
    }

    func reloadTimeline(_ agentId: String) async {
        timelines.requestReload(agentId)
        fetchTails()
        await subscriptionSync.flush()
    }

    func loadOlder(_ agentId: String) async {
        guard let client, let cursor = timelines.beginLoadingOlder(agentId) else { return }
        do {
            let page = try await client.fetchTimeline(agentId: agentId, direction: "before", cursor: cursor)
            timelines.finishLoadingOlder(agentId, page: page)
        } catch {
            timelines.finishLoadingOlder(agentId, page: nil)
            lastError = error.localizedDescription
        }
    }

    // MARK: Actions

    func send(_ text: String, to agentId: String) async {
        guard let client else { return }
        let messageId = UUID().uuidString.lowercased()
        timelines.addPendingUserMessage(text: text, messageId: messageId, agentId: agentId)
        do {
            try await client.sendMessage(agentId: agentId, text: text, messageId: messageId)
        } catch {
            timelines.removePendingUserMessage(messageId: messageId, agentId: agentId)
            lastError = error.localizedDescription
        }
    }

    func cancel(_ agentId: String) async {
        await perform { try await $0.cancelAgent(agentId: agentId) }
    }

    func archive(_ agentId: String) async {
        await perform { try await $0.archiveAgent(agentId: agentId) }
        if selectedAgentId == agentId { clearSelection() }
    }

    /// Clears the selection when its target goes away. On macOS its workspace stays open.
    private func clearSelection() {
        #if os(macOS)
        selection = lastWorkspaceId.flatMap { workspaces[$0] }.map { .workspace($0.id) }
        #else
        selection = nil
        #endif
    }

    /// This client's open-tab label, see `Agent.openTabLabel(clientId:)`.
    var openTabLabel: String { Agent.openTabLabel(clientId: clientId) }

    /// Tells the daemon whether this client shows subagent `agentId` in a tab.
    func setOpenTab(_ open: Bool, for agentId: String) async throws {
        guard let client else { throw PaseoError.disconnected }
        try await client.updateAgent(agentId: agentId, labels: [openTabLabel: open ? "true" : "false"])
    }

    func setMode(_ modeId: String, for agentId: String) async {
        await perform { try await $0.setMode(agentId: agentId, modeId: modeId) }
    }

    func respond(to request: PermissionRequest, agentId: String, allow: Bool, actionId: String? = nil) async {
        await perform {
            try await $0.respondToPermission(
                agentId: agentId, permissionId: request.id, allow: allow, actionId: actionId,
                message: allow ? nil : "Denied from Garbeo")
        }
        permissions[agentId]?.removeAll { $0.id == request.id }
    }

    func providers() async throws -> [ProviderAvailability] {
        guard let client else { throw PaseoError.disconnected }
        return try await client.listProviders()
    }

    func models(provider: String, cwd: String?) async throws -> [ProviderModel] {
        guard let client else { throw PaseoError.disconnected }
        return try await client.listModels(provider: provider, cwd: cwd)
    }

    func modes(provider: String, cwd: String?) async throws -> [AgentMode] {
        guard let client else { throw PaseoError.disconnected }
        return try await client.listModes(provider: provider, cwd: cwd)
    }

    func createAgent(_ options: DaemonClient.CreateAgentOptions) async throws {
        guard let client else { throw PaseoError.disconnected }
        let agent = try await client.createAgent(options)
        agents[agent.id] = agent
        selection = .agent(agent.id)
    }

    /// Creates a worktree workspace and selects it. When `firstAgent` is given, also starts an agent
    /// there and selects that instead. Throws only if the worktree wasn't created.
    func createWorkspace(
        _ options: CreateWorktreeOptions,
        firstAgent: ((Workspace) -> DaemonClient.CreateAgentOptions)? = nil
    ) async throws {
        guard let client else { throw PaseoError.disconnected }
        let response = try await client.createWorktree(options)
        guard let workspace = response.workspace else { return }
        workspaces[workspace.id] = workspace
        Task { await terminals.observe(workspace) }
        selection = .workspace(workspace.id)
        Task { await loadSetupStatus(for: workspace.id) }
        guard let firstAgent else { return }
        do {
            try await createAgent(firstAgent(workspace))
        } catch {
            lastError = "The workspace was created, but its agent could not start: \(error.localizedDescription)"
        }
    }

    /// Fetches a workspace's setup progress unless it is already known. Finished setups from before
    /// are left out, so only progress seen live keeps showing once done.
    func loadSetupStatus(for workspaceId: String) async {
        guard let client, setups[workspaceId] == nil,
              let snapshot = try? await client.workspaceSetupStatus(workspaceId: workspaceId),
              setups[workspaceId] == nil, snapshot.status != .completed
        else { return }
        setups[workspaceId] = snapshot
    }

    func dismissSetupStatus(for workspaceId: String) {
        setups[workspaceId] = nil
    }

    /// Approves a setup blocked on code from a fork pull request, and runs it.
    func runSetup(for workspaceId: String) async {
        await perform { try await $0.runWorkspaceSetup(workspaceId: workspaceId) }
    }

    func branchSuggestions(cwd: String, query: String) async throws -> [BranchSuggestion] {
        guard let client else { throw PaseoError.disconnected }
        return try await client.branchSuggestions(cwd: cwd, query: query)
    }

    /// Adds a directory on the daemon's machine as a project and selects its workspace there. A
    /// directory already in a project selects that one. When `name` is given and differs, renames
    /// the project too. Throws only if the project wasn't added.
    func createProject(at path: ProjectPath, name: String? = nil) async throws {
        guard let client else { throw PaseoError.disconnected }
        let workspace = try await client.openProject(path)
        workspaces[workspace.id] = workspace
        Task { await terminals.observe(workspace) }
        selection = .workspace(workspace.id)
        guard let name, !name.isEmpty, name != workspace.projectName else { return }
        do {
            let customName = try await client.renameProject(projectId: workspace.projectId, to: name)
            for (id, other) in workspaces where other.projectId == workspace.projectId {
                workspaces[id]?.projectCustomName = customName
            }
        } catch {
            lastError = "The project was added, but could not be renamed: \(error.localizedDescription)"
        }
    }

    func directorySuggestions(query: String) async throws -> [String] {
        guard let client else { throw PaseoError.disconnected }
        return try await client.directorySuggestions(query: query)
    }

    private func perform(_ action: (DaemonClient) async throws -> Void) async {
        guard let client else {
            lastError = PaseoError.disconnected.localizedDescription
            return
        }
        do {
            try await action(client)
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: Persistence

    // Saved hosts live in UserDefaults; passwords and relay keys go to the Keychain.
    private static func loadEndpoint() -> DaemonEndpoint? {
        HostStore.shared.currentEndpoint
    }

    private static func saveEndpoint(_ endpoint: DaemonEndpoint?) {
        HostStore.shared.setCurrent(endpoint)
    }
}
