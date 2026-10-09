#if DEBUG
import Foundation
import WebKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Development aids for plugin panes (DEBUG builds):
/// - `-PaseoOpenPluginPane <pluginId>/screen/<screenId>` or `<pluginId>/panel/<panelId>[/<workspaceId>]`
///   opens a pane once contributions arrive (panels default to the first workspace), and
///   `-PaseoOpenPluginPane sidebar:<label>` presses a plugin sidebar row instead, and
///   `command:<pluginId>/<commandId>` runs a Command Center item in the first workspace.
/// - `-PaseoPluginPress <accessibility label prefix>` clicks an element in the pane after it renders.
/// - With `-PaseoSnapshot /path/prefix`, writes `<prefix>-plugin.png` (the pane's web content) and
///   `<prefix>-plugin.txt` (contributions, sidebar rows, bridge RPC log).
@MainActor
enum PluginDebug {
    private static var opened = false
    private static var captured = false

    static func contributionsArrived(store: PluginStore) {
        guard !opened, let request = UserDefaults.standard.string(forKey: "PaseoOpenPluginPane") else { return }
        opened = true
        if request.hasPrefix("sidebar:") {
            let label = String(request.dropFirst("sidebar:".count))
            Task {
                for _ in 0..<50 {
                    if let row = store.sidebarRows.first(where: { $0.label == label }) {
                        store.press(row)
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            return
        }
        let firstWorkspaceId = store.app?.projects.first?.workspaces.first?.id
        if request.hasPrefix("command:") {
            let parts = request.dropFirst("command:".count).split(separator: "/").map(String.init)
            if parts.count == 2 { store.runCommand(pluginId: parts[0], commandId: parts[1], workspaceId: firstWorkspaceId) }
            return
        }
        let parts = request.split(separator: "/").map(String.init)
        guard parts.count >= 3 else { return }
        switch parts[1] {
        case "screen":
            store.open(.screen(pluginId: parts[0], screenId: parts[2]))
        case "panel":
            let workspaceId = parts.count > 3 ? parts[3] : firstWorkspaceId
            if let workspaceId { store.open(.panel(pluginId: parts[0], panelId: parts[2], workspaceId: workspaceId)) }
        default:
            break
        }
    }

    static func paneRendered(_ runtime: PluginWebRuntime, store: PluginStore) {
        guard !captured, let prefix = UserDefaults.standard.string(forKey: "PaseoSnapshot") else { return }
        captured = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if let label = UserDefaults.standard.string(forKey: "PaseoPluginPress") {
                do {
                    try await runtime.press(accessibilityLabel: label)
                } catch {
                    store.lastError = "PaseoPluginPress: \(error.localizedDescription)"
                }
                try? await Task.sleep(for: .seconds(2))
            }
            await capture(runtime, store: store, prefix: prefix)
        }
    }

    private static func capture(_ runtime: PluginWebRuntime, store: PluginStore, prefix: String) async {
        let summary = """
        pane: \(store.activePane?.id ?? "-") title: \(store.activePane.map(store.title(for:)) ?? "-")
        installed: \(store.installed.map { "\($0.id)(\($0.statusRaw))" })
        clientPlugins: \(store.catalog.filter(\.hasClient).map(\.id))
        contributions: \(store.contributions.map { "\($0.id): screens=\($0.screens.map(\.id)) panels=\($0.panels.map(\.id)) commands=\($0.commands.map(\.id)) unsupported=\($0.unsupported)" })
        sidebarRows: \(store.sidebarRows.map { "\($0.label)[\($0.icon ?? "-")]\($0.active ? "*" : "")" })
        failures: \(store.failures.map { "\($0.pluginId): \($0.message)" })
        bridgeLog:
        \(store.bridgeLog.joined(separator: "\n"))
        """
        try? summary.write(toFile: prefix + "-plugin.txt", atomically: true, encoding: .utf8)
        guard let image = try? await runtime.webView.takeSnapshot(configuration: nil) else { return }
        #if os(macOS)
        guard let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        #else
        guard let png = image.pngData() else { return }
        #endif
        try? png.write(to: URL(fileURLWithPath: prefix + "-plugin.png"))
    }
}
#endif
