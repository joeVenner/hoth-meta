import XCTest

/// P1-01 demo trigger: long-press the HoTH wordmark → seeded neighbour critical report + "Demo"
/// alert banner on the feed. Offline; writes `10_neighbour_alert.png` when `SCREENSHOT_DIR` is set.
final class NeighbourAlertUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += [
            "-hoth.onboarding.done", "YES",
            "-hoth.settings.demoMode", "YES",
            "-hoth.settings.language", "en",
            "-AppleLanguages", "(en)",
        ]
        app.launchEnvironment["HOTH_UITEST"] = "1"
    }

    @MainActor
    func testWordmarkLongPressShowsNeighbourAlert() throws {
        app.launch()
        let wordmark = app.staticTexts["hothWordmark"]
        XCTAssertTrue(wordmark.waitForExistence(timeout: 15), "Feed wordmark did not appear")
        wordmark.press(forDuration: 1.0)

        let banner = app.descendants(matching: .any)["neighbourAlertBanner"]
        XCTAssertTrue(banner.waitForExistence(timeout: 5), "Neighbour alert banner did not appear")
        XCTAssertTrue(app.staticTexts["Demo"].exists, "Banner should be labelled Demo")
        sleep(1)  // let the card insertion animation settle
        snapshot("10_neighbour_alert")
    }

    private func snapshot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let dir = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"], !dir.isEmpty else { return }
        do {
            try screenshot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        } catch {
            XCTFail("Could not write screenshot \(name): \(error)")
        }
    }
}
