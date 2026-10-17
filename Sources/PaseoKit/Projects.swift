import Foundation

// Adding projects from a directory on the daemon's machine, renaming them, and directory
// suggestions for picking that directory (packages/protocol/src/messages.ts).

/// A project directory as typed by the user: an absolute path on the daemon's machine, or one
/// under its home directory (`~/…`), which the daemon expands.
public struct ProjectPath: Sendable, Hashable {
    public enum Problem: LocalizedError, Sendable, Hashable {
        case empty
        /// Relative paths would resolve against the daemon's working directory.
        case notAbsolute

        public var errorDescription: String? {
            switch self {
            case .empty: "Enter the project's directory."
            case .notAbsolute: "Enter a full path, starting with / or ~/."
            }
        }
    }

    public var path: String

    /// The trimmed path, or the reason it can't be sent. Trailing slashes are dropped.
    public static func parse(_ input: String) -> Result<ProjectPath, Problem> {
        var path = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return .failure(.empty) }
        guard path.hasPrefix("/") || path == "~" || path.hasPrefix("~/") else { return .failure(.notAbsolute) }
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return .success(ProjectPath(path: path))
    }

    /// The last path component, the name the daemon derives for the project by default.
    public var defaultName: String { (path as NSString).lastPathComponent }
}

struct OpenProjectResponse: Decodable {
    var workspace: Workspace?
    var error: String?
    var errorCode: String?
}

struct ProjectRenameResponse: Decodable {
    var accepted: Bool
    var customName: String?
    var error: String?
}

struct DirectorySuggestionsResponse: Decodable {
    var directories: [String]
    var error: String?
}

extension DaemonClient {
    /// Adds the directory at `path` on the daemon's machine as a project (or finds the project it
    /// already belongs to) and returns its workspace for that directory.
    public func openProject(_ path: ProjectPath) async throws -> Workspace {
        let response = try await request(Self.openProjectMessage(path), as: OpenProjectResponse.self)
        guard let workspace = response.workspace else {
            throw PaseoError.rpc(response.error ?? "The project could not be added")
        }
        return workspace
    }

    /// Sets the project's display name; nil or empty reverts to the name derived from its directory.
    /// Returns the name now in effect.
    @discardableResult
    public func renameProject(projectId: String, to name: String?) async throws -> String? {
        let response = try await request(
            Self.renameProjectMessage(projectId: projectId, name: name), as: ProjectRenameResponse.self)
        guard response.accepted else { throw PaseoError.rpc(response.error ?? "The project could not be renamed") }
        return response.customName
    }

    /// Absolute paths of directories on the daemon's machine matching `query` (a path, `~/…`, or
    /// part of a directory name under the home directory).
    public func directorySuggestions(query: String, limit: Int = 20) async throws -> [String] {
        let response = try await request(
            Self.directorySuggestionsMessage(query: query, limit: limit), as: DirectorySuggestionsResponse.self)
        if let error = response.error { throw PaseoError.rpc(error) }
        return response.directories
    }

    static func openProjectMessage(_ path: ProjectPath) -> [String: JSONValue] {
        ["type": "open_project_request", "cwd": .string(path.path)]
    }

    static func renameProjectMessage(projectId: String, name: String?) -> [String: JSONValue] {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return [
            "type": "project.rename.request", "projectId": .string(projectId),
            "customName": trimmed.isEmpty ? .null : .string(trimmed),
        ]
    }

    static func directorySuggestionsMessage(query: String, limit: Int) -> [String: JSONValue] {
        [
            "type": "directory_suggestions_request", "query": .string(query),
            "includeDirectories": true, "includeFiles": false, "limit": .number(Double(limit)),
        ]
    }
}
