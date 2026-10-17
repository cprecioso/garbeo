import XCTest

extension XCUIApplication {
    /// Launches the app isolated from the user's state: settings start empty and secrets stay in memory
    /// (`-GarbeoEphemeral YES`, see `LaunchOptions`). With `daemon`, it connects there on launch
    /// (`-PaseoConnect`); pass `LiveDaemon.require()` for the CI test daemon. `arguments` are appended
    /// after those, e.g. the debug aids in the README (`-PaseoSelectWorkspace first`).
    @MainActor @discardableResult
    static func launchForTesting(
        daemon: String? = nil, arguments: [String] = [], environment: [String: String] = [:]
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-GarbeoEphemeral", "YES"]
        if let daemon { app.launchArguments += ["-PaseoConnect", daemon] }
        app.launchArguments += arguments
        app.launchEnvironment.merge(environment) { $1 }
        app.launch()
        return app
    }

    /// The first element with this accessibility identifier (see `AccessibilityID`), whatever its type.
    @MainActor
    func element(_ identifier: String) -> XCUIElement {
        descendants(matching: .any)[identifier].firstMatch
    }
}

extension XCUIElement {
    /// Clicks on macOS, where `tap()` doesn't press SwiftUI buttons, and taps on iOS.
    @MainActor
    func clickOrTap() {
        #if os(macOS)
        click()
        #else
        tap()
        #endif
    }

    /// Replaces a text field's contents with `text`.
    @MainActor
    func replaceText(_ text: String) {
        #if os(macOS)
        click()
        typeKey("a", modifierFlags: .command)
        #else
        // Tapping past the end puts the cursor after the current text.
        coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
        let current = value as? String ?? ""
        typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        #endif
        typeText(text)
    }
}
