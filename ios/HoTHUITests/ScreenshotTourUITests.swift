import XCTest

/// Screenshot tour for docs and visual review: onboarding (incl. Powered by Meta AI), feed, a case,
/// Settings. Offline (demo mode, no key). Skipped unless `SCREENSHOT_DIR` is set
/// (`TEST_RUNNER_SCREENSHOT_DIR`); `SCREENSHOT_LANG` (`en` / `ar`) and `SCREENSHOT_PREFIX` name the run.
/// Needs a fresh install so onboarding shows (`xcrun simctl uninstall booted io.fomy.hoth` first): an
/// `-hoth.onboarding.done NO` argument would pin the flag and onboarding could never finish.
final class ScreenshotTourUITests: XCTestCase {
    private var app: XCUIApplication!
    private var directory = ""
    private var prefix = ""

    override func setUpWithError() throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        directory = environment["SCREENSHOT_DIR"] ?? ""
        try XCTSkipIf(directory.isEmpty, "Set TEST_RUNNER_SCREENSHOT_DIR to run the screenshot tour")
        let language = environment["SCREENSHOT_LANG"] == "ar" ? "ar" : "en"
        prefix = environment["SCREENSHOT_PREFIX"] ?? language
        app = XCUIApplication()
        app.launchArguments += [
            "-hoth.settings.demoMode", "YES",
            "-hoth.settings.role", "resident",
            "-hoth.settings.language", language,
            "-AppleLanguages", "(\(language))",
            "-AppleLocale", language == "ar" ? "ar_AE" : "en_AE",
        ]
        app.launchEnvironment["HOTH_UITEST"] = "1"
    }

    @MainActor
    func testScreenshotTour() throws {
        app.launch()

        let next = app.buttons["onboardingContinueButton"]
        XCTAssertTrue(next.waitForExistence(timeout: 15), "Onboarding missing")
        sleep(1)
        snapshot("01_onboarding")
        next.tap()
        next.tap()
        XCTAssertTrue(app.descendants(matching: .any)["onboardingMetaPage"].waitForExistence(timeout: 5),
                      "Powered by Meta AI page missing")
        sleep(1)
        snapshot("02_onboarding_meta")
        next.tap()
        sleep(1)
        snapshot("03_onboarding_permissions")
        next.tap()

        XCTAssertTrue(next.waitForNonExistence(timeout: 10), "Onboarding did not finish")
        XCTAssertTrue(app.buttons["feedTabButton"].waitForExistence(timeout: 10), "Feed missing")
        sleep(2)
        snapshot("04_feed")
        app.swipeUp()
        sleep(1)
        snapshot("05_feed_posts")

        let comment = app.buttons.matching(identifier: "feedCommentButton").firstMatch
        XCTAssertTrue(comment.waitForExistence(timeout: 5), "Comment action missing")
        comment.tap()
        sleep(2)
        snapshot("07_case_comments")
        for _ in 0..<3 { app.swipeDown() }
        sleep(1)
        snapshot("06_case_detail")

        app.buttons["settingsTabButton"].tap()
        sleep(1)
        snapshot("08_settings")
        for _ in 0..<3 { app.swipeUp() }
        sleep(1)
        snapshot("09_settings_ai_reset")

        // Reset app brings the welcome screens back without a relaunch.
        let reset = app.buttons["resetAppButton"]
        var swipes = 0
        while !reset.isHittable && swipes < 4 {
            app.swipeUp()
            swipes += 1
        }
        reset.tap()
        sleep(1)
        snapshot("10_reset_dialog")
        app.buttons["confirmResetAppButton"].firstMatch.tap()
        XCTAssertTrue(next.waitForExistence(timeout: 10), "Onboarding did not return after reset")
    }

    private func snapshot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let url = URL(fileURLWithPath: directory).appendingPathComponent("\(prefix)_\(name).png")
        do {
            try screenshot.pngRepresentation.write(to: url)
        } catch {
            XCTFail("Could not write screenshot \(name): \(error)")
        }
    }
}
