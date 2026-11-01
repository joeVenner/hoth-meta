import HoTHCore
import SwiftData
import XCTest
@testable import HoTH

/// "I saw it too" from the feed card and case detail: guards, priority bump, points once.
@MainActor
final class SightingConfirmationTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var me: Neighbour!
    private var reporter: Neighbour!

    override func setUp() async throws {
        container = try HoTHStore.makeContainer(inMemory: true)
        context = container.mainContext
        suiteName = "SightingConfirmationTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        me = Neighbour(displayName: "You", hayName: "Khalifa City", points: 100, isCurrentUser: true)
        reporter = Neighbour(displayName: "Fatima", hayName: "Khalifa City", points: 100)
        context.insert(me)
        context.insert(reporter)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeReport(reporter: Neighbour, status: ReportStatus = .open, score: Int = 40) -> Report {
        let report = Report(createdAt: Date().addingTimeInterval(-3600), category: .potholePavement,
                            titleEN: "Pothole", titleAR: "حفرة", summaryEN: "", summaryAR: "",
                            latitude: 24.42, longitude: 54.57, placeName: "Street 1",
                            priority: .medium, priorityScore: score, priorityReasonEN: "", priorityReasonAR: "",
                            status: status, reporter: reporter)
        context.insert(report)
        return report
    }

    func testConfirmBumpsConfirmationsScoreAndPaysPointsOnce() throws {
        let report = makeReport(reporter: reporter)
        XCTAssertTrue(SightingConfirmation.canConfirm(report, by: me, defaults: defaults))

        XCTAssertTrue(SightingConfirmation.confirm(report, by: me, context: context, defaults: defaults))
        XCTAssertEqual(report.confirmations, 1)
        XCTAssertGreaterThan(report.priorityScore, 40)
        XCTAssertEqual(me.points, 100 + Rewards.confirmationPoints)
        XCTAssertTrue(ConfirmedReports.contains(report.id, defaults: defaults))

        XCTAssertFalse(SightingConfirmation.confirm(report, by: me, context: context, defaults: defaults))
        XCTAssertEqual(report.confirmations, 1)
        XCTAssertEqual(me.points, 100 + Rewards.confirmationPoints)
        XCTAssertEqual(try context.fetch(FetchDescriptor<PointsEvent>()).count, 1)
    }

    func testOwnReportCannotBeConfirmed() {
        let report = makeReport(reporter: me)
        XCTAssertFalse(SightingConfirmation.canConfirm(report, by: me, defaults: defaults))
        XCTAssertFalse(SightingConfirmation.confirm(report, by: me, context: context, defaults: defaults))
        XCTAssertEqual(report.confirmations, 0)
    }

    func testFixedReportCannotBeConfirmed() {
        let report = makeReport(reporter: reporter, status: .fixed)
        XCTAssertFalse(SightingConfirmation.confirm(report, by: me, context: context, defaults: defaults))
        XCTAssertEqual(me.points, 100)
    }

    func testNoCurrentUserCannotConfirm() {
        let report = makeReport(reporter: reporter)
        XCTAssertFalse(SightingConfirmation.canConfirm(report, by: nil, defaults: defaults))
        XCTAssertFalse(SightingConfirmation.confirm(report, by: nil, context: context, defaults: defaults))
    }
}
