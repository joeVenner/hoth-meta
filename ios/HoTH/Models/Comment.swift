import Foundation
import SwiftData

/// A comment on a report.
@Model
final class Comment {
    @Attribute(.unique) var id: UUID
    var author: Neighbour?
    var report: Report?
    var text: String
    var createdAt: Date
    var moderationStatusRaw: String
    var isDemoSeed: Bool

    init(
        id: UUID = UUID(),
        author: Neighbour?,
        text: String,
        createdAt: Date = .now,
        moderationStatus: ModerationStatus = .pending,
        isDemoSeed: Bool = false
    ) {
        self.id = id
        self.author = author
        self.text = text
        self.createdAt = createdAt
        self.moderationStatusRaw = moderationStatus.rawValue
        self.isDemoSeed = isDemoSeed
    }

    var moderationStatus: ModerationStatus {
        get { ModerationStatus(rawValue: moderationStatusRaw) ?? .pending }
        set { moderationStatusRaw = newValue.rawValue }
    }
}
