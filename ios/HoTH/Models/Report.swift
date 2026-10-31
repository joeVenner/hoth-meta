import Foundation
import SwiftData

/// A neighbourhood hazard report. Photos live in the app Documents directory (or, for demo
/// seeds, as bundled `seed_<n>` asset names); only file names are stored here.
@Model
final class Report {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var categoryRaw: String
    var titleEN: String
    var titleAR: String
    var summaryEN: String
    var summaryAR: String
    var latitude: Double
    var longitude: Double
    var placeName: String

    /// Original photo file name (kept on device for the ticket only).
    var photoFileName: String?
    /// Face/plate-blurred photo file name used for public posting.
    var blurredPhotoFileName: String?
    /// Raw VisionAnalysis JSON, decoupled from the HoTHCore types.
    var analysisJSON: Data?

    var priorityRaw: String
    var priorityScore: Int
    var priorityReasonEN: String
    var priorityReasonAR: String
    /// JSON-encoded `[String]` of priority signal chips.
    var signalsJSON: Data?

    var statusRaw: String
    var isPosted: Bool
    var isAnonymous: Bool
    var isDemoSeed: Bool

    var reporter: Neighbour?
    @Relationship(deleteRule: .cascade, inverse: \Comment.report) var comments: [Comment] = []
    @Relationship(deleteRule: .cascade, inverse: \Vote.report) var votes: [Vote] = []

    var confirmations: Int
    var mergedReportIDs: [UUID]
    var fixPhotoFileName: String?
    var fixedAt: Date?

    init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        category: IssueCategory,
        titleEN: String,
        titleAR: String,
        summaryEN: String,
        summaryAR: String,
        latitude: Double,
        longitude: Double,
        placeName: String,
        photoFileName: String? = nil,
        blurredPhotoFileName: String? = nil,
        analysisJSON: Data? = nil,
        priority: PriorityLevel,
        priorityScore: Int,
        priorityReasonEN: String,
        priorityReasonAR: String,
        signals: [String] = [],
        status: ReportStatus = .open,
        isPosted: Bool = false,
        isAnonymous: Bool = false,
        isDemoSeed: Bool = false,
        reporter: Neighbour? = nil,
        confirmations: Int = 0,
        mergedReportIDs: [UUID] = [],
        fixPhotoFileName: String? = nil,
        fixedAt: Date? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.categoryRaw = category.rawValue
        self.titleEN = titleEN
        self.titleAR = titleAR
        self.summaryEN = summaryEN
        self.summaryAR = summaryAR
        self.latitude = latitude
        self.longitude = longitude
        self.placeName = placeName
        self.photoFileName = photoFileName
        self.blurredPhotoFileName = blurredPhotoFileName
        self.analysisJSON = analysisJSON
        self.priorityRaw = priority.rawValue
        self.priorityScore = priorityScore
        self.priorityReasonEN = priorityReasonEN
        self.priorityReasonAR = priorityReasonAR
        self.signalsJSON = Report.encodeSignals(signals)
        self.statusRaw = status.rawValue
        self.isPosted = isPosted
        self.isAnonymous = isAnonymous
        self.isDemoSeed = isDemoSeed
        self.reporter = reporter
        self.confirmations = confirmations
        self.mergedReportIDs = mergedReportIDs
        self.fixPhotoFileName = fixPhotoFileName
        self.fixedAt = fixedAt
    }
}

// MARK: - Typed accessors

extension Report {
    var category: IssueCategory {
        get { IssueCategory(rawValue: categoryRaw) ?? .other }
        set { categoryRaw = newValue.rawValue }
    }

    var priority: PriorityLevel {
        get { PriorityLevel(rawValue: priorityRaw) ?? .medium }
        set { priorityRaw = newValue.rawValue }
    }

    var status: ReportStatus {
        get { ReportStatus(rawValue: statusRaw) ?? .open }
        set { statusRaw = newValue.rawValue }
    }

    var signals: [String] {
        get {
            guard let signalsJSON else { return [] }
            return (try? JSONDecoder().decode([String].self, from: signalsJSON)) ?? []
        }
        set { signalsJSON = Report.encodeSignals(newValue) }
    }

    /// SF Symbol for the UI when the photo asset is missing.
    var fallbackSymbol: String { category.fallbackSymbol }

    var voteCount: Int { votes.count }

    /// Photo to show in public views (feed, case detail). Only the redacted file, never the
    /// original; demo seed rows may use their bundled seed image. Nil → category placeholder.
    var displayPhotoFileName: String? {
        if let blurredPhotoFileName { return blurredPhotoFileName }
        return isDemoSeed ? photoFileName : nil
    }

    static func encodeSignals(_ signals: [String]) -> Data? {
        signals.isEmpty ? nil : try? JSONEncoder().encode(signals)
    }
}
