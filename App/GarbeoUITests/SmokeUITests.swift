import XCTest

@MainActor
final class SmokeUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testLaunchesOnTheConnectScreen() {
        let app = XCUIApplication.launchForTesting()
        XCTAssertTrue(app.element(AccessibilityID.Connect.screen).waitForExistence(timeout: 30))
        XCTAssertTrue(app.element(AccessibilityID.Connect.address).exists)
        XCTAssertTrue(app.element(AccessibilityID.Connect.connectButton).exists)
    }

    func testConnectsOnLaunchAndShowsTheSidebar() throws {
        let app = XCUIApplication.launchForTesting(daemon: try LiveDaemon.require())
        XCTAssertTrue(app.element(AccessibilityID.Sidebar.list).waitForExistence(timeout: 30))
    }

    func testConnectsFromTheConnectScreen() throws {
        let url = try LiveDaemon.require()
        let app = XCUIApplication.launchForTesting()
        let address = app.element(AccessibilityID.Connect.address)
        XCTAssertTrue(address.waitForExistence(timeout: 30))
        address.replaceText(url)
        app.element(AccessibilityID.Connect.connectButton).tap()
        XCTAssertTrue(app.element(AccessibilityID.Sidebar.list).waitForExistence(timeout: 30))
    }
}
