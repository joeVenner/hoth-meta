import XCTest

/// Settings "Reset app": the confirmation dialog runs the reset and the app rebuilds on the feed.
/// Offline (demo mode, in-memory store, no key so the remove-key option is hidden).
final class ResetAppUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testResetAppReturnsToFeed() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "-hoth.onboarding.done", "YES",
            "-hoth.settings.demoMode", "YES",
            "-hoth.settings.role", "resident",
            "-hoth.settings.language", "en",
            "-AppleLanguages", "(en)",
        ]
        app.launchEnvironment["HOTH_UITEST"] = "1"
        app.launch()

        let settingsTab = app.buttons["settingsTabButton"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 10))
        settingsTab.tap()

        let reset = app.buttons["resetAppButton"]
        var swipes = 0
        while !reset.isHittable && swipes < 6 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(reset.isHittable, "Reset app row missing")
        reset.tap()

        let confirm = app.buttons["confirmResetAppButton"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Confirmation dialog missing")
        XCTAssertFalse(app.buttons["confirmResetAppRemoveKeyButton"].exists, "No key, so no remove-key option")
        confirm.tap()

        // The rebuilt root starts on the feed again.
        XCTAssertTrue(app.segmentedControls["feedLayoutPicker"].waitForExistence(timeout: 10),
                      "App did not return to the feed after reset")
        XCTAssertFalse(reset.exists, "Settings should be gone after the rebuild")
    }
}
