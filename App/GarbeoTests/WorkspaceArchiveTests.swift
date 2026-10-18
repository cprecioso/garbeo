import Foundation
import PaseoKit
import Testing
@testable import Garbeo

/// An app model connected to a fresh `FakeDaemon`.
@MainActor
private func connectedModel() async throws -> (AppModel, FakeDaemon) {
    let daemon = FakeDaemon()
    let model = AppModel()
    model.transportFactory = { daemon }
    await model.connect(to: DaemonEndpoint(url: "fake.invalid:6767"))
    try #require(model.connection.isConnected)
    return (model, daemon)
}

private func workspace(
    kind: String, diff: (Int, Int)? = nil, dirty: Bool? = nil, ahead: Int? = nil
) throws -> Workspace {
    var fields: [String: JSONValue] = [
        "id": "w1", "projectId": "p1", "workspaceDirectory": "/wt/fix", "workspaceKind": .string(kind), "name": "fix",
    ]
    if let diff { fields["diffStat"] = ["additions": .number(Double(diff.0)), "deletions": .number(Double(diff.1))] }
    var git: [String: JSONValue] = [:]
    if let dirty { git["isDirty"] = .bool(dirty) }
    if let ahead { git["aheadOfOrigin"] = .number(Double(ahead)) }
    if !git.isEmpty { fields["gitRuntime"] = .object(git) }
    return try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(JSONValue.object(fields)))
}

@Suite struct WorkspaceArchiveConfirmationTests {
    @Test func cleanWorktreeArchivesWithoutAsking() throws {
        #expect(try workspace(kind: "worktree").archiveConfirmation == nil)
        #expect(try workspace(kind: "worktree", diff: (0, 0), dirty: false, ahead: 0).archiveConfirmation == nil)
        #expect(try workspace(kind: "worktree").archiveTitle == "Archive Workspace")
    }

    @Test func worktreeWithWorkAsks() throws {
        let confirmation = try #require(try workspace(kind: "worktree", diff: (3, 1), dirty: true, ahead: 2).archiveConfirmation)
        #expect(confirmation.title == "Archive \"fix\"?")
        #expect(confirmation.message == "Uncommitted changes (3 added lines, 1 deleted line)\n2 unpushed commits")
        #expect(confirmation.action == "Archive")
    }

    @Test func diffWithoutGitStatusCountsAsUncommitted() throws {
        #expect(try workspace(kind: "worktree", diff: (1, 0)).archiveRisks == ["Uncommitted changes (1 added line)"])
        #expect(try workspace(kind: "worktree", diff: (1, 0), dirty: false).archiveRisks.isEmpty)
        #expect(try workspace(kind: "worktree", dirty: true, ahead: 1).archiveRisks == ["Uncommitted changes", "1 unpushed commit"])
    }

    @Test func otherWorkspacesAreHidden() throws {
        let local = try workspace(kind: "local_checkout")
        #expect(local.archiveTitle == "Hide Workspace from Sidebar")
        let confirmation = try #require(local.archiveConfirmation)
        #expect(confirmation.title == "Hide workspace?")
        #expect(confirmation.action == "Hide")
    }
}

@MainActor @Suite struct WorkspaceArchiveTests {
    @Test func archivesAndLeavesSidebar() async throws {
        let (model, daemon) = try await connectedModel()
        model.selection = .workspace("ws_feature")
        let feature = try #require(model.workspaces["ws_feature"])

        await model.archive(feature)

        #expect(await daemon.archivedWorkspaces == ["ws_feature"])
        #expect(model.workspaces["ws_feature"] == nil)
        #expect(model.selection == nil)
        #expect(model.lastError == nil)
    }

    @Test func failureRestoresWorkspace() async throws {
        let (model, daemon) = try await connectedModel()
        await daemon.failWorkspaceArchiving("Worktree is locked")
        let feature = try #require(model.workspaces["ws_feature"])

        await model.archive(feature)

        #expect(model.workspaces["ws_feature"] != nil)
        #expect(model.lastError?.contains("Worktree is locked") == true)
    }

    @Test func requestAsksOnlyWhenNeeded() async throws {
        let (model, daemon) = try await connectedModel()
        let main = try #require(model.workspaces["ws_main"])

        model.requestArchive(main)
        #expect(model.commandCenter.workspaceToArchive?.id == "ws_main")
        #expect(await daemon.archivedWorkspaces.isEmpty)
    }

    @Test func workspacesBeingArchivedLeaveSidebar() async throws {
        let (model, _) = try await connectedModel()
        var feature = try #require(model.workspaces["ws_feature"])
        feature.archivingAt = "2026-10-17T10:10:00Z"

        model.handle(.workspaceUpdate(.upsert(feature)))

        #expect(model.workspaces["ws_feature"] != nil)
        #expect(!model.projects.flatMap(\.workspaces).contains { $0.id == "ws_feature" })
    }
}
