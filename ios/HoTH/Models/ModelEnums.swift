import Foundation

// App-local enums mirrored as String raw values in SwiftData models.
// Kept independent of the HoTHCore package so the persistence layer compiles on its own;
// raw values intentionally match prompts.json so conversion is a plain rawValue round-trip.

/// Issue category. Raw values match `categories` in prompts.json.
enum IssueCategory: String, CaseIterable, Codable, Sendable {
    case playgroundEquipment = "playground_equipment"
    case fitnessEquipment = "fitness_equipment"
    case potholePavement = "pothole_pavement"
    case electricalHazard = "electrical_hazard"
    case openManhole = "open_manhole"
    case wasteOverflowDumping = "waste_overflow_dumping"
    case blockedAccessibility = "blocked_accessibility"
    case waterLeak = "water_leak"
    case other = "other"
    case notAnIssue = "not_an_issue"

    /// SF Symbol shown when a report photo (e.g. a `seed_<n>` placeholder) is unavailable.
    var fallbackSymbol: String {
        switch self {
        case .playgroundEquipment: return "figure.play"
        case .fitnessEquipment: return "dumbbell.fill"
        case .potholePavement: return "road.lanes"
        case .electricalHazard: return "bolt.trianglebadge.exclamationmark.fill"
        case .openManhole: return "exclamationmark.octagon.fill"
        case .wasteOverflowDumping: return "trash.fill"
        case .blockedAccessibility: return "figure.roll"
        case .waterLeak: return "drop.fill"
        case .other: return "exclamationmark.triangle.fill"
        case .notAnIssue: return "checkmark.circle"
        }
    }
}

/// Priority level. Raw values match `severity_levels` in prompts.json.
enum PriorityLevel: String, CaseIterable, Codable, Sendable, Comparable {
    case low, medium, high, critical

    private var rank: Int {
        switch self {
        case .low: return 0
        case .medium: return 1
        case .high: return 2
        case .critical: return 3
        }
    }

    static func < (lhs: PriorityLevel, rhs: PriorityLevel) -> Bool { lhs.rank < rhs.rank }
}

/// Lifecycle of a report.
enum ReportStatus: String, CaseIterable, Codable, Sendable {
    case open
    case inProgress
    case fixed
    case rejected
}

/// Outcome of comment moderation (P1-06).
enum ModerationStatus: String, CaseIterable, Codable, Sendable {
    case pending
    case allowed
    case softened
    case blocked
}

/// Why points were granted (P1-04).
enum PointsReason: String, CaseIterable, Codable, Sendable {
    case welcomeBonus
    case reportPosted
    case reportVerified
    case reportFixed
    case confirmation
    case helpfulComment
    case rejectedSubmission
}

/// Hero levels derived from points: Neighbour (0) -> Guardian (150) -> Hero of the Hay (400).
enum HeroLevel: String, CaseIterable, Sendable {
    case neighbour
    case guardian
    case heroOfTheHay

    static func forPoints(_ points: Int) -> HeroLevel {
        if points >= 400 { return .heroOfTheHay }
        if points >= 150 { return .guardian }
        return .neighbour
    }
}
