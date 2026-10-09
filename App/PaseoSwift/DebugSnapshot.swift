#if DEBUG
#if os(macOS)
import AppKit
#endif
import Foundation
import PaseoKit

/// Development aid: launch with `-PaseoSnapshot /path/prefix` to write PNGs of the key window
/// (and a state summary) a few seconds after launch, and again after `-PaseoSelectAgent` applies.
@MainActor
enum DebugSnapshot {
    static func scheduleIfRequested(model: AppModel) {
        guard let prefix = UserDefaults.standard.string(forKey: "PaseoSnapshot") else { return }
        Task {
            try? await Task.sleep(for: .seconds(4))
            capture(to: prefix + "-1.png", model: model)
            if UserDefaults.standard.string(forKey: "PaseoSelectAgent") != nil {
                try? await Task.sleep(for: .seconds(4))
                capture(to: prefix + "-2.png", model: model)
            }
        }
    }

    private static func capture(to path: String, model: AppModel) {
        let summary = """
        connected: \(model.connection.isConnected)
        projects: \(model.projects.map { "\($0.name)[\($0.workspaces.map { "\($0.displayName):\(model.agents(in: $0).count)" }.joined(separator: ","))]" })
        unplaced: \(model.unplacedAgents.count)
        workspaces: \(model.workspaces.count) agents: \(model.agents.count)
        selected: \(model.selectedAgentId ?? "-") firstRows: \(model.timeline.rows.prefix(3).map(\.id)) hasOlder: \(model.timeline.hasOlder) timelineRows: \(model.timeline.rows.count) loaded: \(model.timeline.isLoaded)
        timelineError: \(model.timelineError ?? "-")
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
