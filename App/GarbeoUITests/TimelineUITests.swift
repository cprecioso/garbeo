import XCTest

/// Creates a real (cheap) agent through the New Agent sheet, so besides a throwaway daemon it needs
/// `PASEO_LIVE_WRITE=1` and a provider the daemon can run, like PaseoKit's write tests. It skips on CI,
/// whose daemon has no provider credentials.
@MainActor
final class TimelineUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testToolCallsCollapseIntoOneRow() throws {
        let url = try LiveDaemon.requireThrowaway()
        _ = try LiveDaemon.requireWorkspace()
        guard ProcessInfo.processInfo.environment["PASEO_LIVE_WRITE"] == "1" else {
            throw XCTSkip("Creates a real agent; set PASEO_LIVE_WRITE=1 if that's fine")
        }
        let app = XCUIApplication.launchForTesting(daemon: url)
        XCTAssertTrue(app.element(AccessibilityID.Sidebar.list).waitForExistence(timeout: 30))

        // The sheet picks the daemon's only workspace and its first available provider.
        app.buttons["New Agent"].firstMatch.clickOrTap()
        let prompt = app.element(AccessibilityID.AgentFields.prompt)
        XCTAssertTrue(prompt.waitForExistence(timeout: 10))
        // Glob runs without asking for permission.
        prompt.replaceText("Use the Glob tool to list *.md files, then use it again to list *.swift files, then reply with exactly: done")
        let create = app.element(AccessibilityID.NewAgent.createButton)
        let enabled = expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: create)
        guard XCTWaiter.wait(for: [enabled], timeout: 30) == .completed else {
            throw XCTSkip("The daemon has no available provider")
        }
        create.clickOrTap()

        // The reply ends the run of tool calls, which then collapses.
        let reply = app.staticTexts.matching(NSPredicate(format: "label MATCHES[c] %@", "done\\.?")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 180), "The agent should reply")
        let group = app.element(AccessibilityID.Timeline.activityGroup)
        XCTAssertTrue(group.waitForExistence(timeout: 10), "The tool calls collapse into one row")
        XCTAssertTrue(group.label.contains("tool calls"), group.label)
        let calls = app.descendants(matching: .any).matching(identifier: AccessibilityID.Timeline.toolCall)
        XCTAssertEqual(calls.count, 0, "The tool calls are hidden while collapsed")

        group.clickOrTap()
        XCTAssertTrue(calls.firstMatch.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(calls.count, 2)

        group.clickOrTap()
        XCTAssertTrue(calls.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertTrue(reply.exists, "The reply stays visible")
    }
}
