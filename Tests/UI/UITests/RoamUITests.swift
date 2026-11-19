import XCTest
final class RoamUITests: XCTestCase {
    private let bundleID = "com.ppanphper.roamcontrol"
    override func setUp() { continueAfterFailure = false }
    func app(_ flags: [String] = []) -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: bundleID)
        app.launchArguments = ["-hasCompletedOnboarding", "YES", "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-movementAndInterfacePreferences.v1", "UI-test-argument-domain"] + flags
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        // Release deliberately ignores Debug navigation flags. Exercise the real entry instead.
        if flags.contains("--show-settings"), !app.navigationBars["Settings"].exists {
            XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 10))
            app.buttons["Settings"].tap()
        }
        return app
    }
    func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    func testHomeAndSettings() {
        let app = app(["--show-settings"])
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 15))
        shot(app, "settings-english")
        let movement = app.buttons["Movement & Coordinates"]
        if !movement.isHittable { app.swipeUp() }
        XCTAssertTrue(movement.waitForExistence(timeout: 5))
        movement.tap()
        XCTAssertTrue(app.navigationBars["Movement & Coordinates"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.sliders.count == 3)
        shot(app, "movement-preferences")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let backup = app.buttons["Backup & Restore"]
        if !backup.isHittable { app.swipeUp() }
        backup.tap()
        XCTAssertTrue(app.buttons["Create Backup"].waitForExistence(timeout: 5))
        app.buttons["Create Backup"].tap()
        XCTAssertTrue(app.buttons["Save or Share Backup"].waitForExistence(timeout: 5))
        shot(app, "backup-created")
    }
    func testMapRouteAndJoystick() {
        let app = app()
        XCTAssertTrue(app.buttons["Location mode"].waitForExistence(timeout: 15) || app.buttons["Route"].exists)
        shot(app, "home-english")
        if !app.buttons["Route"].exists { app.buttons["Location mode"].tap() }
        app.buttons["Route"].tap()
        shot(app, "route-controls")
        if !app.buttons["Joystick"].exists { app.buttons["Location mode"].tap() }
        XCTAssertTrue(app.buttons["Joystick"].waitForExistence(timeout: 5))
        app.buttons["Joystick"].tap()
        shot(app, "joystick-preview")
    }
    func testLanguageSwitchAndRTL() {
        let app = app(["--show-settings"])
        let language = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Language")).firstMatch
        XCTAssertTrue(language.waitForExistence(timeout: 10))
        language.tap()
        app.buttons["简体中文"].tap()
        XCTAssertTrue(app.navigationBars["语言"].waitForExistence(timeout: 5))
        shot(app, "language-chinese-immediate")
        app.buttons["العربية"].tap()
        XCTAssertTrue(app.navigationBars["اللغة"].waitForExistence(timeout: 5))
        let back = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in back.frame.midX > app.frame.midX }, object: nil)], timeout: 5), .completed)
        shot(app, "language-arabic-rtl")
        app.buttons["English"].tap()
        XCTAssertTrue(app.navigationBars["Language"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
    }

    func testPointRouteAndGPXPicker() {
        let app = app()
        if !app.buttons["Route"].exists { app.buttons["Location mode"].tap() }
        app.buttons["Route"].tap()
        app.buttons["Route source"].tap()
        app.buttons["Draw by Points"].tap()
        XCTAssertFalse(app.buttons["Preview Route"].isEnabled)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.3)).tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.52, dy: 0.38)).tap()
        shot(app, "point-route-two-taps")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: app.buttons["Preview Route"])], timeout: 5), .completed)
        app.buttons["Undo"].tap()
        app.buttons["Clear Route"].tap()
        XCTAssertFalse(app.buttons["Preview Route"].isEnabled)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.3)).tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.4)).tap()
        app.buttons["Preview Route"].tap()
        XCTAssertTrue(app.buttons["Export GPX"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Arrive at")).firstMatch.waitForExistence(timeout: 5))
        shot(app, "point-route-preview")
        app.buttons["Edit Route"].tap()
        app.buttons["Route source"].tap()
        app.buttons["GPX File"].tap()
        app.buttons["Import GPX"].tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 10))
        shot(app, "gpx-document-picker")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Import GPX"].waitForExistence(timeout: 5))
    }

    func testLargeTextControls() {
        let app = app(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        XCTAssertTrue(app.buttons["Location mode"].waitForExistence(timeout: 15))
        shot(app, "home-accessibility-large")
        app.buttons["Location mode"].tap()
        app.buttons["Route"].tap()
        shot(app, "route-accessibility-large")
    }

    func testCopyReadableLocation() {
        let app = app()
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("51.5, -0.12\n")
        XCTAssertTrue(app.buttons["Copy location"].waitForExistence(timeout: 10))
        app.buttons["Copy location"].tap()
        XCTAssertTrue(app.buttons["Location copied"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Share coordinates"].exists)
        shot(app, "readable-location-copied")
    }

    func testDarkFreehandAndCollapse() {
        let app = app(["--show-settings"])
        XCTAssertTrue(app.buttons["Dark"].waitForExistence(timeout: 10))
        app.buttons["Dark"].tap()
        app.buttons["Done"].tap()
        if !app.buttons["Route"].exists { app.buttons["Location mode"].tap() }
        app.buttons["Route"].tap()
        app.buttons["Route source"].tap()
        app.buttons["Freehand"].tap()
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.36))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.43))
        start.press(forDuration: 0.1, thenDragTo: end)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: app.buttons["Preview Route"])], timeout: 5), .completed)
        app.buttons["Undo"].tap()
        XCTAssertFalse(app.buttons["Preview Route"].isEnabled)
        start.press(forDuration: 0.1, thenDragTo: end)
        app.buttons["Preview Route"].tap()
        XCTAssertTrue(app.buttons["Export GPX"].waitForExistence(timeout: 5))
        shot(app, "freehand-preview-dark")
        app.buttons["Collapse location controls"].tap()
        XCTAssertTrue(app.buttons["Expand location controls"].waitForExistence(timeout: 5))
        shot(app, "route-collapsed-dark")
        app.buttons["Expand location controls"].tap()
        XCTAssertTrue(app.buttons["Export GPX"].waitForExistence(timeout: 5))
        app.buttons["Settings"].tap()
        app.buttons["Auto"].tap()
        app.buttons["Done"].tap()
    }

}
