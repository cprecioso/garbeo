import Foundation
import Testing
@testable import PaseoKit

@Suite struct WorktreeTests {
    @Test func branchesOffDefaultBranch() {
        let message = CreateWorktreeOptions(cwd: "/repo", projectId: "p1", source: .branchOff(base: nil)).message
        #expect(message == [
            "type": "create_paseo_worktree_request", "cwd": "/repo", "projectId": "p1", "action": "branch-off",
        ])
    }

    @Test func branchesOffRefWithSlugAndPrompt() {
        let message = CreateWorktreeOptions(
            cwd: "/repo", source: .branchOff(base: "dev"), worktreeSlug: "fix-login", firstAgentPrompt: "Fix login"
        ).message
        #expect(message["action"] == "branch-off")
        #expect(message["refName"] == "dev")
        #expect(message["worktreeSlug"] == "fix-login")
        #expect(message["firstAgentContext"] == ["prompt": "Fix login"])
    }

    @Test func checksOutBranch() {
        let message = CreateWorktreeOptions(cwd: "/repo", source: .checkoutBranch("feature/x")).message
        #expect(message["action"] == "checkout")
        #expect(message["refName"] == "feature/x")
        #expect(message["checkoutSource"] == nil)
    }

    @Test func checksOutPullRequest() {
        let message = CreateWorktreeOptions(cwd: "/repo", source: .checkoutPullRequest(42)).message
        #expect(message["action"] == "checkout")
        #expect(message["refName"] == nil)
        #expect(message["checkoutSource"] == ["kind": "change_request", "number": 42])
        #expect(message["githubPrNumber"] == 42)
    }

    @Test func decodesResponse() throws {
        let created = try JSONDecoder().decode(SessionFrame<CreateWorktreeResponse>.self, from: Data("""
        {"type":"session","message":{"type":"create_paseo_worktree_response","payload":{"requestId":"r",
          "workspace":{"id":"w1","projectId":"p1","projectDisplayName":"repo","projectRootPath":"/repo",
            "workspaceDirectory":"/wt/fix-login","worktreeSlug":"fix-login","projectKind":"git",
            "workspaceKind":"worktree","name":"fix-login","status":"done","statusEnteredAt":null},
          "error":null,"setupTerminalId":null,"setupSkippedReason":"Untrusted fork"}}}
        """.utf8)).message.payload
        #expect(created.workspace?.id == "w1")
        #expect(created.workspace?.workspaceDirectory == "/wt/fix-login")
        #expect(created.setupSkippedReason == "Untrusted fork")

        let failed = try JSONDecoder().decode(SessionFrame<CreateWorktreeResponse>.self, from: Data("""
        {"type":"session","message":{"type":"create_paseo_worktree_response","payload":{"requestId":"r",
          "workspace":null,"error":"Branch not found","errorCode":"unknown","setupTerminalId":null}}}
        """.utf8)).message.payload
        #expect(failed.workspace == nil)
        #expect(failed.error == "Branch not found")
    }

    @Test func decodesSetupProgress() throws {
        let progress = try JSONDecoder().decode(SessionFrame<WorkspaceSetupProgress>.self, from: Data("""
        {"type":"session","message":{"type":"workspace_setup_progress","payload":{"workspaceId":"w1","status":"running",
          "detail":{"type":"worktree_setup","worktreePath":"/wt/x","branchName":"x","log":"",
            "commands":[{"index":1,"command":"npm ci","cwd":"/wt/x","log":"added 3 packages","status":"completed","exitCode":0,"durationMs":1200},
                        {"index":2,"command":"make","cwd":"/wt/x","status":"running","exitCode":null}]},
          "error":null}}}
        """.utf8)).message.payload
        #expect(progress.workspaceId == "w1")
        #expect(progress.snapshot.status == .running)
        #expect(progress.snapshot.commands.map(\.status) == [.completed, .running])
        #expect(progress.snapshot.commands[0].log == "added 3 packages")

        let blocked = try JSONDecoder().decode(SessionFrame<WorkspaceSetupStatusResponse>.self, from: Data("""
        {"type":"session","message":{"type":"workspace_setup_status_response","payload":{"requestId":"r","workspaceId":"w1",
          "snapshot":{"status":"blocked","detail":{"type":"worktree_setup","worktreePath":"/wt/x","branchName":"x","log":"","commands":[]},
            "error":null,"blockedSource":{"kind":"change_request","forge":"github","number":7,"headRepository":"someone/repo"}}}}}
        """.utf8)).message.payload
        #expect(blocked.snapshot?.status == .blocked)
        #expect(blocked.snapshot?.blockedSource?.number == 7)
    }

    @Test func decodesBranchSuggestions() throws {
        let response = try JSONDecoder().decode(SessionFrame<BranchSuggestionsResponse>.self, from: Data("""
        {"type":"session","message":{"type":"branch_suggestions_response","payload":{"requestId":"r","branches":["main","dev"],
          "branchDetails":[{"name":"main","committerDate":1760000000,"hasLocal":true,"hasRemote":true},{"name":"dev","committerDate":1750000000}],
          "error":null}}}
        """.utf8)).message.payload
        #expect(response.branchDetails?.map(\.name) == ["main", "dev"])
        #expect(response.branchDetails?.first?.hasRemote == true)
    }
}
