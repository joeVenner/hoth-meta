import XCTest
@testable import HoTHCore

final class DedupTests: XCTestCase {
    private let origin = Coordinate(latitude: 24.4539, longitude: 54.3773)

    /// Point `meters` north of origin (1 degree latitude = 2πR/360 m).
    private func north(_ meters: Double) -> Coordinate {
        let degrees = meters / (2 * .pi * Dedup.earthRadiusMeters / 360)
        return Coordinate(latitude: origin.latitude + degrees, longitude: origin.longitude)
    }

    func testHaversineKnownDistances() {
        XCTAssertEqual(Dedup.haversineMeters(origin, origin), 0, accuracy: 1e-9)
        let milliDegree = Coordinate(latitude: origin.latitude + 0.001, longitude: origin.longitude)
        XCTAssertEqual(Dedup.haversineMeters(origin, milliDegree), 111.2, accuracy: 0.1)
        // Abu Dhabi -> Dubai (approx. 110-125 km great-circle).
        let dubai = Coordinate(latitude: 25.2048, longitude: 55.2708)
        XCTAssertEqual(Dedup.haversineMeters(origin, dubai) / 1000, 124, accuracy: 6)
        XCTAssertEqual(Dedup.haversineMeters(origin, dubai), Dedup.haversineMeters(dubai, origin), accuracy: 1e-6)
    }

    func testRadiusIsInclusiveAt75Meters() {
        let reports = [
            ExistingReport(id: "under", category: .potholePavement, coordinate: north(74), isOpen: true),
            ExistingReport(id: "edge", category: .potholePavement, coordinate: north(74.999), isOpen: true),
            ExistingReport(id: "over", category: .potholePavement, coordinate: north(76), isOpen: true)
        ]
        let ids = Dedup.candidates(for: .potholePavement, at: origin, among: reports).map(\.report.id)
        XCTAssertEqual(ids, ["under", "edge"])
    }

    func testFiltersCategoryAndClosedAndSortsNearestFirst() {
        let reports = [
            ExistingReport(id: "far", category: .potholePavement, coordinate: north(60), isOpen: true),
            ExistingReport(id: "near", category: .potholePavement, coordinate: north(10), isOpen: true),
            ExistingReport(id: "closed", category: .potholePavement, coordinate: north(5), isOpen: false),
            ExistingReport(id: "other", category: .waterLeak, coordinate: north(5), isOpen: true)
        ]
        let ids = Dedup.candidates(for: .potholePavement, at: origin, among: reports).map(\.report.id)
        XCTAssertEqual(ids, ["near", "far"])
    }

    func testDecisionCombinesWithVerdict() {
        let candidate = DedupCandidate(
            report: ExistingReport(id: "a", category: .potholePavement, coordinate: north(10), isOpen: true),
            distanceMeters: 10)
        XCTAssertEqual(Dedup.decide(nearest: nil, verdict: SameIssueVerdict(sameIssue: true, reason: "x")), .newReport)
        XCTAssertEqual(Dedup.decide(nearest: candidate, verdict: nil), .candidate(candidate))
        XCTAssertEqual(Dedup.decide(nearest: candidate, verdict: SameIssueVerdict(sameIssue: true, reason: "same")),
                       .duplicate(of: candidate, reason: "same"))
        XCTAssertEqual(Dedup.decide(nearest: candidate, verdict: SameIssueVerdict(sameIssue: false, reason: "diff")),
                       .distinct(candidate, reason: "diff"))
    }
}
