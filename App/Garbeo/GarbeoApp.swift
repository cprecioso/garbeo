import PaseoKit
import SwiftUI

@main
struct GarbeoApp: App {
    @State private var model = AppModel()
    #if SPARKLE
    @StateObject private var updater = SoftwareUpdater()
    #endif

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task {
                    #if DEBUG
                    DebugSnapshot.scheduleIfRequested(model: model)
                    // Development aid: `-PaseoPairingLink <url>` pairs and connects on launch.
                    if let link = UserDefaults.standard.string(forKey: "PaseoPairingLink"),
                       let endpoint = try? DaemonEndpoint.fromPairingLink(link)
                    {
                        await model.connect(to: endpoint)
                        return
                    }
                    #endif
                    if let endpoint = model.endpoint, model.connection == .idle {
                        await model.connect(to: endpoint)
                    }
                }
        }
        #if os(macOS)
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(after: .appInfo) {
                #if SPARKLE
                CheckForUpdatesMenuItem(updater: updater)
                #endif
                CreditsMenuItem()
            }
            CommandMenu("Daemon") {
                Button("Reconnect") { model.retryNow() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(model.endpoint == nil)
                Button("Disconnect") { model.forgetEndpoint() }
                    .disabled(model.endpoint == nil)
            }
        }
        #endif

        #if os(macOS)
        Window("Credits", id: CreditsMenuItem.windowId) {
            CreditsView()
        }
        .defaultSize(width: 520, height: 640)
        #endif
    }
}

#if os(macOS)
private struct CreditsMenuItem: View {
    static let windowId = "credits"
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Credits") { openWindow(id: Self.windowId) }
    }
}
#endif

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch model.connection {
            case .idle, .failed:
                ConnectView()
            case .connecting:
                ProgressView("Connecting to \(model.endpoint?.displayAddress ?? "daemon")…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .connected, .reconnecting:
                MainView()
            }
        }
        .onChange(of: model.serverInfo?.hostname) { _, hostname in
            HostStore.shared.updateCurrentName(hostname)
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.lastError != nil }, set: { if !$0 { model.lastError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.lastError ?? "")
        }
    }
}

struct MainView: View {
    @Environment(AppModel.self) private var model
    @State private var showingNewAgent = false
    @State private var showingNewWorkspace = false
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    #if os(macOS)
    @State private var workspaceTabs = WorkspaceTabsRegistry()
    #else
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(showingNewAgent: $showingNewAgent, showingNewWorkspace: $showingNewWorkspace)
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 420)
        } detail: {
            #if os(macOS)
            if let pane = model.plugins.activePane {
                PluginPaneDetail(target: pane)
            } else if let workspace = model.selectedWorkspace {
                WorkspaceView(
                    workspace: workspace, tabs: workspaceTabs.tabs(for: workspace, model: model),
                    showingNewAgent: $showingNewAgent)
                    .id(workspace.id)
            } else if let terminal = model.terminals.selectedTerminal {
                TerminalDetailView(terminal: terminal)
                    .id(terminal.id)
            } else if let agent = model.selectedAgent {
                AgentDetailView(agent: agent)
                    .id(agent.id)
            } else {
                EmptyDetailView(showingNewAgent: $showingNewAgent, showingNewWorkspace: $showingNewWorkspace)
            }
            #else
            if let pane = model.plugins.activePane, sizeClass != .compact {
                PluginPaneDetail(target: pane)
            } else if let terminal = model.terminals.selectedTerminal {
                TerminalDetailView(terminal: terminal)
                    .id(terminal.id)
            } else if let agent = model.selectedAgent {
                AgentDetailView(agent: agent)
                    .id(agent.id)
            } else {
                EmptyDetailView(showingNewAgent: $showingNewAgent, showingNewWorkspace: $showingNewWorkspace)
            }
            #endif
        }
        .sheet(isPresented: $showingNewAgent) {
            NewAgentView()
        }
        .sheet(isPresented: $showingNewWorkspace) {
            NewWorkspaceView()
        }
        #if os(iOS)
        // Compact iPhone layouts show the sidebar alone, so plugin panes open as a sheet there.
        .sheet(item: Binding(
            get: { sizeClass == .compact ? model.plugins.activePane : nil },
            set: { model.plugins.activePane = $0 }
        )) { pane in
            NavigationStack { PluginPaneDetail(target: pane) }
                .environment(model)
        }
        #endif
        .onChange(of: model.selection) { _, selection in
            if selection != nil { model.plugins.activePane = nil }
        }
        .background(PluginRegistryHost())
    }
}

struct EmptyDetailView: View {
    @Environment(AppModel.self) private var model
    @Binding var showingNewAgent: Bool
    @Binding var showingNewWorkspace: Bool

    var body: some View {
        ContentUnavailableView {
            Label("No agent selected", systemImage: "sparkles.rectangle.stack")
        } description: {
            if let info = model.serverInfo {
                Text("Connected to \(info.hostname ?? info.serverId) · Paseo \(info.version ?? "?")")
            } else {
                Text("Pick an agent from the sidebar.")
            }
        } actions: {
            Button("New Agent") { showingNewAgent = true }
                .buttonStyle(.borderedProminent)
            Button("New Workspace") { showingNewWorkspace = true }
        }
    }
}
