import PaseoKit
import SwiftUI
import WebKit

/// A plugin screen or workspace panel. Self-contained: give it a target and an `AppModel` in the
/// environment, and host it in any container (detail column, sheet, tab, split pane). It owns
/// its web page for as long as it stays in the view tree with the same target.
struct PluginPaneView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    let target: PluginPaneTarget
    @State private var holder = RuntimeHolder()

    var body: some View {
        let plugins = model.plugins
        Group {
            if let runtime = holder.runtime {
                PluginWebView(webView: runtime.webView)
            } else if !model.connection.isConnected {
                ContentUnavailableView("Disconnected", systemImage: "bolt.horizontal.circle", description: Text("Plugin panes need a daemon connection."))
            } else if plugins.catalog.isEmpty {
                ProgressView()
            } else {
                ContentUnavailableView(
                    "Plugin unavailable", systemImage: LucideSymbols.fallback,
                    description: Text("\(plugins.displayName(of: target.pluginId)) is not installed or has no client UI."))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Rebuild the page when the target changes or the plugin catalog reloads.
        .task(id: "\(target.id)#\(plugins.revision)") {
            holder.replace(with: plugins.makePaneRuntime(for: target, scheme: colorScheme, compact: isCompact), store: plugins)
        }
        .onChange(of: colorScheme) { _, scheme in holder.runtime?.updateTheme(scheme) }
    }

    private var isCompact: Bool {
        #if os(iOS)
        sizeClass == .compact
        #else
        false
        #endif
    }

    /// Owns the pane's runtime and shuts it down when the view goes away. Not actor-isolated so
    /// its deinit can read the runtime; it is only touched from the main actor.
    @Observable
    final class RuntimeHolder {
        private(set) var runtime: PluginWebRuntime?
        @ObservationIgnored private weak var store: PluginStore?

        @MainActor func replace(with runtime: PluginWebRuntime?, store: PluginStore) {
            if let old = self.runtime { store.releasePane(old) }
            self.runtime = runtime
            self.store = store
        }

        deinit {
            let runtime = runtime
            let store = store
            Task { @MainActor in
                if let runtime { store?.releasePane(runtime) ?? runtime.shutdown() }
            }
        }
    }
}

/// `PluginPaneView` with a title, icon and close button, for navigation containers.
struct PluginPaneDetail: View {
    @Environment(AppModel.self) private var model
    let target: PluginPaneTarget

    var body: some View {
        PluginPaneView(target: target)
            .navigationTitle(model.plugins.title(for: target))
            #if os(macOS)
            .navigationSubtitle(model.plugins.displayName(of: target.pluginId))
            #else
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { model.plugins.activePane = nil }
                        .help("Close plugin pane")
                }
            }
    }
}

/// Hosts a runtime's WKWebView.
struct PluginWebView {
    let webView: WKWebView
}

#if os(macOS)
extension PluginWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#else
extension PluginWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#endif

/// Keeps the registry page in the window (1pt, invisible) so iOS doesn't suspend its process.
struct PluginRegistryHost: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let webView = model.plugins.registryWebView {
            PluginWebView(webView: webView)
                .id(ObjectIdentifier(webView))
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}
