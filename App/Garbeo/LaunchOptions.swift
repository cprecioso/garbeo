import Foundation

/// Launch arguments that isolate the app for tests (DEBUG builds only). UI tests set them through
/// `XCUIApplication.launchForTesting(…)` in `GarbeoUITests/Harness`.
enum LaunchOptions {
    /// Unit tests (`GarbeoTests`) run inside the app.
    static let isHostingUnitTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    /// `-GarbeoEphemeral YES`, and always while hosting unit tests: settings start empty and live in a
    /// throwaway domain (`UserDefaults.app`), and secrets stay in memory (`Keychain`), so the app
    /// neither sees nor changes the user's saved hosts, tab layouts or passwords.
    static let isEphemeral: Bool = {
        #if DEBUG
        isHostingUnitTests || UserDefaults.standard.bool(forKey: "GarbeoEphemeral")
        #else
        false
        #endif
    }()

    /// `-PaseoConnect <address>`: connects directly to that daemon on launch.
    static var connectAddress: String? {
        #if DEBUG
        UserDefaults.standard.string(forKey: "PaseoConnect")
        #else
        nil
        #endif
    }
}

extension UserDefaults {
    /// Where the app keeps its settings (saved hosts, client ID, tab layouts). Launch arguments are
    /// still read from `.standard`.
    /// `UserDefaults` is thread-safe, but not marked `Sendable`.
    nonisolated(unsafe) static let app: UserDefaults = {
        guard LaunchOptions.isEphemeral else { return .standard }
        let suite = "design.precioso.garbeo.ephemeral"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        return UserDefaults(suiteName: suite)!
    }()
}
