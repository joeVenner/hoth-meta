import XCTest

/// Regression: with the keyboard up, the floating tab bar sat over the case comment composer, so the
/// send tap opened Settings and the comment never posted (English layout; Arabic happened to miss it).
/// Offline (`HOTH_UITEST`: local moderation, no model calls).
final class CommentComposerUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["HOTH_UITEST"] = "1"
    }

    @MainActor
    func testCommentPostsWithKeyboardUpEnglish() throws {
        try postComment(language: "en", caseTitle: "Open power cabinet with exposed wires",
                        comment: "Careful, the wires are bare by the school path.")
    }

    @MainActor
    func testCommentPostsWithKeyboardUpArabic() throws {
        try postComment(language: "ar", caseTitle: "خزانة كهرباء مفتوحة وأسلاك مكشوفة",
                        comment: "انتبهوا، الأسلاك مكشوفة جنب ممشى المدرسة.")
    }

    @MainActor
    private func postComment(language: String, caseTitle: String, comment: String) throws {
        app.launchArguments += [
            "-hoth.onboarding.done", "YES",
            "-hoth.settings.demoMode", "YES",
            "-hoth.settings.language", language,
            "-AppleLanguages", "(\(language))",
        ]
        app.launch()

        // The demo neighbour alert adds the case the film's C2 scene comments on.
        let wordmark = app.staticTexts["hothWordmark"]
        XCTAssertTrue(wordmark.waitForExistence(timeout: 15), "Feed wordmark did not appear")
        wordmark.press(forDuration: 1.0)
        let card = app.staticTexts[caseTitle].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10), "Alert case card missing")
        card.tap()
        XCTAssertTrue(app.buttons["caseConfirmButton"].waitForExistence(timeout: 10), "Case detail did not open")

        let field = app.descendants(matching: .any)["commentField"].firstMatch
        var swipes = 0
        while !(field.exists && field.isHittable) && swipes < 8 {
            app.swipeUp(velocity: .slow)
            swipes += 1
        }
        XCTAssertTrue(field.isHittable, "Comment field not reachable")
        field.tap()
        field.typeText(comment)

        let send = app.buttons["commentSendButton"]
        XCTAssertTrue(send.waitForExistence(timeout: 5), "Send button missing")
        // A connected hardware keyboard keeps the software one down; the bar only hides for the latter.
        if app.keyboards.firstMatch.exists {
            XCTAssertFalse(app.buttons["settingsTabButton"].isHittable, "Tab bar still shown over the keyboard")
        }
        XCTAssertTrue(send.isHittable, "Send button is covered")
        send.tap()

        let posted = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", String(comment.prefix(8))))
            .firstMatch
        XCTAssertTrue(posted.waitForExistence(timeout: 10), "The comment was never posted")
        XCTAssertFalse(app.buttons["settingsTabButton"].isSelected, "The send tap must not switch tabs")
    }
}
