import Foundation

public struct Coordinate: Equatable, Sendable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// Minimal view of an existing report for duplicate search.
public struct ExistingReport: Equatable, Sendable {
    public let id: String
    public let category: ReportCategory
    public let coordinate: Coordinate
    public let isOpen: Bool

    public init(id: String, category: ReportCategory, coordinate: Coordinate, isOpen: Bool) {
        self.id = id
        self.category = category
        self.coordinate = coordinate
        self.isOpen = isOpen
    }
}

public struct DedupCandidate: Equatable, Sendable {
    public let report: ExistingReport
    public let distanceMeters: Double
}

public enum DedupDecision: Equatable, Sendable {
    /// No nearby open report of the same category.
    case newReport
    /// Nearby candidate, but no model verdict yet (or the verdict is unavailable).
    case candidate(DedupCandidate)
    /// Confirmed duplicate: add a confirmation to the existing report instead.
    case duplicate(of: DedupCandidate, reason: String)
    /// The model says it is a different physical issue.
    case distinct(DedupCandidate, reason: String)
}

/// Pure duplicate search: same category, open, within 75 m; the model decides "same physical issue".
public enum Dedup {
    public static let radiusMeters: Double = 75
    /// Mean Earth radius (IUGG).
    public static let earthRadiusMeters: Double = 6_371_008.8

    public static func haversineMeters(_ a: Coordinate, _ b: Coordinate) -> Double {
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLat = lat2 - lat1
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadiusMeters * asin(min(1, sqrt(h)))
    }

    /// Candidates sorted nearest first.
    public static func candidates(for category: ReportCategory, at coordinate: Coordinate,
                                  among reports: [ExistingReport], radius: Double = radiusMeters) -> [DedupCandidate] {
        reports
            .filter { $0.isOpen && $0.category == category }
            .map { DedupCandidate(report: $0, distanceMeters: haversineMeters(coordinate, $0.coordinate)) }
            .filter { $0.distanceMeters <= radius }
            .sorted { $0.distanceMeters < $1.distanceMeters }
    }

    /// Combines the nearest candidate with the DuplicateJudge verdict for that candidate.
    public static func decide(nearest: DedupCandidate?, verdict: SameIssueVerdict?) -> DedupDecision {
        guard let nearest else { return .newReport }
        guard let verdict else { return .candidate(nearest) }
        return verdict.sameIssue
            ? .duplicate(of: nearest, reason: verdict.reason)
            : .distinct(nearest, reason: verdict.reason)
    }
}
