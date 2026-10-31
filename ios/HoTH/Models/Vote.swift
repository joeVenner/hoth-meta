import Foundation
import SwiftData

/// An upvote on a report. One per voter per report; enforce via `Report.hasVote(from:)`
/// before inserting (SwiftData has no compound unique constraint on iOS 17).
@Model
final class Vote {
    @Attribute(.unique) var id: UUID
    var voter: Neighbour?
    var report: Report?
    var createdAt: Date
    var isDemoSeed: Bool

    init(id: UUID = UUID(), voter: Neighbour?, createdAt: Date = .now, isDemoSeed: Bool = false) {
        self.id = id
        self.voter = voter
        self.createdAt = createdAt
        self.isDemoSeed = isDemoSeed
    }
}

extension Report {
    func hasVote(from neighbour: Neighbour) -> Bool {
        votes.contains { $0.voter?.id == neighbour.id }
    }
}
