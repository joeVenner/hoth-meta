import XCTest

/// P2-03: Feed list → map toggle, tap a critical pin, compact card opens the case. Offline (demo mode,
/// no model API calls). Writes `11_feed_map.png` to `SCREENSHOT_DIR` when set (`TEST_RUNNER_SCREENSHOT_DIR`).
final class FeedMapUITests: XCTestCase {
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
    func testFeedMapPinOpensCase() throws {
        app.launch()

        let picker = app.segmentedControls["feedLayoutPicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 15), "Feed layout picker missing")
        XCTAssertTrue(picker.buttons["List"].isSelected, "List should be the default layout")
        picker.buttons["Map"].tap()

        let pin = app.buttons.matching(identifier: "feedMapPin_critical").firstMatch
        XCTAssertTrue(pin.waitForExistence(timeout: 15), "Critical pin missing on the feed map")
        pin.tap()

        let card = app.descendants(matching: .any)["feedMapCard"]
        XCTAssertTrue(card.waitForExistence(timeout: 10), "Compact card did not appear")
        sleep(3)  // let map tiles settle
        snapshot("11_feed_map")

        card.tap()
        XCTAssertFalse(picker.isHittable, "Card should navigate to the case detail")
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
