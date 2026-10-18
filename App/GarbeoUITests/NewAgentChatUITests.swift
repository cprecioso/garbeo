import XCTest

/// New Agent opens a chat for the agent right away; the first message creates it.
@MainActor
final class NewAgentChatUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// Launches connected to the test daemon and presses the sidebar's New Agent, so the chat opens in
    /// the daemon's only workspace. Nothing is selected first: on iPhone a selection pushes the detail
    /// over the sidebar and its toolbar.
    private func openNewAgent(daemon: String) throws -> XCUIApplication {
        _ = try LiveDaemon.requireWorkspace()
        let app = XCUIApplication.launchForTesting(daemon: daemon)
        let newAgent = app.element(AccessibilityID.Sidebar.newAgent)
        XCTAssertTrue(newAgent.waitForExistence(timeout: 30))
        newAgent.clickOrTap()
        XCTAssertTrue(app.element(AccessibilityID.NewAgent.placeholder).waitForExistence(timeout: 10))
        return app
    }

    func testNewAgentOpensChatWithFocusedComposer() throws {
        let app = try openNewAgent(daemon: try LiveDaemon.require())

        XCTAssertEqual(app.sheets.count, 0, "no New Agent sheet")
        let composer = app.element(AccessibilityID.Composer.field)
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        let focused = NSPredicate(format: "hasKeyboardFocus == true")
        expectation(for: focused, evaluatedWith: composer)
        waitForExpectations(timeout: 5)
        for option in [AccessibilityID.NewAgent.workspace, AccessibilityID.NewAgent.provider, AccessibilityID.NewAgent.model] {
            XCTAssertTrue(app.element(option).exists, option)
        }
        XCTAssertFalse(app.element(AccessibilityID.Composer.send).isEnabled, "nothing to send yet")
    }

    func testCommandNOpensChatAsWorkspaceTab() throws {
        #if os(macOS)
        let workspace = try LiveDaemon.requireWorkspace()
        let app = XCUIApplication.launchForTesting(daemon: try LiveDaemon.require(), arguments: ["-PaseoSelectWorkspace", workspace])
        let workspaceView = app.element(AccessibilityID.Workspace.view)
        XCTAssertTrue(workspaceView.waitForExistence(timeout: 30))

        app.typeKey("n", modifierFlags: .command)

        XCTAssertTrue(app.element(AccessibilityID.NewAgent.placeholder).waitForExistence(timeout: 10))
        XCTAssertTrue(workspaceView.exists, "the chat opens among the workspace's tabs, not instead of them")
        XCTAssertTrue(app.element(AccessibilityID.Workspace.openTabMenu).exists)
        #else
        throw XCTSkip("Workspace tabs are macOS only")
        #endif
    }

    func testFirstMessageCreatesTheAgent() throws {
        let app = try openNewAgent(daemon: try LiveDaemon.requireThrowaway())
        let prompt = "Reply with exactly the single word: pong. Do not use any tools."

        app.element(AccessibilityID.Composer.field).replaceText(prompt)
        let send = app.element(AccessibilityID.Composer.send)
        // Send needs a provider, and the daemon may have none it can run.
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: send)
        guard XCTWaiter.wait(for: [enabled], timeout: 15) == .completed else {
            throw XCTSkip("The test daemon has no available agent provider")
        }
        send.clickOrTap()

        XCTAssertTrue(app.element(AccessibilityID.NewAgent.placeholder).waitForNonExistence(timeout: 60),
                      app.element(AccessibilityID.NewAgent.error).exists ? app.element(AccessibilityID.NewAgent.error).label : "")
        XCTAssertTrue(app.staticTexts[prompt].firstMatch.waitForExistence(timeout: 30), "the new agent's chat shows the message")
        XCTAssertTrue(app.element(AccessibilityID.Composer.field).exists)
    }

    func testProfileIsOfferedAndApplies() throws {
        try LiveDaemon.requireProfiles()
        let app = try openNewAgent(daemon: try LiveDaemon.require())

        let picker = app.element(AccessibilityID.NewAgent.profile)
        XCTAssertTrue(picker.waitForExistence(timeout: 10), "the daemon's profiles are offered")
        picker.clickOrTap()
        let item = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ OR title == %@",
            "UI Test Profile", "UI Test Profile")).element(boundBy: 0)
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.clickOrTap()

        let applied = NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", "UI Test Profile", "UI Test Profile")
        expectation(for: applied, evaluatedWith: picker)
        waitForExpectations(timeout: 5)
    }
}
