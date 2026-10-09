import Foundation
import Observation
import PaseoKit

/// Workspace terminals, kept current through one `subscribe_terminals_request` per workspace,
/// plus which terminal is open in the detail column.
@MainActor @Observable
final class TerminalDirectory {
    private(set) var byWorkspace: [String: [TerminalInfo]] = [:]
    var selectedTerminalId: String?
    @ObservationIgnored var onError: ((String) -> Void)?

    @ObservationIgnored private var client: DaemonClient?
    @ObservationIgnored private var subscribed: Set<String> = []

    var selectedTerminal: TerminalInfo? {
        guard let selectedTerminalId else { return nil }
        return byWorkspace.values.lazy.flatMap { $0 }.first { $0.id == selectedTerminalId }
    }

    func terminals(in workspace: Workspace) -> [TerminalInfo] {
        byWorkspace[workspace.id] ?? []
    }

    func workspaceId(of terminal: TerminalInfo) -> String? {
        byWorkspace.first { $0.value.contains { $0.id == terminal.id } }?.key
    }

    // MARK: Sync

    /// Loads every terminal, then subscribes to each workspace's changes. Failures are non-fatal:
    /// older daemons may not support workspace terminals at all.
    func connect(_ client: DaemonClient, workspaces: [Workspace]) async {
        self.client = client
        subscribed = []
        if let all = try? await client.listTerminals() {
            let directories = Dictionary(workspaces.map { ($0.workspaceDirectory, $0.id) }, uniquingKeysWith: { first, _ in first })
            byWorkspace = Dictionary(grouping: all) { $0.workspaceId ?? $0.cwd.flatMap { directories[$0] } ?? "" }
            byWorkspace[""] = nil
        }
        await withTaskGroup(of: Void.self) { group in
            for workspace in workspaces { group.addTask { await self.observe(workspace) } }
        }
        if selectedTerminalId != nil, selectedTerminal == nil, !byWorkspace.isEmpty { selectedTerminalId = nil }
    }

    func observe(_ workspace: Workspace) async {
        guard let client, !subscribed.contains(workspace.id) else { return }
        subscribed.insert(workspace.id)
        do {
            apply(try await client.subscribeTerminals(cwd: workspace.workspaceDirectory, workspaceId: workspace.id))
        } catch {
            subscribed.remove(workspace.id)
        }
    }

    func apply(_ change: TerminalsChanged) {
        guard let workspaceId = change.workspaceId else { return }
        let terminals = change.terminals.filter { $0.workspaceId == nil || $0.workspaceId == workspaceId }
        let previous = byWorkspace[workspaceId] ?? []
        byWorkspace[workspaceId] = terminals
        if let selectedTerminalId, previous.contains(where: { $0.id == selectedTerminalId }),
           !terminals.contains(where: { $0.id == selectedTerminalId })
        {
            self.selectedTerminalId = nil
        }
    }

    func forget(workspaceId: String) {
        subscribed.remove(workspaceId)
        byWorkspace[workspaceId] = nil
    }

    func reset() {
        client = nil
        subscribed = []
        byWorkspace = [:]
        selectedTerminalId = nil
    }

    // MARK: Actions

    func create(in workspace: Workspace) async {
        guard let client else { return }
        do {
            let terminal = try await client.createTerminal(cwd: workspace.workspaceDirectory, workspaceId: workspace.id)
            var list = byWorkspace[workspace.id] ?? []
            if !list.contains(where: { $0.id == terminal.id }) { list.append(terminal) }
            byWorkspace[workspace.id] = list
            selectedTerminalId = terminal.id
        } catch {
            onError?(error.localizedDescription)
        }
    }

    func kill(_ terminal: TerminalInfo) async {
        guard let client else { return }
        do {
            try await client.killTerminal(terminal.id)
            if let workspaceId = workspaceId(of: terminal) {
                byWorkspace[workspaceId]?.removeAll { $0.id == terminal.id }
            }
            if selectedTerminalId == terminal.id { selectedTerminalId = nil }
        } catch {
            onError?(error.localizedDescription)
        }
    }

    #if DEBUG
    /// `new` creates a terminal in the first workspace, so only use it against a throwaway daemon.
    func applyDebugSelection(_ requested: String, workspaces: [Workspace]) async {
        switch requested {
        case "first": selectedTerminalId = workspaces.lazy.flatMap(terminals(in:)).first?.id
        case "new": if let workspace = workspaces.first { await create(in: workspace) }
        default: selectedTerminalId = requested
        }
    }
    #endif
}
