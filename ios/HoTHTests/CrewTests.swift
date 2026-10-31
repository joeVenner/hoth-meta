import CoreGraphics
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

    init(verdict: FixVerdict) { self.verdict = verdict }

    func verify(before: Data, after: Data, reportTitle: String, categoryRaw: String,
                beforeCapturedAt: Date) async throws -> FixVerdict {
        callCount += 1
        return verdict
    }
}
