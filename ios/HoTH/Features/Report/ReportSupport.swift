import Foundation
import HoTHCore
import OSLog
import UIKit

// MARK: - Routing

/// Local routing table: which (generic) team receives a ticket. No real agency codes.
enum ReportRouting {
    struct Team: Equatable {
        let nameEN: String
        let nameAR: String
        let symbol: String

        func name(arabic: Bool) -> String { arabic ? nameAR : nameEN }
    }

    static let parks = Team(nameEN: "Parks & Recreation", nameAR: "الحدائق والترفيه", symbol: "tree.fill")
    static let roads = Team(nameEN: "Roads & Infrastructure", nameAR: "الطرق والبنية التحتية", symbol: "road.lanes")
    static let electrical = Team(nameEN: "Electrical Utility", nameAR: "مرفق الكهرباء", symbol: "bolt.fill")
    static let waste = Team(nameEN: "Waste Management", nameAR: "إدارة النفايات", symbol: "trash.fill")
    static let safety = Team(nameEN: "Community Safety", nameAR: "سلامة المجتمع", symbol: "figure.roll")

    static func team(for category: ReportCategory) -> Team {
        switch category {
        case .playgroundEquipment, .fitnessEquipment: return parks
        case .potholePavement, .openManhole, .waterLeak: return roads
        case .electricalHazard: return electrical
        case .wasteOverflowDumping: return waste
        case .blockedAccessibility, .other, .notAnIssue: return safety
        }
    }
}

// MARK: - Ticket number

enum TicketNumber {
    /// Stable "HOTH-1234" derived from the report UUID bytes (never `hashValue`, which is per-process).
    static func make(for id: UUID) -> String {
        let bytes = id.uuid
        let value = (Int(bytes.0) << 16) | (Int(bytes.1) << 8) | Int(bytes.2)
        return "HOTH-\(1000 + value % 9000)"
    }
}

// MARK: - SubmitReportArgs construction

/// Builds `SubmitReportArgs` for locally finished interviews. Uses the core memberwise init, so there is
/// no JSON round-trip that could fail at runtime (previously a `fatalError` on schema drift).
enum SubmitReportArgsFactory {
    static func make(summaryEN: String, summaryAR: String, answers: [String: String], userLanguage: String,
                     wantsToPost: Bool, anonymous: Bool) -> SubmitReportArgs {
        SubmitReportArgs(summaryEN: summaryEN, summaryAR: summaryAR, answers: answers,
                         userLanguage: userLanguage, wantsToPost: wantsToPost, anonymous: anonymous)
    }
}

// MARK: - Answers

enum AnswerParsing {
    private static let affirmatives: Set<String> = [
        "yes", "yeah", "yep", "y", "true", "sure", "نعم", "ايه", "إيه", "اي", "إي", "أيوه", "ايوه", "اكيد", "أكيد", "ايوا",
    ]

    /// True when the first word of the answer is a yes (English or Arabic).
    static func isAffirmative(_ answer: String?) -> Bool {
        guard let text = answer?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !text.isEmpty else {
            return false
        }
        let separators: Set<Character> = [" ", ",", ".", "،", "!"]
        let firstWord = text.split(whereSeparator: { separators.contains($0) }).first.map(String.init) ?? text
        return affirmatives.contains(firstWord)
    }
}

// MARK: - Confirmed reports

/// Report ids the current user has confirmed (merge or "I saw it too"), shared with `CaseDetailView`'s
/// `@AppStorage` so confirmation points are paid once per report.
enum ConfirmedReports {
    static let storageKey = "hoth.confirmedReportIDs"

    static func contains(_ id: UUID, defaults: UserDefaults = .standard) -> Bool {
        ids(defaults).contains(id.uuidString)
    }

    /// Records the id; returns false when it was already recorded.
    @discardableResult
    static func insert(_ id: UUID, defaults: UserDefaults = .standard) -> Bool {
        var current = ids(defaults)
        guard !current.contains(id.uuidString) else { return false }
        current.append(id.uuidString)
        defaults.set(current.joined(separator: ","), forKey: storageKey)
        return true
    }

    private static func ids(_ defaults: UserDefaults) -> [String] {
        (defaults.string(forKey: storageKey) ?? "").split(separator: ",").map(String.init)
    }
}

// MARK: - Photo files

/// Saves report photos in the app Documents directory (the feed loads them by file name).
enum ReportPhotoFiles {
    private static let logger = Logger(subsystem: "io.fomy.hoth", category: "ReportPhotoFiles")

    /// Writes JPEG data and returns the file name, or nil on failure (logged).
    static func save(_ data: Data, named fileName: String) -> String? {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            logger.error("No Documents directory")
            return nil
        }
        do {
            try data.write(to: documents.appendingPathComponent(fileName), options: [.atomic, .completeFileProtection])
            return fileName
        } catch {
            logger.error("Saving \(fileName, privacy: .public) failed: \(error.localizedDescription)")
            return nil
        }
    }

    static func save(_ image: UIImage, named fileName: String) -> String? {
        guard let data = image.jpegData(compressionQuality: 0.85) else { return nil }
        return save(data, named: fileName)
    }

    static func loadJPEG(_ fileName: String?) -> Data? {
        guard let fileName, !fileName.isEmpty else { return nil }
        if let asset = UIImage(named: fileName) { return asset.jpegData(compressionQuality: 0.8) }
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        return try? Data(contentsOf: documents.appendingPathComponent(fileName))
    }
}
