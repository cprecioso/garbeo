import XCTest

/// Plugin entries in workspace menus, against the test daemon's Scripts/test-plugin, which is shaped
/// like paseo-gh-stack (#32): a "Fixture Panel" workspace panel, an "Open Fixture Panel" command that
/// only opens it, and a "Fixture: run action" command.
@MainActor
final class PluginMenuUITests: XCTestCase {
    private let panel = "Fixture Panel"
    private let commands = ["Open Fixture Panel", "Fixture: run action"]

    override func setUp() {
        continueAfterFailure = false
    }

    /// The Open Tab menu opens tabs, so it lists the panel once and none of the commands.
    func testOpenTabMenuListsPluginPanelsOnly() throws {
        #if os(macOS)
        let daemon = try LiveDaemon.require()
        try LiveDaemon.requirePlugins()
        let workspace = try LiveDaemon.requireWorkspace()
        let app = XCUIApplication.launchForTesting(daemon: daemon, arguments: ["-PaseoSelectWorkspace", workspace])

        let openTab = app.element(AccessibilityID.Workspace.openTabMenu)
        XCTAssertTrue(openTab.waitForExistence(timeout: 30), "The workspace didn't open")
        open(until: panel, in: app) { openTab.clickOrTap() }

        XCTAssertEqual(menuItemsOutsideMenuBar(panel, in: app), 1)
        for command in commands {
            XCTAssertEqual(menuItemsOutsideMenuBar(command, in: app), 0, "\"\(command)\" is a command, not a tab")
        }
        #else
        throw XCTSkip("The Open Tab menu is macOS only")
        #endif
    }

    /// A workspace's context menu keeps both the panel and the commands.
    func testWorkspaceContextMenuListsPanelsAndCommands() throws {
        #if os(macOS)
        let daemon = try LiveDaemon.require()
        try LiveDaemon.requirePlugins()
        let app = XCUIApplication.launchForTesting(daemon: daemon)

        let row = app.element(AccessibilityID.Sidebar.workspaceRow)
        XCTAssertTrue(row.waitForExistence(timeout: 30), "The sidebar has no workspace")
        open(until: panel, in: app) { row.rightClick() }

        for command in commands {
            XCTAssertEqual(menuItemsOutsideMenuBar(command, in: app), 1, "\"\(command)\" is missing from the context menu")
        }
        #else
        throw XCTSkip("Context menus are covered on macOS")
        #endif
    }

    #if os(macOS)
    /// Menu items titled `title` in open menus. The menu bar's Plugins menu lists the selected
    /// workspace's panels and commands too, and its items count even while it's closed.
    private func menuItemsOutsideMenuBar(_ title: String, in app: XCUIApplication) -> Int {
        app.menuItems.matching(identifier: title).count - app.menuBars.menuItems.matching(identifier: title).count
    }

    /// Opens a menu until its `item` shows up: plugin contributions arrive once the app's registry page
    /// has run the plugin's client bundle.
    private func open(until item: String, in app: XCUIApplication, with show: () -> Void) {
        let deadline = Date.now.addingTimeInterval(30)
        repeat {
            show()
            if app.menuItems[item].waitForExistence(timeout: 2), menuItemsOutsideMenuBar(item, in: app) > 0 { return }
            app.typeKey(.escape, modifierFlags: [])
        } while Date.now < deadline
        XCTFail("\"\(item)\" never appeared in the menu")
    }
    #endif
}
