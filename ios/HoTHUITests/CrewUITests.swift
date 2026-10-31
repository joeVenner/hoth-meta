import XCTest

/// City Crew demo: queue → pothole case → partial repair rejected → full repair accepted → Fixed moment.
/// With `TEST_RUNNER_OPENAI_API_KEY` this makes exactly two live fix-check calls; without a key it uses the
/// labelled offline demo verdicts. Screenshots go to `SCREENSHOT_DIR` when set (`TEST_RUNNER_SCREENSHOT_DIR`).
final class CrewUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += [
            "-hoth.onboarding.done", "YES",
            "-hoth.settings.demoMode", "YES",
            "-hoth.settings.role", "crew",
            "-hoth.settings.language", "en",
            "-AppleLanguages", "(en)",
        ]
        app.launchEnvironment["HOTH_UITEST"] = "1"
        if let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !key.isEmpty {
            app.launchEnvironment["OPENAI_API_KEY"] = key
        }
    }

    @MainActor
    func testCrewFixCheckRejectThenAccept() throws {
        app.launch()

        let crewTab = app.buttons["crewTabButton"]
        XCTAssertTrue(crewTab.waitForExistence(timeout: 15), "Crew tab missing")
        crewTab.tap()
        XCTAssertTrue(app.staticTexts["City Crew"].waitForExistence(timeout: 10), "Crew queue did not appear")
        sleep(1)
        snapshot("07_crew_queue")

        // The demo repair photos match the seeded pothole at the school drop-off (reported by "you").
        let row = app.staticTexts["Broken paving at the school drop-off"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Pothole case missing from the queue")
        var swipes = 0
        while !row.isHittable && swipes < 6 {
            app.swipeUp()
            swipes += 1
        }
        row.tap()

        let start = app.buttons["crewStartWorkButton"]
        XCTAssertTrue(start.waitForExistence(timeout: 10), "Start work missing")
        start.tap()

        // 1. Partial repair → rejected, status stays open.
        uploadDemo("demoFix_bad")
        let rejected = app.descendants(matching: .any)["fixVerdictRejected"]
        XCTAssertTrue(rejected.waitForExistence(timeout: 90), "Rejected verdict did not appear")
        scrollTo(app.descendants(matching: .any)["fixAfterPhoto"])
        sleep(1)
        snapshot("08_fix_rejected")

        // 2. Full repair → fixed, celebration sheet.
        app.swipeDown()
        uploadDemo("demoFix_good")
        let celebration = app.descendants(matching: .any)["celebrationMessage"]
        XCTAssertTrue(celebration.waitForExistence(timeout: 90), "Fixed celebration did not appear")
        sleep(2)
        snapshot("09_fixed_celebration")
    }

    private func uploadDemo(_ identifier: String) {
        let upload = app.buttons["crewUploadRepairButton"]
        var swipes = 0
        while !(upload.exists && upload.isHittable) && swipes < 4 {
            app.swipeDown()
            swipes += 1
        }
        XCTAssertTrue(upload.waitForExistence(timeout: 10), "Upload repair photo missing")
        upload.tap()
        let pick = app.buttons[identifier]
        XCTAssertTrue(pick.waitForExistence(timeout: 10), "Demo repair photo \(identifier) missing")
        pick.tap()
    }

    private func scrollTo(_ element: XCUIElement) {
        var swipes = 0
        while element.exists && !element.isHittable && swipes < 4 {
            app.swipeUp()
            swipes += 1
        }
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
