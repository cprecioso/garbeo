import Foundation

/// Saved tab/split layout of one workspace, independent of Bonsplit's runtime IDs.
struct WorkspaceLayout: Codable, Equatable {
    /// `horizontal` places panes side by side, `vertical` stacks them (Bonsplit's convention).
    enum Axis: String, Codable { case horizontal, vertical }

    indirect enum Node: Codable, Equatable {
        case pane(Pane)
        case split(Split)
    }

    struct Pane: Codable, Equatable {
        var tabs: [WorkspaceTabContent]
        var selected: WorkspaceTabContent?
    }

    struct Split: Codable, Equatable {
        var axis: Axis
        /// Fraction of the split given to `first`.
        var divider: Double
        var first: Node
        var second: Node
    }

    var root: Node
    /// The selected tab of the focused pane.
    var focused: WorkspaceTabContent?

    var allTabs: [WorkspaceTabContent] { root.allTabs }

    /// Drops tabs that fail `keep` and collapses panes left empty. Nil when nothing remains.
    func pruned(keeping keep: (WorkspaceTabContent) -> Bool) -> WorkspaceLayout? {
        guard let root = root.pruned(keeping: keep) else { return nil }
        return WorkspaceLayout(root: root, focused: focused.flatMap { keep($0) ? $0 : nil })
    }
}

extension WorkspaceLayout.Node {
    var allTabs: [WorkspaceTabContent] {
        switch self {
        case .pane(let pane): pane.tabs
        case .split(let split): split.first.allTabs + split.second.allTabs
        }
    }

    func pruned(keeping keep: (WorkspaceTabContent) -> Bool) -> Self? {
        switch self {
        case .pane(var pane):
            pane.tabs = pane.tabs.filter(keep)
            guard !pane.tabs.isEmpty else { return nil }
            if let selected = pane.selected, !pane.tabs.contains(selected) { pane.selected = pane.tabs.first }
            return .pane(pane)
        case .split(var split):
            let first = split.first.pruned(keeping: keep)
            let second = split.second.pruned(keeping: keep)
            guard let first, let second else { return first ?? second }
            split.first = first
            split.second = second
            return .split(split)
        }
    }
}

extension WorkspaceLayout.Pane {
    // Tabs that no longer decode (a kind from another build) are skipped rather than failing the
    // whole layout.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tabs = try container.decode([Lossy<WorkspaceTabContent>].self, forKey: .tabs).compactMap(\.value)
        selected = try? container.decodeIfPresent(WorkspaceTabContent.self, forKey: .selected)
    }
}

private struct Lossy<Value: Decodable>: Decodable {
    var value: Value?
    init(from decoder: any Decoder) throws { value = try? Value(from: decoder) }
}

/// Saves layouts in UserDefaults, one key per daemon and workspace.
enum WorkspaceLayoutStore {
    static func load(server: String, workspace: String) -> WorkspaceLayout? {
        guard let data = UserDefaults.app.data(forKey: key(server, workspace)) else { return nil }
        return try? JSONDecoder().decode(WorkspaceLayout.self, from: data)
    }

    static func save(_ layout: WorkspaceLayout?, server: String, workspace: String) {
        if let layout, let data = try? JSONEncoder().encode(layout) {
            UserDefaults.app.set(data, forKey: key(server, workspace))
        } else {
            UserDefaults.app.removeObject(forKey: key(server, workspace))
        }
    }

    private static func key(_ server: String, _ workspace: String) -> String {
        "workspaceLayout.v1.\(server).\(workspace)"
    }
}
