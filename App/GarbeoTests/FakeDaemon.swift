import Foundation
import PaseoKit
@testable import Garbeo

/// An in-memory daemon for tests: one project with two workspaces, two providers, and agents
/// created on request. Answers every request (unknown ones with an empty response) so the app
/// connects and runs as it would against a real daemon. Connect an `AppModel` to it through
/// `transportFactory`.
actor FakeDaemon: DaemonTransport {
    static let projectRoot = "/tmp/garbeo-fake/garbeo"

    /// The `create_agent_request` messages received, oldest first.
    private(set) var createdAgents: [JSONValue] = []
    /// The `create_paseo_worktree_request` messages received, oldest first.
    private(set) var createdWorktrees: [JSONValue] = []
    /// The workspace IDs of the `archive_workspace_request` messages received, oldest first.
    private(set) var archivedWorkspaces: [String] = []
    /// Fails agent creation with this error instead.
    var createAgentError: String?
    /// Fails archiving workspaces with this error instead.
    var archiveWorkspaceError: String?
    private var inbox: [TransportMessage] = []
    private var waiters: [CheckedContinuation<TransportMessage, Error>] = []
    private var closed = false

    init() {}

    func failAgentCreation(_ error: String?) { createAgentError = error }

    func failWorkspaceArchiving(_ error: String?) { archiveWorkspaceError = error }

    // MARK: DaemonTransport

    func open() async throws {}

    func send(_ message: TransportMessage) async throws {
        guard !closed else { throw PaseoError.disconnected }
        guard case .text(let text) = message,
              let frame = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        else { return }
        switch frame["type"]?.stringValue {
        case "hello":
            deliver(["type": "session", "message": ["type": "status", "payload": [
                "status": "server_info", "serverId": "srv_fake", "hostname": "Fake Daemon", "version": "0.0.0",
                "protocolVersion": 1, "features": [:],
            ]]])
        case "ping":
            deliver(["type": "pong"])
        case "session":
            if let request = frame["message"], case .object(let fields) = request { respond(to: fields) }
        default:
            break
        }
    }

    func receive() async throws -> TransportMessage {
        if !inbox.isEmpty { return inbox.removeFirst() }
        guard !closed else { throw PaseoError.disconnected }
        return try await withCheckedThrowingContinuation { waiters.append($0) }
    }

    nonisolated func close() { Task { await markClosed() } }

    private func markClosed() {
        closed = true
        for waiter in waiters { waiter.resume(throwing: PaseoError.disconnected) }
        waiters.removeAll()
    }

    private func deliver(_ frame: JSONValue) {
        guard let data = try? JSONEncoder().encode(frame) else { return }
        let message = TransportMessage.text(String(decoding: data, as: UTF8.self))
        if waiters.isEmpty { inbox.append(message) } else { waiters.removeFirst().resume(returning: message) }
    }

    // MARK: Requests

    private func respond(to request: [String: JSONValue]) {
        guard let type = request["type"]?.stringValue, let requestId = request["requestId"] else { return }
        var payload: [String: JSONValue] = ["requestId": requestId]
        let responseType: String
        switch type {
        case "fetch_workspaces_request":
            responseType = "fetch_workspaces_response"
            payload["entries"] = [
                Self.workspace(id: "ws_main", name: "main", directory: Self.projectRoot, kind: "local_checkout"),
                Self.workspace(id: "ws_feature", name: "feature", directory: "/tmp/garbeo-fake/worktrees/feature", kind: "worktree"),
            ]
        case "fetch_agents_request":
            responseType = "fetch_agents_response"
            payload["entries"] = []
        case "list_available_providers_request":
            responseType = "list_available_providers_response"
            payload["providers"] = [
                ["provider": "claude", "available": true],
                ["provider": "codex", "available": true],
            ]
        case "list_provider_models_request":
            responseType = "list_provider_models_response"
            let provider = request["provider"] ?? "claude"
            payload["provider"] = provider
            payload["models"] = provider == "codex"
                ? [["provider": "codex", "id": "gpt-fake", "label": "GPT Fake", "isDefault": true]]
                : [
                    ["provider": "claude", "id": "haiku-fake", "label": "Haiku Fake", "isDefault": true],
                    ["provider": "claude", "id": "opus-fake", "label": "Opus Fake",
                     "thinkingOptions": [["id": "high", "label": "High"], ["id": "low", "label": "Low"]]],
                ]
        case "list_provider_modes_request":
            responseType = "list_provider_modes_response"
            payload["modes"] = [["id": "default", "label": "Ask"], ["id": "plan", "label": "Plan"]]
        case "create_agent_request":
            responseType = "status"
            createdAgents.append(.object(request))
            if let createAgentError {
                payload["status"] = "agent_create_failed"
                payload["error"] = .string(createAgentError)
            } else {
                payload["status"] = "agent_created"
                payload["agent"] = Self.agent(id: "agent_\(createdAgents.count)", from: request)
            }
        case "create_paseo_worktree_request":
            responseType = "create_paseo_worktree_response"
            createdWorktrees.append(.object(request))
            let slug = request["worktreeSlug"]?.stringValue ?? "worktree-\(createdWorktrees.count)"
            payload["workspace"] = Self.workspace(
                id: "ws_\(slug)", name: slug, directory: "/tmp/garbeo-fake/worktrees/\(slug)", kind: "worktree")
            payload["error"] = nil
            payload["setupTerminalId"] = nil
        case "archive_workspace_request":
            responseType = "archive_workspace_response"
            let workspaceId = request["workspaceId"] ?? ""
            archivedWorkspaces.append(workspaceId.stringValue ?? "")
            payload["workspaceId"] = workspaceId
            if let archiveWorkspaceError {
                payload["error"] = .string(archiveWorkspaceError)
            } else {
                payload["archivedAt"] = "2026-10-17T10:10:00Z"
            }
        case "fetch_agent_timeline_request":
            responseType = "fetch_agent_timeline_response"
            payload["agentId"] = request["agentId"] ?? ""
            payload["epoch"] = "e1"
            payload["entries"] = []
            payload["hasOlder"] = false
            payload["hasNewer"] = false
        default:
            // Subscriptions, terminal lists…: an empty response of the matching type.
            responseType = type.hasSuffix("_request") ? String(type.dropLast("_request".count)) + "_response" : type + ".response"
            payload["cwd"] = request["cwd"] ?? ""
            payload["terminals"] = []
            payload["entries"] = []
        }
        deliver(["type": "session", "message": ["type": .string(responseType), "payload": .object(payload)]])
    }

    private static func workspace(id: String, name: String, directory: String, kind: String) -> JSONValue {
        [
            "id": .string(id), "projectId": "proj_garbeo", "projectDisplayName": "garbeo", "projectRootPath": .string(projectRoot),
            "workspaceDirectory": .string(directory), "workspaceKind": .string(kind), "name": .string(name),
            "status": "done", "activityAt": id == "ws_main" ? "2026-10-17T10:00:00Z" : "2026-10-16T10:00:00Z",
        ]
    }

    private static func agent(id: String, from request: [String: JSONValue]) -> JSONValue {
        let config = request["config"] ?? [:]
        return [
            "id": .string(id), "provider": config["provider"] ?? "claude", "cwd": config["cwd"] ?? .string(projectRoot),
            "workspaceId": request["workspaceId"] ?? nil, "model": config["model"] ?? nil,
            "thinkingOptionId": config["thinkingOptionId"] ?? nil, "currentModeId": config["modeId"] ?? nil,
            "status": "idle", "title": request["initialPrompt"] ?? nil,
            "createdAt": "2026-10-17T10:05:00Z", "updatedAt": "2026-10-17T10:05:00Z",
            "availableModes": [["id": "default", "label": "Ask"], ["id": "plan", "label": "Plan"]],
        ]
    }
}
