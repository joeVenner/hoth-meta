import Foundation
import SwiftData

/// A resident of the hay (neighbourhood). Exactly one has `isCurrentUser == true`.
@Model
final class Neighbour {
    @Attribute(.unique) var id: UUID
    var displayName: String
    /// SF Symbol name or asset name for the avatar.
    var avatarSymbol: String
    var hayName: String
    var points: Int
    var trust: Int
    var isCurrentUser: Bool
    var isDemoSeed: Bool

    @Relationship(deleteRule: .nullify, inverse: \Report.reporter) var reports: [Report] = []
    @Relationship(deleteRule: .nullify, inverse: \Comment.author) var comments: [Comment] = []
    @Relationship(deleteRule: .cascade, inverse: \Vote.voter) var votes: [Vote] = []
    @Relationship(deleteRule: .cascade, inverse: \PointsEvent.user) var pointsEvents: [PointsEvent] = []

    init(
        id: UUID = UUID(),
        displayName: String,
        avatarSymbol: String = "person.crop.circle.fill",
        hayName: String,
        points: Int = 0,
        trust: Int = 0,
        isCurrentUser: Bool = false,
        isDemoSeed: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.avatarSymbol = avatarSymbol
        self.hayName = hayName
        self.points = points
        self.trust = trust
        self.isCurrentUser = isCurrentUser
        self.isDemoSeed = isDemoSeed
    }

    var level: HeroLevel { HeroLevel.forPoints(points) }
}
