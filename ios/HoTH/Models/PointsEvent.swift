import Foundation
import SwiftData

/// A ledger entry for points granted to (or removed from) a neighbour.
@Model
final class PointsEvent {
    @Attribute(.unique) var id: UUID
    var user: Neighbour?
    var delta: Int
    var reasonRaw: String
    var createdAt: Date
    /// The related report, by id, to avoid a second relationship graph.
    var reportID: UUID?
    var isDemoSeed: Bool

    init(
        id: UUID = UUID(),
        user: Neighbour?,
        delta: Int,
        reason: PointsReason,
        createdAt: Date = .now,
        reportID: UUID? = nil,
        isDemoSeed: Bool = false
    ) {
        self.id = id
        self.user = user
        self.delta = delta
        self.reasonRaw = reason.rawValue
        self.createdAt = createdAt
        self.reportID = reportID
        self.isDemoSeed = isDemoSeed
    }

    var reason: PointsReason {
        get { PointsReason(rawValue: reasonRaw) ?? .reportPosted }
        set { reasonRaw = newValue.rawValue }
    }
}
