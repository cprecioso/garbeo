import XCTest

/// The New Project sheet against the test daemon, which runs on this machine and so sees the
/// temporary directory the test adds as a project.
@MainActor
final class NewProjectUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    #if os(macOS)
    func testMenuCommandOpensTheSheet() throws {
        let app = XCUIApplication.launchForTesting(daemon: try LiveDaemon.require())
        XCTAssertTrue(app.element(AccessibilityID.Sidebar.list).waitForExistence(timeout: 30))

        app.menuBars.menuBarItems["File"].clickOrTap()
        app.menuBars.menuItems["New Project…"].clickOrTap()
        let path = app.element(AccessibilityID.NewProject.path)
        XCTAssertTrue(path.waitForExistence(timeout: 5))
        app.buttons["Cancel"].clickOrTap()
        XCTAssertTrue(path.waitForNonExistence(timeout: 5))
    }
    #endif

    func testValidatesCreatesAndShowsTheProject() throws {
        let app = XCUIApplication.launchForTesting(daemon: try LiveDaemon.requireThrowaway())
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("garbeo-ui-\(UUID().uuidString.prefix(8).lowercased())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let projectName = "UI Test \(directory.lastPathComponent.suffix(8))"

        let newProject = app.element(AccessibilityID.Sidebar.newProject)
        XCTAssertTrue(newProject.waitForExistence(timeout: 30))
        newProject.clickOrTap()

        let path = app.element(AccessibilityID.NewProject.path)
        let create = app.element(AccessibilityID.NewProject.create)
        let error = app.element(AccessibilityID.NewProject.error)
        XCTAssertTrue(path.waitForExistence(timeout: 5))
        XCTAssertFalse(create.isEnabled, "Create is enabled without a path")

        // A relative path is rejected before reaching the daemon.
        path.replaceText("relative/dir")
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertFalse(create.isEnabled)

        // A missing directory is reported by the daemon, inline, and the sheet stays open.
        path.replaceText("/garbeo-ui-missing-\(UUID().uuidString.prefix(8).lowercased())")
        XCTAssertTrue(error.waitForNonExistence(timeout: 5))
        create.clickOrTap()
        XCTAssertTrue(text("Directory not found", in: app).waitForExistence(timeout: 15))
        XCTAssertTrue(path.exists)

        // A real directory with a name adds the project and lists it in the sidebar.
        app.element(AccessibilityID.NewProject.name).replaceText(projectName)
        path.replaceText(directory.path)
        create.clickOrTap()
        // On macOS the click can go to dismissing the path's suggestions; adding is idempotent.
        if !path.waitForNonExistence(timeout: 5), create.exists, create.isEnabled { create.clickOrTap() }
        XCTAssertTrue(path.waitForNonExistence(timeout: 15), "the sheet stayed open")

        #if os(iOS)
        // Compact layouts may show the (empty) detail for the selected workspace; go back to the sidebar.
        let sidebar = app.element(AccessibilityID.Sidebar.list)
        if !sidebar.waitForExistence(timeout: 2) || !sidebar.isHittable {
            app.navigationBars.buttons.element(boundBy: 0).clickOrTap()
        }
        #endif
        XCTAssertTrue(text(projectName, in: app).waitForExistence(timeout: 15), "the project isn't in the sidebar")
        #if os(macOS)
        // Selecting its workspace opens it in place of the empty detail.
        XCTAssertTrue(app.element(AccessibilityID.Detail.empty).waitForNonExistence(timeout: 10), "its workspace isn't selected")
        #endif
    }

    /// Static text containing `string`: macOS exposes a text's contents as its value, iOS as its label.
    private func text(_ string: String, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", string, string)).firstMatch
    }
}
