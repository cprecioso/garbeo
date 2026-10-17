import Foundation

// Paseo worktree creation, its setup scripts, archiving workspaces, and branch suggestions for
// picking refs (packages/protocol/src/messages.ts).

public struct CreateWorktreeOptions: Sendable, Hashable {
    public enum Source: Sendable, Hashable {
        /// A new branch off `base`; nil lets the daemon pick the repository's default branch.
        case branchOff(base: String?)
        case checkoutBranch(String)
        case checkoutPullRequest(Int)
    }

    /// A directory inside the project's repository.
    public var cwd: String
    public var projectId: String?
    public var source: Source
    /// The worktree directory name, and the new branch's name when branching off; nil lets the
    /// daemon generate one.
    public var worktreeSlug: String?
    /// The first agent's prompt, which the daemon uses to name the workspace and its branch.
    public var firstAgentPrompt: String?

    public init(
        cwd: String, projectId: String? = nil, source: Source, worktreeSlug: String? = nil,
        firstAgentPrompt: String? = nil
    ) {
        self.cwd = cwd
        self.projectId = projectId
        self.source = source
        self.worktreeSlug = worktreeSlug
        self.firstAgentPrompt = firstAgentPrompt
    }

    var message: [String: JSONValue] {
        var message: [String: JSONValue] = ["type": "create_paseo_worktree_request", "cwd": .string(cwd)]
        if let projectId { message["projectId"] = .string(projectId) }
        if let worktreeSlug { message["worktreeSlug"] = .string(worktreeSlug) }
        if let firstAgentPrompt { message["firstAgentContext"] = ["prompt": .string(firstAgentPrompt)] }
        switch source {
        case .branchOff(let base):
            message["action"] = "branch-off"
            if let base { message["refName"] = .string(base) }
        case .checkoutBranch(let branch):
            message["action"] = "checkout"
            message["refName"] = .string(branch)
        case .checkoutPullRequest(let number):
            message["action"] = "checkout"
            // No forge, so the daemon uses the project's. `githubPrNumber` is for daemons older than
            // v0.2.0, which don't know `checkoutSource`.
            message["checkoutSource"] = ["kind": "change_request", "number": .number(Double(number))]
            message["githubPrNumber"] = .number(Double(number))
        }
        return message
    }
}

public struct CreateWorktreeResponse: Decodable, Sendable {
    public var requestId: String
    public var workspace: Workspace?
    public var error: String?
    public var errorCode: String?
    public var setupTerminalId: String?
    /// Why the setup scripts didn't run (e.g. a pull request from an untrusted fork).
    public var setupSkippedReason: String?
}

/// Progress of a workspace's setup scripts (`WorkspaceSetupSnapshotSchema`).
public struct WorkspaceSetupSnapshot: Decodable, Sendable, Hashable {
    public enum Status: Sendable, Hashable {
        case running, completed, failed
        /// Waiting for approval to run code from a fork pull request, see `DaemonClient.runWorkspaceSetup`.
        case blocked
        case other(String)

        public init(raw: String) {
            switch raw {
            case "running": self = .running
            case "completed": self = .completed
            case "failed": self = .failed
            case "blocked": self = .blocked
            default: self = .other(raw)
            }
        }
    }

    public struct Detail: Decodable, Sendable, Hashable {
        public var worktreePath: String?
        public var branchName: String?
        public var log: String?
        public var commands: [Command]?
        public var truncated: Bool?
    }

    public struct Command: Decodable, Sendable, Hashable, Identifiable {
        public var index: Int
        public var command: String
        public var cwd: String?
        public var log: String?
        public var statusRaw: String
        public var exitCode: Int?
        public var durationMs: Double?

        enum CodingKeys: String, CodingKey {
            case index, command, cwd, log, exitCode, durationMs
            case statusRaw = "status"
        }

        public var id: Int { index }
        public var status: Status { Status(raw: statusRaw) }
    }

    /// The fork pull request whose code is waiting for approval.
    public struct BlockedSource: Decodable, Sendable, Hashable {
        public var forge: String?
        public var number: Int
        public var headRepository: String?
    }

    public var statusRaw: String
    public var detail: Detail?
    public var error: String?
    public var blockedSource: BlockedSource?

    enum CodingKeys: String, CodingKey {
        case detail, error, blockedSource
        case statusRaw = "status"
    }

    public var status: Status { Status(raw: statusRaw) }
    public var commands: [Command] { detail?.commands ?? [] }
}

/// A `workspace_setup_progress` event: the workspace's whole setup snapshot so far.
public struct WorkspaceSetupProgress: Decodable, Sendable {
    public var workspaceId: String
    public var snapshot: WorkspaceSetupSnapshot

    enum CodingKeys: String, CodingKey { case workspaceId }

    public init(from decoder: Decoder) throws {
        workspaceId = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .workspaceId)
        snapshot = try WorkspaceSetupSnapshot(from: decoder)
    }
}

struct WorkspaceSetupStatusResponse: Decodable {
    var snapshot: WorkspaceSetupSnapshot?
}

struct WorkspaceSetupRunResponse: Decodable {
    var started: Bool
    var error: String?
}

public struct BranchSuggestion: Decodable, Sendable, Hashable, Identifiable {
    public var name: String
    /// Seconds since 1970.
    public var committerDate: Double?
    public var hasLocal: Bool?
    public var hasRemote: Bool?

    public var id: String { name }
}

struct ArchiveWorkspaceResponse: Decodable {
    var workspaceId: String
    var archivedAt: String?
    var error: String?
}

struct BranchSuggestionsResponse: Decodable {
    var branches: [String]
    var branchDetails: [BranchSuggestion]?
    var error: String?
}

extension DaemonClient {
    /// Creates a Paseo-owned worktree and its workspace. The daemon runs the project's setup
    /// scripts in the background afterwards.
    public func createWorktree(_ options: CreateWorktreeOptions) async throws -> CreateWorktreeResponse {
        // Checking out a pull request fetches from the remote first.
        let response = try await request(options.message, as: CreateWorktreeResponse.self, timeout: .seconds(120))
        guard response.workspace != nil else {
            throw PaseoError.rpc(response.error ?? "Worktree creation failed")
        }
        return response
    }

    /// The workspace's setup progress, or nil if its setup hasn't run since the daemon started.
    /// Later progress arrives as `DaemonEvent.workspaceSetupProgress`.
    public func workspaceSetupStatus(workspaceId: String) async throws -> WorkspaceSetupSnapshot? {
        try await request([
            "type": "workspace_setup_status_request", "workspaceId": .string(workspaceId),
        ], as: WorkspaceSetupStatusResponse.self).snapshot
    }

    /// Approves a blocked setup (code from a fork pull request) and runs it. Returns whether it
    /// started; setups that aren't blocked don't run again.
    @discardableResult
    public func runWorkspaceSetup(workspaceId: String) async throws -> Bool {
        let response = try await request([
            "type": "workspace.setup.run.request", "workspaceId": .string(workspaceId),
        ], as: WorkspaceSetupRunResponse.self)
        if let error = response.error { throw PaseoError.rpc(error) }
        return response.started
    }

    /// Archives a workspace: the daemon archives its agents, kills its terminals and, for a Paseo
    /// worktree, removes its directory. Other workspaces' files stay as they are.
    public func archiveWorkspace(workspaceId: String) async throws {
        // Removing a worktree's directory can take a while.
        let response = try await request(
            Self.archiveWorkspaceMessage(workspaceId: workspaceId), as: ArchiveWorkspaceResponse.self,
            timeout: .seconds(120))
        if let error = response.error { throw PaseoError.rpc(error) }
    }

    static func archiveWorkspaceMessage(workspaceId: String) -> [String: JSONValue] {
        ["type": "archive_workspace_request", "workspaceId": .string(workspaceId)]
    }

    /// Branches of the repository at `cwd` matching `query`.
    public func branchSuggestions(cwd: String, query: String? = nil, limit: Int = 20) async throws -> [BranchSuggestion] {
        var message: [String: JSONValue] = [
            "type": "branch_suggestions_request", "cwd": .string(cwd), "limit": .number(Double(limit)),
        ]
        if let query, !query.isEmpty { message["query"] = .string(query) }
        let response = try await request(message, as: BranchSuggestionsResponse.self)
        if let error = response.error { throw PaseoError.rpc(error) }
        return response.branchDetails ?? response.branches.map { BranchSuggestion(name: $0) }
    }
}
