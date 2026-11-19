import XCTest
final class ReleaseLaunchTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }
    func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
    func testReleaseOnboardingSetupAndRelaunch() {
        let app = XCUIApplication(bundleIdentifier: "com.ppanphper.roamcontrol")
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-hasCompletedOnboarding", "NO", "-movementAndInterfacePreferences.v1", "release-launch-test"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(app.buttons["Continue"].waitForExistence(timeout: 10))
        capture(app, "release-first-launch")
        for _ in 0..<3 { app.buttons["Continue"].tap() }
        XCTAssertTrue(app.buttons["Set Up This iPhone"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Restore an Existing Backup"].exists)
        capture(app, "release-onboarding-last-page")
        app.buttons["Set Up This iPhone"].tap()
        XCTAssertTrue(app.navigationBars["Device Setup"].waitForExistence(timeout: 10))
        capture(app, "release-device-setup")
        app.buttons["Import Existing File"].tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 10))
        capture(app, "release-pairing-copy-import")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Device Setup"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 5))
        app.terminate()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-movementAndInterfacePreferences.v1", "release-launch-test"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Continue"].exists)
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        capture(app, "release-relaunch-settings")
    }
}
