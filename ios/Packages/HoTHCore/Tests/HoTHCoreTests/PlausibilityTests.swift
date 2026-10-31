import XCTest
@testable import HoTHCore

final class PlausibilityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_760_000_000)
    private let goodGPS = GPSFix(latitude: 24.45, longitude: 54.38, accuracyMeters: 10)
    private let goodVision = makeVision(category: .potholePavement, scene: .street, proposal: .medium)

    private func evaluate(source: CaptureSource = .liveCamera, age: TimeInterval = 10, gps: GPSFix?? = .none,
                          vision: VisionAnalysis? = nil, reported: ReportCategory? = nil,
                          demo: Bool = false) -> PlausibilityResult {
        Plausibility.evaluate(PlausibilityInput(
            captureSource: source, capturedAt: now.addingTimeInterval(-age), now: now,
            gps: gps ?? goodGPS, vision: vision ?? goodVision, reportedCategory: reported, isDemoMode: demo))
    }

    func testFreshLiveCaptureIsAccepted() {
        let result = evaluate()
        XCTAssertEqual(result.status, .accepted)
        XCTAssertEqual(result.reasonsEN.count, result.reasonsAR.count)
    }

    func testDemoLibraryRejectedOutsideDemoMode() {
        XCTAssertEqual(evaluate(source: .demoLibrary).status, .rejected)
    }

    func testDemoLibraryAcceptedInDemoModeEvenIfOld() {
        XCTAssertEqual(evaluate(source: .demoLibrary, age: 86_400, demo: true).status, .accepted)
    }

    func testCaptureOlderThanTwoMinutesNeedsLivePhoto() {
        XCTAssertEqual(evaluate(age: 120).status, .accepted)
        XCTAssertEqual(evaluate(age: 121).status, .needsLivePhoto)
    }

    func testFutureCaptureTimeBeyondSkewNeedsLivePhoto() {
        XCTAssertEqual(evaluate(age: -30).status, .accepted)
        XCTAssertEqual(evaluate(age: -61).status, .needsLivePhoto)
    }

    func testMissingGPSRejected() {
        XCTAssertEqual(evaluate(gps: .some(nil)).status, .rejected)
    }

    func testPoorGPSAccuracyNeedsLivePhoto() {
        let poor = GPSFix(latitude: 24.45, longitude: 54.38, accuracyMeters: 250)
        XCTAssertEqual(evaluate(gps: .some(poor)).status, .needsLivePhoto)
    }

    func testScreenOrPrintNeedsLivePhoto() {
        let result = evaluate(vision: makeVision(category: .potholePavement, screen: true))
        XCTAssertEqual(result.status, .needsLivePhoto)
        XCTAssertTrue(result.reasonsEN.contains { $0.contains("screen") })
    }

    func testStockOrWatermarkNeedsLivePhoto() {
        XCTAssertEqual(evaluate(vision: makeVision(category: .potholePavement, stock: true)).status, .needsLivePhoto)
    }

    func testNotAnIssueOrNotShowingIssueNeedsLivePhoto() {
        XCTAssertEqual(evaluate(vision: makeVision(category: .notAnIssue)).status, .needsLivePhoto)
        XCTAssertEqual(evaluate(vision: makeVision(category: .waterLeak, showsIssue: false)).status, .needsLivePhoto)
    }

    func testCategoryMismatchIsSoftNote() {
        let result = evaluate(reported: .waterLeak)
        XCTAssertEqual(result.status, .accepted)
        XCTAssertTrue(result.reasonsEN.first?.contains("pothole pavement") ?? false)
    }

    func testWorstStatusWinsAndAllReasonsKept() {
        let result = evaluate(source: .demoLibrary, gps: .some(nil),
                              vision: makeVision(category: .potholePavement, screen: true))
        XCTAssertEqual(result.status, .rejected)
        XCTAssertGreaterThanOrEqual(result.reasonsEN.count, 2)
        XCTAssertEqual(result.reasonsEN.count, result.reasonsAR.count)
    }

    func testWordingNeverClaimsProofOfAuthenticity() {
        let results = [
            evaluate(), evaluate(source: .demoLibrary), evaluate(age: 500), evaluate(gps: .some(nil)),
            evaluate(vision: makeVision(category: .notAnIssue, screen: true, stock: true))
        ]
        let banned = ["genuine", "fake", "proof", "authentic", "fraud"]
        for text in results.flatMap(\.reasonsEN) {
            for word in banned { XCTAssertFalse(text.lowercased().contains(word), text) }
        }
    }
}
