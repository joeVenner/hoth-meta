import XCTest

/// Scripted walkthroughs for the demo film (capture plan in the hoth-meta-demo repo, `script/capture-plan.md`
/// §4). Each method is one filmed scene in one fresh launch; the method names are the contract with the
/// storyboard's `app_clip.capture_test`.
///
/// **Live:** these make real Meta calls (Muse Spark, SAM, Muse Voice Transcribe), so they are skipped
/// unless `TEST_RUNNER_DEMO_CAPTURE=1`. They launch with `HOTH_DEMO_CAPTURE=1` and never set `HOTH_UITEST`
/// (which would switch SAM, push-to-talk, the agent, moderation, the splash and alerts off).
///
/// Inputs (pass with the `TEST_RUNNER_` prefix to xcodebuild; the runner sees them without it):
/// - `META_API_KEY`: the Meta key, forwarded to the app's environment. Never logged.
/// - `CAPTURE_LOG`: host JSONL path for `mark()` events (scene, event, time, tap position).
/// - `HOTH_PTT_WAV_DIR`: host directory of push-to-talk WAV clips for C1, played in name order.
/// - `HOTH_CAPTURE_LOG_DIR`: host directory for the app's own log (tool calls); defaults to the
///   directory of `CAPTURE_LOG`.
///
/// Never films the Settings key card and never touches `call999Button`.
final class DemoCaptureUITests: XCTestCase {
    private var app: XCUIApplication!
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    private var scene = ""
    private var logURL: URL?
    private var lastCaption = ""

    /// Idle push-to-talk status ("Hold to talk"), the orb's accessibility value, per UI language.
    private static let holdToTalkValues = ["Hold to talk", "اضغط مطوّل وتكلّم"]
    /// Clips the agent may need: two scripted answers plus two spares (capture plan §3).
    private static let maxClips = 4

    override func setUpWithError() throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["DEMO_CAPTURE"] == "1",
                          "Live demo capture: set TEST_RUNNER_DEMO_CAPTURE=1 (makes real Meta calls)")
        if let path = environment["CAPTURE_LOG"], !path.isEmpty {
            logURL = URL(fileURLWithPath: path)
        }

        app = XCUIApplication()
        app.launchArguments += [
            "-hoth.onboarding.done", "YES",
            "-hoth.settings.demoMode", "YES",
            "-hoth.settings.voiceFirstInterview", "YES",
            "-hoth.settings.agentIntake", "YES",
            "-hoth.alerts.demoNeighbourSimulated", "YES",
            "-hoth.alerts.lastAlertAt", "0",
        ]
        app.launchEnvironment["HOTH_DEMO_CAPTURE"] = "1"
        if let key = environment["META_API_KEY"], !key.isEmpty {
            app.launchEnvironment["META_API_KEY"] = key
        }
        // Forwarded to every scene, so the app's `capture_launch` log line proves it can read the playlist.
        if let directory = environment["HOTH_PTT_WAV_DIR"], !directory.isEmpty {
            app.launchEnvironment["HOTH_PTT_WAV_DIR"] = directory
        }
        if let directory = environment["HOTH_CAPTURE_LOG_DIR"], !directory.isEmpty {
            app.launchEnvironment["HOTH_CAPTURE_LOG_DIR"] = directory
        } else if let logURL {
            app.launchEnvironment["HOTH_CAPTURE_LOG_DIR"] = logURL.deletingLastPathComponent().path
        }

        // Backstop for the notification prompt (C0 should have answered it already). The monitor only
        // fires on the next interaction, so waits also call `allowSystemAlert()`.
        _ = addUIInterruptionMonitor(withDescription: "System permission") { alert in
            for title in ["Allow", "Allow While Using App", "OK"] where alert.buttons[title].exists {
                alert.buttons[title].tap()
                return true
            }
            return false
        }
    }

    // MARK: - Scenes

    /// C0 (not filmed): answer the notification prompt once, so it never shows in a take.
    @MainActor
    func test00_WarmUpNotifications() throws {
        launch(scene: "C0", language: "en", role: "resident", extraEnvironment: ["HOTH_CAPTURE_SKIP_SPLASH": "1"])
        let wordmark = app.staticTexts["hothWordmark"]
        XCTAssertTrue(wordmark.waitForExistence(timeout: 20), "Feed wordmark did not appear")
        mark("feed_shown")
        wordmark.press(forDuration: 1.0)
        mark("alert_fired", element: wordmark)
        allowSystemAlert(timeout: 10)
        beat(1)
        mark("warm_up_done")
    }

    /// C1 → storyboard S03–S06: splash, spring rider photo, live analysis + SAM + CRITICAL, Arabic
    /// push-to-talk interview from the WAV playlist, ticket, posted, feed, r10 card, map.
    @MainActor
    func test02_SpringRiderVoiceAR() throws {
        let environment = ProcessInfo.processInfo.environment
        let clipDirectory = try XCTUnwrap(environment["HOTH_PTT_WAV_DIR"].flatMap { $0.isEmpty ? nil : $0 },
                                          "Set TEST_RUNNER_HOTH_PTT_WAV_DIR to the push-to-talk WAV playlist")
        let clips = try clipDurations(in: clipDirectory)
        XCTAssertFalse(clips.isEmpty, "No .wav clips in the playlist")

        launch(scene: "C1", language: "ar", role: "resident", extraEnvironment: [:], startMark: "splash_start")

        let reportTab = app.buttons["reportTabButton"]
        XCTAssertTrue(reportTab.waitForExistence(timeout: 30), "Feed did not appear")
        mark("feed_shown")
        beat(1.5)

        tap(reportTab, mark: "capture_open")
        let demoPhoto = app.buttons["demoPhotoButton"]
        XCTAssertTrue(demoPhoto.waitForExistence(timeout: 15), "Demo photo button missing")
        beat(1.5)
        tap(demoPhoto, mark: "picker_open")
        let sample = app.buttons["demoSample_spring_rider"]
        XCTAssertTrue(sample.waitForExistence(timeout: 10), "Spring rider sample missing")
        beat(1.5)
        tap(sample, mark: "sample_tapped")

        // Live Muse Spark vision: marks start and end of the wait so the edit can label the speed-up.
        mark("vision_wait_start")
        let continueButton = app.buttons["analysisContinueButton"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 90), "Analysis card did not appear within 90 s")
        mark("vision_done")

        mark("sam_wait_start")
        let samChip = app.descendants(matching: .any)["samOutlineChip"]
        mark(samChip.waitForExistence(timeout: 25) ? "sam_chip" : "sam_timeout", element: samChip.exists ? samChip : nil)

        let critical = app.descendants(matching: .any)["priorityBadge_critical"]
        XCTAssertTrue(critical.waitForExistence(timeout: 5), "Expected the CRITICAL badge (spark_critical_floor)")
        mark("badge_critical", element: critical)
        beat(4)

        app.swipeUp(velocity: .slow)
        mark("why_visible")
        beat(2)

        tap(continueButton, mark: "continue_tapped")
        try runInterview(clips: clips)

        // Ticket.
        let submit = app.buttons["ticketSubmitButton"]
        XCTAssertTrue(submit.exists, "Ticket missing")
        let routed = app.descendants(matching: .any)["routedToTeam"]
        mark("ticket_shown", element: routed.exists ? routed : nil, extra: ["routed_to": routed.exists ? routed.label : ""])
        beat(4)
        app.swipeUp(velocity: .slow)
        beat(2)
        scrollIntoView(submit)
        tap(submit, mark: "submitted")

        let done = app.buttons["postedDoneButton"]
        XCTAssertTrue(done.waitForExistence(timeout: 30), "Posted screen missing")
        beat(1)
        tap(done, mark: "feed_top_card")
        beat(3)

        // §6.3: hold on the seeded r10 card ("Mariam's other report") before the map.
        let r10 = app.staticTexts["بلاط مكسور عند نقطة إنزال الطلاب"].firstMatch
        if scrollIntoView(r10, maxSwipes: 8) {
            mark("r10_card", element: r10)
            beat(2.5)
        } else {
            mark("r10_card_missing")
        }

        let mapTab = app.buttons["mapTabButton"]
        XCTAssertTrue(mapTab.waitForExistence(timeout: 10), "Map tab missing")
        tap(mapTab, mark: "map_shown")
        beat(4)
        mark("scene_end")
    }

    /// C2 → storyboard S07: demo neighbour alert, open the case, "I saw it too", one moderated comment.
    @MainActor
    func test06_NeighbourAlertConfirmCommentAR() throws {
        let skipsSplash = ProcessInfo.processInfo.environment["CAPTURE_SKIP_SPLASH"] == "1"
        launch(scene: "C2", language: "ar", role: "resident",
               extraEnvironment: skipsSplash ? ["HOTH_CAPTURE_SKIP_SPLASH": "1"] : [:])

        let wordmark = app.staticTexts["hothWordmark"]
        XCTAssertTrue(wordmark.waitForExistence(timeout: 30), "Feed did not appear")
        mark("feed_shown")
        beat(2)

        mark("alert_fired", element: wordmark)
        wordmark.press(forDuration: 1.0)
        let banner = app.descendants(matching: .any)["neighbourAlertBanner"]
        XCTAssertTrue(banner.waitForExistence(timeout: 10), "Neighbour alert banner did not appear")
        mark("banner_shown", element: banner)
        beat(4)

        let cardTitle = app.staticTexts["خزانة كهرباء مفتوحة وأسلاك مكشوفة"].firstMatch
        XCTAssertTrue(cardTitle.waitForExistence(timeout: 10), "Alert case card missing from the feed")
        tap(cardTitle, mark: "case_open")
        let confirm = app.buttons["caseConfirmButton"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "Case detail did not open")
        mark("confirmations_before", extra: ["text": confirmationText()])
        beat(2.5)

        tap(confirm, mark: "confirmed")
        beat(3)
        mark("confirmations_after", extra: ["text": confirmationText(), "button": confirm.label])

        let field = app.descendants(matching: .any)["commentField"].firstMatch
        XCTAssertTrue(scrollIntoView(field, maxSwipes: 8), "Comment field not reachable")
        tap(field, mark: "composer")
        beat(1)
        field.typeText("انتبهوا، الخزانة مفتوحة والأسلاك مكشوفة جنب ممشى المدرسة. خلّوا اليهال بعيد.")
        let send = app.buttons["commentSendButton"]
        XCTAssertTrue(send.waitForExistence(timeout: 5), "Send button missing")
        tap(send, mark: "comment_sent")

        // Live Muse Spark moderation: "Checking…" then the comment stays (or is removed).
        let pending = app.descendants(matching: .any)["commentPending"].firstMatch
        mark("moderation_wait_start", extra: ["pending_seen": pending.waitForExistence(timeout: 5)])
        XCTAssertTrue(pending.waitForNonExistence(timeout: 60), "Moderation did not finish within 60 s")
        let removed = app.descendants(matching: .any)["commentRemoved"].exists
        mark("moderation_done", extra: ["removed": removed])
        beat(3)
        mark("scene_end")
    }

    /// C3 → storyboard S09–S10: crew rejects a partial repair, accepts the full one, celebration and
    /// "Hero of the Hay" level-up (fresh launch at 360 points).
    @MainActor
    func test08_CrewFixCheck() throws {
        launch(scene: "C3", language: "en", role: "crew", extraEnvironment: ["HOTH_CAPTURE_SKIP_SPLASH": "1"])

        let crewTab = app.buttons["crewTabButton"]
        XCTAssertTrue(crewTab.waitForExistence(timeout: 30), "Crew tab missing")
        tap(crewTab, mark: "crew_queue")
        XCTAssertTrue(app.staticTexts["City Crew"].waitForExistence(timeout: 10), "Crew queue did not appear")
        beat(2.5)

        let row = app.staticTexts["Broken paving at the school drop-off"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Pothole case missing from the queue")
        scrollIntoView(row)
        tap(row, mark: "case_open")
        beat(2)

        let start = app.buttons["crewStartWorkButton"]
        XCTAssertTrue(start.waitForExistence(timeout: 10), "Start work missing")
        tap(start, mark: "start_work")
        beat(1.5)

        try uploadRepair("demoFix_bad", sheetMark: "repair_sheet", pickMark: "bad_uploaded")
        mark("fix_wait_start")
        let rejected = app.descendants(matching: .any)["fixVerdictRejected"]
        XCTAssertTrue(rejected.waitForExistence(timeout: 90), "Rejected verdict did not appear")
        mark("rejected", element: rejected)
        beat(5)

        try uploadRepair("demoFix_good", sheetMark: "repair_sheet_2", pickMark: "good_uploaded")
        mark("fix_wait_start_2")
        let resolved = app.descendants(matching: .any)["fixVerdictResolved"]
        XCTAssertTrue(resolved.waitForExistence(timeout: 90), "Resolved verdict did not appear")
        mark("resolved")
        beat(1)

        let celebration = app.descendants(matching: .any)["celebrationMessage"]
        XCTAssertTrue(celebration.waitForExistence(timeout: 30), "Fixed celebration did not appear")
        mark("celebration")
        allowSystemAlert(timeout: 1)
        beat(2)

        let handle = app.descendants(matching: .any)["beforeAfterHandle"]
        if handle.waitForExistence(timeout: 5) {
            mark("slider", element: handle)
            let centre = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let window = app.windows.firstMatch
            let left = window.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0)).withOffset(CGVector(dx: 0, dy: handle.frame.midY))
            let right = window.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0)).withOffset(CGVector(dx: 0, dy: handle.frame.midY))
            centre.press(forDuration: 0.1, thenDragTo: left, withVelocity: .slow, thenHoldForDuration: 0.2)
            let atLeft = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            atLeft.press(forDuration: 0.1, thenDragTo: right, withVelocity: .slow, thenHoldForDuration: 0.2)
            let atRight = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            atRight.press(forDuration: 0.1, thenDragTo: centre, withVelocity: .slow, thenHoldForDuration: 0.2)
            beat(1)
        } else {
            mark("slider_missing")
        }

        let levelUp = app.descendants(matching: .any)["celebrationLevelUp"]
        XCTAssertTrue(levelUp.waitForExistence(timeout: 15), "Level-up did not appear")
        scrollIntoView(levelUp)
        mark("level_up", element: levelUp)
        beat(4)
        mark("scene_end")
    }

    // MARK: - Interview (C1)

    /// Plays playlist clips by holding the orb until the ticket shows (or the urgent safety sheet,
    /// which is tapped through after a 3 s hold). Waits never use fixed sleeps.
    @MainActor
    private func runInterview(clips: [TimeInterval]) throws {
        let talk = app.descendants(matching: .any)["pushToTalkButton"]
        let ticket = app.buttons["ticketSubmitButton"]
        let safety = app.buttons["safetyContinueButton"]

        if safety.waitForExistence(timeout: 3) {
            mark("safety_sheet", element: safety)
            beat(3)
            safety.tap()
        }
        XCTAssertTrue(talk.waitForExistence(timeout: 30) || ticket.exists, "Voice interview did not open")
        mark("interview_open")

        var assistantCount = 0
        var residentCount = 0
        var played = 0
        while !ticket.exists {
            // Wait for the agent's reply to be read out and the orb to return to "Hold to talk".
            mark("assistant_wait_start")
            let state = waitForInterviewTurn(talk: talk, ticket: ticket, safety: safety,
                                             assistantsBefore: assistantCount, timeout: 90)
            assistantCount = logNewBubbles(role: "assistant", seen: assistantCount, event: "assistant")
            switch state {
            case .ticket:
                continue
            case .safety:
                mark("safety_sheet", element: safety)
                beat(3)
                safety.tap()
                continue
            case .timedOut:
                XCTFail("Interview stalled (no idle orb, ticket or safety sheet within 90 s)")
                return
            case .idle:
                break
            }
            beat(played == 0 ? 1 : 2)
            guard played < min(clips.count, Self.maxClips) else {
                XCTFail("Interview needs more than \(min(clips.count, Self.maxClips)) clips; stop and log it")
                return
            }
            played += 1
            let label = String(format: "%02d", played)
            mark("ptt_\(label)_start", element: talk)
            holdToTalk(clips[played - 1] + 0.4)
            mark("ptt_\(label)_release")

            // Muse Voice Transcribe: the resident bubble is the real transcript.
            mark("transcribe_wait_start")
            let resident = app.descendants(matching: .any).matching(identifier: "chatBubble_resident")
            let gotTranscript = waitUntil(timeout: 60) { resident.count > residentCount || self.voiceNoticeShown() }
            if gotTranscript && resident.count > residentCount {
                residentCount = logNewBubbles(role: "resident", seen: residentCount, event: "transcript_\(label)")
            } else {
                let notice = app.descendants(matching: .any)["voiceNotice"]
                mark("transcript_\(label)_failed", extra: ["notice": notice.exists ? notice.label : "timeout"])
                XCTFail("No transcript for clip \(label) (voice_transcribe_ar)")
                return
            }
        }
    }

    private enum InterviewState { case idle, ticket, safety, timedOut }

    /// Idle means: a new assistant bubble arrived, the chat is not thinking (no typing line), and the
    /// orb reads "Hold to talk" again (the reply was read aloud). Agent tool captions seen on the typing
    /// line on the way are marked with their text (`agent_tool_caption`).
    @MainActor
    private func waitForInterviewTurn(talk: XCUIElement, ticket: XCUIElement, safety: XCUIElement,
                                      assistantsBefore: Int, timeout: TimeInterval) -> InterviewState {
        let activity = app.descendants(matching: .any)["chatActivity"]
        let assistants = app.descendants(matching: .any).matching(identifier: "chatBubble_assistant")
        var result = InterviewState.timedOut
        _ = waitUntil(timeout: timeout) {
            if ticket.exists { result = .ticket; return true }
            if safety.exists { result = .safety; return true }
            if activity.exists {
                let caption = activity.label
                if caption != self.lastCaption {
                    self.lastCaption = caption
                    self.mark("agent_caption", extra: ["text": caption])
                }
                return false
            }
            guard assistants.count > assistantsBefore, talk.exists,
                  let value = talk.value as? String, Self.holdToTalkValues.contains(value) else { return false }
            result = .idle
            return true
        }
        return result
    }

    private func voiceNoticeShown() -> Bool {
        app.descendants(matching: .any)["voiceNotice"].exists
    }

    /// Marks each bubble that appeared since `seen`, with its text (the transcript, or the agent's line).
    @discardableResult
    private func logNewBubbles(role: String, seen: Int, event: String) -> Int {
        let bubbles = app.descendants(matching: .any).matching(identifier: "chatBubble_\(role)")
        let count = bubbles.count
        guard count > seen else { return seen }
        for index in seen..<count {
            let bubble = bubbles.element(boundBy: index)
            mark(count - seen > 1 ? "\(event)_\(index + 1)" : event, element: bubble, extra: ["text": bubble.label])
        }
        return count
    }

    // MARK: - Helpers

    @MainActor
    private func launch(scene: String, language: String, role: String, extraEnvironment: [String: String],
                        startMark: String = "launch_start") {
        self.scene = scene
        app.launchArguments += [
            "-hoth.settings.role", role,
            "-hoth.settings.language", language,
            "-AppleLanguages", "(\(language))",
        ]
        app.launchEnvironment["HOTH_CAPTURE_SCENE"] = scene
        for (key, value) in extraEnvironment { app.launchEnvironment[key] = value }
        mark(startMark)
        app.launch()
        mark("launched")
    }

    /// A deliberate on-screen pause (the only fixed sleeps in these tests).
    private func beat(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    /// Appends `{"scene","event","t"[,"tap"]...}` to `CAPTURE_LOG`. `tap` is the element's centre,
    /// normalised to the app window, for the editor's tap rings (the simulator draws no touches).
    private func mark(_ event: String, element: XCUIElement? = nil, extra: [String: Any] = [:]) {
        var record: [String: Any] = extra
        record["scene"] = scene
        record["event"] = event
        record["t"] = Date().timeIntervalSince1970
        if let element, element.exists, let app {
            let window = app.windows.firstMatch.frame
            let frame = element.frame
            if window.width > 0, window.height > 0, !frame.isEmpty {
                record["tap"] = ["x": Double((frame.midX - window.minX) / window.width),
                                 "y": Double((frame.midY - window.minY) / window.height)]
            }
        }
        guard let logURL else { return }
        do {
            var line = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes])
            line.append(0x0A)
            if !FileManager.default.fileExists(atPath: logURL.path) {
                FileManager.default.createFile(atPath: logURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: logURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } catch {
            XCTFail("Could not write capture log \(logURL.path): \(error)")
        }
    }

    private func tap(_ element: XCUIElement, mark event: String) {
        mark(event, element: element)
        element.tap()
    }

    /// Holds the orb for `seconds` (clip length + 0.4 s); must exceed the 0.35 s tap threshold.
    private func holdToTalk(_ seconds: TimeInterval) {
        app.descendants(matching: .any)["pushToTalkButton"].press(forDuration: max(seconds, 0.5))
    }

    /// Polls `condition` every 0.25 s; also answers a system permission alert if one is up.
    @discardableResult
    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            allowSystemAlert(timeout: 0)
            Thread.sleep(forTimeInterval: 0.25)
        }
        return condition()
    }

    private func allowSystemAlert(timeout: TimeInterval) {
        let alert = springboard.alerts.firstMatch
        guard timeout > 0 ? alert.waitForExistence(timeout: timeout) : alert.exists else { return }
        for title in ["Allow", "Allow While Using App", "OK"] where alert.buttons[title].exists {
            mark("system_alert_allowed", extra: ["button": title])
            alert.buttons[title].tap()
            return
        }
    }

    @discardableResult
    private func scrollIntoView(_ element: XCUIElement, maxSwipes: Int = 4) -> Bool {
        var swipes = 0
        while !(element.exists && element.isHittable) && swipes < maxSwipes {
            app.swipeUp(velocity: .slow)
            swipes += 1
        }
        return element.exists && element.isHittable
    }

    private func confirmationText() -> String {
        let predicate = NSPredicate(format: "label CONTAINS[c] 'confirmation' OR label CONTAINS 'تأكيد'")
        let text = app.staticTexts.matching(predicate).firstMatch
        return text.exists ? text.label : ""
    }

    @MainActor
    private func uploadRepair(_ identifier: String, sheetMark: String, pickMark: String) throws {
        let upload = app.buttons["crewUploadRepairButton"]
        var swipes = 0
        while !(upload.exists && upload.isHittable) && swipes < 4 {
            app.swipeDown()
            swipes += 1
        }
        XCTAssertTrue(upload.waitForExistence(timeout: 10), "Upload repair photo missing")
        tap(upload, mark: sheetMark)
        let pick = app.buttons[identifier]
        XCTAssertTrue(pick.waitForExistence(timeout: 10), "Demo repair photo \(identifier) missing")
        beat(1.5)
        tap(pick, mark: pickMark)
    }

    /// Each playlist clip's length in seconds, in playlist (name) order, read from the WAV header.
    private func clipDurations(in directory: String) throws -> [TimeInterval] {
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: url.path)
            .filter { $0.lowercased().hasSuffix(".wav") && !$0.hasPrefix(".") }
            .sorted()
        return try names.map { name in
            let data = try Data(contentsOf: url.appendingPathComponent(name))
            return try XCTUnwrap(Self.wavDuration(data), "Not a PCM WAV: \(name)")
        }
    }

    /// Duration of a PCM WAV: `data` chunk size / byte rate (from the `fmt ` chunk).
    static func wavDuration(_ data: Data) -> TimeInterval? {
        let bytes = [UInt8](data)
        guard bytes.count >= 12, String(bytes: bytes[0..<4], encoding: .ascii) == "RIFF" else { return nil }
        func uint32(_ offset: Int) -> Int {
            Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2]) << 16 | Int(bytes[offset + 3]) << 24
        }
        var offset = 12
        var byteRate = 0
        while offset + 8 <= bytes.count {
            let id = String(bytes: bytes[offset..<offset + 4], encoding: .ascii)
            let size = uint32(offset + 4)
            // fmt: format(2) channels(2) sampleRate(4) byteRate(4) after the 8-byte chunk header.
            if id == "fmt ", offset + 20 <= bytes.count { byteRate = uint32(offset + 16) }
            if id == "data" {
                guard byteRate > 0 else { return nil }
                return Double(min(size, bytes.count - offset - 8)) / Double(byteRate)
            }
            offset += 8 + size + (size % 2)
        }
        return nil
    }
}
