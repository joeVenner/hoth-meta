import Foundation

// Codable mirrors of the strict JSON schemas in `ios/HoTH/Resources/prompts.json`.
// prompts.json is the single source of truth; keep field names and enums in sync with it.

/// Report category (`categories` / `vision_analysis.category`).
public enum ReportCategory: String, Codable, CaseIterable, Sendable {
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
}

/// Severity level, ordered low < medium < high < critical.
public enum Severity: String, Codable, CaseIterable, Comparable, Sendable {
    case low, medium, high, critical

    var rank: Int {
        switch self {
        case .low: return 0
        case .medium: return 1
        case .high: return 2
        case .critical: return 3
        }
    }

    public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rank < rhs.rank }
}

/// Qualitative confidence word (never a number).
public enum QualitativeConfidence: String, Codable, Sendable {
    case low, medium, high
}

public enum HazardKind: String, Codable, CaseIterable, Sendable {
    case sharpEdge = "sharp_edge"
    case electrical, fall, trip, sanitation, traffic, drowning, other
}

public enum SceneType: String, Codable, CaseIterable, Sendable {
    case playground, park, street, sidewalk, residential
    case schoolArea = "school_area"
    case parking, other
}

/// Approximate highlight region, normalized 0...1 (x,y = top-left).
public struct NormalizedBox: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let w: Double
    public let h: Double

    public init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x; self.y = y; self.w = w; self.h = h
    }

    /// Builds a box from corner coordinates on a `width` x `height` grid (source pixels for SAM, 1000 x 1000
    /// for Muse Spark grounding). Corners are reordered and clamped, so slightly out-of-range values
    /// (models emit e.g. 1001 at an edge) still land inside 0...1.
    public static func fromCorners(x1: Double, y1: Double, x2: Double, y2: Double,
                                   width: Double, height: Double) -> NormalizedBox {
        guard width > 0, height > 0 else { return NormalizedBox(x: 0, y: 0, w: 0, h: 0) }
        func unit(_ value: Double, _ size: Double) -> Double { min(max(value / size, 0), 1) }
        let left = unit(min(x1, x2), width), right = unit(max(x1, x2), width)
        let top = unit(min(y1, y2), height), bottom = unit(max(y1, y2), height)
        return NormalizedBox(x: left, y: top, w: right - left, h: bottom - top)
    }
}

public struct Hazard: Codable, Equatable, Sendable {
    public let label: String
    public let kind: HazardKind
    public let box: NormalizedBox

    public init(label: String, kind: HazardKind, box: NormalizedBox) {
        self.label = label; self.kind = kind; self.box = box
    }
}

public struct PlausibilitySignals: Codable, Equatable, Sendable {
    public let showsReportedIssue: Bool
    public let looksLikeScreenOrPrint: Bool
    public let looksLikeStockOrWatermarked: Bool
    public let notes: String

    enum CodingKeys: String, CodingKey {
        case showsReportedIssue = "shows_reported_issue"
        case looksLikeScreenOrPrint = "looks_like_screen_or_print"
        case looksLikeStockOrWatermarked = "looks_like_stock_or_watermarked"
        case notes
    }

    public init(showsReportedIssue: Bool, looksLikeScreenOrPrint: Bool, looksLikeStockOrWatermarked: Bool, notes: String) {
        self.showsReportedIssue = showsReportedIssue
        self.looksLikeScreenOrPrint = looksLikeScreenOrPrint
        self.looksLikeStockOrWatermarked = looksLikeStockOrWatermarked
        self.notes = notes
    }
}

/// `vision_analyze.json_schema` (name `vision_analysis`).
public struct VisionAnalysis: Codable, Equatable, Sendable {
    public let category: ReportCategory
    public let titleEN: String
    public let titleAR: String
    public let descriptionEN: String
    public let descriptionAR: String
    public let hazards: [Hazard]
    public let childUseEquipment: Bool
    public let childPresent: Bool
    public let sceneType: SceneType
    public let severityProposal: Severity
    public let severityReasonEN: String
    public let severityReasonAR: String
    public let plausibility: PlausibilitySignals
    public let suggestedQuestions: [String]
    public let confidence: QualitativeConfidence

    enum CodingKeys: String, CodingKey {
        case category
        case titleEN = "title_en"
        case titleAR = "title_ar"
        case descriptionEN = "description_en"
        case descriptionAR = "description_ar"
        case hazards
        case childUseEquipment = "child_use_equipment"
        case childPresent = "child_present"
        case sceneType = "scene_type"
        case severityProposal = "severity_proposal"
        case severityReasonEN = "severity_reason_en"
        case severityReasonAR = "severity_reason_ar"
        case plausibility
        case suggestedQuestions = "suggested_questions"
        case confidence
    }

    public init(
        category: ReportCategory,
        titleEN: String = "",
        titleAR: String = "",
        descriptionEN: String = "",
        descriptionAR: String = "",
        hazards: [Hazard] = [],
        childUseEquipment: Bool = false,
        childPresent: Bool = false,
        sceneType: SceneType = .other,
        severityProposal: Severity = .low,
        severityReasonEN: String = "",
        severityReasonAR: String = "",
        plausibility: PlausibilitySignals = PlausibilitySignals(
            showsReportedIssue: true, looksLikeScreenOrPrint: false, looksLikeStockOrWatermarked: false, notes: ""),
        suggestedQuestions: [String] = [],
        confidence: QualitativeConfidence = .medium
    ) {
        self.category = category
        self.titleEN = titleEN
        self.titleAR = titleAR
        self.descriptionEN = descriptionEN
        self.descriptionAR = descriptionAR
        self.hazards = hazards
        self.childUseEquipment = childUseEquipment
        self.childPresent = childPresent
        self.sceneType = sceneType
        self.severityProposal = severityProposal
        self.severityReasonEN = severityReasonEN
        self.severityReasonAR = severityReasonAR
        self.plausibility = plausibility
        self.suggestedQuestions = suggestedQuestions
        self.confidence = confidence
    }

    public func hasHazard(_ kind: HazardKind) -> Bool { hazards.contains { $0.kind == kind } }
}

public struct RemainingIssue: Codable, Equatable, Sendable {
    public let label: String
    public let box: NormalizedBox
}

/// `fix_verify.json_schema` (name `fix_verification`).
public struct FixVerification: Codable, Equatable, Sendable {
    public let resolved: Bool
    public let reasonEN: String
    public let reasonAR: String
    public let remainingIssues: [RemainingIssue]
    public let sameLocationLikely: Bool

    enum CodingKeys: String, CodingKey {
        case resolved
        case reasonEN = "reason_en"
        case reasonAR = "reason_ar"
        case remainingIssues = "remaining_issues"
        case sameLocationLikely = "same_location_likely"
    }
}

/// `same_issue.json_schema` (name `same_issue_check`).
public struct SameIssueVerdict: Codable, Equatable, Sendable {
    public let sameIssue: Bool
    public let reason: String

    enum CodingKeys: String, CodingKey {
        case sameIssue = "same_issue"
        case reason
    }

    public init(sameIssue: Bool, reason: String) {
        self.sameIssue = sameIssue
        self.reason = reason
    }
}

/// Arguments of the Realtime `submit_report` tool (`realtime_tools[0].parameters`).
public struct SubmitReportArgs: Codable, Equatable, Sendable {
    public let summaryEN: String
    public let summaryAR: String
    public let answers: [String: String]
    public let userLanguage: String
    public let wantsToPost: Bool
    public let anonymous: Bool

    /// Builds the args locally (chat fallback, safety sheet) without a JSON round-trip.
    public init(summaryEN: String, summaryAR: String, answers: [String: String], userLanguage: String,
                wantsToPost: Bool, anonymous: Bool) {
        self.summaryEN = summaryEN
        self.summaryAR = summaryAR
        self.answers = answers
        self.userLanguage = userLanguage
        self.wantsToPost = wantsToPost
        self.anonymous = anonymous
    }

    enum CodingKeys: String, CodingKey {
        case summaryEN = "summary_en"
        case summaryAR = "summary_ar"
        case answers
        case userLanguage = "user_language"
        case wantsToPost = "wants_to_post"
        case anonymous
    }
}
