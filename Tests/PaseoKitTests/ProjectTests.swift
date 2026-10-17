import Foundation
import Testing
@testable import PaseoKit

@Suite struct ProjectTests {
    @Test func parsesPaths() {
        #expect(ProjectPath.parse("  /srv/repo/ \n") == .success(ProjectPath(path: "/srv/repo")))
        #expect(ProjectPath.parse("~/code/app") == .success(ProjectPath(path: "~/code/app")))
        #expect(ProjectPath.parse("~") == .success(ProjectPath(path: "~")))
        #expect(ProjectPath.parse("/") == .success(ProjectPath(path: "/")))
        #expect(ProjectPath.parse("   ") == .failure(.empty))
        #expect(ProjectPath.parse("code/app") == .failure(.notAbsolute))
        #expect(ProjectPath.parse("~someone/app") == .failure(.notAbsolute))
    }

    @Test func defaultName() {
        #expect(ProjectPath(path: "/srv/my-repo").defaultName == "my-repo")
        #expect(ProjectPath(path: "~/code/app").defaultName == "app")
    }

    @Test func encodesRequests() {
        #expect(DaemonClient.openProjectMessage(ProjectPath(path: "~/repo")) == [
            "type": "open_project_request", "cwd": "~/repo",
        ])
        #expect(DaemonClient.renameProjectMessage(projectId: "p1", name: "  My App ") == [
            "type": "project.rename.request", "projectId": "p1", "customName": "My App",
        ])
        #expect(DaemonClient.renameProjectMessage(projectId: "p1", name: " ")["customName"] == .null)
        #expect(DaemonClient.directorySuggestionsMessage(query: "~/co", limit: 8) == [
            "type": "directory_suggestions_request", "query": "~/co",
            "includeDirectories": true, "includeFiles": false, "limit": 8,
        ])
    }

    @Test func decodesOpenProjectResponse() throws {
        let opened = try JSONDecoder().decode(SessionFrame<OpenProjectResponse>.self, from: Data("""
        {"type":"session","message":{"type":"open_project_response","payload":{"requestId":"r",
          "workspace":{"id":"w1","projectId":"p1","projectDisplayName":"repo","projectRootPath":"/srv/repo",
            "workspaceDirectory":"/srv/repo","projectKind":"git","workspaceKind":"local_checkout",
            "name":"main","status":"done","statusEnteredAt":null},
          "error":null}}}
        """.utf8)).message.payload
        #expect(opened.workspace?.id == "w1")
        #expect(opened.workspace?.projectName == "repo")

        let missing = try JSONDecoder().decode(SessionFrame<OpenProjectResponse>.self, from: Data("""
        {"type":"session","message":{"type":"open_project_response","payload":{"requestId":"r",
          "workspace":null,"error":"Directory not found: /nope","errorCode":"directory_not_found"}}}
        """.utf8)).message.payload
        #expect(missing.workspace == nil)
        #expect(missing.error == "Directory not found: /nope")
        #expect(missing.errorCode == "directory_not_found")
    }

    @Test func decodesRenameAndSuggestions() throws {
        let renamed = try JSONDecoder().decode(SessionFrame<ProjectRenameResponse>.self, from: Data("""
        {"type":"session","message":{"type":"project.rename.response","payload":{"requestId":"r","projectId":"p1",
          "accepted":false,"customName":null,"error":"Project not found"}}}
        """.utf8)).message.payload
        #expect(!renamed.accepted)
        #expect(renamed.error == "Project not found")

        let suggestions = try JSONDecoder().decode(SessionFrame<DirectorySuggestionsResponse>.self, from: Data("""
        {"type":"session","message":{"type":"directory_suggestions_response","payload":{"requestId":"r",
          "directories":["/home/me/code","/home/me/code/app"],
          "entries":[{"path":"/home/me/code","kind":"directory"},{"path":"/home/me/code/app","kind":"directory"}],
          "error":null}}}
        """.utf8)).message.payload
        #expect(suggestions.directories == ["/home/me/code", "/home/me/code/app"])
    }
}

/// Adds, renames and removes a project made from a fresh temporary directory. The daemon must run
/// on this machine to see that directory, and it changes the daemon's state, so it only runs against
/// a throwaway one: `PASEO_LIVE_URL` plus `PASEO_LIVE_THROWAWAY=1` (`Scripts/with-test-daemon.sh`).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PASEO_LIVE_URL"] != nil
    && ProcessInfo.processInfo.environment["PASEO_LIVE_THROWAWAY"] == "1"))
struct LiveProjectTests {
    @Test(.timeLimit(.minutes(1))) func openRenameRemove() async throws {
        let env = ProcessInfo.processInfo.environment
        let client = DaemonClient(
            endpoint: DaemonEndpoint(url: env["PASEO_LIVE_URL"]!, password: env["PASEO_PASSWORD"]),
            clientId: "garbeo-tests-projects")
        try await client.connect()
        defer { Task { await client.disconnect() } }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("garbeo-project-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let path = try ProjectPath.parse(directory.path + "/").get()
        let workspace = try await client.openProject(path)
        print("live-project: opened \(workspace.projectId) as workspace \(workspace.id)")
        // The daemon resolves symlinks such as /var → /private/var.
        #expect(workspace.workspaceDirectory.hasSuffix(directory.lastPathComponent))

        // Opening the same directory again finds the same workspace.
        #expect(try await client.openProject(path).id == workspace.id)

        do {
            #expect(try await client.renameProject(projectId: workspace.projectId, to: " Garbeo test ") == "Garbeo test")
            #expect(try await client.renameProject(projectId: workspace.projectId, to: nil) == nil)
        } catch {
            _ = try? await client.requestData(["type": "project.remove.request", "projectId": .string(workspace.projectId)])
            throw error
        }
        _ = try await client.requestData(["type": "project.remove.request", "projectId": .string(workspace.projectId)])

        await #expect(throws: PaseoError.rpc("Directory not found: \(directory.path)/missing")) {
            _ = try await client.openProject(ProjectPath(path: directory.path + "/missing"))
        }
        let suggestions = try await client.directorySuggestions(query: "/", limit: 5)
        #expect(suggestions.allSatisfy { $0.hasPrefix("/") })
    }
}
