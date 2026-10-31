import Foundation

/// Where the issue is, from the vision scene plus an optional MapKit point of interest.
public enum LocationType: String, Codable, CaseIterable, Sendable {
    case playground, school, park, street, residential, unknown

    /// A known POI (within ~100 m) wins over the scene the model described.
    public init(scene: SceneType, poi: LocationType? = nil) {
        if let poi, poi != .unknown {
            self = poi
            return
        }
        switch scene {
        case .playground: self = .playground
        case .schoolArea: self = .school
        case .park: self = .park
        case .street, .sidewalk, .parking: self = .street
        case .residential: self = .residential
        case .other: self = .unknown
        }
    }

    var isChildZone: Bool { self == .playground || self == .school }
}

/// Everything the priority agent looks at.
public struct PriorityInput: Sendable {
    public let vision: VisionAnalysis
    /// Interview answers keyed by slot id (e.g. "sparking": "yes").
    public let answers: [String: String]
    /// Explicit flag; when nil the `children_using_now` answer is used.
    public let childUsingNow: Bool?
    public let durationDays: Int?
    public let location: LocationType
    /// On-device MapKit point of interest within ~100 m (P2-02); nil when unknown or not looked up.
    public let nearbyPlace: LocationType?
    public let confirmations: Int
    public let reportAgeHours: Double

    public init(
        vision: VisionAnalysis,
        answers: [String: String] = [:],
        childUsingNow: Bool? = nil,
        durationDays: Int? = nil,
        location: LocationType? = nil,
        nearbyPlace: LocationType? = nil,
        confirmations: Int = 0,
        reportAgeHours: Double = 0
    ) {
        self.vision = vision
        self.answers = answers
        self.childUsingNow = childUsingNow
        self.durationDays = durationDays
        self.nearbyPlace = nearbyPlace == .unknown ? nil : nearbyPlace
        self.location = location ?? LocationType(scene: vision.sceneType, poi: nearbyPlace)
        self.confirmations = confirmations
        self.reportAgeHours = reportAgeHours
    }
}

/// One explainable factor, shown as a chip on the ticket.
public struct Signal: Equatable, Sendable {
    public let id: String
    public let labelEN: String
    public let labelAR: String
    /// Score points this factor contributed.
    public let weight: Int
}

public struct PriorityDecision: Equatable, Sendable {
    public let level: Severity
    public let score: Int
    public let reasonEN: String
    public let reasonAR: String
    public let signals: [Signal]
    /// Label of the safety floor that set the level, e.g. "CRITICAL — child safety".
    public let floorApplied: String?
    /// True when the photo was judged not to show a neighbourhood issue.
    public let isFlagged: Bool
}

/// Hybrid triage: the LLM proposes, deterministic safety floors can only raise (pure, no I/O).
public enum PriorityAgent {
    public static let confirmationPoints = 6
    public static let confirmationCap = 30
    public static let longDurationDays = 7
    public static let longDurationPoints = 5

    /// Minimum score for each level; scores are clamped into the final level's band.
    public static func minimumScore(for level: Severity) -> Int {
        switch level {
        case .low: return 0
        case .medium: return 40
        case .high: return 60
        case .critical: return 80
        }
    }

    public static func level(forScore score: Int) -> Severity {
        if score >= minimumScore(for: .critical) { return .critical }
        if score >= minimumScore(for: .high) { return .high }
        if score >= minimumScore(for: .medium) { return .medium }
        return .low
    }

    static func baseScore(for level: Severity) -> Int {
        switch level {
        case .low: return 20
        case .medium: return 45
        case .high: return 65
        case .critical: return 85
        }
    }

    private struct Floor {
        let level: Severity
        let label: String
    }

    public static func decide(_ input: PriorityInput) -> PriorityDecision {
        let vision = input.vision
        let proposal = vision.severityProposal

        if vision.category == .notAnIssue {
            let signal = Signal(id: "not_an_issue", labelEN: "Not a neighbourhood issue",
                                labelAR: "ليست مشكلة في الحي", weight: 0)
            return PriorityDecision(
                level: .low, score: 0,
                reasonEN: "The photo does not show a neighbourhood issue — kept at low and flagged for review.",
                reasonAR: "الصورة لا تُظهر مشكلة في الحي — بقيت منخفضة وتم وضع علامة للمراجعة.",
                signals: [signal], floorApplied: nil, isFlagged: true)
        }

        var signals: [Signal] = []
        var floors: [Floor] = []

        let childUsingNow = input.childUsingNow ?? isAffirmative(input.answers["children_using_now"])
        let childContext = vision.childPresent || childUsingNow || input.location.isChildZone
        let contextSignals = childContextSignals(input: input, childUsingNow: childUsingNow)

        // Floor 1: broken child equipment with sharp edges or a fall risk.
        let hasSharp = vision.hasHazard(.sharpEdge)
        let hasFall = vision.hasHazard(.fall)
        if vision.childUseEquipment && (hasSharp || hasFall) {
            signals.append(Signal(
                id: "child_equipment_hazard",
                labelEN: hasSharp ? "Sharp metal on equipment children use" : "Fall risk on equipment children use",
                labelAR: hasSharp ? "معدن حاد في لعبة يستخدمها الأطفال" : "خطر سقوط في لعبة يستخدمها الأطفال",
                weight: 15))
            floors.append(Floor(level: .high, label: "HIGH — child equipment"))
            if childContext {
                signals.append(contentsOf: contextSignals)
                floors.append(Floor(level: .critical, label: "CRITICAL — child safety"))
            }
        }

        // Floor 2: an open manhole is always critical.
        if vision.category == .openManhole {
            signals.append(Signal(id: "open_manhole", labelEN: "Open manhole", labelAR: "فتحة صرف مكشوفة", weight: 30))
            floors.append(Floor(level: .critical, label: "CRITICAL — open manhole"))
        }

        // Floor 3: electrical hazard.
        if vision.hasHazard(.electrical) || vision.category == .electricalHazard {
            signals.append(Signal(id: "electrical", labelEN: "Electrical hazard", labelAR: "خطر كهربائي", weight: 15))
            floors.append(Floor(level: .high, label: "HIGH — electrical"))
            let sparking = isAffirmative(input.answers["sparking"])
            let nearWater = isAffirmative(input.answers["near_water"])
            if sparking {
                signals.append(Signal(id: "sparking", labelEN: "Sparking reported", labelAR: "تم الإبلاغ عن شرارة", weight: 15))
            }
            if nearWater {
                signals.append(Signal(id: "near_water", labelEN: "Water nearby", labelAR: "يوجد ماء قريب", weight: 15))
            }
            if childContext || sparking || nearWater {
                for signal in contextSignals where !signals.contains(signal) { signals.append(signal) }
                floors.append(Floor(level: .critical, label: "CRITICAL — electrical danger"))
            }
        }

        // Nearby place (P2-02): an informational chip so the resident sees why the location matters.
        // Weight 0: a child-zone place already raises the level through the floors above.
        if let place = input.nearbyPlace, !signals.contains(where: { $0.id.hasPrefix("location_") }),
           let chip = nearbyPlaceSignal(place) {
            signals.append(chip)
        }

        // Community and time signals (score only).
        if input.confirmations > 0 {
            let points = min(input.confirmations * confirmationPoints, confirmationCap)
            let count = input.confirmations
            signals.append(Signal(
                id: "confirmations",
                labelEN: count == 1 ? "1 neighbour confirmed" : "\(count) neighbours confirmed",
                labelAR: "أكّد \(count) من الجيران",
                weight: points))
        }
        if let days = input.durationDays, days > longDurationDays {
            signals.append(Signal(id: "long_duration", labelEN: "Ongoing for \(days) days",
                                  labelAR: "مستمرة منذ \(days) يوم", weight: longDurationPoints))
        }
        if input.reportAgeHours >= 48 {
            // Informational only: age is shown but does not change the score.
            let days = Int(input.reportAgeHours / 24)
            signals.append(Signal(id: "report_age", labelEN: "Open for \(days) days",
                                  labelAR: "مفتوحة منذ \(days) يوم", weight: 0))
        }

        let rawScore = baseScore(for: proposal) + signals.reduce(0) { $0 + $1.weight }
        let strongestFloor = floors.max { $0.level < $1.level }
        let floorLevel = strongestFloor?.level ?? .low
        let level = max(proposal, floorLevel, level(forScore: min(rawScore, 100)))
        let score = clamp(rawScore, to: level)
        let floorApplied = (strongestFloor.map { $0.level == level } ?? false) ? strongestFloor?.label : nil

        let reasons = buildReasons(signals: signals, vision: vision, proposal: proposal, level: level)
        return PriorityDecision(level: level, score: score, reasonEN: reasons.en, reasonAR: reasons.ar,
                                signals: signals, floorApplied: floorApplied, isFlagged: false)
    }

    // MARK: Helpers

    static func nearbyPlaceSignal(_ place: LocationType) -> Signal? {
        switch place {
        case .playground:
            return Signal(id: "location_playground", labelEN: "Near a playground", labelAR: "قرب ملعب أطفال", weight: 0)
        case .school:
            return Signal(id: "location_school", labelEN: "Near a school", labelAR: "قرب مدرسة", weight: 0)
        case .park:
            return Signal(id: "location_park", labelEN: "In a park", labelAR: "في حديقة", weight: 0)
        case .street, .residential, .unknown:
            return nil
        }
    }

    private static func childContextSignals(input: PriorityInput, childUsingNow: Bool) -> [Signal] {
        var result: [Signal] = []
        switch input.location {
        case .playground:
            result.append(Signal(id: "location_playground", labelEN: "In a playground", labelAR: "في ملعب أطفال", weight: 15))
        case .school:
            result.append(Signal(id: "location_school", labelEN: "Near a school", labelAR: "قرب مدرسة", weight: 15))
        default:
            break
        }
        if childUsingNow {
            result.append(Signal(id: "children_using_now", labelEN: "Children using it now",
                                 labelAR: "أطفال يستخدمونها الآن", weight: 15))
        } else if input.vision.childPresent {
            result.append(Signal(id: "child_present", labelEN: "A child is in the photo",
                                 labelAR: "يظهر طفل في الصورة", weight: 15))
        }
        return result
    }

    private static func clamp(_ score: Int, to level: Severity) -> Int {
        let lower = minimumScore(for: level)
        let upper: Int
        switch level {
        case .low: upper = minimumScore(for: .medium) - 1
        case .medium: upper = minimumScore(for: .high) - 1
        case .high: upper = minimumScore(for: .critical) - 1
        case .critical: upper = 100
        }
        return min(max(score, lower), upper)
    }

    static func isAffirmative(_ answer: String?) -> Bool {
        guard let text = answer?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !text.isEmpty else {
            return false
        }
        let prefixes = ["yes", "yeah", "yep", "y", "true", "نعم", "ايه", "إيه", "اي", "إي", "أيوه", "ايوه", "اكيد", "أكيد"]
        let firstWord = text.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "." || $0 == "،" }).first.map(String.init) ?? text
        return prefixes.contains(firstWord)
    }

    static func arabicName(_ level: Severity) -> String {
        switch level {
        case .low: return "منخفضة"
        case .medium: return "متوسطة"
        case .high: return "عالية"
        case .critical: return "حرجة"
        }
    }

    private static func buildReasons(signals: [Signal], vision: VisionAnalysis, proposal: Severity, level: Severity) -> (en: String, ar: String) {
        let reasonSignals = signals.filter { $0.id != "report_age" }
        let escalated = level > proposal
        let tailEN = escalated ? "escalated to \(level.rawValue)." : "rated \(level.rawValue)."
        let tailAR = escalated ? "تم رفعها إلى \(arabicName(level))." : "الأولوية \(arabicName(level))."

        guard !reasonSignals.isEmpty else {
            let en = vision.severityReasonEN.isEmpty ? "Based on the photo — \(tailEN)" : "\(vision.severityReasonEN) — \(tailEN)"
            let ar = vision.severityReasonAR.isEmpty ? "بناءً على الصورة — \(tailAR)" : "\(vision.severityReasonAR) — \(tailAR)"
            return (en, ar)
        }
        let fragmentsEN = reasonSignals.enumerated().map { index, signal in
            index == 0 ? signal.labelEN : lowercasingFirst(signal.labelEN)
        }
        let en = fragmentsEN.joined(separator: ", ") + " — " + tailEN
        let ar = reasonSignals.map(\.labelAR).joined(separator: "، ") + " — " + tailAR
        return (en, ar)
    }

    private static func lowercasingFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.lowercased() + text.dropFirst()
    }
}
