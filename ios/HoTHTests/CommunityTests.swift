import CoreLocation
import HoTHCore
import XCTest
@testable import HoTH

/// P1-01 neighbour-alert policy and P1-06 comment moderation fallback (no network).
final class CommunityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: Neighbour alert policy

    func testFirstNearbyCriticalAlerts() {
        XCTAssertTrue(NeighbourAlertPolicy.shouldAlert(priority: .critical, distance: 400, lastAlertAt: nil, now: now))
        XCTAssertTrue(NeighbourAlertPolicy.shouldAlert(priority: .high, distance: 1000, lastAlertAt: nil, now: now))
    }

    func testRateLimitBlocksWithinTenMinutes() {
        let recent = now.addingTimeInterval(-9 * 60)
        XCTAssertFalse(NeighbourAlertPolicy.shouldAlert(priority: .critical, distance: 100, lastAlertAt: recent, now: now))
    }

    func testRateLimitReleasesAfterTenMinutes() {
        let exactly = now.addingTimeInterval(-10 * 60)
        let older = now.addingTimeInterval(-3600)
        XCTAssertTrue(NeighbourAlertPolicy.shouldAlert(priority: .critical, distance: 100, lastAlertAt: exactly, now: now))
        XCTAssertTrue(NeighbourAlertPolicy.shouldAlert(priority: .high, distance: 100, lastAlertAt: older, now: now))
    }

    func testLowerPrioritiesNeverAlert() {
        XCTAssertFalse(NeighbourAlertPolicy.shouldAlert(priority: .medium, distance: 50, lastAlertAt: nil, now: now))
        XCTAssertFalse(NeighbourAlertPolicy.shouldAlert(priority: .low, distance: 50, lastAlertAt: nil, now: now))
    }

    func testFarAwayNeverAlerts() {
        XCTAssertFalse(NeighbourAlertPolicy.shouldAlert(priority: .critical, distance: 1001, lastAlertAt: nil, now: now))
    }

    func testAlertMessageFormat() {
        XCTAssertEqual(NeighbourAlertPolicy.message(title: "Exposed wire", place: "Al Sidr Street", arabic: false),
                       "⚠️ Hazard near you: Exposed wire · Al Sidr Street")
        XCTAssertTrue(NeighbourAlertPolicy.message(title: "سلك", place: "شارع", arabic: true).hasPrefix("⚠️ خطر بالقرب منك"))
    }

    func testDemoNeighbourReportPassesPolicyFromHome() {
        // The seeded neighbour report sits ~400 m from the demo home, inside the alert radius.
        let distance = FeedGeography.home.distance(from: CLLocation(latitude: 24.4234, longitude: 54.5762))
        XCTAssertLessThan(distance, NeighbourAlertPolicy.radius)
    }

    // MARK: Local moderation

    func testCleanCommentsAllowed() {
        XCTAssertEqual(LocalCommentModerator.check("I saw this too, the chain is broken."), .allowed)
        XCTAssertEqual(LocalCommentModerator.check("شفتها أمس، خطيرة على الأطفال"), .allowed)
        XCTAssertEqual(LocalCommentModerator.check("It has been broken for 3 days near gate 12."), .allowed)
        XCTAssertEqual(LocalCommentModerator.check("A stray dog sleeps next to it"), .allowed)
    }

    func testEmailBlocked() {
        XCTAssertEqual(LocalCommentModerator.check("Contact me at someone@example.com"), .blocked)
    }

    func testPhoneNumbersBlocked() {
        XCTAssertEqual(LocalCommentModerator.check("Call +971 50 123 4567 now"), .blocked)
        XCTAssertEqual(LocalCommentModerator.check("رقمي ٠٥٠١٢٣٤٥٦٧"), .blocked)
        XCTAssertEqual(LocalCommentModerator.check("050-123-4567"), .blocked)
    }

    func testSlursBlocked() {
        XCTAssertEqual(LocalCommentModerator.check("The crew are idiots"), .blocked)
        XCTAssertEqual(LocalCommentModerator.check("المسؤول غبي"), .blocked)
    }

    func testVerdictMapping() {
        XCTAssertEqual(ModerationVerdict(decision: "block", reason: "x").status, .blocked)
        XCTAssertEqual(ModerationVerdict(decision: "allow", reason: "x").status, .allowed)
    }

    // MARK: OpenAI moderator fallback

    func testNoKeyFallsBackToLocalChecks() async throws {
        let moderator = try makeModerator(hasKey: false)
        let allowed = await moderator.moderate("Still broken today", reportTitle: "Swing")
        let blocked = await moderator.moderate("text me 0501234567", reportTitle: "Swing")
        XCTAssertEqual(allowed, .allowed)
        XCTAssertEqual(blocked, .blocked)
    }

    func testClientErrorFallsBackToAllow() async throws {
        // hasKey reports true, but the provider throws: the client fails before any network I/O.
        let moderator = try makeModerator(hasKey: true)
        let status = await moderator.moderate("Kids were playing on it this morning", reportTitle: "Swing")
        XCTAssertEqual(status, .allowed)
    }

    private struct ThrowingKeyProvider: APIKeyProvider {
        func apiKey() async throws -> String { throw ModelAPIError.missingKey }
    }

    private func makeModerator(hasKey: Bool) throws -> ModelCommentModerator {
        let prompts = try Prompts(bundle: .main)
        return ModelCommentModerator(client: MetaModelClient(keyProvider: ThrowingKeyProvider()),
                                      prompts: prompts, hasKey: { hasKey })
    }
}
