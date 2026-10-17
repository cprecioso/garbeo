import XCTest

/// The daemon UI tests that need one connect to: `PASEO_LIVE_URL` (`host:port`), the same variable as
/// PaseoKit's live tests. xcodebuild hands it to the test runner as `TEST_RUNNER_PASEO_LIVE_URL`;
/// `mise run //App:test:ui:*` starts a throwaway daemon and does that (`Scripts/with-test-daemon.sh`).
enum LiveDaemon {
    static var url: String? {
        ProcessInfo.processInfo.environment["PASEO_LIVE_URL"].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The daemon's address, or skips the test when `PASEO_LIVE_URL` isn't set.
    static func require() throws -> String {
        guard let url else { throw XCTSkip("Set PASEO_LIVE_URL to run against a daemon") }
        return url
    }

    /// Whether the daemon is a throwaway one (`PASEO_LIVE_THROWAWAY=1`, set by `with-test-daemon.sh`).
    static var isThrowaway: Bool { ProcessInfo.processInfo.environment["PASEO_LIVE_THROWAWAY"] == "1" }

    /// Like `require()`, but also skips unless the daemon is a throwaway one; for tests that create,
    /// change or archive things on it.
    static func requireThrowaway() throws -> String {
        let url = try require()
        guard isThrowaway else { throw XCTSkip("Changes the daemon's state; set PASEO_LIVE_THROWAWAY=1 if that's fine") }
        return url
    }

    /// Skips unless the daemon has Scripts/test-plugin installed (`PASEO_LIVE_PLUGINS=1`, set by
    /// `with-test-daemon.sh`): a workspace panel "Fixture Panel", a command "Open Fixture Panel" that only
    /// opens it, and a command "Fixture: run action".
    static func requirePlugins() throws {
        guard ProcessInfo.processInfo.environment["PASEO_LIVE_PLUGINS"] == "1" else {
            throw XCTSkip("Needs Scripts/test-plugin installed; set PASEO_LIVE_PLUGINS=1 if it is")
        }
    }

    /// The workspace `with-test-daemon.sh` created (`PASEO_LIVE_WORKSPACE`), or skips the test.
    static func requireWorkspace() throws -> String {
        guard let id = ProcessInfo.processInfo.environment["PASEO_LIVE_WORKSPACE"], !id.isEmpty else {
            throw XCTSkip("Set PASEO_LIVE_WORKSPACE to a workspace id")
        }
        return id
    }
}
