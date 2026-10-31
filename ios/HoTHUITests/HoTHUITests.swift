import XCTest

final class HoTHUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testAppLaunchesAndShowsTabs() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-hoth.onboarding.done", "YES"]
        app.launchEnvironment["HOTH_UITEST"] = "1"
        app.launch()
        XCTAssertTrue(app.buttons["Feed"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["reportTabButton"].exists)
    }

    /// 2 + camera + 2 bar: Feed, Map | Report | Hero, Settings. Map is full screen with tappable pins;
    /// Hero lists my reports. Writes draft_tabbar / draft_map_tab to `SCREENSHOT_DIR` when set.
    @MainActor
    func testTabBarMapAndMyReports() throws {
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

        for id in ["feedTabButton", "mapTabButton", "reportTabButton", "heroTabButton", "settingsTabButton"] {
            XCTAssertTrue(app.buttons[id].waitForExistence(timeout: 10), "Missing tab \(id)")
        }
        // Equal spacing: the camera button sits at the bar's horizontal centre.
        let feedX = app.buttons["feedTabButton"].frame.midX
        let settingsX = app.buttons["settingsTabButton"].frame.midX
        let reportX = app.buttons["reportTabButton"].frame.midX
        XCTAssertEqual(reportX, (feedX + settingsX) / 2, accuracy: 2)
        sleep(1)
        snapshot("draft_tabbar")

        app.buttons["mapTabButton"].tap()
        XCTAssertTrue(app.staticTexts["mapReportCount"].waitForExistence(timeout: 10), "Map tab header missing")
        let pin = app.buttons.matching(identifier: "feedMapPin_critical").firstMatch
        XCTAssertTrue(pin.waitForExistence(timeout: 15), "Critical pin missing on the Map tab")
        pin.tap()
        let card = app.descendants(matching: .any)["feedMapCard"]
        XCTAssertTrue(card.waitForExistence(timeout: 10), "Compact card did not appear")
        XCTAssertLessThan(card.frame.maxY, app.buttons["mapTabButton"].frame.minY, "Card hidden behind the tab bar")
        sleep(2)  // let map tiles settle
        snapshot("draft_map_tab")
        card.tap()
        XCTAssertFalse(app.staticTexts["mapReportCount"].isHittable, "Card should open the case")

        app.buttons["heroTabButton"].tap()
        let header = app.staticTexts["myReportsHeader"]
        var swipes = 0
        while !header.exists && swipes < 4 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(header.exists, "My reports section missing")
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
