import Foundation
import Observation
import PaseoKit
import SwiftUI
import WebKit

/// Contribution metadata reported by the registry page after it runs every client bundle.
struct PluginContributions: Decodable, Identifiable, Hashable {
    struct Screen: Decodable, Hashable { var id: String; var title: String? }
    struct SettingsScreen: Decodable, Hashable { var id: String; var title: String; var icon: String }
    struct Panel: Decodable, Hashable, Identifiable {
        var id: String
        var title: String
        var icon: String
        var context: String
        var locations: [String]
    }
    struct Command: Decodable, Hashable, Identifiable {
        var id: String
        var title: String
        var icon: String
        var context: String
        var keywords: [String]
    }
    struct LegacySidebarItem: Decodable, Hashable, Identifiable { var id: String; var title: String; var icon: String; var surface: String }

    var id: String
    var screens: [Screen]
    var settingsScreens: [SettingsScreen]
    var panels: [Panel]
    var commands: [Command]
    var legacySidebarItems: [LegacySidebarItem]
    var unsupported: [String]
}

/// A row a plugin's sidebar item rendered through `SidebarRow`.
struct PluginSidebarRow: Decodable, Identifiable, Hashable {
    var key: String
    var pluginId: String
    var section: String
    var itemId: String
    var label: String
    var icon: String?
    var active: Bool
    var id: String { key }
}

/// A contribution with the plugin it belongs to; ids are only unique within a plugin.
struct PluginItem<Item: Identifiable & Hashable>: Identifiable, Hashable where Item.ID == String {
    var pluginId: String
    var item: Item
    var id: String { "\(pluginId)/\(item.id)" }
}

struct PluginFailure: Decodable, Hashable { var pluginId: String; var message: String }

/// Plugin state for the current daemon connection: installed plugins, their client bundles, the
/// contributions those bundles register, and which plugin pane is open.
///
/// A hidden registry page runs every client bundle to learn contributions and to render sidebar
/// items headlessly; each open pane runs its own page (`PluginPaneView`).
@MainActor @Observable
final class PluginStore {
    private(set) var installed: [PluginListItem] = []
    private(set) var catalog: [PluginCatalogEntry] = []
    private(set) var contributions: [PluginContributions] = []
    private(set) var failures: [PluginFailure] = []
    private(set) var sidebarRows: [PluginSidebarRow] = []
    /// Bumps whenever the catalog is reloaded; open panes rebuild on change.
    private(set) var revision = 0
    private(set) var titles: [String: String] = [:]
    private(set) var registryWebView: WKWebView?
    /// The pane shown in the detail column (or a sheet on iPhone). On macOS, workspace panels
    /// open as workspace tabs instead, see `tabRequest`.
    var activePane: PluginPaneTarget? {
        didSet { if oldValue != activePane { syncCurrentScreen() } }
    }
    /// A panel waiting for its workspace's tab view to open it (macOS).
    var tabRequest: PluginPaneTarget?
    var lastError: String?
    #if DEBUG
    private(set) var bridgeLog: [String] = []
    #endif

    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored private(set) var pluginClient: DaemonClient?
    @ObservationIgnored private var serverInfo: ServerInfo?
    @ObservationIgnored private var registry: PluginWebRuntime?
    @ObservationIgnored private let runtimes = NSHashTable<PluginWebRuntime>.weakObjects()
    @ObservationIgnored private var observingState = false
    @ObservationIgnored private var statePushScheduled = false
    @ObservationIgnored private var reloadTask: Task<Void, Never>?

    var hasClientPlugins: Bool { catalog.contains(where: \.hasClient) }

    // MARK: Connection lifecycle (driven by AppModel)

    func attach(client: DaemonClient, info: ServerInfo) {
        pluginClient = client
        serverInfo = info
        guard info.supportsPlugins else {
            reset()
            return
        }
        observeState()
        scheduleReload()
    }

    /// Drops connection state. `keepPane` keeps the open pane across a reconnect; it rebuilds
    /// once the catalog reloads.
    func detach(keepPane: Bool) {
        reloadTask?.cancel()
        pluginClient = nil
        serverInfo = nil
        let pane = activePane
        reset()
        if keepPane { activePane = pane }
    }

    func handle(_ status: PluginStatusPayload) {
        switch status.status {
        case "plugin_catalog_changed":
            scheduleReload()
        case "plugin_settings_changed":
            broadcast([
                "type": "settingsChanged", "pluginId": .string(status.pluginId),
                "settingsId": .string(status.settingsId ?? ""),
            ])
        default:
            break
        }
    }

    private func reset() {
        registry?.shutdown()
        registry = nil
        registryWebView = nil
        installed = []
        catalog = []
        contributions = []
        failures = []
        sidebarRows = []
        activePane = nil
    }

    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            // Coalesce bursts of catalog changes (install = several events).
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            await self?.reload()
        }
    }

    func reload() async {
        guard let client = pluginClient else { return }
        do {
            async let list = client.listPlugins()
            async let entries = client.pluginCatalog()
            let (installed, catalog) = try await (list, entries)
            guard client === pluginClient else { return }
            self.installed = installed
            self.catalog = catalog
            revision += 1
            rebuildRegistry()
        } catch {
            lastError = "Plugins: \(error.localizedDescription)"
        }
    }

    private func rebuildRegistry() {
        registry?.shutdown()
        registry = nil
        registryWebView = nil
        contributions = []
        failures = []
        sidebarRows = []
        guard hasClientPlugins else { return }
        let runtime = PluginWebRuntime(mode: .registry, initPayload: initPayload(mode: .registry, scheme: .light, compact: false), host: self)
        registry = runtime
        registryWebView = runtime.webView
        runtimes.add(runtime)
    }

    // MARK: Panes

    /// A new page for `target`. The caller owns it and must `releasePane` it.
    func makePaneRuntime(for target: PluginPaneTarget, scheme: ColorScheme, compact: Bool) -> PluginWebRuntime? {
        guard catalog.contains(where: { $0.id == target.pluginId && $0.hasClient }) else { return nil }
        let runtime = PluginWebRuntime(mode: .pane(target), initPayload: initPayload(mode: .pane(target), scheme: scheme, compact: compact), host: self)
        runtimes.add(runtime)
        return runtime
    }

    func releasePane(_ runtime: PluginWebRuntime) {
        runtimes.remove(runtime)
        runtime.shutdown()
    }

    func open(_ target: PluginPaneTarget) {
        #if os(macOS)
        if case .panel(_, let workspaceId, _) = target.kind, app?.workspaces[workspaceId] != nil {
            activePane = nil
            tabRequest = target
            if app?.selectedWorkspace?.id != workspaceId { app?.selection = .workspace(workspaceId) }
            return
        }
        #endif
        activePane = target
        app?.selection = nil
    }

    /// Whether a saved plugin tab should stay: unknown until the catalog loads, then only if the
    /// plugin still has client UI.
    func keepsTab(for target: PluginPaneTarget) -> Bool {
        catalog.isEmpty || catalog.contains { $0.id == target.pluginId && $0.hasClient }
    }

    func title(for target: PluginPaneTarget) -> String {
        if let title = titles[target.id] { return title }
        let plugin = contributions.first { $0.id == target.pluginId }
        switch target.kind {
        case .screen(let screenId, _):
            return plugin?.screens.first { $0.id == screenId }?.title
                ?? plugin?.settingsScreens.first { $0.id == screenId }?.title
                ?? plugin?.legacySidebarItems.first { $0.surface == screenId }?.title
                ?? sidebarRows.first { $0.pluginId == target.pluginId }?.label
                ?? screenId
        case .panel(let panelId, _, _):
            return plugin?.panels.first { $0.id == panelId }?.title ?? panelId
        }
    }

    func symbol(for target: PluginPaneTarget) -> String {
        let plugin = contributions.first { $0.id == target.pluginId }
        switch target.kind {
        case .screen(let screenId, _):
            let icon = plugin?.legacySidebarItems.first { $0.surface == screenId }?.icon
                ?? plugin?.settingsScreens.first { $0.id == screenId }?.icon
                ?? sidebarRows.first { $0.pluginId == target.pluginId && $0.active }?.icon
            return LucideSymbols.symbol(for: icon)
        case .panel(let panelId, _, _):
            return LucideSymbols.symbol(for: plugin?.panels.first { $0.id == panelId }?.icon)
        }
    }

    func displayName(of pluginId: String) -> String {
        installed.first { $0.id == pluginId }?.displayName ?? pluginId
    }

    /// Panels that can open for a workspace (and, for agent panels, a given agent).
    func panels(agent: Bool) -> [PluginItem<PluginContributions.Panel>] {
        contributions.flatMap { plugin in
            plugin.panels.filter { ($0.context == "agent") == agent }.map { PluginItem(pluginId: plugin.id, item: $0) }
        }
    }

    func commands(context: String) -> [PluginItem<PluginContributions.Command>] {
        contributions.flatMap { plugin in
            plugin.commands.filter { $0.context == context }.map { PluginItem(pluginId: plugin.id, item: $0) }
        }
    }

    // MARK: Registry interactions

    func press(_ row: PluginSidebarRow) {
        registry?.send(["type": "sidebar.press", "key": .string(row.key)])
    }

    func runCommand(pluginId: String, commandId: String, workspaceId: String? = nil, agentId: String? = nil) {
        registry?.send([
            "type": "command.select", "pluginId": .string(pluginId), "itemId": .string(commandId),
            "workspaceId": workspaceId.map(JSONValue.string) ?? .null, "agentId": agentId.map(JSONValue.string) ?? .null,
        ])
    }

    private func syncCurrentScreen() {
        var screen: JSONValue = .null
        if let activePane, case .screen(let screenId, let params) = activePane.kind {
            screen = ["pluginId": .string(activePane.pluginId), "screenId": .string(screenId), "params": .object(params.mapValues(JSONValue.string))]
        }
        registry?.send(["type": "currentScreen", "screen": screen])
    }

    // MARK: Host values

    private func initPayload(mode: PluginWebRuntime.Mode, scheme: ColorScheme, compact: Bool) -> JSONValue {
        var target: JSONValue = .null
        var plugins = catalog.filter(\.hasClient)
        if case .pane(let paneTarget) = mode {
            target = paneTarget.bridgeValue
            plugins = plugins.filter { $0.id == paneTarget.pluginId }
        }
        var currentScreen: JSONValue = .null
        if let activePane, case .screen(let screenId, let params) = activePane.kind {
            currentScreen = ["pluginId": .string(activePane.pluginId), "screenId": .string(screenId), "params": .object(params.mapValues(JSONValue.string))]
        }
        let serverId = serverInfo?.serverId ?? "local"
        return [
            "type": "init",
            "mode": .string(mode == .registry ? "registry" : "pane"),
            "plugins": .array(plugins.map { ["id": .string($0.id), "clientBundle": .string($0.clientBundle)] }),
            "target": target,
            "host": ["id": .string(serverId), "label": .string(serverInfo?.hostname ?? serverId)],
            "layout": ["compact": .bool(compact), "platform": .string(PluginHostValues.platform)],
            "theme": PluginHostValues.theme(for: scheme),
            "colorScheme": .string(scheme == .dark ? "dark" : "light"),
            "connection": [
                // Its own client id: the in-page SDK holds a separate daemon session.
                "clientId": .string("cid_swift_plugin_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()),
                "password": app?.endpoint?.password.map(JSONValue.string) ?? .null,
                "appVersion": .string(serverInfo?.version ?? "0.11.1"),
            ],
            "state": stateValue(),
            "currentScreen": currentScreen,
        ]
    }

    private func stateValue() -> JSONValue {
        guard let app else { return ["workspaces": [], "agents": []] }
        let workspaces = app.workspaces.values.map(PluginHostValues.snapshot)
        let byDirectory = Dictionary(app.workspaces.values.map { ($0.workspaceDirectory, $0.id) }, uniquingKeysWith: { first, _ in first })
        let agents = app.agents.values.compactMap { agent -> JSONValue? in
            guard agent.archivedAt == nil, let workspaceId = agent.workspaceId ?? byDirectory[agent.cwd] else { return nil }
            return PluginHostValues.snapshot(agent, workspaceId: workspaceId)
        }
        return ["workspaces": .array(workspaces), "agents": .array(agents)]
    }

    /// Pushes workspace/agent snapshots to every page whenever the app's directory changes.
    private func observeState() {
        guard !observingState else { return }
        observingState = true
        track()
    }

    private func track() {
        withObservationTracking {
            _ = app?.workspaces
            _ = app?.agents
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.track()
                guard !self.statePushScheduled else { return }
                self.statePushScheduled = true
                try? await Task.sleep(for: .milliseconds(100))
                self.statePushScheduled = false
                var message = self.stateValue()
                if case .object(var fields) = message { fields["type"] = "state"; message = .object(fields) }
                self.broadcast(message)
            }
        }
    }

    private func broadcast(_ message: JSONValue) {
        for runtime in runtimes.allObjects { runtime.send(message) }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ value: JSONValue?) -> T? {
        guard let value, let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

// MARK: - Bridge callbacks

extension PluginStore: PluginRuntimeHost {
    var pluginEndpoint: DaemonEndpoint? { app?.endpoint }

    func runtime(_ runtime: PluginWebRuntime, received message: [String: JSONValue]) {
        let type = message["type"]?.stringValue ?? ""
        let pluginId = message["pluginId"]?.stringValue ?? ""
        switch type {
        case "contributions" where runtime === registry:
            contributions = decode([PluginContributions].self, message["plugins"]) ?? []
            failures = decode([PluginFailure].self, message["failures"]) ?? []
            #if DEBUG
            PluginDebug.contributionsArrived(store: self)
            #endif
        case "sidebar" where runtime === registry:
            sidebarRows = decode([PluginSidebarRow].self, message["rows"]) ?? []
        case "openScreen":
            guard let screenId = message["screenId"]?.stringValue else { return }
            let params = decode([String: String].self, message["params"]) ?? [:]
            open(.screen(pluginId: pluginId, screenId: screenId, params: params))
        case "openSettings":
            guard let settingsId = message["settingsId"]?.stringValue else { return }
            open(.screen(pluginId: pluginId, screenId: settingsId))
        case "openPanel":
            guard let panelId = message["panelId"]?.stringValue else { return }
            guard let workspaceId = message["workspaceId"]?.stringValue else {
                lastError = "Plugin \(pluginId) tried to open panel \(panelId) without a workspace."
                return
            }
            open(.panel(pluginId: pluginId, panelId: panelId, workspaceId: workspaceId, agentId: message["agentId"]?.stringValue))
        case "openAgent":
            guard let agentId = message["agentId"]?.stringValue, app?.agents[agentId] != nil else { return }
            activePane = nil
            app?.selection = .agent(agentId)
        case "openWorkspace":
            guard let workspace = message["workspaceId"]?.stringValue.flatMap({ app?.workspaces[$0] }) else { return }
            activePane = nil
            #if os(macOS)
            app?.selection = .workspace(workspace.id)
            #else
            // iOS has no workspace view; open its most recent agent instead.
            if let agent = app?.agents(in: workspace).first { app?.selection = .agent(agent.id) }
            #endif
        case "title":
            if case .pane(let target) = runtime.mode, let title = message["title"]?.stringValue { titles[target.id] = title }
        case "rpc":
            #if DEBUG
            let outcome = message["output"].map { "-> \($0.jsonString)" } ?? "!! \(message["error"]?.stringValue ?? "?")"
            bridgeLog.append("rpc \(pluginId).\(message["method"]?.stringValue ?? "?")(\(message["input"]?.jsonString ?? "null")) \(outcome)")
            #endif
        case "rendered":
            #if DEBUG
            PluginDebug.paneRendered(runtime, store: self)
            #endif
        default:
            break
        }
    }
}
