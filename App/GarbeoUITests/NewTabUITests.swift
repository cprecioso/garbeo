import XCTest

/// ⌘T (#38): the Open Tab menu of the focused window's workspace (macOS), or a new terminal there (iOS).
@MainActor
final class NewTabUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testFileMenuOffersANewTabOnlyOnceConnected() throws {
        #if os(macOS)
        let app = XCUIApplication.launchForTesting()
        XCTAssertTrue(app.element(AccessibilityID.Connect.screen).waitForExistence(timeout: 30))
        app.menuBars.menuBarItems["File"].click()
        let item = app.menuBars.menuItems["New Tab…"]
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        XCTAssertFalse(item.isEnabled, "Nothing to open a tab in before connecting")
        app.typeKey(.escape, modifierFlags: [])
        #else
        throw XCTSkip("The menu bar is macOS only")
        #endif
    }

    func testCommandTOpensATerminalFromTheSelectedWorkspace() throws {
        #if os(iOS)
        // Commands' keyboard shortcuts are an iPad (and Mac) thing; CI runs on an iPhone.
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("⌘T needs an iPad") }
        #endif
        let daemon = try LiveDaemon.requireThrowaway()
        let workspace = try LiveDaemon.requireWorkspace()
        let app = XCUIApplication.launchForTesting(daemon: daemon, arguments: ["-PaseoSelectWorkspace", workspace])
        #if os(macOS)
        XCTAssertTrue(app.element(AccessibilityID.Workspace.view).waitForExistence(timeout: 30))
        #else
        // iOS has no workspace view; the selection lands with the sidebar.
        XCTAssertTrue(app.element(AccessibilityID.Sidebar.list).waitForExistence(timeout: 30))
        sleep(2)
        #endif
        let terminal = app.element(AccessibilityID.Terminal.view)
        XCTAssertFalse(terminal.exists)

        app.typeKey("t", modifierFlags: .command)

        #if os(macOS)
        // ⌘T shows the Open Tab menu; its New Terminal item opens the terminal.
        let newTerminal = app.menuItems["New Terminal"]
        XCTAssertTrue(newTerminal.waitForExistence(timeout: 5), "⌘T didn't show the Open Tab menu")
        newTerminal.click()
        #endif
        XCTAssertTrue(terminal.waitForExistence(timeout: 30))
    }
}
