import Foundation

public enum RewardEvent: Equatable, Sendable {
    case firstReporter
    case confirmation
    case verifiedFix
    /// Report rejected by plausibility checks or moderation (affects trust, no points).
    case rejectedReport
    /// Report later verified (by neighbours or a fix); raises trust.
    case verifiedReport
}

public enum HeroLevel: String, CaseIterable, Sendable {
    case neighbour, guardian, heroOfTheHay

    public var minimumPoints: Int {
        switch self {
        case .neighbour: return 0
        case .guardian: return 150
        case .heroOfTheHay: return 400
        }
    }

    public var titleEN: String {
        switch self {
        case .neighbour: return "Neighbour"
        case .guardian: return "Guardian"
        case .heroOfTheHay: return "Hero of the Hay"
        }
    }

    public var titleAR: String {
        switch self {
        case .neighbour: return "جار"
        case .guardian: return "حارس"
        case .heroOfTheHay: return "بطل الحي"
        }
    }
}

public struct RewardState: Equatable, Sendable {
    public let points: Int
    public let trust: Int

    public static let initial = RewardState(points: 0, trust: Rewards.initialTrust)

    public init(points: Int, trust: Int) {
        self.points = max(0, points)
        self.trust = min(max(trust, 0), 100)
    }

    public var level: HeroLevel { Rewards.level(forPoints: points) }
}

/// Pure points, trust and level rules.
public enum Rewards {
    public static let firstReporterPoints = 20
    public static let confirmationPoints = 10
    public static let verifiedFixPoints = 50
    public static let initialTrust = 50
    public static let verifiedTrustGain = 5
    public static let rejectedTrustLoss = 15

    public static func points(for event: RewardEvent) -> Int {
        switch event {
        case .firstReporter: return firstReporterPoints
        case .confirmation: return confirmationPoints
        case .verifiedFix: return verifiedFixPoints
        case .rejectedReport, .verifiedReport: return 0
        }
    }

    public static func trustDelta(for event: RewardEvent) -> Int {
        switch event {
        case .verifiedReport, .verifiedFix: return verifiedTrustGain
        case .rejectedReport: return -rejectedTrustLoss
        case .firstReporter, .confirmation: return 0
        }
    }

    public static func apply(_ event: RewardEvent, to state: RewardState) -> RewardState {
        RewardState(points: state.points + points(for: event), trust: state.trust + trustDelta(for: event))
    }

    public static func apply(_ events: [RewardEvent], to state: RewardState = .initial) -> RewardState {
        events.reduce(state) { apply($1, to: $0) }
    }

    public static func level(forPoints points: Int) -> HeroLevel {
        HeroLevel.allCases.last { points >= $0.minimumPoints } ?? .neighbour
    }

    /// Points still needed for the next level, or nil at the top level.
    public static func pointsToNextLevel(from points: Int) -> Int? {
        let current = level(forPoints: points)
        guard let next = HeroLevel.allCases.first(where: { $0.minimumPoints > current.minimumPoints }) else { return nil }
        return next.minimumPoints - points
    }
}
