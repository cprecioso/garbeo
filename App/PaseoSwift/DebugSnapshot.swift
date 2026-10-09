#if DEBUG
#if os(macOS)
import AppKit
#endif
import Foundation
import PaseoKit

/// Development aid: launch with `-PaseoSnapshot /path/prefix` to write PNGs of the key window
/// (and a state summary) a few seconds after launch, and again after `-PaseoSelectAgent` /
/// `-PaseoSelectWorkspace` / `-PaseoSelectTerminal` apply.
@MainActor
enum DebugSnapshot {
    /// Describes the workspace view on screen (tabs, panes, layout); set by `WorkspaceView`.
    static var describeWorkspace: (() -> String)?

    static func scheduleIfRequested(model: AppModel) {
        guard let prefix = UserDefaults.standard.string(forKey: "PaseoSnapshot") else { return }
        Task {
            try? await Task.sleep(for: .seconds(4))
            capture(to: prefix + "-1.png", model: model)
            let defaults = UserDefaults.standard
            if ["PaseoSelectAgent", "PaseoSelectWorkspace", "PaseoSelectTerminal"].contains(where: { defaults.string(forKey: $0) != nil }) {
                try? await Task.sleep(for: .seconds(4))
                capture(to: prefix + "-2.png", model: model)
            }
            #if os(macOS)
            // `-PaseoResizeWindow 900x500` then resizes the window and captures once more.
            if let size = UserDefaults.standard.string(forKey: "PaseoResizeWindow")?.split(separator: "x")
                .compactMap({ Double($0) }), size.count == 2,
                let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil })
            {
                window.setFrame(NSRect(origin: window.frame.origin, size: NSSize(width: size[0], height: size[1])), display: true)
                try? await Task.sleep(for: .seconds(3))
                capture(to: prefix + "-3.png", model: model)
            }
            #endif
        }
    }

    private static func capture(to path: String, model: AppModel) {
        let summary = """
        connected: \(model.connection.isConnected)
        transport: \(model.endpoint.map { "\($0.transportKind.label) \($0.displayAddress)" } ?? "-")
        projects: \(model.projects.map { "\($0.name)[\($0.workspaces.map { "\($0.displayName):\(model.agents(in: $0).count)" }.joined(separator: ","))]" })
        unplaced: \(model.unplacedAgents.count)
        workspaces: \(model.workspaces.count) agents: \(model.agents.count)
        selection: \(model.selection.map { "\($0)" } ?? "-")
        visibleTimelines: \(model.timelines.visibleAgentIds) subscribed: \(model.timelines.subscribed.sorted())
        \(model.timelines.timelines.sorted { $0.key < $1.key }.map { id, live in
            "timeline \(id): rows=\(live.timeline.rows.count) loaded=\(live.timeline.isLoaded) needsTail=\(live.needsTail) hasOlder=\(live.timeline.hasOlder) error=\(live.error ?? "-")"
        }.joined(separator: "\n"))
        terminals: \(model.terminals.byWorkspace.mapValues { $0.map(\.id) }) selectedTerminal: \(model.terminals.selectedTerminalId ?? "-")
        \(describeWorkspace?() ?? "workspace: -")
        """
        #if os(iOS)
        try? summary.write(toFile: path + ".txt", atomically: true, encoding: .utf8)
        #else
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else { return }
        // Sidebar rows live in layer-backed vibrancy views that `cacheDisplay` cannot draw,
        // so report the backing table's row count as well.
        func tables(in view: NSView) -> [NSTableView] {
            (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap(tables(in:))
        }
        let rowCounts = window.contentView.map(tables(in:))?.map(\.numberOfRows) ?? []
        try? (summary + "\ntableRows: \(rowCounts)").write(toFile: path + ".txt", atomically: true, encoding: .utf8)
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        #endif
    }
}
#endif
