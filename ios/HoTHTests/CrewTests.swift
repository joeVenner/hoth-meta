import CoreGraphics
import HoTHCore
import SwiftData
import UIKit
import XCTest
@testable import HoTH

/// Crew workflow: status transitions, the points-once rule, level-up detection, and the fix-check
/// model with a stubbed verifier (no network).
@MainActor
final class CrewTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private var me: Neighbour!
    private var reporter: Neighbour!
    private var report: Report!

    override func setUp() async throws {
        container = try HoTHStore.makeContainer(inMemory: true)
        context = container.mainContext
        me = Neighbour(displayName: "You", hayName: "Khalifa City", points: 360, isCurrentUser: true)
        reporter = Neighbour(displayName: "Fatima", hayName: "Khalifa City", points: 100)
        context.insert(me)
        context.insert(reporter)
        report = makeReport(reporter: reporter, status: .open)
        let vote = Vote(voter: me)
        context.insert(vote)
        vote.report = report
        try context.save()
    }

    private func makeReport(reporter: Neighbour, status: ReportStatus,
                            priority: PriorityLevel = .high, score: Int = 70, hoursAgo: Double = 1) -> Report {
        let report = Report(createdAt: Date().addingTimeInterval(-hoursAgo * 3600), category: .potholePavement,
                            titleEN: "Pothole", titleAR: "حفرة", summaryEN: "", summaryAR: "",
                            latitude: 24.42, longitude: 54.57, placeName: "Street 1",
                            priority: priority, priorityScore: score, priorityReasonEN: "", priorityReasonAR: "",
                            status: status, reporter: reporter)
        context.insert(report)
        return report
    }

    private let resolved = FixVerdict(resolved: true, reasonEN: "Patched", reasonAR: "تم", remaining: [], isCanned: true)
    private let notResolved = FixVerdict(
        resolved: false, reasonEN: "Half filled", reasonAR: "نصف",
        remaining: [.init(label: "gravel", box: CGRect(x: 0.2, y: 0.5, width: 0.2, height: 0.2))], isCanned: true)

    private func fixEvents() throws -> [PointsEvent] {
        let raw = PointsReason.reportFixed.rawValue
        return try context.fetch(FetchDescriptor<PointsEvent>(predicate: #Predicate { $0.reasonRaw == raw }))
    }

    // MARK: Status transitions

    func testStartWorkMovesOpenToInProgress() throws {
        try CrewWorkflow.startWork(on: report)
        XCTAssertEqual(report.status, .inProgress)
        try CrewWorkflow.startWork(on: report)  // idempotent
        XCTAssertEqual(report.status, .inProgress)
    }

    func testStartWorkRejectsClosedReports() {
        report.status = .fixed
        XCTAssertThrowsError(try CrewWorkflow.startWork(on: report)) {
            XCTAssertEqual($0 as? CrewWorkflowError, .notActionable(.fixed))
        }
    }

    func testRejectedVerdictKeepsStatusAndAwardsNothing() throws {
        try CrewWorkflow.startWork(on: report)
        let outcome = try CrewWorkflow.apply(notResolved, to: report, fixPhotoFileName: "x.jpg", context: context)
        XCTAssertFalse(outcome.verdictResolved)
        XCTAssertEqual(report.status, .inProgress)
        XCTAssertNil(report.fixedAt)
        XCTAssertNil(report.fixPhotoFileName)
        XCTAssertEqual(reporter.points, 100)
        XCTAssertTrue(try fixEvents().isEmpty)
    }

    func testResolvedVerdictMarksFixed() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let outcome = try CrewWorkflow.apply(resolved, to: report, fixPhotoFileName: "fix.jpg", context: context, now: now)
        XCTAssertEqual(outcome.newStatus, .fixed)
        XCTAssertEqual(report.status, .fixed)
        XCTAssertEqual(report.fixedAt, now)
        XCTAssertEqual(report.fixPhotoFileName, "fix.jpg")
    }

    func testFixedIsTerminal() throws {
        try CrewWorkflow.apply(resolved, to: report, fixPhotoFileName: nil, context: context)
        XCTAssertThrowsError(try CrewWorkflow.apply(resolved, to: report, fixPhotoFileName: nil, context: context))
    }

    // MARK: Points

    func testReporterGetsFiftyAndConfirmerTenOnce() throws {
        let outcome = try CrewWorkflow.apply(resolved, to: report, fixPhotoFileName: nil, context: context)
        XCTAssertEqual(outcome.reporterPointsAwarded, 50)
        XCTAssertEqual(reporter.points, 150)
        XCTAssertEqual(me.points, 370)
        XCTAssertEqual(outcome.currentUserPointsAwarded, 10)
        XCTAssertTrue(outcome.isCurrentUserInvolved)
        XCTAssertFalse(outcome.currentUserWasReporter)
        XCTAssertEqual(try fixEvents().count, 2)
    }

    func testPointsAreAwardedOncePerReport() throws {
        XCTAssertTrue(try CrewWorkflow.award(50, to: reporter, for: report, context: context))
        XCTAssertFalse(try CrewWorkflow.award(50, to: reporter, for: report, context: context))
        XCTAssertEqual(reporter.points, 150)
        // Even if the report is reopened and fixed again, the reporter is not paid twice.
        report.status = .open
        let outcome = try CrewWorkflow.apply(resolved, to: report, fixPhotoFileName: nil, context: context)
        XCTAssertEqual(outcome.reporterPointsAwarded, 0)
        XCTAssertEqual(reporter.points, 150)
        XCTAssertEqual(try fixEvents().filter { $0.user?.id == reporter.id }.count, 1)
    }

    func testLevelUpDetectedWhenCurrentUserIsReporter() throws {
        let mine = makeReport(reporter: me, status: .inProgress)
        let outcome = try CrewWorkflow.apply(resolved, to: mine, fixPhotoFileName: nil, context: context)
        XCTAssertTrue(outcome.currentUserWasReporter)
        XCTAssertEqual(outcome.currentUserPointsAwarded, 50)
        XCTAssertEqual(outcome.currentUserPointsAfter, 410)
        XCTAssertTrue(outcome.didLevelUp)  // Guardian (360) → Hero of the Hay (400+)
    }

    // MARK: Queue

    func testQueueRanksByLevelThenScoreThenAgeAndHidesClosed() {
        let critical = makeReport(reporter: reporter, status: .open, priority: .critical, score: 90)
        let oldHigh = makeReport(reporter: reporter, status: .inProgress, priority: .high, score: 70, hoursAgo: 10)
        let fixed = makeReport(reporter: reporter, status: .fixed, priority: .critical, score: 99)
        let ranked = CrewQueue.ranked([report, fixed, oldHigh, critical])
        XCTAssertEqual(ranked.map(\.id), [critical.id, oldHigh.id, report.id])
        XCTAssertTrue(CrewQueue.ranked([report], teamNameEN: ReportRouting.parks.nameEN).isEmpty)
        XCTAssertEqual(CrewQueue.ranked([report], teamNameEN: ReportRouting.roads.nameEN).count, 1)
    }

    // MARK: Fix-check model with a stub verifier

    func testFixCheckModelRejectedKeepsOpen() async throws {
        let stub = StubVerifier(verdict: notResolved)
        let model = FixCheckModel(verifierFactory: { _ in stub })
        let mine = makeReport(reporter: me, status: .open)
        mine.photoFileName = "demo_fix_before"
        mine.isDemoSeed = true
        await model.check(report: mine, after: Self.sampleImage(), demo: .bad, context: context)
        XCTAssertEqual(model.phase, .verdict)
        XCTAssertEqual(model.verdict?.resolved, false)
        XCTAssertEqual(mine.status, .open)
        XCTAssertNil(model.celebration)
        XCTAssertEqual(stub.callCount, 1)
    }

    func testFixCheckModelWithoutVerifierFailsWithoutCalling() async {
        let model = FixCheckModel(verifierFactory: { _ in nil })
        report.photoFileName = "demo_fix_before"
        report.isDemoSeed = true
        await model.check(report: report, after: Self.sampleImage(), demo: nil, context: context)
        guard case .failed = model.phase else { return XCTFail("Expected failure, got \(model.phase)") }
        XCTAssertEqual(report.status, .open)
    }

    func testNotificationMessage() {
        let en = FixedMomentNotifier.message(titleEN: "Spring rider seat snapped", titleAR: "", points: 50,
                                             wasReporter: true, arabic: false)
        XCTAssertEqual(en, "The spring rider seat snapped you reported is fixed ✨ +50 points")
        let ar = FixedMomentNotifier.message(titleEN: "x", titleAR: "حفرة", points: 10, wasReporter: false, arabic: true)
        XCTAssertTrue(ar.contains("حفرة") && ar.contains("+10"))
    }

    // MARK: SAM "what's left"

    private var liveRejected: FixVerdict {
        FixVerdict(resolved: false, reasonEN: notResolved.reasonEN, reasonAR: notResolved.reasonAR,
                   remaining: notResolved.remaining, isCanned: false)
    }

    private func demoSeedReport() -> Report {
        let mine = makeReport(reporter: me, status: .open)
        mine.photoFileName = "demo_fix_before"
        mine.isDemoSeed = true
        return mine
    }

    func testRejectedLiveVerdictPrefersSAMBoxes() async throws {
        let stub = StubVerifier(verdict: liveRejected)
        let sam = SegmentOutline(concept: "pothole", boxes: [NormalizedBox(x: 0.1, y: 0.6, w: 0.3, h: 0.2)])
        let fake = FakeOutliner { _, _ in sam }
        let model = FixCheckModel(verifierFactory: { _ in stub }, outlinerFactory: { fake })
        await model.check(report: demoSeedReport(), after: Self.sampleImage(), demo: nil, context: context)
        await model.waitForOutline()

        XCTAssertEqual(model.phase, .verdict)
        XCTAssertEqual(model.samRemaining, sam)
        XCTAssertEqual(fake.calls.first?.category, .potholePavement)
        XCTAssertEqual(fake.calls.first?.jpeg, stub.lastAfter, "SAM sees exactly the after JPEG the verifier saw")
        let shown = FixCheckModel.remainingRegions(verdict: try XCTUnwrap(model.verdict), sam: model.samRemaining)
        XCTAssertTrue(shown.isFromSAM)
        XCTAssertEqual(shown.regions, [.init(label: "pothole", box: CGRect(x: 0.1, y: 0.6, width: 0.3, height: 0.2))])
    }

    func testSAMFailureOrNoMatchKeepsSparkBoxes() async throws {
        let failing = FakeOutliner { _, _ in throw HazardSegmenter.Failure.timedOut }
        let model = FixCheckModel(verifierFactory: { _ in StubVerifier(verdict: self.liveRejected) },
                                  outlinerFactory: { failing })
        await model.check(report: demoSeedReport(), after: Self.sampleImage(), demo: nil, context: context)
        await model.waitForOutline()
        XCTAssertEqual(model.phase, .verdict)
        XCTAssertNil(model.samRemaining)
        XCTAssertEqual(failing.calls.count, 1)

        let verdict = liveRejected
        XCTAssertEqual(FixCheckModel.remainingRegions(verdict: verdict, sam: nil).regions, verdict.remaining)
        let none = FixCheckModel.remainingRegions(verdict: verdict, sam: SegmentOutline(concept: "pothole", boxes: []))
        XCTAssertFalse(none.isFromSAM)
        XCTAssertEqual(none.regions, verdict.remaining)
        let fixed = FixCheckModel.remainingRegions(verdict: resolved, sam: SegmentOutline(
            concept: "pothole", boxes: [NormalizedBox(x: 0, y: 0, w: 1, h: 1)]))
        XCTAssertTrue(fixed.regions.isEmpty, "a resolved repair shows nothing left")
    }

    func testCannedOrResolvedVerdictsNeverCallSAM() async throws {
        let fake = FakeOutliner { _, _ in SegmentOutline(concept: "pothole", boxes: []) }
        let canned = FixCheckModel(verifierFactory: { _ in StubVerifier(verdict: self.notResolved) },
                                   outlinerFactory: { fake })
        await canned.check(report: demoSeedReport(), after: Self.sampleImage(), demo: .bad, context: context)
        await canned.waitForOutline()
        let liveResolved = FixVerdict(resolved: true, reasonEN: "Patched", reasonAR: "تم", remaining: [], isCanned: false)
        let fixedModel = FixCheckModel(verifierFactory: { _ in StubVerifier(verdict: liveResolved) },
                                       outlinerFactory: { fake })
        await fixedModel.check(report: demoSeedReport(), after: Self.sampleImage(), demo: nil, context: context)
        await fixedModel.waitForOutline()
        XCTAssertTrue(fake.calls.isEmpty)
    }

    func testAfterPhotoIsMadeUprightBeforeChecking() async throws {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let sensor = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 60, height: 30), format: format)
            .image { context in
                UIColor.gray.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 60, height: 30))
            }.cgImage)
        let portrait = UIImage(cgImage: sensor, scale: 1, orientation: .right)
        let stub = StubVerifier(verdict: notResolved)
        let model = FixCheckModel(verifierFactory: { _ in stub }, outlinerFactory: { nil })
        await model.check(report: demoSeedReport(), after: portrait, demo: nil, context: context)
        XCTAssertEqual(model.afterImage?.imageOrientation, .up)
        XCTAssertEqual(model.afterImage?.cgImage?.width, 30)
        XCTAssertEqual(model.afterImage?.cgImage?.height, 60)
        XCTAssertEqual(JPEGSize.pixelSize(of: try XCTUnwrap(stub.lastAfter)), PixelSize(width: 30, height: 60))
        model.reset()
        XCTAssertNil(model.samRemaining)
    }

    private static func sampleImage() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40)).image { context in
            UIColor.gray.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        }
    }
}

private final class StubVerifier: FixVerifying, @unchecked Sendable {
    let verdict: FixVerdict
    private(set) var callCount = 0
    private(set) var lastAfter: Data?

    init(verdict: FixVerdict) { self.verdict = verdict }

    func verify(before: Data, after: Data, reportTitle: String, categoryRaw: String,
                beforeCapturedAt: Date) async throws -> FixVerdict {
        callCount += 1
        lastAfter = after
        return verdict
    }
}
