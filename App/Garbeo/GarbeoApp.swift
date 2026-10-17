import PaseoKit
import SwiftUI

@main
struct GarbeoApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task {
                    #if DEBUG
                    DebugSnapshot.scheduleIfRequested(model: model)
                    // Unit tests run inside the app; keep it off the network meanwhile.
                    if LaunchOptions.isHostingUnitTests { return }
                    if let address = LaunchOptions.connectAddress {
                        await model.connect(to: DaemonEndpoint(url: address))
                        return
                    }
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
        .commands {
            GarbeoCommands(model: model)
        }
        #if os(macOS)
        .defaultSize(width: 1180, height: 760)
        #endif
    }
}

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
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    #if os(macOS)
    @State private var workspaceTabs = WorkspaceTabsRegistry()
    #else
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    var body: some View {
        @Bindable var model = model
        @Bindable var center = model.commandCenter
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(
                showingNewWorkspace: $center.showingNewWorkspace,
                showingNewProject: $center.showingNewProject)
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 420)
        } detail: {
            #if os(macOS)
            if let pane = model.plugins.activePane {
                PluginPaneDetail(target: pane)
            } else if let chat = model.newAgent {
                NewAgentChatView(chat: chat)
                    .id(ObjectIdentifier(chat))
            } else if let workspace = model.selectedWorkspace {
                WorkspaceView(workspace: workspace, tabs: workspaceTabs.tabs(for: workspace, model: model))
                    .id(workspace.id)
            } else if let terminal = model.terminals.selectedTerminal {
                TerminalDetailView(terminal: terminal)
                    .id(terminal.id)
            } else if let agent = model.selectedAgent {
                AgentDetailView(agent: agent)
                    .id(agent.id)
            } else {
                EmptyDetailView(
                    showingNewWorkspace: $center.showingNewWorkspace,
                    showingNewProject: $center.showingNewProject)
            }
            #else
            if let pane = model.plugins.activePane, sizeClass != .compact {
                PluginPaneDetail(target: pane)
            } else if let chat = model.newAgent {
                NewAgentChatView(chat: chat)
                    .id(ObjectIdentifier(chat))
            } else if let terminal = model.terminals.selectedTerminal {
                TerminalDetailView(terminal: terminal)
                    .id(terminal.id)
            } else if let agent = model.selectedAgent {
                AgentDetailView(agent: agent)
                    .id(agent.id)
            } else {
                EmptyDetailView(
                    showingNewWorkspace: $center.showingNewWorkspace,
                    showingNewProject: $center.showingNewProject)
            }
            #endif
        }
        .sheet(isPresented: $center.showingNewWorkspace) {
            NewWorkspaceView()
        }
        .sheet(isPresented: $center.showingNewProject) {
            NewProjectView()
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
        .commandCenter()
        .workspaceArchiveConfirmation()
        .background(PluginRegistryHost())
    }
}

struct EmptyDetailView: View {
    @Environment(AppModel.self) private var model
    @Binding var showingNewWorkspace: Bool
    @Binding var showingNewProject: Bool

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
            Button("New Agent") { model.startNewAgent() }
                .buttonStyle(.borderedProminent)
            Button("New Workspace") { showingNewWorkspace = true }
            Button("New Project") { showingNewProject = true }
        }
        .accessibilityIdentifier(AccessibilityID.Detail.empty)
    }
}
