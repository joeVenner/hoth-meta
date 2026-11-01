import XCTest

/// Golden path in demo mode: Report → demo spring rider → analysis (CRITICAL) → typed interview →
/// ticket → posted → feed. Screenshots go to the test attachments and, when `SCREENSHOT_DIR` is set
/// (pass `TEST_RUNNER_SCREENSHOT_DIR=<abs path>` to xcodebuild), to PNG files there.
///
/// The OpenAI key is optional: pass `TEST_RUNNER_OPENAI_API_KEY` at invocation time for the real
/// vision call; without it the app uses the labelled offline demo analysis. Never commit a key.
final class GoldenPathUITests: XCTestCase {
    private var app: XCUIApplication!
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

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
        if let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !key.isEmpty {
            app.launchEnvironment["OPENAI_API_KEY"] = key
        }
    }

    @MainActor
    func testGoldenPathSpringRider() throws {
        app.launch()

        // 1. Feed.
        let reportButton = app.buttons["reportTabButton"]
        XCTAssertTrue(reportButton.waitForExistence(timeout: 15), "Feed / tab bar did not appear")
        snapshot("01_feed")

        // 2. Capture (full screen, tab bar hidden).
        reportButton.tap()
        dismissSystemAlerts()
        let demoButton = app.buttons["demoPhotoButton"]
        XCTAssertTrue(demoButton.waitForExistence(timeout: 15), "Demo photo button missing on capture")
        dismissSystemAlerts()
        XCTAssertFalse(app.buttons["reportTabButton"].isHittable, "Tab bar should be hidden during capture")
        snapshot("02_capture")

        demoButton.tap()
        let sample = app.buttons["demoSample_spring_rider"]
        XCTAssertTrue(sample.waitForExistence(timeout: 10), "Demo spring rider sample missing")
        sample.tap()

        // 3. Analysis card with the CRITICAL badge (animates up from the model's proposal).
        let continueButton = app.buttons["analysisContinueButton"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 60), "Analysis card did not appear within 60 s")
        let critical = app.descendants(matching: .any)["priorityBadge_critical"]
        XCTAssertTrue(critical.waitForExistence(timeout: 10), "Expected a CRITICAL priority badge")
        sleep(1)
        snapshot("03_analysis_critical")
        continueButton.tap()
        tapSafetyContinueIfShown()

        // 4. Interview: switch to Type when the Talk/Type picker is shown (only when a voice interview is
        //    available), then answer the two slot questions.
        let typeSegment = app.buttons["Type"]
        if typeSegment.waitForExistence(timeout: 5) { typeSegment.tap() }

        let noReply = app.buttons["No"]
        XCTAssertTrue(noReply.waitForExistence(timeout: 20), "First question (children using it now?) missing")
        noReply.tap()

        let input = app.textFields["chatInputField"].exists ? app.textFields["chatInputField"]
            : app.textViews["chatInputField"]
        XCTAssertTrue(input.waitForExistence(timeout: 10), "Chat input missing")
        input.tap()
        input.typeText("The seat snapped off and sharp metal sticks out")
        app.buttons["chatSendButton"].tap()

        let confirm = app.buttons["Yes, that's right"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 20), "Read-back confirmation missing")
        snapshot("04_interview")
        confirm.tap()

        let postIt = app.buttons["Post it"]
        XCTAssertTrue(postIt.waitForExistence(timeout: 20), "Post question missing")
        postIt.tap()
        tapSafetyContinueIfShown()

        // 5. Ticket.
        let submit = app.buttons["ticketSubmitButton"]
        XCTAssertTrue(submit.waitForExistence(timeout: 20), "Ticket did not appear")
        tapSafetyContinueIfShown()
        sleep(1)
        snapshot("05_ticket")
        submit.tap()

        // 6. Posted → back to the feed.
        let done = app.buttons["postedDoneButton"]
        XCTAssertTrue(done.waitForExistence(timeout: 20), "Posted confirmation missing")
        done.tap()
        XCTAssertTrue(app.buttons["reportTabButton"].waitForExistence(timeout: 10), "Did not return to the feed")
        sleep(1)
        snapshot("06_posted_feed")
    }

    // MARK: Helpers

    /// Location / camera permission prompts belong to SpringBoard.
    private func dismissSystemAlerts() {
        let alert = springboard.alerts.firstMatch
        guard alert.waitForExistence(timeout: 3) else { return }
        for title in ["Allow While Using App", "Allow Once", "Allow", "OK"] where alert.buttons[title].exists {
            alert.buttons[title].tap()
            return
        }
    }

    private func tapSafetyContinueIfShown() {
        let safety = app.buttons["safetyContinueButton"]
        if safety.waitForExistence(timeout: 2) { safety.tap() }
    }

    private func snapshot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let dir = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"], !dir.isEmpty else { return }
        let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
        do {
            try screenshot.pngRepresentation.write(to: url)
        } catch {
            XCTFail("Could not write screenshot \(name): \(error)")
        }
    }
}
