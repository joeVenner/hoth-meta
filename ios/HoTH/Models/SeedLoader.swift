import Foundation
import OSLog
import SwiftData

/// Inserts the bundled demo community (`seed.json`) into SwiftData.
///
/// Seeding is idempotent: it only inserts when no demo rows exist, and records a UserDefaults flag. Every seeded record has `isDemoSeed == true` (demo photos, the demo fix check and duplicate matching key off it).
/// Seed times are stored as "hours ago" and resolved against the moment of seeding.
@MainActor
enum SeedLoader {
    static let seededFlagKey = "hoth.seed.v1.loaded"
    static let resourceName = "seed"

    private static let logger = Logger(subsystem: "io.fomy.hoth", category: "SeedLoader")

    enum SeedError: Error, CustomStringConvertible {
        case resourceMissing(String)
        case unknownNeighbour(key: String, context: String)
        case unknownReport(key: String)

        var description: String {
            switch self {
            case .resourceMissing(let name): return "Seed resource \(name).json not found in bundle"
            case .unknownNeighbour(let key, let context): return "Seed references unknown neighbour '\(key)' in \(context)"
            case .unknownReport(let key): return "Seed references unknown report '\(key)'"
            }
        }
    }

    /// Seeds the store if it has not been seeded yet. Safe to call on every launch.
    /// - Returns: `true` when records were inserted.
    @discardableResult
    static func seedIfNeeded(
        context: ModelContext,
        defaults: UserDefaults = .standard,
        bundle: Bundle = .main,
        now: Date = .now
    ) throws -> Bool {
        // The store itself is the source of truth (the flag alone would skip seeding a fresh
        // in-memory fallback store); the flag records that seeding happened for this install.
        if try hasDemoSeed(context: context) {
            defaults.set(true, forKey: seededFlagKey)
            return false
        }
        let seed = try loadSeed(bundle: bundle)
        try insert(seed, into: context, now: now)
        try context.save()
        defaults.set(true, forKey: seededFlagKey)
        logger.info("Seeded demo community: \(seed.neighbours.count) neighbours, \(seed.reports.count) reports")
        return true
    }

    /// Demo mode reset: deletes ALL records (seeded and user-created) and re-inserts the seed.
    static func reset(
        context: ModelContext,
        defaults: UserDefaults = .standard,
        bundle: Bundle = .main,
        now: Date = .now
    ) throws {
        try deleteAll(Report.self, in: context)
        try deleteAll(PointsEvent.self, in: context)
        try deleteAll(Neighbour.self, in: context)
        // Comments and votes cascade from reports/neighbours; sweep orphans anyway.
        try deleteAll(Comment.self, in: context)
        try deleteAll(Vote.self, in: context)
        try context.save()
        defaults.set(false, forKey: seededFlagKey)
        try seedIfNeeded(context: context, defaults: defaults, bundle: bundle, now: now)
    }

    /// Decodes `seed.json` from the bundle.
    static func loadSeed(bundle: Bundle = .main) throws -> SeedFile {
        guard let url = bundle.url(forResource: resourceName, withExtension: "json") else {
            throw SeedError.resourceMissing(resourceName)
        }
        return try JSONDecoder().decode(SeedFile.self, from: Data(contentsOf: url))
    }

    // MARK: - Private

    private static func hasDemoSeed(context: ModelContext) throws -> Bool {
        var descriptor = FetchDescriptor<Neighbour>(predicate: #Predicate { $0.isDemoSeed })
        descriptor.fetchLimit = 1
        return try context.fetchCount(descriptor) > 0
    }

    private static func deleteAll<T: PersistentModel>(_ type: T.Type, in context: ModelContext) throws {
        // Fetch-and-delete instead of batch delete so relationship delete rules are honoured.
        for model in try context.fetch(FetchDescriptor<T>()) {
            context.delete(model)
        }
    }

    private static func insert(_ seed: SeedFile, into context: ModelContext, now: Date) throws {
        func date(hoursAgo: Double) -> Date { now.addingTimeInterval(-hoursAgo * 3600) }

        var neighbours: [String: Neighbour] = [:]
        for entry in seed.neighbours {
            let neighbour = Neighbour(
                displayName: entry.displayName,
                avatarSymbol: entry.avatarSymbol,
                hayName: entry.hay,
                points: entry.points,
                trust: entry.trust,
                isCurrentUser: entry.isCurrentUser,
                isDemoSeed: true
            )
            context.insert(neighbour)
            neighbours[entry.key] = neighbour
        }

        func neighbour(_ key: String, _ where_: String) throws -> Neighbour {
            guard let found = neighbours[key] else { throw SeedError.unknownNeighbour(key: key, context: where_) }
            return found
        }

        var reports: [String: Report] = [:]
        for entry in seed.reports {
            let createdAt = date(hoursAgo: entry.hoursAgo)
            let report = Report(
                createdAt: createdAt,
                category: IssueCategory(rawValue: entry.category) ?? .other,
                titleEN: entry.titleEN,
                titleAR: entry.titleAR,
                summaryEN: entry.summaryEN,
                summaryAR: entry.summaryAR,
                latitude: entry.latitude,
                longitude: entry.longitude,
                placeName: entry.placeName,
                photoFileName: entry.photo,
                blurredPhotoFileName: entry.photo,
                priority: PriorityLevel(rawValue: entry.priority) ?? .medium,
                priorityScore: entry.priorityScore,
                priorityReasonEN: entry.priorityReasonEN,
                priorityReasonAR: entry.priorityReasonAR,
                signals: entry.signals,
                status: ReportStatus(rawValue: entry.status) ?? .open,
                isPosted: true,
                isAnonymous: entry.isAnonymous,
                isDemoSeed: true,
                reporter: try neighbour(entry.reporter, "report \(entry.key)"),
                confirmations: entry.confirmations,
                fixPhotoFileName: entry.fixPhoto,
                fixedAt: entry.fixedHoursAgo.map { date(hoursAgo: $0) }
            )
            context.insert(report)
            reports[entry.key] = report

            for (index, voterKey) in entry.voters.enumerated() {
                // Spread votes between report creation and now.
                let fraction = Double(index + 1) / Double(entry.voters.count + 1)
                let vote = Vote(
                    voter: try neighbour(voterKey, "votes of \(entry.key)"),
                    createdAt: createdAt.addingTimeInterval(now.timeIntervalSince(createdAt) * fraction),
                    isDemoSeed: true
                )
                context.insert(vote)
                vote.report = report
            }

            for commentEntry in entry.comments {
                let comment = Comment(
                    author: try neighbour(commentEntry.author, "comments of \(entry.key)"),
                    text: commentEntry.text,
                    createdAt: date(hoursAgo: commentEntry.hoursAgo),
                    moderationStatus: ModerationStatus(rawValue: commentEntry.moderation ?? "") ?? .allowed,
                    isDemoSeed: true
                )
                context.insert(comment)
                comment.report = report
            }
        }

        for entry in seed.pointsEvents {
            var reportID: UUID?
            if let reportKey = entry.report {
                guard let report = reports[reportKey] else { throw SeedError.unknownReport(key: reportKey) }
                reportID = report.id
            }
            let event = PointsEvent(
                user: try neighbour(entry.user, "points events"),
                delta: entry.delta,
                reason: PointsReason(rawValue: entry.reason) ?? .reportPosted,
                createdAt: date(hoursAgo: entry.hoursAgo),
                reportID: reportID,
                isDemoSeed: true
            )
            context.insert(event)
        }
    }
}

// MARK: - seed.json schema

struct SeedFile: Decodable {
    struct Area: Decodable {
        let name: String
        let nameAR: String
        let latitude: Double
        let longitude: Double
    }

    struct NeighbourEntry: Decodable {
        let key: String
        let displayName: String
        let avatarSymbol: String
        let hay: String
        let points: Int
        let trust: Int
        let isCurrentUser: Bool
    }

    struct CommentEntry: Decodable {
        let author: String
        let hoursAgo: Double
        let text: String
        let moderation: String?
    }

    struct ReportEntry: Decodable {
        let key: String
        let hoursAgo: Double
        let category: String
        let titleEN: String
        let titleAR: String
        let summaryEN: String
        let summaryAR: String
        let latitude: Double
        let longitude: Double
        let placeName: String
        let photo: String?
        let priority: String
        let priorityScore: Int
        let priorityReasonEN: String
        let priorityReasonAR: String
        let signals: [String]
        let status: String
        let fixedHoursAgo: Double?
        let fixPhoto: String?
        let reporter: String
        let isAnonymous: Bool
        let confirmations: Int
        let voters: [String]
        let comments: [CommentEntry]
    }

    struct PointsEventEntry: Decodable {
        let user: String
        let delta: Int
        let reason: String
        let hoursAgo: Double
        let report: String?
    }

    let version: Int
    let area: Area
    let neighbours: [NeighbourEntry]
    let reports: [ReportEntry]
    let pointsEvents: [PointsEventEntry]
}
